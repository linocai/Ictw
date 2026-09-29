"""Synthetic regressions: stable rewrites, invalidation, editable-only Bible focus."""
import sqlite3
from threading import Event

import pytest
from sqlalchemy import select

import app.db as db_module
from app.llm.factory import get_memory_selector_client, get_writer_client
from app.models import AgentPersona, Chapter, ChapterCharacter, Character, JobRun
from app.services.personas import BIBLE_FOCUS_PERSONAS, DEFAULT_PERSONAS, PROGRAM_PROTOCOLS
from conftest import FakeWriter
from scripts.upgrade_bible_personas import upgrade
from test_v2_2_checker_context import _story


def setup_writer(client):
    calls, messages = [], []
    class Selector:
        def complete_json(self, **kwargs):
            calls.append(1)
            return {"briefs": [{"text": "林夕已归还钥匙。", "source_ids": ["M1"]}],
                    "conflicts": [], "previous_ending_start_id": "E1"}
    class Writer(FakeWriter):
        def complete_stream(self, **kwargs):
            messages.append(kwargs["user"])
            yield "稿" * 4000
    client.app.dependency_overrides[get_memory_selector_client] = Selector
    client.app.dependency_overrides[get_writer_client] = Writer
    return calls, messages


def write(client, auth_headers, wait_for_terminal, cid):
    response = client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers, json={"replace_draft": True})
    response.raise_for_status()
    result = wait_for_terminal(client, cid, auth_headers)
    assert result["phase"] == "done", result
    return result


def test_repeated_writes_reuse_persisted_reference_not_previous_draft(client, auth_headers, wait_for_terminal):
    cid, _, _ = _story()
    calls, messages = setup_writer(client)
    write(client, auth_headers, wait_for_terminal, cid)
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, cid)
        chapter.draft_text = "上一版偏离内容，不得进入新输入"
        db.commit()
    # Dependency must not be resolved on reuse; database survives all job objects.
    def unavailable():
        raise AssertionError("cached selection must not call Selector")
    client.app.dependency_overrides[get_memory_selector_client] = unavailable
    for _ in range(2):
        write(client, auth_headers, wait_for_terminal, cid)
    assert len(calls) == 1 and len(messages) == 3
    assert messages[0] == messages[1] == messages[2]
    assert "上一版偏离内容" not in messages[-1]
    with db_module.SessionLocal() as db:
        runs = list(db.scalars(select(JobRun).where(JobRun.chapter_id == cid)))
        assert len({r.input_snapshot["rewrite_reference_key"] for r in runs}) == 1


@pytest.mark.parametrize("change", ["bible", "world", "character", "selection", "history", "ending", "selector_persona"])
def test_changed_inputs_reselect_reference(client, auth_headers, wait_for_terminal, change):
    cid, prior_id, _ = _story()
    calls, messages = setup_writer(client)
    write(client, auth_headers, wait_for_terminal, cid)
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, cid)
        if change == "bible": chapter.user_prompt += " 在门口结束。"
        elif change == "world": chapter.book.world_setting += " 正在冬季。"
        elif change == "character": chapter.character_links[0].character.fixed_profile += " 性格沉稳。"
        elif change == "selection":
            other = db.scalars(select(Character).where(Character.book_id == chapter.book_id, Character.name == "夏天")).one()
            chapter.character_links.append(ChapterCharacter(character_id=other.id))
        elif change == "history": db.get(Chapter, prior_id).long_summary += " 并锁上门。"
        elif change == "ending": db.get(Chapter, prior_id).draft_text += " 雨停了。"
        else: db.get(AgentPersona, "memory_selector").system_prompt += " 优先保留地点。"
        db.commit()
    write(client, auth_headers, wait_for_terminal, cid)
    assert len(calls) == 2


def test_corrupt_saved_manifest_falls_back_to_fresh_selection(client, auth_headers, wait_for_terminal):
    cid, _, _ = _story()
    calls, _ = setup_writer(client)
    result = write(client, auth_headers, wait_for_terminal, cid)
    with db_module.SessionLocal() as db:
        run = db.get(JobRun, result["job_id"])
        run.memory_context = {"memory_brief": [{"text": "bad", "source_ids": ["missing"]}]}
        db.commit()
    write(client, auth_headers, wait_for_terminal, cid)
    assert len(calls) == 2


def test_world_changes_during_preparation_retire_job_and_restore_old_draft(client, auth_headers, wait_for_terminal):
    cid, _, _ = _story()
    _, messages = setup_writer(client)
    started, release = Event(), Event()
    class BlockingSelector:
        def complete_json(self, **kwargs):
            started.set()
            assert release.wait(5)
            return {"briefs": [], "conflicts": [], "previous_ending_start_id": None}
    client.app.dependency_overrides[get_memory_selector_client] = BlockingSelector
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, cid)
        chapter.draft_text = "已有正文"
        chapter.status = "draft_ready"
        db.commit()
    try:
        client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers, json={"replace_draft": True}).raise_for_status()
        assert started.wait(5)
        with db_module.SessionLocal() as db:
            db.get(Chapter, cid).book.world_setting += " 冬季。"
            db.commit()
    finally:
        release.set()
    result = wait_for_terminal(client, cid, auth_headers)
    assert result["phase"] == "failed" and result["error_code"] == "production_input_changed"
    assert not messages
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, cid)
        assert chapter.draft_text == "已有正文" and chapter.status == "draft_ready"


def test_bible_focus_is_editable_persona_and_checker_protocol_uses_group_ids():
    for role, text in BIBLE_FOCUS_PERSONAS.items():
        assert text in DEFAULT_PERSONAS[role]
        assert text not in PROGRAM_PROTOCOLS[role]
    assert "每项含 group_id" in PROGRAM_PROTOCOLS["checker"]
    assert "每项含 hit_ids" not in PROGRAM_PROTOCOLS["checker"]


def test_explicit_persona_upgrade_preserves_custom_text_and_is_idempotent(tmp_path):
    path = tmp_path / "personas.db"
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE agent_personas(agent_role TEXT PRIMARY KEY, system_prompt TEXT, content_revision INTEGER, updated_at TEXT)")
        db.execute("CREATE TABLE book_agent_personas(id TEXT PRIMARY KEY, agent_role TEXT, editable_persona TEXT, content_revision INTEGER, updated_at TEXT)")
        db.execute("INSERT INTO agent_personas VALUES('writer','作者自定文风',7,'old')")
        db.execute("INSERT INTO agent_personas VALUES('extractor','不动',2,'old')")
        db.execute("INSERT INTO book_agent_personas VALUES('one','checker','单书检查人格',4,'old')")
    assert upgrade(path) == {"agent_personas": 1, "book_agent_personas": 1}
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT system_prompt FROM agent_personas WHERE agent_role='writer'").fetchone()[0] == "作者自定文风"
    upgrade(path, apply=True)
    assert upgrade(path, apply=True) == {"agent_personas": 0, "book_agent_personas": 0}
    with sqlite3.connect(path) as db:
        text, revision = db.execute("SELECT system_prompt,content_revision FROM agent_personas WHERE agent_role='writer'").fetchone()
        assert text.startswith("作者自定文风\n\n") and revision == 8
        assert db.execute("SELECT content_revision FROM book_agent_personas").fetchone()[0] == 5
        assert db.execute("SELECT system_prompt,content_revision FROM agent_personas WHERE agent_role='extractor'").fetchone() == ("不动", 2)
