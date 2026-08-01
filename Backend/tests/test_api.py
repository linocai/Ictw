from __future__ import annotations

import pytest
from sqlalchemy import select

import app.db as db_module
from app.llm.base import LLMError
from app.llm.factory import get_checker_client, get_extractor_client, get_writer_client
from app.models import ChapterDraftCandidate
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

    accepted = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers)
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
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    events = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"]
    assert len(events) == 1


def test_extractor_discards_name_and_unknown_refs_but_keeps_valid(client, auth_headers, wait_for_terminal):
    class MixedExtractor:
        def complete_json(self, **kwargs):
            return {
                "summary": "梗概",
                "headline": "大事",
                "character_events": [
                    {"character_id": pytest.character_id, "event_text": "有效事件"},
                    {"character_id": "林夕", "event_text": "姓名引用丢弃"},
                    {"character_id": "unknown", "event_text": "未知引用丢弃"},
                ],
                "dynamic_fields_patch": [{"character_id": "unknown", "fields": "坏结构也随非法引用丢弃"}],
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
    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "正文"})
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "done"
    assert len(status["added_event_ids"]) == 1


def test_selected_extractor_item_malformed_restores_draft_ready(client, auth_headers, wait_for_terminal):
    class BadExtractor:
        def complete_json(self, **kwargs):
            return {
                "summary": "梗概",
                "headline": "大事",
                "character_events": [{"character_id": pytest.character_id}],
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
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    assert status["job_id"]
    assert status["outcome_current"] is True
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["status"] == "draft_ready"
    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"character_links": []},
    ).raise_for_status()
    stale = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert stale["phase"] == "failed"
    assert stale["outcome_current"] is False


def test_writer_preflight_uses_longest_name_and_rejects_unselected(client, auth_headers, wait_for_terminal):
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
    assert started.json()["phase"] == "selecting_memory"
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    bad = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "林进入废城", "character_links": [{"character_id": long["id"]}]},
    ).json()
    response = client.post(f"/api/v1/chapters/{bad['id']}/write", headers=auth_headers)
    assert response.status_code == 409
    assert response.json()["detail"]["details"]["names"] == ["林"]
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
            return {"verdict": "violation", "issues": [{"kind": "new_plot", "draft_evidence": "正文证据", "bible_evidence": "Bible证据", "reason": "越界"}]}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}).json()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: ViolationChecker()
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    assert status["error_code"] == "checker_rejected"
    assert status["checker_result"]["verdict"] == "violation"
    assert "draft_candidate" not in status
    assert ("文" * 4000) not in client.get(
        f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers
    ).text
    visible = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert visible["draft_text"] == ""
    assert visible["status"] == "draft"
    candidates = stored_candidates(chapter["id"])
    assert len(candidates) == 1
    assert candidates[0]["draft_text"] == "文" * 4000
    assert candidates[0]["checker_result"]["verdict"] == "violation"
    assert candidates[0]["is_current"] is False
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
            return {"verdict": "passed", "issues": []}

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
    assert failed["error_code"] == "writer_validation_failed"
    assert {item["code"] for item in failed["violations"]} == {"unselected_character"}
    assert failed["visible_checker_result"]["verdict"] == "passed"

    visible = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert visible["draft_text"] == baseline
    candidates = stored_candidates(chapter["id"])
    assert len(candidates) == 2
    assert candidates[0]["draft_text"] == baseline and candidates[0]["is_current"] is True
    assert candidates[1]["draft_text"] == rejected and candidates[1]["is_current"] is False
    assert candidates[1]["deterministic_violations"][0]["code"] == "unselected_character"
    assert checker.calls == 1


def test_manual_edit_recheck_preserves_generated_candidate_and_creates_next_attempt(client, auth_headers, wait_for_terminal):
    class RecordingChecker:
        def __init__(self):
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            return {"verdict": "passed", "issues": []}

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


def test_manual_recheck_rejects_invalid_text_without_calling_checker(client, auth_headers, wait_for_terminal):
    class RecordingChecker:
        def __init__(self):
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            return {"verdict": "passed", "issues": []}

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "行动"}).json()
    checker = RecordingChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: TextLLM("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    client.patch(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers, json={"draft_text": "太短"}).raise_for_status()

    response = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "checker_preflight_failed"
    assert {item["code"] for item in response.json()["detail"]["violations"]} >= {"minimum_length"}
    assert checker.calls == 1


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
    original = stored_candidates(chapter["id"])[0]

    client.patch(f"/api/v1/books/{book['id']}", headers=auth_headers, json={"world_setting": "新世界观"}).raise_for_status()
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).status_code == 409
    world_recheck = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    assert world_recheck.status_code == 200
    assert world_recheck.json()["draft_fingerprint"] != original["draft_fingerprint"]

    client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"name": "林夕改名", "fixed_profile": "新设定", "dynamic_fields": {"状态": "新"}},
    ).raise_for_status()
    assert client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).status_code == 409
    character_recheck = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    assert character_recheck.status_code == 200
    assert character_recheck.json()["draft_fingerprint"] != world_recheck.json()["draft_fingerprint"]


def test_delete_middle_chapter_reindexes_and_is_idempotent(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapters = [
        client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": str(i)}).json()
        for i in range(3)
    ]
    assert client.delete(f"/api/v1/chapters/{chapters[1]['id']}", headers=auth_headers).status_code == 204
    listed = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    assert [item["index"] for item in listed] == [1, 2]
    assert client.delete(f"/api/v1/chapters/{chapters[1]['id']}", headers=auth_headers).status_code == 204


def test_duplicate_character_name_is_an_explicit_preflight_error(client, auth_headers):
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
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "ambiguous_character_name"


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
                # Pre-shaped as openai_compatible._safe_upstream_reason would produce it;
                # the whitelist extraction itself is covered in test_v1_pipeline.py.
                upstream_reason="content policy violation | invalid_request_error | invalid_request_error_type",
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
    assert ctx["upstream_reason"] == "content policy violation | invalid_request_error | invalid_request_error_type"

    # The polling endpoint independently surfaces the same error_context, not just the POST response.
    fetched = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert fetched["error_context"] == ctx


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
    assert status["outcome_current"] is True


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
            return {"verdict": "passed", "issues": []}

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
    client.post(
        f"/api/v1/chapters/{chapters[1]['id']}/import", headers=auth_headers, json={"draft_text": "林夕行动"}
    )
    client.post(f"/api/v1/chapters/{chapters[1]['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapters[1]["id"], auth_headers)["phase"] == "done"

    client.delete(f"/api/v1/chapters/{chapters[0]['id']}", headers=auth_headers).raise_for_status()
    client.delete(f"/api/v1/chapters/{chapters[1]['id']}", headers=auth_headers).raise_for_status()
    detail = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert detail["events"] == []
    # v1.1.2: the chapter introduced this key, so deleting the chapter removes it.
    assert "current_status" not in detail["dynamic_fields"]
    listed = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    assert [(item["id"], item["index"]) for item in listed] == [(chapters[2]["id"], 1)]


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
    assert "【章节梗概】" in text
    assert "主角在雨夜抵达小镇。" in text
    assert "冲突爆发。" in text
    assert "【人物记忆】" in text
    assert "林昭（主角）" in text
    assert "最近状态：受伤未愈" in text
    assert "随身物品：[\"短刀\", \"地图\"]" in text
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
