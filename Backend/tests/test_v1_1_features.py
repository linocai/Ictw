from __future__ import annotations

import sqlite3

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import Base, make_engine
from app.llm.base import LLMError
from app.models import Book, Chapter, Character, JobRun, LLMCallAudit
from app.services.context import (
    CHARACTER_EVENT_MAX_CHARS,
    MEMORY_SUMMARY_MAX_ITEMS,
    MemoryBlock,
    draft_violations,
    nonspace_len,
    pack_selected_memories,
    scan_known_character_names,
    truncate_to_nonspace,
    word_count_bounds,
)


class FixedText:
    def __init__(self, text: str) -> None:
        self.text = text
        self.calls = 0
        self.last_finish_reason = "stop"
        self.model_name = "test-model"
        self.last_usage = {"prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7}

    def complete_stream(self, **kwargs):
        self.calls += 1
        yield from self.text

    def complete(self, **kwargs):
        self.calls += 1
        return self.text

    def complete_json(self, **kwargs):
        return {"memory_ids": []}


# --- B3 word count ------------------------------------------------------------


def test_word_count_bounds_are_80_120():
    assert word_count_bounds(100) == (80, 120)
    assert word_count_bounds(3000) == (2400, 3600)


def test_draft_violation_word_count_boundary(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'wc.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        db.add_all([Book(id="b", title="书"), Chapter(id="c", book_id="b", index=1, target_word_count=100)])
        db.commit()
        chapter = db.get(Chapter, "c")
        assert draft_violations(db, chapter, "字" * 80, "stop") == []
        low = draft_violations(db, chapter, "字" * 79, "stop")
        assert any(item["code"] == "word_count" for item in low)


# --- B3 summary packing -------------------------------------------------------


def test_summary_packing_caps_at_two():
    blocks = [
        MemoryBlock("s1", "第一章梗概：一", 1, memory_type="summary"),
        MemoryBlock("s2", "第二章梗概：二", 2, memory_type="summary"),
        MemoryBlock("s3", "第三章梗概：三", 3, memory_type="summary"),
        MemoryBlock("h1", "第一章大事记：甲", 1, memory_type="headline"),
        MemoryBlock("e1", "第一章人物故事线：乙", 1, memory_type="character_event"),
    ]
    packed = pack_selected_memories(blocks, ["s1", "s2", "s3", "h1", "e1"], 10_000)
    ids = [block.id for block in packed]
    assert sum(1 for block in packed if block.memory_type == "summary") == MEMORY_SUMMARY_MAX_ITEMS
    assert "s3" not in ids
    assert "h1" in ids and "e1" in ids


# --- B3 short name boundary ---------------------------------------------------


def test_short_name_left_boundary_and_two_char_substring():
    lin = Character(id="lin", book_id="b", name="林")
    linxi = Character(id="linxi", book_id="b", name="林夕")

    forest, _ = scan_known_character_names("森林深处", [lin])
    assert lin not in forest

    enters, _ = scan_known_character_names("林进入废城", [lin])
    assert lin in enters

    two_char, _ = scan_known_character_names("对林夕说", [linxi])
    assert linxi in two_char

    longest, _ = scan_known_character_names("林夕进入", [lin, linxi])
    assert linxi in longest and lin not in longest


# --- B3 chapter exemption -----------------------------------------------------


def test_draft_violations_respect_exemption(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'exempt.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        db.add_all(
            [
                Book(id="b", title="书"),
                Character(id="p", book_id="b", name="赵一"),
                Chapter(id="c", book_id="b", index=1, target_word_count=6, exempted_character_names=["赵一"]),
            ]
        )
        db.commit()
        chapter = db.get(Chapter, "c")
        violations = draft_violations(db, chapter, "赵一赵一赵一", "stop")
        assert not any(item["code"] == "unselected_character" for item in violations)


def test_chapter_exemption_relaxes_preflight(client, auth_headers, wait_for_terminal):
    from app.llm.factory import get_writer_client

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    client.post(f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "赵一"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "赵一出现", "target_word_count": 6},
    ).json()

    blocked = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    assert blocked.status_code == 409
    assert blocked.json()["detail"]["code"] == "unselected_characters_in_bible"
    assert blocked.json()["detail"]["details"]["names"] == ["赵一"]

    patched = client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers, json={"exempted_character_names": ["赵一"]}
    ).json()
    assert patched["exempted_character_names"] == ["赵一"]

    client.app.dependency_overrides[get_writer_client] = lambda: FixedText("字" * 6)
    started = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    assert started.status_code == 200
    wait_for_terminal(client, chapter["id"], auth_headers)


# --- B1 job persistence / restart recovery ------------------------------------


def test_recover_interrupted_jobs_marks_failed(client, auth_headers):
    import app.db as db_module
    from app.main import recover_interrupted_chapters

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": "章"}).json()

    db = db_module.SessionLocal()
    try:
        ch = db.get(Chapter, chapter["id"])
        ch.status = "writing"
        run = JobRun(chapter_id=chapter["id"], kind="write", phase="writing")
        db.add(run)
        db.commit()
        run_id = run.id
        recover_interrupted_chapters(db)
        db.expire_all()
        recovered = db.get(JobRun, run_id)
        assert recovered.phase == "failed"
        assert recovered.error_code == "interrupted"
        assert recovered.finished_at is not None
        assert db.get(Chapter, chapter["id"]).status == "draft"
    finally:
        db.close()


# --- B4 LLM audit -------------------------------------------------------------


def test_llm_audit_records_writer_row_without_secrets(client, auth_headers, wait_for_terminal):
    import app.db as db_module
    from app.llm.factory import get_writer_client

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "target_word_count": 20},
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: FixedText("文" * 20)
    assert client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    db = db_module.SessionLocal()
    try:
        rows = db.scalars(select(LLMCallAudit)).all()
    finally:
        db.close()
    writer_rows = [row for row in rows if row.agent_role == "writer"]
    assert writer_rows
    assert writer_rows[0].model_name == "test-model"
    assert writer_rows[0].total_tokens == 7

    columns = set(LLMCallAudit.__table__.columns.keys())
    assert not (columns & {"api_key", "prompt", "content", "draft_text", "system_prompt", "body"})


def test_llm_audit_records_error_code_on_failure(client, auth_headers, wait_for_terminal):
    import app.db as db_module
    from app.llm.factory import get_writer_client

    class FailingWriter(FixedText):
        def complete_stream(self, **kwargs):
            raise LLMError("upstream", code="llm_upstream_unavailable", retryable=True)
            yield  # pragma: no cover - keep generator

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "target_word_count": 20},
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: FailingWriter("")
    assert client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "failed"

    db = db_module.SessionLocal()
    try:
        rows = db.scalars(select(LLMCallAudit)).all()
    finally:
        db.close()
    assert any(row.agent_role == "writer" and row.error_code == "llm_upstream_unavailable" for row in rows)


def test_llm_audit_records_upstream_reason_without_prompt_or_key(client, auth_headers, wait_for_terminal):
    import app.db as db_module
    from app.llm.factory import get_writer_client

    class FailingWriter(FixedText):
        def complete_stream(self, **kwargs):
            raise LLMError(
                "upstream rejected",
                code="llm_upstream_rejected",
                status_code=400,
                upstream_reason="content policy violation | invalid_request_error | invalid_request_error_type",
            )
            yield  # pragma: no cover - keep generator

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "target_word_count": 20},
    ).json()
    client.app.dependency_overrides[get_writer_client] = lambda: FailingWriter("")
    assert client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "failed"

    db = db_module.SessionLocal()
    try:
        rows = db.scalars(select(LLMCallAudit)).all()
    finally:
        db.close()
    writer_rows = [row for row in rows if row.agent_role == "writer"]
    assert writer_rows
    assert (
        writer_rows[0].upstream_reason
        == "content policy violation | invalid_request_error | invalid_request_error_type"
    )

    # Same invariant as test_llm_audit_records_writer_row_without_secrets, re-asserted
    # here because this row is the one that actually carries a populated upstream_reason.
    columns = set(LLMCallAudit.__table__.columns.keys())
    assert not (columns & {"api_key", "prompt", "content", "draft_text", "system_prompt", "body"})


# --- B4 character event editing / truncation ----------------------------------


def _finalize_with_event(client, auth_headers, wait_for_terminal, event_text: str | None = None):
    from app.llm.factory import get_extractor_client

    if event_text is not None:
        class LongExtractor:
            def complete_json(self, **kwargs):
                return {
                    "summary": "梗概",
                    "headline": "大事",
                    "character_events": [{"character_id": pytest.character_id, "event_text": event_text}],
                    "dynamic_fields_patch": [],
                }

        client.app.dependency_overrides[get_extractor_client] = lambda: LongExtractor()

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
    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "林夕行动"})
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    return character


def test_character_event_patch_delete_and_truncate(client, auth_headers, wait_for_terminal):
    character = _finalize_with_event(client, auth_headers, wait_for_terminal)
    event = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"][0]

    patched = client.patch(
        f"/api/v1/character-events/{event['id']}", headers=auth_headers, json={"event_text": "字" * 80}
    )
    assert patched.status_code == 200
    assert nonspace_len(patched.json()["event_text"]) == CHARACTER_EVENT_MAX_CHARS
    assert patched.json()["chapter_index"] is not None

    deleted = client.delete(f"/api/v1/character-events/{event['id']}", headers=auth_headers)
    assert deleted.status_code == 204
    assert client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"] == []


def test_extractor_truncates_long_event_text(client, auth_headers, wait_for_terminal):
    character = _finalize_with_event(client, auth_headers, wait_for_terminal, event_text="字" * 80)
    events = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"]
    assert len(events) == 1
    assert nonspace_len(events[0]["event_text"]) == CHARACTER_EVENT_MAX_CHARS


def test_truncate_to_nonspace_helper():
    assert truncate_to_nonspace("abcdef", 3) == "abc"
    assert nonspace_len(truncate_to_nonspace("字" * 80, 60)) == 60
    assert truncate_to_nonspace("ab", 5) == "ab"
    assert truncate_to_nonspace("anything", 0) == ""


# --- B5 chapter patch summary/headline + version ------------------------------


def test_chapter_patch_summary_and_headline(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": "章"}).json()
    patched = client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers, json={"summary": "新梗概", "headline": "新大事"}
    ).json()
    assert patched["summary"] == "新梗概"
    assert patched["headline"] == "新大事"


def test_health_reports_current_version(client, auth_headers):
    assert client.get("/api/v1/health", headers=auth_headers).json()["version"] == "1.1.2"


# --- B8 migration from the production revision --------------------------------


def test_v1_1_migration_upgrades_from_v1_head(tmp_path, monkeypatch):
    database_path = tmp_path / "v1_1_migration.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("DATABASE_URL", database_url)
    get_settings.cache_clear()
    config = Config("alembic.ini")
    command.upgrade(config, "20260710_0002")

    connection = sqlite3.connect(database_path)
    try:
        connection.executescript(
            """
            PRAGMA foreign_keys=ON;
            INSERT INTO books VALUES('b','书','世界','2026-01-01','2026-01-01',NULL);
            INSERT INTO chapters VALUES(
                'c','b',1,'章','Bible',3000,'备注','正文','','','draft','agent','2026-01-01','2026-01-01'
            );
            """
        )
        connection.commit()
    finally:
        connection.close()

    command.upgrade(config, "head")
    engine = make_engine(database_url)
    with engine.connect() as migrated:
        assert migrated.execute(text("SELECT exempted_character_names FROM chapters WHERE id='c'")).scalar_one() == "[]"
        table_names = {
            row[0]
            for row in migrated.exec_driver_sql(
                "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('job_runs','llm_call_audits')"
            ).fetchall()
        }
        assert table_names == {"job_runs", "llm_call_audits"}
        assert migrated.exec_driver_sql("PRAGMA foreign_key_check").fetchall() == []
    get_settings.cache_clear()
