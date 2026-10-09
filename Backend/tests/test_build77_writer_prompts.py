"""Writer prompt assembly and explicit, reversible-by-backup persona maintenance."""
import hashlib
import json
import sqlite3

import pytest

from app.llm.factory import get_checker_client, get_writer_client
from app.persona_contract import BIBLE_FOCUS_PERSONAS, COMPACT_WRITER_PERSONA
from scripts import compact_writer_personas as maintenance


@pytest.mark.parametrize("bible", [
    "雨停后修好窗户，停在准备离开，不要写出门后的事。",
    "一句话本章：修窗。\n情节分点发展：\n1. 先写今夜窗已修好。\n2. 再回忆下午修窗的经过。\n收束边界：回到今夜，停在准备离开。",
])
@pytest.mark.parametrize("custom_persona", [None, "保留我自定的简短段落风格。"])
def test_actual_write_keeps_free_bible_and_one_plot_contract(
    client, auth_headers, wait_for_terminal, bible, custom_persona,
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "合成写作"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
                          json={"title": "雨停", "user_prompt": bible}).json()
    if custom_persona:
        client.put(f"/api/v1/books/{book['id']}/agent-personas/writer", headers=auth_headers,
                   json={"editable_persona": custom_persona}).raise_for_status()
    calls = {"writer": [], "checker": []}

    class Writer:
        last_finish_reason = "stop"

        def complete_stream(self, **kwargs):
            calls["writer"].append(kwargs)
            yield "窗外下着雨。" * 800

    class Checker:
        def complete_json(self, **kwargs):
            calls["checker"].append(kwargs)
            return {"verdict": "passed", "issues": [], "name_uses": []}

    client.app.dependency_overrides[get_writer_client] = Writer
    client.app.dependency_overrides[get_checker_client] = Checker
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter['id'], auth_headers)["phase"] == "done"
    assert len(calls["writer"]) == len(calls["checker"]) == 1
    writer = calls["writer"][0]
    assert writer["system"].startswith((custom_persona or COMPACT_WRITER_PERSONA) + "\n\n")
    assert BIBLE_FOCUS_PERSONAS["writer"] not in writer["system"]
    combined = writer["system"] + writer["user"]
    assert combined.count("Bible 中情节分点的排列顺序") == 1
    assert combined.count("在作者指定的落点收束") == 1
    assert "不得自行改成时间顺序" in writer["system"]
    assert "不要求固定格式" in writer["system"]
    assert "篇幅不足也不能成为越界的理由" in writer["system"]
    assert "# 最终执行契约" not in writer["user"]
    assert "至少 4000 个去空白字符" in writer["user"]
    assert f"标题：雨停\n\n{bible}\n\n# 输出要求" in writer["user"]
    checker = calls["checker"][0]
    assert "不得强求时间顺序" in checker["system"]
    assert "不因Bible未采用提示格式或缺少栏目而补造要求" in checker["system"]
    assert bible in checker["user"]
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["user_prompt"] == bible


@pytest.fixture()
def persona_database(tmp_path, monkeypatch):
    path = tmp_path / "personas.db"
    reviewed = {"agent_personas": "合成已审阅全局稿", "book_agent_personas": "合成已审阅单书稿"}
    monkeypatch.setattr(maintenance, "REVIEWED_SOURCE_SHA256", {
        table: hashlib.sha256(text.encode()).hexdigest() for table, text in reviewed.items()
    })
    with sqlite3.connect(path) as db:
        db.execute("CREATE TABLE agent_personas(agent_role TEXT PRIMARY KEY, system_prompt TEXT, content_revision INTEGER, updated_at TEXT)")
        db.execute("CREATE TABLE book_agent_personas(id TEXT PRIMARY KEY, agent_role TEXT, editable_persona TEXT, content_revision INTEGER, updated_at TEXT)")
        db.execute("CREATE TABLE agent_model_bindings(agent_role TEXT PRIMARY KEY, temperature REAL)")
        db.executemany("INSERT INTO agent_personas VALUES(?,?,?,?)", [
            ("writer", reviewed['agent_personas'], 7, "old"),
            ("extractor", "归档人格不动", 3, "old"), ("checker", "检查人格不动", 5, "old"),
        ])
        db.executemany("INSERT INTO book_agent_personas VALUES(?,?,?,?,?)", [
            ("reviewed", "writer", reviewed['book_agent_personas'], 9, "old"),
            ("custom", "writer", reviewed['book_agent_personas'] + "，后来作者追加", 12, "old"),
            ("extractor", "extractor", "单书归档不动", 4, "old"),
        ])
        db.execute("INSERT INTO agent_model_bindings VALUES('extractor',0.1)")
    return path


def test_maintenance_dry_run_apply_idempotence_and_custom_protection(persona_database):
    path = persona_database
    before = path.read_bytes()
    report = maintenance.compact(path)
    assert path.read_bytes() == before
    assert report['agent_personas']['eligible'] == report['book_agent_personas']['eligible'] == 1
    assert report['book_agent_personas']['preserved_custom'] == 1
    assert all(row['updated'] == 0 for row in report.values())
    report = maintenance.compact(path, apply=True)
    assert report['agent_personas']['updated'] == report['book_agent_personas']['updated'] == 1
    assert "合成" not in json.dumps(report, ensure_ascii=False)
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT system_prompt,content_revision FROM agent_personas WHERE agent_role='writer'").fetchone() == (maintenance.REVIEWED_WRITER_PERSONA, 8)
        assert db.execute("SELECT editable_persona,content_revision FROM book_agent_personas WHERE id='reviewed'").fetchone() == (maintenance.REVIEWED_WRITER_PERSONA, 10)
        assert db.execute("SELECT content_revision,updated_at FROM book_agent_personas WHERE id='custom'").fetchone() == (12, "old")
        assert db.execute("SELECT system_prompt,content_revision,updated_at FROM agent_personas WHERE agent_role='extractor'").fetchone() == ("归档人格不动", 3, "old")
        assert db.execute("SELECT system_prompt,content_revision,updated_at FROM agent_personas WHERE agent_role='checker'").fetchone() == ("检查人格不动", 5, "old")
        assert db.execute("SELECT editable_persona,content_revision,updated_at FROM book_agent_personas WHERE id='extractor'").fetchone() == ("单书归档不动", 4, "old")
        assert db.execute("SELECT temperature FROM agent_model_bindings").fetchone() == (0.1,)
    after = path.read_bytes()
    repeated = maintenance.compact(path, apply=True)
    assert path.read_bytes() == after
    assert all(row['updated'] == 0 and row['already_current'] == 1 for row in repeated.values())
    assert "中文R18小说创作者" in maintenance.REVIEWED_WRITER_PERSONA


def test_maintenance_second_table_failure_rolls_back_first(persona_database):
    with sqlite3.connect(persona_database) as db:
        db.execute("CREATE TRIGGER reject_book BEFORE UPDATE ON book_agent_personas BEGIN SELECT RAISE(ABORT,'synthetic_failure'); END")
    before = persona_database.read_bytes()
    with pytest.raises(sqlite3.IntegrityError, match="synthetic_failure"):
        maintenance.compact(persona_database, apply=True)
    assert persona_database.read_bytes() == before


def test_maintenance_never_creates_a_database(tmp_path):
    path = tmp_path / "missing.db"
    with pytest.raises(sqlite3.OperationalError):
        maintenance.compact(path, apply=True)
    assert not path.exists()
