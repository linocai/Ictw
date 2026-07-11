from __future__ import annotations

import pytest

from app.llm.base import LLMError
from app.llm.factory import get_extractor_client, get_reviser_client, get_writer_client
from app.services.write_jobs import WriteJob, write_registry


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
        return {"memory_ids": []}


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
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "done"
    assert status["chapter"]["status"] == "finalized"

    client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers).raise_for_status()
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
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["status"] == "draft_ready"


def test_writer_preflight_uses_longest_name_and_rejects_unselected(client, auth_headers, wait_for_terminal):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    short = client.post(f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林"}).json()
    long = client.post(f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "林夕进入废城", "target_word_count": 20, "character_links": [{"character_id": long["id"]}]},
    ).json()
    writer = TextLLM("文" * 20)
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


def test_reviser_one_attempt_and_two_attempt_failure_restore_baseline(client, auth_headers, wait_for_terminal):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "target_word_count": 20},
    ).json()
    writer = TextLLM("短")
    reviser = TextLLM("修" * 20)
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    client.app.dependency_overrides[get_reviser_client] = lambda: reviser
    assert client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    assert reviser.calls == 1

    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "旧稿"})
    always_bad = TextLLM("坏")
    client.app.dependency_overrides[get_reviser_client] = lambda: always_bad
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers, json={"replace_draft": True}
    ).status_code == 200
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    assert status["phase"] == "failed"
    assert status["error_code"] == "revision_failed"
    assert status["violations"]
    assert always_bad.calls == 2
    latest = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert latest["draft_text"] == "旧稿"
    assert latest["status"] == "draft_ready"


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
        response = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers)
        assert response.status_code == 409
        assert response.json()["detail"]["code"] == "write_running"
    finally:
        write_registry.clear()


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
