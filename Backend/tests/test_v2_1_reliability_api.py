from __future__ import annotations

import sqlite3

from alembic import command
from alembic.config import Config
from sqlalchemy import text

from app.llm.factory import build_llm_client, get_checker_client, resolve_model_binding
from app.models import ChapterDraftCandidate, CharacterEvent, SearchDocument


def _create_book(client, headers, title: str = "可靠书") -> dict:
    response = client.post("/api/v1/books", headers=headers, json={"title": title, "world_setting": "雨夜旧城"})
    assert response.status_code == 201, response.text
    return response.json()


def test_0013_migration_backfills_public_author_note_search(tmp_path, monkeypatch):
    from app.config import get_settings
    from app.db import make_engine

    database_path = tmp_path / "reliability-backfill.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("DATABASE_URL", database_url)
    get_settings.cache_clear()
    config = Config("alembic.ini")
    command.upgrade(config, "20260814_0012")
    connection = sqlite3.connect(database_path)
    try:
        connection.executescript("""
            PRAGMA foreign_keys=ON;
            INSERT INTO books (id, title, world_setting, created_at, updated_at, last_opened_at)
            VALUES ('book', '旧书', '旧世界', '2026-01-01', '2026-01-01', NULL);
            INSERT INTO chapters
                (id, book_id, "index", title, user_prompt, target_word_count, author_note,
                 draft_text, headline, status, source, created_at, updated_at)
            VALUES
                ('chapter', 'book', 1, '旧章', '作者输入', 3000, '公开作者备注',
                 '旧正文', '', 'draft', 'author', '2026-01-01', '2026-01-01');
        """)
        connection.commit()
    finally:
        connection.close()
    command.upgrade(config, "head")
    engine = make_engine(database_url)
    with engine.connect() as migrated:
        body = migrated.execute(
            text("SELECT body FROM search_documents WHERE id='chapter:chapter'")
        ).scalar_one()
    assert "公开作者备注" in body
    get_settings.cache_clear()


def test_conditional_writes_reject_stale_revision_and_legacy_requests_still_work(client, auth_headers):
    book = _create_book(client, auth_headers)
    revision = book["content_revision"]
    first = client.patch(
        f"/api/v1/books/{book['id']}",
        headers={**auth_headers, "If-Match": f'"{revision}"'},
        json={"title": "第一次保存"},
    )
    assert first.status_code == 200
    assert first.json()["content_revision"] == revision + 1

    stale = client.patch(
        f"/api/v1/books/{book['id']}",
        headers={**auth_headers, "If-Match": str(revision)},
        json={"title": "不该覆盖"},
    )
    assert stale.status_code == 409
    assert stale.json()["detail"] == {
        "code": "write_conflict",
        "message": "内容已在其他设备更新，请先同步后再保存",
        "details": {
            "resource_type": "book",
            "resource_id": book["id"],
            "submitted_revision": revision,
            "current_revision": revision + 1,
        },
    }
    # Public v1.8.1 compatibility: no conditional header retains old behavior.
    legacy = client.patch(f"/api/v1/books/{book['id']}", headers=auth_headers, json={"title": "旧客户端"})
    assert legacy.status_code == 200
    assert legacy.json()["title"] == "旧客户端"


def test_chapter_character_and_event_expose_and_honor_content_revisions(client, auth_headers):
    book = _create_book(client, auth_headers)
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers,
        json={"name": "林雨", "fixed_profile": "摄影师"},
    ).json()
    assert character["content_revision"] == 1
    changed = client.patch(
        f"/api/v1/characters/{character['id']}",
        headers={**auth_headers, "If-Match": '"1"'}, json={"role": "记者"},
    )
    assert changed.status_code == 200
    assert changed.json()["content_revision"] == 2
    assert client.patch(
        f"/api/v1/characters/{character['id']}",
        headers={**auth_headers, "If-Match": '"1"'}, json={"role": "过期"},
    ).status_code == 409

    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"title": "第一章", "character_links": [{"character_id": character["id"]}]},
    ).json()
    assert chapter["content_revision"] == 1
    changed_chapter = client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers={**auth_headers, "If-Match": '"1"'}, json={"draft_text": "作者可见正文"},
    )
    assert changed_chapter.status_code == 200
    assert changed_chapter.json()["content_revision"] == 2

    import app.db as db_module
    db = db_module.SessionLocal()
    try:
        event = CharacterEvent(
            book_id=book["id"],
            character_id=character["id"],
            chapter_id=chapter["id"],
            event_type="story",
            event_text="第一次记录",
        )
        db.add(event)
        db.commit()
        event_id = event.id
    finally:
        db.close()

    first_event_patch = client.patch(
        f"/api/v1/character-events/{event_id}",
        headers={**auth_headers, "If-Match": '"1"'},
        json={"event_text": "第二次记录"},
    )
    assert first_event_patch.status_code == 200
    assert first_event_patch.json()["content_revision"] == 2

    listed_characters = client.get(f"/api/v1/books/{book['id']}/characters", headers=auth_headers)
    assert listed_characters.status_code == 200
    listed_event = next(
        item
        for listed_character in listed_characters.json()
        if listed_character["id"] == character["id"]
        for item in listed_character["events"]
        if item["id"] == event_id
    )
    assert listed_event["content_revision"] == 2

    second_event_patch = client.patch(
        f"/api/v1/character-events/{event_id}",
        headers={**auth_headers, "If-Match": f'"{listed_event["content_revision"]}"'},
        json={"event_text": "第三次记录"},
    )
    assert second_event_patch.status_code == 200
    assert second_event_patch.json()["content_revision"] == 3


def test_search_indexes_visible_content_but_never_hidden_candidates(client, auth_headers):
    book = _create_book(client, auth_headers, "雨夜编年")
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"title": "雨夜", "user_prompt": "必须找到灯塔"},
    ).json()
    client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers,
        json={"draft_text": "她在雨夜看见灯塔。"},
    )
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers,
        json={"name": "阿明", "fixed_profile": "守塔人"},
    )
    assert character.status_code == 201

    import app.db as db_module
    db = db_module.SessionLocal()
    try:
        event = CharacterEvent(
            book_id=book["id"], character_id=character.json()["id"], chapter_id=chapter["id"],
            event_type="story", event_text="旧站台重逢",
        )
        db.add(event)
        db.commit()
        event_id = event.id
    finally:
        db.close()
    updated_event = client.patch(
        f"/api/v1/character-events/{event_id}", headers={**auth_headers, "If-Match": "1"},
        json={"event_text": "旧站台重逢"},
    )
    assert updated_event.status_code == 200

    visible = client.get("/api/v1/search", headers=auth_headers, params={"q": "灯塔"})
    assert visible.status_code == 200
    assert any(item["chapter_id"] == chapter["id"] for item in visible.json()["items"])
    people = client.get("/api/v1/search", headers=auth_headers, params={"q": "守塔人"})
    assert any(item["character_id"] == character.json()["id"] for item in people.json()["items"])

    db = db_module.SessionLocal()
    try:
        db.add(ChapterDraftCandidate(
            chapter_id=chapter["id"], attempt=99, draft_text="绝密候选短语", non_whitespace_count=6,
            is_current=False,
        ))
        db.commit()
        assert db.query(SearchDocument).filter(SearchDocument.body.contains("绝密候选短语")).count() == 0
    finally:
        db.close()
    hidden = client.get("/api/v1/search", headers=auth_headers, params={"q": "绝密候选短语"})
    assert hidden.status_code == 200
    assert hidden.json()["items"] == []
    legacy_event = client.get("/api/v1/search", headers=auth_headers, params={"q": "旧站台"})
    assert any(
        item["character_id"] == character.json()["id"] and item["chapter_id"] == chapter["id"]
        for item in legacy_event.json()["items"]
    )

    percent_book = _create_book(client, auth_headers, "完成度 100%")
    literal_percent = client.get("/api/v1/search", headers=auth_headers, params={"q": "%"})
    assert literal_percent.status_code == 200
    assert literal_percent.json()["total"] == 1
    assert literal_percent.json()["items"][0]["book_id"] == percent_book["id"]

    author_note = client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers,
        json={"author_note": "这段公开备注提到月台"},
    )
    assert author_note.status_code == 200
    client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"title": "第二章", "author_note": "另一处月台"},
    )
    paged = client.get(
        "/api/v1/search", headers=auth_headers, params={"q": "月台", "limit": 1, "offset": 1}
    )
    assert paged.status_code == 200
    assert paged.json()["total"] == 2
    assert len(paged.json()["items"]) == 1


def test_book_model_binding_overrides_global_and_runtime_client_is_frozen(client, auth_headers):
    book = _create_book(client, auth_headers)
    global_profile = client.post("/api/v1/llm_profiles", headers=auth_headers, json={
        "name": "全局", "base_url": "https://api.deepseek.com", "api_key": "global-key", "model_name": "deepseek-v4-pro",
    }).json()
    book_profile = client.post("/api/v1/llm_profiles", headers=auth_headers, json={
        "name": "本书", "base_url": "https://api.deepseek.com", "api_key": "book-key", "model_name": "deepseek-v4-pro",
    }).json()
    global_binding = client.patch(
        "/api/v1/agent-model-bindings/writer", headers=auth_headers,
        json={"llm_profile_id": global_profile["id"], "thinking_enabled": False},
    )
    assert global_binding.status_code == 200

    inherited = client.get(f"/api/v1/books/{book['id']}/agent-model-bindings", headers=auth_headers).json()
    writer = next(item for item in inherited if item["agent_role"] == "writer")
    assert writer["source"] == "global"
    assert writer["effective_binding"]["llm_profile_id"] == global_profile["id"]

    override = client.put(
        f"/api/v1/books/{book['id']}/agent-model-bindings/writer", headers=auth_headers,
        json={"llm_profile_id": book_profile["id"], "thinking_enabled": False, "reasoning_effort": None, "temperature": 0.7},
    )
    assert override.status_code == 200, override.text
    assert override.json()["source"] == "book"
    assert override.json()["effective_binding"]["llm_profile_id"] == book_profile["id"]

    extractor = client.put(
        f"/api/v1/books/{book['id']}/agent-model-bindings/extractor", headers=auth_headers,
        json={"llm_profile_id": book_profile["id"], "thinking_enabled": False, "reasoning_effort": None, "temperature": 0.1},
    )
    assert extractor.status_code == 200
    assert extractor.json()["effective_binding"]["effective_thinking_enabled"] is False

    import app.db as db_module
    db = db_module.SessionLocal()
    try:
        binding, source = resolve_model_binding(db, "writer", book_id=book["id"])
        frozen_client = build_llm_client(db, "writer", book_id=book["id"])
        assert source == "book"
        assert binding.llm_profile_id == book_profile["id"]
        assert frozen_client.model_name == "deepseek-v4-pro"
        binding.llm_profile_id = global_profile["id"]
        db.commit()
        # A started job owns this already-built client; later setting changes
        # cannot mutate its model endpoint/key/configuration in place.
        assert frozen_client.model_name == "deepseek-v4-pro"
    finally:
        db.close()


def test_book_model_override_is_resolved_before_invalid_global_binding(client, auth_headers):
    book = _create_book(client, auth_headers)
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"title": "空章"},
    ).json()
    profile = client.post("/api/v1/llm_profiles", headers=auth_headers, json={
        "name": "本书 Checker", "base_url": "https://api.deepseek.com",
        "api_key": "book-only-key", "model_name": "deepseek-v4-pro",
    }).json()
    override = client.put(
        f"/api/v1/books/{book['id']}/agent-model-bindings/checker",
        headers={**auth_headers, "If-Match": "0"},
        json={"llm_profile_id": profile["id"], "thinking_enabled": False},
    )
    assert override.status_code == 200

    previous = client.app.dependency_overrides.pop(get_checker_client)
    try:
        response = client.post(
            f"/api/v1/chapters/{chapter['id']}/check",
            headers={**auth_headers, "If-Match": str(chapter["content_revision"])},
        )
    finally:
        client.app.dependency_overrides[get_checker_client] = previous
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "checker_preflight_failed"


def test_chapter_task_actions_reject_a_stale_revision(client, auth_headers):
    book = _create_book(client, auth_headers)
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"title": "并发章", "draft_text": "作者正文"},
    ).json()
    changed = client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers={**auth_headers, "If-Match": str(chapter["content_revision"])},
        json={"title": "另一端已更新"},
    )
    assert changed.status_code == 200
    stale_headers = {**auth_headers, "If-Match": str(chapter["content_revision"])}
    for suffix, payload in (
        ("write", {"replace_draft": False}),
        ("check", None),
        ("accept", {"override_checker": True}),
        ("archive/retry", None),
    ):
        request_kwargs = {"headers": stale_headers}
        if payload is not None:
            request_kwargs["json"] = payload
        response = client.post(f"/api/v1/chapters/{chapter['id']}/{suffix}", **request_kwargs)
        assert response.status_code == 409, (suffix, response.text)
        assert response.json()["detail"]["code"] == "write_conflict"


def test_conflict_snapshot_reads_and_profile_binding_revisions(client, auth_headers):
    book = _create_book(client, auth_headers)
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers,
        json={"name": "沈星", "fixed_profile": "律师"},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"title": "第一章", "character_links": [{"character_id": character["id"]}]},
    ).json()
    import app.db as db_module
    db = db_module.SessionLocal()
    try:
        event = CharacterEvent(
            book_id=book["id"], character_id=character["id"], chapter_id=chapter["id"],
            event_type="story", event_text="在雨中重逢",
        )
        db.add(event)
        db.commit()
        event_id = event.id
    finally:
        db.close()

    assert client.get(f"/api/v1/character-events/{event_id}", headers=auth_headers).json()["event_text"] == "在雨中重逢"
    assert client.get("/api/v1/agent-personas/writer", headers=auth_headers).status_code == 200
    global_binding = client.get("/api/v1/agent-model-bindings/writer", headers=auth_headers)
    assert global_binding.status_code == 200

    profile = client.post("/api/v1/llm_profiles", headers=auth_headers, json={
        "name": "可变模型", "base_url": "https://api.deepseek.com", "api_key": "never-return-me",
        "model_name": "deepseek-v4-pro",
    }).json()
    profile_read = client.get(f"/api/v1/llm_profiles/{profile['id']}", headers=auth_headers)
    assert profile_read.status_code == 200
    assert "api_key" not in profile_read.json()
    assert "api_key_encrypted" not in profile_read.json()

    global_update = client.patch(
        "/api/v1/agent-model-bindings/writer", headers=auth_headers,
        json={"llm_profile_id": profile["id"], "thinking_enabled": True, "reasoning_effort": "high"},
    )
    assert global_update.status_code == 200
    book_update = client.put(
        f"/api/v1/books/{book['id']}/agent-model-bindings/writer", headers={**auth_headers, "If-Match": "0"},
        json={"llm_profile_id": profile["id"], "thinking_enabled": True, "reasoning_effort": "high"},
    )
    assert book_update.status_code == 200
    assert client.get(
        f"/api/v1/books/{book['id']}/agent-model-bindings/writer", headers=auth_headers
    ).json()["content_revision"] == 1
    persona_update = client.put(
        f"/api/v1/books/{book['id']}/agent-personas/writer", headers={**auth_headers, "If-Match": "0"},
        json={"editable_persona": "本书作者口吻"},
    )
    assert persona_update.status_code == 200
    assert client.get(
        f"/api/v1/books/{book['id']}/agent-personas/writer", headers=auth_headers
    ).json()["effective_persona"] == "本书作者口吻"

    global_revision = global_update.json()["content_revision"]
    book_revision = book_update.json()["content_revision"]
    profile_patch = client.patch(
        f"/api/v1/llm_profiles/{profile['id']}", headers={**auth_headers, "If-Match": '"1"'},
        json={"model_name": "unknown-model"},
    )
    assert profile_patch.status_code == 200
    assert client.get("/api/v1/agent-model-bindings/writer", headers=auth_headers).json()["content_revision"] == global_revision + 1
    assert client.get(
        f"/api/v1/books/{book['id']}/agent-model-bindings/writer", headers=auth_headers
    ).json()["content_revision"] == book_revision + 1

    global_after_patch = client.get("/api/v1/agent-model-bindings/writer", headers=auth_headers).json()
    book_after_patch = client.get(
        f"/api/v1/books/{book['id']}/agent-model-bindings/writer", headers=auth_headers
    ).json()
    deleted = client.delete(
        f"/api/v1/llm_profiles/{profile['id']}",
        headers={**auth_headers, "If-Match": str(profile_patch.json()["content_revision"])},
    )
    assert deleted.status_code == 204
    global_after_delete = client.get("/api/v1/agent-model-bindings/writer", headers=auth_headers).json()
    book_after_delete = client.get(
        f"/api/v1/books/{book['id']}/agent-model-bindings/writer", headers=auth_headers
    ).json()
    assert global_after_delete["llm_profile_id"] is None
    assert book_after_delete["effective_binding"]["llm_profile_id"] is None
    assert global_after_delete["content_revision"] == global_after_patch["content_revision"] + 1
    assert book_after_delete["content_revision"] == book_after_patch["content_revision"] + 1

    # A stale initial-create token is a recoverable conflict, not a malformed
    # header or a uniqueness error once another device owns the override.
    competing_create = client.put(
        f"/api/v1/books/{book['id']}/agent-personas/writer", headers={**auth_headers, "If-Match": "0"},
        json={"editable_persona": "不能覆盖"},
    )
    assert competing_create.status_code == 409
    assert competing_create.json()["detail"]["code"] == "write_conflict"
    assert competing_create.json()["detail"]["details"]["submitted_revision"] == 0
