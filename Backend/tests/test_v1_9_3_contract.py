from __future__ import annotations

from sqlalchemy import select

from app.models import Book, BookAgentPersona
from app.services.personas import AGENT_ROLES, PROGRAM_PROTOCOLS, get_persona


def test_book_persona_override_inherits_and_resolves_all_roles(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "甲书"}).json()
    book_id = book["id"]

    initial = client.get(f"/api/v1/books/{book_id}/agent-personas", headers=auth_headers)
    assert initial.status_code == 200
    assert [item["agent_role"] for item in initial.json()] == list(AGENT_ROLES)
    assert {item["source"] for item in initial.json()} == {"global"}

    invalid = client.put(
        f"/api/v1/books/{book_id}/agent-personas/writer",
        headers=auth_headers,
        json={"editable_persona": "本书写作人格", "program_protocol": "不能覆盖"},
    )
    assert invalid.status_code == 422
    changed = client.put(
        f"/api/v1/books/{book_id}/agent-personas/writer",
        headers=auth_headers,
        json={"editable_persona": "本书写作人格"},
    )
    assert changed.status_code == 200
    assert changed.json()["source"] == "book"
    assert changed.json()["effective_persona"] == "本书写作人格"
    assert changed.json()["program_protocol"] == PROGRAM_PROTOCOLS["writer"]

    blank = client.put(
        f"/api/v1/books/{book_id}/agent-personas/writer",
        headers=auth_headers,
        json={"editable_persona": "   "},
    )
    assert blank.status_code == 422
    too_long = client.put(
        f"/api/v1/books/{book_id}/agent-personas/writer",
        headers=auth_headers,
        json={"editable_persona": "x" * 8001},
    )
    assert too_long.status_code == 422

    global_changed = client.patch(
        "/api/v1/agent-personas/writer",
        headers=auth_headers,
        json={"editable_persona": "新的全局写作人格"},
    )
    assert global_changed.status_code == 200
    writer = next(
        item for item in client.get(f"/api/v1/books/{book_id}/agent-personas", headers=auth_headers).json()
        if item["agent_role"] == "writer"
    )
    assert writer["effective_persona"] == "本书写作人格"
    assert writer["global_persona"] == "新的全局写作人格"

    assert client.delete(f"/api/v1/books/{book_id}/agent-personas/writer", headers=auth_headers).status_code == 204
    inherited = next(
        item for item in client.get(f"/api/v1/books/{book_id}/agent-personas", headers=auth_headers).json()
        if item["agent_role"] == "writer"
    )
    assert inherited["source"] == "global"
    assert inherited["effective_persona"] == "新的全局写作人格"
    # Reset is idempotent and restores inheritance rather than a saved copy.
    assert client.delete(f"/api/v1/books/{book_id}/agent-personas/writer", headers=auth_headers).status_code == 204


def test_persona_resolution_is_book_scoped_and_frozen_at_agent_start(client, auth_headers):
    import app.routers.chapters as chapters_router

    first = client.post("/api/v1/books", headers=auth_headers, json={"title": "甲书"}).json()
    second = client.post("/api/v1/books", headers=auth_headers, json={"title": "乙书"}).json()
    for role in AGENT_ROLES:
        response = client.put(
            f"/api/v1/books/{first['id']}/agent-personas/{role}",
            headers=auth_headers,
            json={"editable_persona": f"甲书-{role}"},
        )
        assert response.status_code == 200
    with chapters_router.SessionLocal() as db:
        frozen_writer_persona = get_persona(db, "writer", book_id=first["id"])
        assert frozen_writer_persona == "甲书-writer"
        assert [get_persona(db, role, book_id=first["id"]) for role in AGENT_ROLES] == [
            f"甲书-{role}" for role in AGENT_ROLES
        ]
        assert get_persona(db, "writer", book_id=second["id"]) != frozen_writer_persona
        override = db.scalars(select(BookAgentPersona).where(
            BookAgentPersona.book_id == first["id"], BookAgentPersona.agent_role == "writer"
        )).first()
        assert override is not None
        override.editable_persona = "后来修改的人格"
        db.commit()
        # Jobs retain this already-resolved string, so a settings change only
        # applies to a subsequent job construction.
        assert frozen_writer_persona == "甲书-writer"
        assert get_persona(db, "writer", book_id=first["id"]) == "后来修改的人格"


def test_maintenance_rebuild_uses_the_book_extractor_persona(client, auth_headers, monkeypatch):
    import app.routers.chapters as chapters_router
    import scripts.rebuild_book_character_memory as rebuild_script

    book_data = client.post("/api/v1/books", headers=auth_headers, json={"title": "维护书"}).json()
    assert client.put(
        f"/api/v1/books/{book_data['id']}/agent-personas/extractor",
        headers=auth_headers,
        json={"editable_persona": "维护书专属 Extractor"},
    ).status_code == 200
    monkeypatch.setattr(rebuild_script, "build_llm_client", lambda _db, _role: object())
    with chapters_router.SessionLocal() as db:
        book = db.get(Book, book_data["id"])
        assert book is not None
        extractor = rebuild_script.build_book_extractor(db, book)
    assert extractor.system_prompt.startswith("维护书专属 Extractor\n\n")


def test_chapter_list_has_archive_health_without_detail_fetches(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    first = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={}).json()
    chapters = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    assert len(chapters) == 1
    assert chapters[0]["id"] == first["id"]
    assert chapters[0]["archive_status"] == "stale"
    assert chapters[0]["archive_schema"] == "none"
    assert chapters[0]["archive_can_retry"] is False
    assert chapters[0]["archive_latest_attempt_status"] == "stale"
    refreshed_book = client.get(f"/api/v1/books/{book['id']}", headers=auth_headers).json()
    assert refreshed_book["archive_pending_count"] == 0
    assert refreshed_book["archive_attention_count"] == 0


def test_inactive_archive_preview_is_display_only(client, auth_headers, wait_for_terminal):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "等待"}
    ).json()
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "人物停在门边，决定暂时等待。"},
    ).status_code == 200
    assert client.post(
        f"/api/v1/chapters/{chapter['id']}/accept",
        headers=auth_headers,
        json={"override_checker": True},
    ).status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    active = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["archive"]
    assert active["schema"] == "v2"
    assert active["inactive_preview"] is None

    # Changing accepted prose invalidates the old ledger revision.  Its compact
    # display preview is not returned as active summary/facts.
    assert client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers,
        json={"draft_text": "人物停在窗边，决定暂时等待。"},
    ).status_code == 200
    stale = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["archive"]
    assert stale["schema"] == "none"
    assert stale["summary"] == ""
    assert stale["facts"] == []
    assert stale["inactive_preview"]["status"] == "stale"
    assert stale["inactive_preview"]["summary"]
    refreshed_book = client.get(f"/api/v1/books/{book['id']}", headers=auth_headers).json()
    assert refreshed_book["archive_attention_count"] == 1
