"""Build70: API, explicit upgrade and project restore share one safe capacity."""
import sqlite3
from pathlib import Path

import pytest

from app.config import get_settings
from app.persona_contract import (
    BIBLE_FOCUS_PERSONAS, EDITABLE_PERSONA_MAX_LENGTH, with_bible_focus,
)
from scripts.upgrade_bible_personas import upgrade


def _database(tmp_path, first, second):
    path = tmp_path / "personas.db"
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE agent_personas(agent_role TEXT PRIMARY KEY, system_prompt TEXT, content_revision INTEGER, updated_at TEXT)")
        db.execute("CREATE TABLE book_agent_personas(id TEXT PRIMARY KEY, agent_role TEXT, editable_persona TEXT, content_revision INTEGER, updated_at TEXT)")
        db.execute("INSERT INTO agent_personas VALUES('writer',?,7,'old')", (first,))
        db.execute("INSERT INTO book_agent_personas VALUES('one','checker',?,4,'old')", (second,))
    return path


def _snapshot(path):
    with sqlite3.connect(path) as db:
        return (db.execute("SELECT * FROM agent_personas").fetchall(),
                db.execute("SELECT * FROM book_agent_personas").fetchall())


@pytest.mark.parametrize("size", [7900, 8000])
def test_original_capacity_preserved_dry_run_apply_and_idempotence(tmp_path, size):
    original = "稿" * (size - 2) + " \n"
    path = _database(tmp_path, original, original)
    before = _snapshot(path)
    assert EDITABLE_PERSONA_MAX_LENGTH == 8230
    assert upgrade(path) == {"agent_personas": 1, "book_agent_personas": 1}
    assert _snapshot(path) == before
    assert upgrade(path, apply=True) == {"agent_personas": 1, "book_agent_personas": 1}
    after = _snapshot(path)
    assert after[0][0][1] == original + "\n\n" + BIBLE_FOCUS_PERSONAS["writer"]
    assert after[1][0][2] == original + "\n\n" + BIBLE_FOCUS_PERSONAS["checker"]
    assert after[0][0][2] == 8 and after[1][0][3] == 5
    assert upgrade(path, apply=True) == {"agent_personas": 0, "book_agent_personas": 0}
    assert _snapshot(path) == after


@pytest.mark.parametrize("apply", [False, True])
@pytest.mark.parametrize("already_upgraded", [False, True])
def test_capacity_failure_leaves_both_tables_unchanged(tmp_path, apply, already_upgraded):
    invalid = "保密作者原文" * EDITABLE_PERSONA_MAX_LENGTH
    if already_upgraded:
        invalid += BIBLE_FOCUS_PERSONAS["checker"]
    path = _database(tmp_path, "合法先行记录", invalid)
    before = _snapshot(path)
    with pytest.raises(ValueError, match="persona_upgrade_capacity_exceeded") as exc:
        upgrade(path, apply=apply)
    assert "保密作者原文" not in str(exc.value)
    assert _snapshot(path) == before


@pytest.mark.parametrize("role", ["writer", "checker"])
def test_api_upgrade_save_export_restore_capacity(client, auth_headers, role):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "容量回归"}).json()
    path = f"/api/v1/books/{book['id']}/agent-personas/{role}"
    original = "作者原文" * 2000
    assert client.put(path, headers=auth_headers, json={"editable_persona": original}).status_code == 200
    global_path = f"/api/v1/agent-personas/{role}"
    assert client.patch(global_path, headers=auth_headers, json={"system_prompt": original}).status_code == 200
    db_path = Path(get_settings().database_url.removeprefix("sqlite:///"))
    upgrade(db_path, apply=True)
    upgraded = with_bible_focus(role, original)
    assert len(upgraded) <= EDITABLE_PERSONA_MAX_LENGTH
    book_read = client.get(path, headers=auth_headers).json()
    assert book_read["book_persona"] == upgraded
    assert book_read["global_persona"] == upgraded
    assert client.put(path, headers={**auth_headers, "If-Match": str(book_read['content_revision'])},
                      json={"system_prompt": upgraded}).status_code == 200
    global_read = next(p for p in client.get("/api/v1/agent-personas", headers=auth_headers).json()
                       if p["agent_role"] == role)
    assert client.patch(global_path, headers={**auth_headers, "If-Match": str(global_read['content_revision'])},
                        json={"editable_persona": upgraded}).status_code == 200
    exported = client.get(f"/api/v1/books/{book['id']}/project-export", headers=auth_headers)
    assert exported.status_code == 200, exported.text
    restored = client.post("/api/v1/books/project-import", headers=auth_headers, content=exported.content)
    assert restored.status_code == 201, restored.text
    restored_book = restored.json()
    restored_id = restored_book.get("id") or restored_book.get("book_id") or restored_book["book"]["id"]
    read = client.get(f"/api/v1/books/{restored_id}/agent-personas/{role}", headers=auth_headers)
    assert read.json()["book_persona"] == upgraded
    oversized = "文" * (EDITABLE_PERSONA_MAX_LENGTH + 1)
    assert client.put(path, headers=auth_headers, json={"editable_persona": oversized}).status_code == 422
    assert client.patch(global_path, headers=auth_headers, json={"system_prompt": oversized}).status_code == 422
