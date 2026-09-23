from __future__ import annotations

import pytest
from sqlalchemy import select

import app.db as db_module
from app.llm.base import LLMError
from app.llm.factory import get_checker_client, get_extractor_client, get_memory_selector_client, get_writer_client
from app.models import Chapter, ChapterDraftCandidate, JobRun
from app.services.write_jobs import WriteJob, write_registry


def stored_candidates(chapter_id: str) -> list[dict]:
    """Inspect backend-only candidate audit records without a public API."""
    db = db_module.SessionLocal()
    try:
        rows = db.scalars(
            select(ChapterDraftCandidate)
            .where(ChapterDraftCandidate.chapter_id == chapter_id)
            .order_by(ChapterDraftCandidate.created_at, ChapterDraftCandidate.id)
        ).all()
        return [
            {
                "id": row.id,
                "attempt": row.attempt,
                "draft_text": row.draft_text,
                "deterministic_violations": row.deterministic_violations,
                "checker_result": row.checker_result,
                "bible_sha256": row.bible_sha256,
                "draft_fingerprint": row.draft_fingerprint,
                "checker_input_fingerprint": row.checker_input_fingerprint,
                "is_current": row.is_current,
            }
            for row in rows
        ]
    finally:
        db.close()


class TextLLM:
    def __init__(self, text: str) -> None:
        self.text = text
        self.calls = 0
        self.last_finish_reason = "stop"

    def complete_stream(self, **kwargs):
        self.calls += 1
        yield from self.text

    def complete(self, **kwargs):
        self.calls += 1
        return self.text

    def complete_json(self, **kwargs):
        return {"briefs": [], "conflicts": [], "previous_ending_start_id": None}


def test_memory_manifest_reports_actual_packed_brief_count(client, auth_headers, wait_for_terminal):
    class OneBriefSelector:
        def complete_json(self, **kwargs):
            user = kwargs["user"]
            start = user.index("[chapter:") + 1
            source_id = user[start : user.index("]", start)]
            return {
                "briefs": [{"text": "旧事实仍然成立", "source_ids": [source_id]}],
                "conflicts": [],
                "previous_ending_start_id": None,
            }

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    prior = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "旧章"},
    ).json()
    db = db_module.SessionLocal()
    try:
        prior_row = db.get(Chapter, prior["id"])
        assert prior_row is not None
        prior_row.status = "finalized"
        prior_row.long_summary = "历史事实"
        prior_row.draft_text = "上一章结尾"
        db.commit()
    finally:
        db.close()
    current = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "沿用旧事实"},
    ).json()
    client.app.dependency_overrides[get_memory_selector_client] = lambda: OneBriefSelector()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)

    readiness = client.get(
        f"/api/v1/chapters/{current['id']}/production-readiness", headers=auth_headers
    ).json()
    client.post(
        f"/api/v1/chapters/{current['id']}/write", headers=auth_headers,
        json={"acknowledged_context_token": readiness["context_token"]},
    ).raise_for_status()
    status = wait_for_terminal(client, current["id"], auth_headers)
    assert status["phase"] == "done"
    assert status["memory_context"]["memory_non_whitespace_count"] == len("旧事实仍然成立")
    assert len(status["memory_context"]["memory_brief"]) == 1
    assert len(status["memory_context"]["sources"]) == 1


class SequenceTextLLM(TextLLM):
    def __init__(self, texts: list[str], finish_reasons: list[str] | None = None) -> None:
        super().__init__(texts[-1])
        self.texts = texts
        self.finish_reasons = finish_reasons or ["stop"] * len(texts)
        self.users: list[str] = []

    def _next(self) -> str:
        index = min(self.calls, len(self.texts) - 1)
        self.last_finish_reason = self.finish_reasons[min(index, len(self.finish_reasons) - 1)]
        self.calls += 1
        return self.texts[index]

    def complete_stream(self, **kwargs):
        self.users.append(kwargs["user"])
        yield from self._next()

    def complete(self, **kwargs):
        self.users.append(kwargs["user"])
        return self._next()


def test_bearer_token_required(client):
    assert client.get("/api/v1/health").status_code == 401


def test_every_route_requires_the_bearer_token(client):
    # A new router mounted without `dependencies=deps` would otherwise ship
    # unauthenticated; this walks the real route table instead of a fixed list.
    from fastapi.routing import APIRoute

    unprotected = []
    for route in client.app.routes:
        if not isinstance(route, APIRoute):
            continue
        method = "GET" if "GET" in route.methods else sorted(route.methods)[0]
        path = route.path
        for name in route.param_convertors:
            path = path.replace("{" + name + "}", "probe")
        response = client.request(method, path)
        if response.status_code != 401:
            unprotected.append((method, route.path, response.status_code))
    assert unprotected == []


def test_non_ascii_authorization_header_is_rejected_not_crashed(client):
    # Starlette decodes headers as latin-1 and hmac.compare_digest raises
    # TypeError on non-ASCII str, which used to escape as an unauthenticated
    # 500 that anyone could trigger from the public entrypoint.
    # Sent as raw bytes: an httpx str header would be rejected client-side,
    # while curl puts these bytes on the wire without complaint.
    response = client.get(
        "/api/v1/health", headers=[(b"authorization", b"Bearer \xc3\xa9")]
    )
    assert response.status_code == 401


def test_schema_and_interactive_docs_are_not_exposed(client):
    for path in ("/openapi.json", "/docs", "/redoc"):
        assert client.get(path).status_code == 404, path


def test_health_requires_the_schema_to_match_the_shipped_head(client, auth_headers):
    import app.db as db_module
    from sqlalchemy import text

    assert client.get("/api/v1/health", headers=auth_headers).status_code == 200
    with db_module.engine.begin() as connection:
        connection.execute(text("UPDATE alembic_version SET version_num = 'not-the-head'"))
    stale = client.get("/api/v1/health", headers=auth_headers)
    assert stale.status_code == 503
    assert stale.json()["detail"]["code"] == "schema_out_of_date"


def test_books_characters_chapters_flow_and_legacy_author_note(client, auth_headers):
    book = client.post(
        "/api/v1/books", headers=auth_headers, json={"title": "云上书", "world_setting": "天穹有两个月亮。"}
    ).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "role": "主角", "fixed_profile": "谨慎。"},
    ).json()
    pytest.character_id = character["id"]
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={
            "title": "第一章",
            "user_prompt": "林夕进入废城。",
            "chapter_style": "短句为主，冷静克制。",
            "character_links": [{"character_id": character["id"], "chapter_note": "旧客户端字段"}],
        },
    ).json()
    assert chapter["author_note"] == "短句为主，冷静克制。"
    assert chapter["chapter_style"] == chapter["author_note"]
    assert chapter["exempted_character_names"] == []
    assert chapter["character_links"] == [{"character_id": character["id"], "chapter_note": ""}]


def test_patch_chapter_can_add_and_resend_character_links(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕"},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "第一章"},
    ).json()
    links = [{"character_id": character["id"]}]

    added = client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"character_links": links},
    )
    assert added.status_code == 200
    assert added.json()["character_links"] == [{"character_id": character["id"], "chapter_note": ""}]

    resent = client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"character_links": links},
    )
    assert resent.status_code == 200
    assert resent.json()["character_links"] == added.json()["character_links"]


def test_accept_success_and_reaccept_replaces_events(client, auth_headers, wait_for_terminal):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "role": "主角", "fixed_profile": "谨慎。"},
    ).json()
    pytest.character_id = character["id"]
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动。", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "林夕行动。"}
    ).raise_for_status()

    accepted = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers, json={"override_checker": True})
    assert accepted.status_code == 200
    assert accepted.json()["phase"] == "extracting"
    assert accepted.json()["job_id"]
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "done"
    assert status["outcome_current"] is True
    assert status["chapter"]["status"] == "finalized"

    client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers).raise_for_status()
    stale = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert stale["phase"] == "done"
    assert stale["outcome_current"] is False
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers, json={"override_checker": True}).status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    events = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"]
    assert len(events) == 1


def test_extractor_rejects_unknown_character_name_without_partial_writes(client, auth_headers, wait_for_terminal):
    class MixedExtractor:
        def complete_json(self, **kwargs):
            return {
                "long_summary": "梗概",
                "headline": "大事",
                "state_changes": [],
                "unresolved_items": [],
                "atomic_memories": [],
                "character_events": [
                    {
                        "character_name": "林夕",
                        "event_type": "行动",
                        "event_text": "林夕完成行动。",
                        "evidence": "林夕完成行动。",
                    },
                    {
                        "character_name": "未知人物",
                        "event_type": "行动",
                        "event_text": "未知人物完成行动。",
                        "evidence": "未知人物完成行动。",
                    },
                ],
                "dynamic_fields_patch": [],
            }

    client.app.dependency_overrides[get_extractor_client] = lambda: MixedExtractor()
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    pytest.character_id = character["id"]
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "林夕完成行动。未知人物完成行动。"},
    )
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers, json={"override_checker": True}).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    assert client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"] == []


def test_malformed_archive_keeps_accepted_prose_and_marks_archive_partial(client, auth_headers, wait_for_terminal):
    class BadExtractor:
        def complete_json(self, **kwargs):
            return {
                "long_summary": "梗概",
                "headline": "大事",
                "state_changes": [],
                "unresolved_items": [],
                "atomic_memories": [],
                "character_events": [{}],
                "dynamic_fields_patch": [],
            }

    client.app.dependency_overrides[get_extractor_client] = lambda: BadExtractor()
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    pytest.character_id = character["id"]
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "旧稿"})
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers, json={"override_checker": True}).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    assert status["job_id"]
    assert status["outcome_current"] is True
    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert current["status"] == "finalized"
    assert current["archive"]["status"] == "partial"
    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"character_links": []},
    ).raise_for_status()
    stale = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert stale["phase"] == "failed"
    assert stale["outcome_current"] is False


def test_writer_defers_longest_name_and_unselected_identity_to_checker(client, auth_headers, wait_for_terminal):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    short = client.post(f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林"}).json()
    long = client.post(f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "林夕进入废城", "target_word_count": 20, "character_links": [{"character_id": long["id"]}]},
    ).json()
    writer = TextLLM("文" * 4000)
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    started = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    assert started.status_code == 200
    assert started.json()["phase"] == "writing"
    # The selected longer name is a permitted identity.  v2.2 delegates the
    # semantic result to Checker instead of rejecting it with a substring
    # preflight before Writer runs.
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    bad = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "林进入废城", "character_links": [{"character_id": long["id"]}]},
    ).json()
    response = client.post(f"/api/v1/chapters/{bad['id']}/write", headers=auth_headers)
    assert response.status_code == 200
    # The default fake Checker deliberately cannot classify the remaining
    # unselected one-character use, but the pipeline has started and reaches
    # a terminal Checker outcome rather than being blocked by local matching.
    assert wait_for_terminal(client, bad["id"], auth_headers)["phase"] == "failed"
    assert short["id"] != long["id"]


def test_short_draft_rewrites_once_from_identical_input_and_preserves_candidates(client, auth_headers, wait_for_terminal):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}).json()
    writer = SequenceTextLLM(["短", "全" * 4000])
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    assert client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "done" and writer.calls == 2
    assert writer.users[0] == writer.users[1]
    candidates = stored_candidates(chapter["id"])
    assert [item["attempt"] for item in candidates] == [1, 2]


def test_checker_violation_stays_backend_only_and_does_not_replace_visible_draft(client, auth_headers, wait_for_terminal):
    class ViolationChecker:
        def complete_json(self, **kwargs):
            return {"verdict": "violation", "issues": [{
                "kind": "missing_requirement", "draft_evidence": "", "bible_evidence": "行动",
                "reason": "缺少要求的行动", "source_kind": "bible", "source_id": "bible", "source_evidence": "行动",
            }], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}).json()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: ViolationChecker()
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    assert status["error_code"] == "checker_rejected"
    assert status["checker_result"]["verdict"] == "violation"
    assert "缺少要求的行动" in status["error_message"]
    assert "draft_candidate" not in status
    assert ("文" * 4000) not in client.get(
        f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers
    ).text
    visible = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert visible["draft_text"] == ""
    assert visible["status"] == "draft"
    # The verdict and its reasons explain the failure; the verbatim excerpts
    # quote a candidate the author never saw and must not cross the wire.
    wire_issue = status["checker_result"]["issues"][0]
    assert wire_issue == {"kind": "missing_requirement", "reason": "缺少要求的行动"}
    job_text = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).text
    assert "正文证据" not in job_text
    assert "Bible证据" not in job_text

    candidates = stored_candidates(chapter["id"])
    assert len(candidates) == 1
    assert candidates[0]["draft_text"] == "文" * 4000
    assert candidates[0]["checker_result"]["verdict"] == "violation"
    assert candidates[0]["is_current"] is False
    # The audit trail keeps the full record server-side.
    assert candidates[0]["checker_result"]["issues"][0]["draft_evidence"] == ""
    assert candidates[0]["checker_result"]["issues"][0]["bible_evidence"] == "行动"
    assert client.get(f"/api/v1/chapters/{chapter['id']}/candidates", headers=auth_headers).status_code == 404
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/candidates/select",
        headers=auth_headers,
        json={"candidate_id": candidates[0]["id"]},
    ).status_code == 404


def test_deterministic_failure_keeps_candidate_backend_only_and_restores_visible_baseline(
    client, auth_headers, wait_for_terminal
):
    class RecordingChecker:
        def __init__(self):
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            return {"verdict": "passed", "issues": [], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    allowed = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "许知"},
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕"},
    ).raise_for_status()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "character_links": [{"character_id": allowed["id"]}]},
    ).json()
    checker = RecordingChecker()
    baseline = "许知" + "文" * 3998
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM(baseline)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    rejected = "林夕" + "文" * 3998
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM(rejected)
    client.post(
        f"/api/v1/chapters/{chapter['id']}/write",
        headers=auth_headers,
        json={"replace_draft": True},
    ).raise_for_status()
    failed = wait_for_terminal(client, chapter["id"], auth_headers)
    assert failed["phase"] == "failed"
    assert failed["error_code"] == "checker_invalid_response"
    assert failed["visible_checker_result"]["verdict"] == "passed"

    visible = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert visible["draft_text"] == baseline
    candidates = stored_candidates(chapter["id"])
    assert len(candidates) == 2
    assert candidates[0]["draft_text"] == baseline and candidates[0]["is_current"] is True
    assert candidates[1]["draft_text"] == rejected and candidates[1]["is_current"] is False
    assert candidates[1]["deterministic_violations"] == []
    assert checker.calls == 2


def test_manual_edit_recheck_preserves_generated_candidate_and_creates_next_attempt(client, auth_headers, wait_for_terminal):
    class RecordingChecker:
        def __init__(self):
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            return {"verdict": "passed", "issues": [], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}).json()
    checker = RecordingChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("初" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    old = stored_candidates(chapter["id"])[0]

    client.patch(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers, json={"draft_text": "改" * 4000}).raise_for_status()
    rerun = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    assert rerun.status_code == 200
    assert rerun.json()["finish_reason"] == "manual_edit"
    assert rerun.json()["draft_text"] == ""
    candidates = stored_candidates(chapter["id"])
    assert len(candidates) == 2
    assert candidates[0]["id"] == old["id"] and candidates[0]["draft_text"] == "初" * 4000
    assert candidates[0]["is_current"] is False
    assert candidates[0]["checker_result"] == old["checker_result"]
    assert candidates[1]["draft_text"] == "改" * 4000
    assert candidates[1]["attempt"] == old["attempt"] + 1
    assert candidates[1]["is_current"] is True
    assert checker.calls == 2

    accepted = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers)
    assert accepted.status_code == 200
    assert accepted.json()["phase"] == "extracting"
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"


def test_manual_recheck_allows_short_author_text_for_checker(client, auth_headers, wait_for_terminal):
    class RecordingChecker:
        def __init__(self):
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            return {"verdict": "passed", "issues": [], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}).json()
    checker = RecordingChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    client.patch(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers, json={"draft_text": "太短"}).raise_for_status()

    response = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    assert response.status_code == 200
    assert response.json()["checker_result"]["verdict"] == "passed"
    assert checker.calls == 2


def test_checker_override_survives_extractor_failure_and_is_scoped_to_exact_draft(
    client, auth_headers, wait_for_terminal
):
    class ViolationChecker:
        def complete_json(self, **_kwargs):
            return {
                "verdict": "violation",
                "issues": [{
                    "kind": "missing_requirement", "draft_evidence": "", "bible_evidence": "行动",
                    "reason": "缺少要求的行动", "source_kind": "bible", "source_id": "bible", "source_evidence": "行动",
                }], "name_uses": [],
            }

    class FailingExtractor:
        def complete_json(self, **_kwargs):
            raise RuntimeError("extract failed")

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动"},
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("初" * 4000)
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    edited_text = "改" * 4000
    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"draft_text": edited_text},
    ).raise_for_status()
    client.app.dependency_overrides[get_checker_client] = lambda: ViolationChecker()
    checked = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    assert checked.status_code == 200
    assert checked.json()["checker_result"]["verdict"] == "violation"

    successful_extractor_factory = client.app.dependency_overrides[get_extractor_client]
    client.app.dependency_overrides[get_extractor_client] = lambda: FailingExtractor()
    accepted = client.post(
        f"/api/v1/chapters/{chapter['id']}/accept",
        headers=auth_headers,
        json={"override_checker": True},
    )
    assert accepted.status_code == 200
    assert accepted.json()["checker_result"]["override"] is True
    failed = wait_for_terminal(client, chapter["id"], auth_headers)
    assert failed["phase"] == "failed"
    assert failed["checker_result"]["override"] is True

    # A pre-v2.2 override that lacks a frozen production-input fingerprint
    # cannot be reused after history/projection could have changed.
    db = db_module.SessionLocal()
    try:
        legacy_run = db.get(JobRun, failed["job_id"])
        assert legacy_run is not None
        legacy_run.draft_fingerprint = None
        legacy_run.checker_result = {"override": True}
        db.commit()
    finally:
        db.close()

    # An already-finalized manuscript may retry its archive, but the new run
    # does not claim that the unscoped old Checker override is still current.
    client.app.dependency_overrides[get_extractor_client] = successful_extractor_factory
    retry = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers)
    assert retry.status_code == 200
    assert retry.json()["checker_result"] is None
    retried = wait_for_terminal(client, chapter["id"], auth_headers)
    assert retried["phase"] == "done"
    assert retried["checker_result"] is None

    # Any later input edit changes the full fingerprint and invalidates the
    # old approval instead of silently accepting a different manuscript.
    client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers).raise_for_status()
    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"draft_text": "另" * 4000},
    ).raise_for_status()
    stale_retry = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers)
    assert stale_retry.status_code == 409
    assert stale_retry.json()["detail"]["code"] == "checker_override_required"


def test_checker_fingerprint_requires_recheck_after_world_or_selected_character_changes(client, auth_headers, wait_for_terminal):
    book = client.post(
        "/api/v1/books", headers=auth_headers, json={"title": "书", "world_setting": "旧世界观"}
    ).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "fixed_profile": "旧设定", "dynamic_fields": {"状态": "旧"}},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    assert client.get(
        f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers
    ).json()["visible_checker_result"]["verdict"] == "passed"
    original = stored_candidates(chapter["id"])[0]

    client.patch(f"/api/v1/books/{book['id']}", headers=auth_headers, json={"world_setting": "新世界观"}).raise_for_status()
    assert client.get(
        f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers
    ).json()["visible_checker_result"] is None
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).status_code == 409
    world_recheck = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    assert world_recheck.status_code == 200
    assert world_recheck.json()["input_fingerprint"] != original["checker_input_fingerprint"]

    client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"name": "林夕改名", "fixed_profile": "新设定", "dynamic_fields": {"状态": "新"}},
    ).raise_for_status()
    assert client.get(
        f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers
    ).json()["visible_checker_result"] is None
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).status_code == 409
    character_recheck = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    assert character_recheck.status_code == 200
    assert character_recheck.json()["input_fingerprint"] != world_recheck.json()["input_fingerprint"]


def test_patch_of_finalized_content_reopens_and_requires_a_current_checker(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("旧" * 4000)
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["status"] == "finalized"

    patched = client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers,
        json={"draft_text": "新" * 4000},
    )
    assert patched.status_code == 200
    assert patched.json()["status"] == "draft_ready"
    accepted = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers)
    assert accepted.status_code == 409
    assert accepted.json()["detail"]["code"] == "checker_override_required"


def test_delete_only_removes_the_last_chapter_and_stays_idempotent(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapters = [
        client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": str(i)}).json()
        for i in range(3)
    ]
    rejected = client.delete(f"/api/v1/chapters/{chapters[1]['id']}", headers=auth_headers)
    assert rejected.status_code == 409
    assert rejected.json()["detail"]["code"] == "chapter_not_last"
    assert rejected.json()["detail"]["details"] == {"index": 2, "last_index": 3}
    # A refused delete leaves the book exactly as it was, chapter and all.
    listed = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    assert [item["index"] for item in listed] == [1, 2, 3]
    assert client.get(f"/api/v1/chapters/{chapters[1]['id']}", headers=auth_headers).status_code == 200

    assert client.delete(f"/api/v1/chapters/{chapters[2]['id']}", headers=auth_headers).status_code == 204
    listed = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    assert [item["index"] for item in listed] == [1, 2]
    # Idempotence outranks the gate: a retried delete of an id that is already
    # gone must not come back as "not the last chapter".
    assert client.delete(f"/api/v1/chapters/{chapters[2]['id']}", headers=auth_headers).status_code == 204


def test_duplicate_character_name_starts_writer_and_requires_checker_classification(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    first = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    client.post(f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"})
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "林夕进入废城", "character_links": [{"character_id": first["id"]}]},
    ).json()
    response = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    assert response.status_code == 200
    # The fixture Checker cannot classify this ambiguity, but the semantic
    # Checker path must reach a terminal result before fixture teardown.
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "failed"


@pytest.mark.parametrize("terminal_verdict", ["passed", "violation"])
def test_checker_retry_requires_the_candidate_latest_attempt(
    client, auth_headers, wait_for_terminal, terminal_verdict
):
    class RetryChecker:
        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            if self.calls == 1:
                # Missing name_uses is a safe unavailable Checker outcome.
                return {"verdict": "passed", "issues": []}
            if terminal_verdict == "passed":
                return {"verdict": "passed", "issues": [], "name_uses": []}
            return {
                "verdict": "violation",
                "issues": [{
                    "kind": "missing_requirement", "reason": "缺少要求的行动",
                    "draft_evidence": "", "bible_evidence": "行动",
                    "source_kind": "bible", "source_id": "bible", "source_evidence": "行动",
                }],
                "name_uses": [],
            }

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    checker = RetryChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    initial = wait_for_terminal(client, chapter["id"], auth_headers)
    assert initial["phase"] == "failed"
    assert initial["can_retry_checker"] is True
    source_job_id = initial["checker_source_job_id"]

    retried = client.post(
        f"/api/v1/chapters/{chapter['id']}/checker/retry", headers=auth_headers,
        json={"source_job_id": source_job_id},
    )
    assert retried.status_code == 200
    settled = wait_for_terminal(client, chapter["id"], auth_headers)
    assert settled["phase"] == ("done" if terminal_verdict == "passed" else "failed")
    assert settled["can_retry_checker"] is False
    assert settled["checker_source_job_id"] is None

    repeated = client.post(
        f"/api/v1/chapters/{chapter['id']}/checker/retry", headers=auth_headers,
        json={"source_job_id": source_job_id},
    )
    assert repeated.status_code == 409
    assert repeated.json()["detail"]["code"] == "checker_retry_not_available"
    assert checker.calls == 2


def test_write_commit_failure_releases_its_reserved_owner(client, auth_headers, monkeypatch):
    from sqlalchemy.orm import Session

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "本章意图"}
    ).json()
    original_reserve = write_registry.reserve
    original_commit = Session.commit
    reserved = False
    failed_once = False

    def observe_reserve(job):
        nonlocal reserved
        original_reserve(job)
        if job.chapter_id == chapter["id"] and job.kind == "write":
            reserved = True

    def fail_first_commit(session):
        nonlocal failed_once
        if reserved and not failed_once:
            failed_once = True
            raise RuntimeError("synthetic write registration failure")
        return original_commit(session)

    monkeypatch.setattr(write_registry, "reserve", observe_reserve)
    monkeypatch.setattr(Session, "commit", fail_first_commit)
    with pytest.raises(RuntimeError, match="synthetic write registration failure"):
        client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)

    assert write_registry.get_live(chapter["id"]) is None
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["status"] == "draft"


def test_write_launch_failure_restores_baseline_and_releases_owner(
    client, auth_headers, wait_for_terminal, monkeypatch
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "本章意图"}
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)
    original_launch = write_registry.launch

    def fail_write_launch(job, _session_factory):
        if job.kind == "write":
            raise RuntimeError("synthetic write launch failure")
        return original_launch(job, _session_factory)

    monkeypatch.setattr(write_registry, "launch", fail_write_launch)
    with pytest.raises(RuntimeError, match="synthetic write launch failure"):
        client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)

    assert write_registry.get_live(chapter["id"]) is None
    failed = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert failed["phase"] == "failed"
    assert failed["error_code"] == "write_start_failed"
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["status"] == "draft"

    monkeypatch.setattr(write_registry, "launch", original_launch)
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"


def test_write_start_cleanup_failure_still_releases_exact_owner(client, auth_headers, monkeypatch):
    import app.routers.chapters as chapters_router

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "本章意图"}
    ).json()

    def fail_launch(_job, _session_factory):
        raise RuntimeError("synthetic launch failure")

    def fail_recovery(*_args, **_kwargs):
        raise RuntimeError("synthetic recovery failure")

    monkeypatch.setattr(write_registry, "launch", fail_launch)
    monkeypatch.setattr(chapters_router, "fail_unlaunched_job", fail_recovery)
    with pytest.raises(RuntimeError, match="synthetic recovery failure"):
        client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)

    assert write_registry.get_live(chapter["id"]) is None


def test_checker_retry_launch_failure_releases_owner_and_remains_retryable(
    client, auth_headers, wait_for_terminal, monkeypatch
):
    class UnavailableChecker:
        def complete_json(self, **_kwargs):
            # Missing name classifications is a validation failure mapped to
            # the retryable Checker-unavailable path.
            return {"verdict": "passed", "issues": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: UnavailableChecker()
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    failed = wait_for_terminal(client, chapter["id"], auth_headers)
    assert failed["can_retry_checker"] is True

    original_launch = write_registry.launch

    def fail_check_launch(job, _session_factory):
        if job.kind == "check":
            raise RuntimeError("synthetic checker retry launch failure")
        return original_launch(job, _session_factory)

    monkeypatch.setattr(write_registry, "launch", fail_check_launch)
    with pytest.raises(RuntimeError, match="synthetic checker retry launch failure"):
        client.post(
            f"/api/v1/chapters/{chapter['id']}/checker/retry", headers=auth_headers,
            json={"source_job_id": failed["checker_source_job_id"]},
        )

    assert write_registry.get_live(chapter["id"]) is None
    after_launch_failure = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert after_launch_failure["phase"] == "failed"
    assert after_launch_failure["error_code"] == "checker_retry_start_failed"
    assert after_launch_failure["can_retry_checker"] is True


def test_manual_checker_input_change_is_not_current_when_it_finishes_later(client, auth_headers):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    class BlockingChecker:
        def __init__(self) -> None:
            self.started = Event()
            self.release = Event()

        def complete_json(self, **_kwargs):
            self.started.set()
            assert self.release.wait(timeout=3)
            return {"verdict": "passed", "issues": [], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers,
        json={"draft_text": "旧" * 4000},
    ).raise_for_status()
    checker = BlockingChecker()
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    with ThreadPoolExecutor(max_workers=1) as executor:
        checking = executor.submit(client.post, f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
        assert checker.started.wait(timeout=3)
        client.patch(
            f"/api/v1/chapters/{chapter['id']}", headers=auth_headers,
            json={"draft_text": "新" * 4000},
        ).raise_for_status()
        checker.release.set()
        response = checking.result(timeout=3)

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "checker_input_changed"
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert status["kind"] == "check"
    assert status["phase"] == "cancelled"
    assert status["error_code"] == "checker_input_changed"
    assert status["outcome_current"] is False


def test_archive_reservation_failure_releases_live_owner_and_allows_retry(
    client, auth_headers, wait_for_terminal, monkeypatch
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers,
        json={"draft_text": "作者短稿"},
    ).raise_for_status()
    original_reserve = write_registry.reserve

    def reserve_then_fail(job):
        original_reserve(job)
        if job.kind == "extract":
            raise RuntimeError("simulate post-reserve archive registration failure")

    monkeypatch.setattr(write_registry, "reserve", reserve_then_fail)
    accepted = client.post(
        f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers,
        json={"override_checker": True},
    )
    assert accepted.status_code == 200
    assert accepted.json()["phase"] == "failed"
    assert write_registry.get_live(chapter["id"]) is None

    monkeypatch.setattr(write_registry, "reserve", original_reserve)
    retry = client.post(f"/api/v1/chapters/{chapter['id']}/archive/retry", headers=auth_headers)
    assert retry.status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"


def test_upstream_failure_restores_old_draft_and_status(client, auth_headers, wait_for_terminal):
    class FailingWriter(TextLLM):
        def complete_stream(self, **kwargs):
            raise LLMError("upstream unavailable", code="llm_upstream_unavailable", retryable=True)
            yield  # pragma: no cover - keep this a generator

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "target_word_count": 20},
    ).json()
    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "旧稿"})
    client.app.dependency_overrides[get_writer_client] = lambda: FailingWriter("")
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers, json={"replace_draft": True}
    ).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    assert status["error_code"] == "llm_upstream_unavailable"
    latest = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert (latest["draft_text"], latest["status"]) == ("旧稿", "draft_ready")


def test_failed_job_persists_error_context_and_job_endpoint_surfaces_it(client, auth_headers, wait_for_terminal):
    class FailingWriter(TextLLM):
        def complete_stream(self, **kwargs):
            raise LLMError(
                "LLM upstream request failed: 400",
                code="llm_upstream_rejected",
                status_code=400,
                upstream_reason="PROMPT_ECHO_MARKER",
            )
            yield  # pragma: no cover - keep this a generator

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "target_word_count": 20},
    ).json()
    writer = FailingWriter("")
    writer.model_name = "gpt-test-4"
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    assert client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    assert status["error_code"] == "llm_upstream_rejected"
    ctx = status["error_context"]
    assert ctx["agent_role"] == "writer"
    assert ctx["model_name"] == "gpt-test-4"
    assert ctx["http_status"] == 400
    assert "upstream_reason" not in ctx

    # The polling endpoint independently surfaces the same error_context, not just the POST response.
    fetched = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert fetched["error_context"] == ctx


def test_unconfigured_writer_returns_safe_409(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.app.dependency_overrides.pop(get_writer_client)
    response = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    assert response.status_code == 409
    assert response.json()["detail"] == {
        "code": "llm_profile_not_configured",
        "message": "该 Agent 尚未完成可用模型配置",
        "details": {"agent_role": "writer"},
    }


def test_concurrent_chapter_creation_never_leaks_integrity_error(client, auth_headers):
    from concurrent.futures import ThreadPoolExecutor

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()

    def create(index: int):
        return client.post(
            f"/api/v1/books/{book['id']}/chapters",
            headers=auth_headers,
            json={"title": f"章节 {index}", "user_prompt": "行动"},
        )

    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(create, range(2)))
    assert all(response.status_code in {201, 409} for response in responses)
    for response in responses:
        if response.status_code == 409:
            assert response.json()["detail"]["code"] == "chapter_index_busy"
    chapters = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    indexes = [chapter["index"] for chapter in chapters]
    assert indexes == sorted(set(indexes))


def test_content_blocked_failure_is_not_disguised_as_generic_rejection(client, auth_headers, wait_for_terminal):
    class BlockedWriter(TextLLM):
        def complete_stream(self, **kwargs):
            raise LLMError(
                "LLM blocked the request",
                code="llm_content_blocked",
                block_reason="PROHIBITED_CONTENT",
            )
            yield  # pragma: no cover - keep this a generator

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "target_word_count": 20},
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: BlockedWriter("")
    assert client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    # Content-filter failures keep their own distinct code; block_reason classification
    # must never collapse into the generic upstream-rejected bucket.
    assert status["error_code"] == "llm_content_blocked"
    assert status["error_code"] != "llm_upstream_rejected"
    assert status["error_context"]["block_reason"] == "PROHIBITED_CONTENT"
    assert status["error_context"]["agent_role"] == "writer"


def test_accept_runs_deterministic_checks_without_a_candidate(client, auth_headers, wait_for_terminal):
    # A candidate row only exists once a write job runs or /check clears its
    # preflight, so a chapter can reach accept having had nothing verified.
    # The client hides the action in that state, but that is a client-side
    # rule and this text becomes a memory source for every later chapter.
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": "第一章"}
    ).json()
    client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers, json={"draft_text": "太短。"}
    ).raise_for_status()

    # /check runs even for an author-provided short draft; acceptance is where
    # the explicit short-draft confirmation is required.
    assert client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers).status_code == 200

    blocked = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers, json={})
    assert blocked.status_code == 409
    assert blocked.json()["detail"]["code"] == "short_draft_confirmation_required"
    assert [item["code"] for item in blocked.json()["detail"]["violations"]] == ["minimum_length"]
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["status"] != "finalized"

    # Length is the author's call about their own manuscript, so a deliberate
    # short chapter stays reachable through an explicit override.
    allowed = client.post(
        f"/api/v1/chapters/{chapter['id']}/accept",
        headers=auth_headers,
        json={"override_checker": True},
    )
    assert allowed.status_code == 200
    wait_for_terminal(client, chapter["id"], auth_headers)


def test_accept_never_waves_through_an_unselected_character(client, auth_headers, wait_for_terminal):
    # Unlike length, an unattributable name is a correctness failure: Extractor
    # cannot bind it and silently degrades the fact to chapter level. No
    # override may pass it; exempting the name is the recorded way through.
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": "第一章"}
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "林夕" + "文" * 4200},
    ).raise_for_status()

    for body in ({}, {"override_checker": True}):
        response = client.post(
            f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers, json=body
        )
        assert response.status_code == 409, body
        assert response.json()["detail"]["code"] in {"checker_override_required", "checker_identity_check_required"}

    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"character_links": [{"character_id": character["id"], "chapter_note": ""}]},
    ).raise_for_status()
    assert client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers).status_code == 200
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers, json={}
    ).status_code == 200
    wait_for_terminal(client, chapter["id"], auth_headers)


def test_accept_rejects_live_job(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "旧稿"})
    job = WriteJob(chapter["id"], writer=None)  # type: ignore[arg-type]
    write_registry.reserve(job)
    try:
        adopted = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers)
        assert adopted.status_code == 200
        assert adopted.json()["phase"] == "writing"
        response = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers)
        assert response.status_code == 409
        assert response.json()["detail"]["code"] == "write_running"
    finally:
        write_registry.clear()


def test_cancelled_job_remains_current_after_chapter_restore(client, auth_headers):
    import time

    class BlockingWriter(TextLLM):
        def complete_stream(self, *, cancel_event=None, **kwargs):
            while cancel_event is not None and not cancel_event.is_set():
                time.sleep(0.01)
            return
            yield  # pragma: no cover - keep this a generator

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "target_word_count": 20},
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: BlockingWriter("")

    started = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).json()
    assert started["job_id"]
    cancelled = client.post(
        f"/api/v1/chapters/{chapter['id']}/write/cancel",
        headers=auth_headers,
    )
    assert cancelled.status_code == 200

    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert status["phase"] == "cancelled"
    assert status["job_id"] == started["job_id"]
    assert status["outcome_current"] is False


def test_cancel_during_checker_never_promotes_old_candidate(client, auth_headers):
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    class BlockingChecker:
        def __init__(self):
            self.started = Event()
            self.release = Event()

        def complete_json(self, **_kwargs):
            self.started.set()
            assert self.release.wait(timeout=3)
            return {"verdict": "passed", "issues": [], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动"},
    ).json()
    baseline = "旧稿"
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": baseline},
    ).raise_for_status()
    checker = BlockingChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("新" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(
        f"/api/v1/chapters/{chapter['id']}/write",
        headers=auth_headers,
        json={"replace_draft": True},
    ).raise_for_status()
    assert checker.started.wait(timeout=3)
    job = write_registry.get_live(chapter["id"])
    assert job is not None

    with ThreadPoolExecutor(max_workers=1) as executor:
        cancelling = executor.submit(
            client.post,
            f"/api/v1/chapters/{chapter['id']}/write/cancel",
            headers=auth_headers,
        )
        assert job.cancel_event.wait(timeout=3)
        checker.release.set()
        response = cancelling.result(timeout=3)

    assert response.status_code == 200
    assert response.json()["draft_text"] == baseline
    assert response.json()["status"] == "draft_ready"
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert status["phase"] == "cancelled"
    candidates = stored_candidates(chapter["id"])
    assert len(candidates) == 1
    assert candidates[0]["draft_text"] == "新" * 4000
    assert candidates[0]["checker_result"] is None
    assert candidates[0]["is_current"] is False


def test_edit_during_checker_keeps_manual_text_and_marks_old_job_changed(client, auth_headers):
    from threading import Event

    class BlockingChecker:
        def __init__(self):
            self.started = Event()
            self.release = Event()

        def complete_json(self, **_kwargs):
            self.started.set()
            assert self.release.wait(timeout=3)
            return {"verdict": "passed", "issues": [], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    baseline = "旧稿"
    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": baseline}).raise_for_status()
    checker = BlockingChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("候选" * 2000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    started = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).json()
    assert checker.started.wait(timeout=3)

    manual = "人工编辑" * 1200
    patched = client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers, json={"draft_text": manual}
    )
    assert patched.status_code == 200
    checker.release.set()
    live = write_registry.get(chapter["id"])
    if live and live.thread:
        live.thread.join(timeout=3)

    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert current["draft_text"] == manual
    assert current["status"] == "draft_ready"
    assert status["job_id"] == started["job_id"]
    assert status["phase"] == "cancelled"
    assert status["error_code"] == "chapter_changed"
    assert status["outcome_current"] is False
    assert all(not candidate["is_current"] for candidate in stored_candidates(chapter["id"]))


@pytest.mark.parametrize("mutation", ["import", "links"])
def test_edit_during_writer_cannot_restore_old_baseline(client, auth_headers, mutation):
    from threading import Event

    class BlockingWriter(TextLLM):
        def __init__(self):
            super().__init__("候选" * 2000)
            self.started = Event()
            self.release = Event()

        def complete_stream(self, **_kwargs):
            self.started.set()
            assert self.release.wait(timeout=3)
            yield from self.text

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "旧稿"}).raise_for_status()
    writer = BlockingWriter()
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    started = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).json()
    assert writer.started.wait(timeout=3)

    if mutation == "import":
        manual = "导入正文" * 1000
        response = client.post(
            f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": manual}
        )
    else:
        manual = "旧稿"
        response = client.patch(
            f"/api/v1/chapters/{chapter['id']}",
            headers=auth_headers,
            json={"character_links": [{"character_id": character["id"]}]},
        )
    assert response.status_code == 200
    writer.release.set()
    live = write_registry.get(chapter["id"])
    if live and live.thread:
        live.thread.join(timeout=3)

    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert current["draft_text"] == manual
    assert status["job_id"] == started["job_id"]
    assert status["phase"] == "cancelled"
    assert status["error_code"] == "chapter_changed"


@pytest.mark.parametrize("stage", ["writer", "checker"])
@pytest.mark.parametrize("mutation", ["world", "character", "delete_character"])
def test_writer_input_owners_cancel_blocked_jobs_without_promoting_old_text(
    client, auth_headers, stage, mutation
):
    from threading import Event

    class BlockingWriter(TextLLM):
        def __init__(self):
            super().__init__("候选" * 2000)
            self.started = Event()
            self.release = Event()

        def complete_stream(self, **_kwargs):
            self.started.set()
            assert self.release.wait(timeout=3)
            yield from self.text

    class BlockingChecker:
        def __init__(self):
            self.started = Event()
            self.release = Event()

        def complete_json(self, **_kwargs):
            self.started.set()
            assert self.release.wait(timeout=3)
            return {"verdict": "passed", "issues": [], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "character_links": [{"character_id": character["id"]}]},
    ).json()
    baseline = "旧稿"
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": baseline}
    ).raise_for_status()
    if stage == "writer":
        blocker = BlockingWriter()
        client.app.dependency_overrides[get_writer_client] = lambda: blocker
    else:
        blocker = BlockingChecker()
        client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("候选" * 2000)
        client.app.dependency_overrides[get_checker_client] = lambda: blocker
    started = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).json()
    assert blocker.started.wait(timeout=3)

    if mutation == "world":
        response = client.patch(f"/api/v1/books/{book['id']}", headers=auth_headers, json={"world_setting": "新规则"})
    elif mutation == "character":
        response = client.patch(
            f"/api/v1/characters/{character['id']}", headers=auth_headers, json={"fixed_profile": "新的固定设定"}
        )
    else:
        response = client.delete(f"/api/v1/characters/{character['id']}", headers=auth_headers)
    assert response.status_code in {200, 204}
    blocker.release.set()
    live = write_registry.get(chapter["id"])
    if live and live.thread:
        live.thread.join(timeout=3)

    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert current["draft_text"] == baseline
    assert status["job_id"] == started["job_id"]
    assert status["phase"] == "cancelled"
    assert status["error_code"] == "chapter_changed"
    assert status["outcome_current"] is False


def test_non_prompt_book_and_unlinked_character_edits_do_not_cancel_writer(client, auth_headers, wait_for_terminal):
    from threading import Event

    class BlockingWriter(TextLLM):
        def __init__(self):
            super().__init__("候选" * 2000)
            self.started = Event()
            self.release = Event()

        def complete_stream(self, **_kwargs):
            self.started.set()
            assert self.release.wait(timeout=3)
            yield from self.text

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    unlinked = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "未入场"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    writer = BlockingWriter()
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert writer.started.wait(timeout=3)
    assert client.patch(f"/api/v1/books/{book['id']}", headers=auth_headers, json={"title": "改标题"}).status_code == 200
    assert client.patch(
        f"/api/v1/characters/{unlinked['id']}", headers=auth_headers, json={"role": "路人"}
    ).status_code == 200
    writer.release.set()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"


def test_new_actual_name_hit_during_checker_cancels_and_restores_owned_baseline(client, auth_headers):
    from threading import Event

    class BlockingChecker:
        def __init__(self) -> None:
            self.started = Event()
            self.release = Event()

        def complete_json(self, **_kwargs):
            self.started.set()
            assert self.release.wait(timeout=3)
            return {"verdict": "passed", "issues": [], "name_uses": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    unlinked = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "原名"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    baseline = "旧稿"
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers,
        json={"draft_text": baseline},
    ).raise_for_status()
    checker = BlockingChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("候选" * 2000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    started = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).json()
    assert checker.started.wait(timeout=3)

    # This card was not a dependency at freeze time. Renaming it to a name
    # actually repeated in the hidden candidate adds program-owned name hits;
    # its route does not advance this chapter's write generation, so the final
    # fresh-session CAS and baseline restoration are both required.
    client.patch(
        f"/api/v1/characters/{unlinked['id']}", headers=auth_headers,
        json={"name": "候选"},
    ).raise_for_status()
    checker.release.set()
    live = write_registry.get(chapter["id"])
    if live is not None and live.thread is not None:
        live.thread.join(timeout=3)

    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert current["draft_text"] == baseline
    assert current["status"] == "draft_ready"
    assert status["job_id"] == started["job_id"]
    assert status["phase"] == "cancelled"
    assert status["error_code"] == "checker_input_changed"
    assert status["outcome_current"] is False


def test_final_writer_cas_serializes_a_dependency_patch_after_promotion(client, auth_headers, monkeypatch):
    """A dependency write cannot enter between final proof and promotion.

    The final CAS deliberately wins this race once it has reserved SQLite's
    short write transaction.  The delayed character PATCH then serializes
    after the promotion, and makes its formerly-current checker evidence
    stale for subsequent reads instead of contaminating the proof window.
    """
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event, get_ident

    import app.services.write_jobs as jobs

    class Writer:
        model_name = "writer"
        last_finish_reason = "stop"

        def complete_stream(self, **_kwargs):
            yield "候选" * 2000

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    other = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "旧名"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "旧稿"}
    ).raise_for_status()

    proof_complete, allow_promotion, patch_submitted = Event(), Event(), Event()
    original = jobs.is_frozen_input_current
    paused = False

    def pause_after_proof(db, row, snapshot):
        nonlocal paused
        current = original(db, row, snapshot)
        if not paused:
            paused = True
            proof_complete.set()
            assert allow_promotion.wait(timeout=3)
        return current

    monkeypatch.setattr(jobs, "is_frozen_input_current", pause_after_proof)
    client.app.dependency_overrides[get_writer_client] = lambda: Writer()

    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert proof_complete.wait(timeout=3)

    def change_name():
        patch_submitted.set()
        return client.patch(
            f"/api/v1/characters/{other['id']}", headers=auth_headers, json={"name": "候选"}
        )

    with ThreadPoolExecutor(max_workers=1) as executor:
        changed = executor.submit(change_name)
        assert patch_submitted.wait(timeout=3)
        assert not changed.done(), "dependency PATCH crossed the final CAS lock"
        allow_promotion.set()
        assert changed.result(timeout=3).status_code == 200

    live = write_registry.get(chapter["id"])
    if live is not None and live.thread is not None:
        live.thread.join(timeout=3)
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert status["phase"] == "done"
    assert status["outcome_current"] is False
    assert current["draft_text"] == "候选" * 2000


def test_accept_cas_serializes_a_late_dependency_patch(client, auth_headers, monkeypatch, wait_for_terminal):
    """Accept either sees the old complete input or a precommitted change."""
    from concurrent.futures import ThreadPoolExecutor
    from threading import Event

    from app.services import production_context

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    other = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "旧名"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "文" * 4000}
    ).raise_for_status()
    client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers).raise_for_status()

    proof_complete, allow_accept, patch_submitted = Event(), Event(), Event()
    original = production_context.is_frozen_input_current
    paused = False

    def pause_after_proof(db, row, snapshot):
        nonlocal paused
        current = original(db, row, snapshot)
        if not paused:
            paused = True
            proof_complete.set()
            assert allow_accept.wait(timeout=3)
        return current

    monkeypatch.setattr(production_context, "is_frozen_input_current", pause_after_proof)
    with ThreadPoolExecutor(max_workers=2) as executor:
        accepting = executor.submit(
            client.post, f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers
        )
        assert proof_complete.wait(timeout=3)

        def change_name():
            patch_submitted.set()
            return client.patch(
                f"/api/v1/characters/{other['id']}", headers=auth_headers, json={"name": "行动"}
            )

        changed = executor.submit(change_name)
        assert patch_submitted.wait(timeout=3)
        assert not changed.done(), "dependency PATCH crossed the accept CAS lock"
        allow_accept.set()
        assert accepting.result(timeout=3).status_code == 200
        assert changed.result(timeout=3).status_code == 200

    db = db_module.SessionLocal()
    try:
        stored_chapter = db.get(Chapter, chapter["id"])
        candidate = db.scalars(
            select(ChapterDraftCandidate)
            .where(ChapterDraftCandidate.chapter_id == chapter["id"], ChapterDraftCandidate.is_current.is_(True))
        ).one()
        assert stored_chapter is not None
        assert candidate.checker_input_snapshot is not None
        assert production_context.is_frozen_input_current(
            db, stored_chapter, candidate.checker_input_snapshot
        ) is False
    finally:
        db.close()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"


def test_accept_with_if_match_reuses_its_existing_sqlite_cas_lock(client, auth_headers, wait_for_terminal):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "本章意图"}
    ).json()
    imported = client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "文" * 4000}
    )
    imported.raise_for_status()
    accepted = client.post(
        f"/api/v1/chapters/{chapter['id']}/accept",
        headers={**auth_headers, "If-Match": str(imported.json()["content_revision"])},
        json={"override_checker": True},
    )
    assert accepted.status_code == 200, accepted.text
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"


def test_failed_archive_start_remains_current_for_the_accepted_checker_result(client, auth_headers):
    from app.llm.factory import LLMConfigurationError

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "作者短稿"}
    ).raise_for_status()
    checked = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    checked.raise_for_status()
    assert checked.json()["checker_result"]["verdict"] == "passed"

    def unavailable_extractor():
        raise LLMConfigurationError("llm_profile_not_configured", "extractor")

    client.app.dependency_overrides[get_extractor_client] = unavailable_extractor
    accepted = client.post(
        f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers,
        json={"allow_short_draft": True},
    )
    assert accepted.status_code == 200
    assert accepted.json()["phase"] == "failed"
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert status["kind"] == "extract"
    assert status["phase"] == "failed"
    assert status["outcome_current"] is True
    assert status["visible_checker_result"]["verdict"] == "passed"


class SnapshotExtractor:
    """v2 Extractor stub whose fact carries a real ending-state delta.

    The shared `FakeExtractor` returns `end_state_delta: []`, so a chapter
    accepted under it never populates `dynamic_fields` and any "the delete
    reverted it" assertion would pass without the revert existing.
    """

    def __init__(self, name: str, slot: str, value: str) -> None:
        self.name, self.slot, self.value = name, slot, value

    def complete_json(self, *, user: str, **kwargs):
        import re

        span_id = re.search(r"\[(P\d{4}-S\d{2})\]", user).group(1)
        return {
            "summary": "梗概。",
            "facts": [{
                "fact_ref": "F1",
                "type": "状态",
                "importance": 3,
                "text": f"{self.name}的章末状态发生变化。",
                "participant_names": [self.name],
                "start_id": span_id,
                "end_id": span_id,
            }],
            "end_state_delta": [{
                "fact_ref": "F1",
                "character_name": self.name,
                "other_character_name": None,
                "scope": "snapshot",
                "slot": self.slot,
                "operation": "set",
                "value": self.value,
            }],
        }


def test_delete_finalized_chapter_cascades_events_and_reverts_dynamic_state(client, auth_headers, wait_for_terminal):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    pytest.character_id = character["id"]
    chapters = [
        client.post(
            f"/api/v1/books/{book['id']}/chapters",
            headers=auth_headers,
            json={"title": str(index), "user_prompt": "行动", "character_links": [{"character_id": character["id"]}]},
        ).json()
        for index in range(3)
    ]
    # v2.0.4: only the last chapter is deletable, so the finalized chapter
    # under test is the last one rather than the middle one.
    client.app.dependency_overrides[get_extractor_client] = lambda: SnapshotExtractor(
        "林夕", "当前位置", "废城"
    )
    client.post(
        f"/api/v1/chapters/{chapters[2]['id']}/import", headers=auth_headers, json={"draft_text": "林夕行动"}
    )
    client.post(f"/api/v1/chapters/{chapters[2]['id']}/accept", headers=auth_headers, json={"override_checker": True}).raise_for_status()
    assert wait_for_terminal(client, chapters[2]["id"], auth_headers)["phase"] == "done"

    # The v2 archive creates one character event for its single fact and one
    # projected dynamic field for its single delta; the deletion below is what
    # has to take both away again.
    before = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert before["events"] != []
    assert before["dynamic_fields"] == {"当前位置": "废城"}

    client.delete(f"/api/v1/chapters/{chapters[2]['id']}", headers=auth_headers).raise_for_status()
    detail = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert detail["events"] == []
    # v1.1.2: the chapter introduced this key, so deleting the chapter removes it.
    assert detail["dynamic_fields"] == {}
    listed = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    assert [item["index"] for item in listed] == [1, 2]


def test_memories_export_contains_headlines_summaries_and_character_memory(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "记忆书"}).json()
    first = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": "开端", "user_prompt": "x"}
    ).json()
    second = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": "转折", "user_prompt": "y"}
    ).json()
    client.patch(
        f"/api/v1/chapters/{first['id']}",
        headers=auth_headers,
        json={"headline": "主角出场", "summary": "主角在雨夜抵达小镇。"},
    )
    client.patch(f"/api/v1/chapters/{second['id']}", headers=auth_headers, json={"summary": "冲突爆发。"})
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林昭", "role": "主角"}
    ).json()
    client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"dynamic_fields": {"最近状态": "受伤未愈", "随身物品": ["短刀", "地图"]}},
    )

    import app.db as db_module
    from app.models import CharacterEvent

    db = db_module.SessionLocal()
    try:
        db.add(
            CharacterEvent(
                book_id=book["id"],
                chapter_id=first["id"],
                character_id=character["id"],
                event_type="story",
                event_text="雨夜初登场",
            )
        )
        db.commit()
    finally:
        db.close()

    response = client.get(f"/api/v1/books/{book['id']}/memories/export.txt", headers=auth_headers)
    assert response.status_code == 200
    assert "text/plain" in response.headers["content-type"]
    text = response.text
    assert "记忆书——记忆导出" in text
    assert "【大事记】" in text
    assert "第 1 章 开端：主角出场" in text
    assert "【章节摘要】" in text
    assert "主角在雨夜抵达小镇。" in text
    assert "冲突爆发。" in text
    assert "【人物记忆】" in text
    assert "林昭（主角）" in text
    assert "最近状态：受伤未愈" not in text
    assert "随身物品：[\"短刀\", \"地图\"]" not in text
    assert "第 1 章 [story] 雨夜初登场" in text
    # 记忆导出不含正文
    assert "draft" not in text

    assert client.get(f"/api/v1/books/{book['id']}/memories/export.txt").status_code == 401
    assert client.get("/api/v1/books/nope/memories/export.txt", headers=auth_headers).status_code == 404


def test_memories_export_empty_book_uses_placeholders(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "空书"}).json()
    text = client.get(f"/api/v1/books/{book['id']}/memories/export.txt", headers=auth_headers).text
    assert "【大事记】" in text
    assert "（暂无）" in text
    assert "（暂无人物）" in text
