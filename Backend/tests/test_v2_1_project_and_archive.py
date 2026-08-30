from __future__ import annotations

import hashlib
import io
import json
import zipfile

from sqlalchemy import event, select

import app.db as db_module
from app.models import (
    Book,
    BookAgentModelBinding,
    Chapter,
    ChapterArchiveFact,
    ChapterArchiveFactParticipant,
    ChapterArchiveRevision,
    ChapterArchiveStateDelta,
    ChapterCharacter,
    Character,
    ChapterDraftCandidate,
)
from app.services.archive_v2 import active_archive_revision, archive_health_summaries, archive_input_fingerprint


def _accepted_archive(db, chapter: Chapter, character: Character | None = None) -> None:
    if character is not None:
        db.add(ChapterCharacter(chapter_id=chapter.id, character_id=character.id))
        db.flush()
    revision = ChapterArchiveRevision(
        chapter_id=chapter.id,
        revision=1,
        provenance="manual_retry",
        input_fingerprint="0" * 64,
        status="complete",
        is_active=True,
        summary=f"第 {chapter.index} 章摘要",
    )
    db.add(revision)
    db.flush()
    fact = ChapterArchiveFact(
        revision_id=revision.id,
        position=1,
        fact_ref="F1",
        fact_type="剧情",
        importance=3,
        fact_text=f"第 {chapter.index} 章发生行动。",
        start_id="P0001-S01",
        end_id="P0001-S01",
    )
    db.add(fact)
    db.flush()
    if character is not None:
        db.add(ChapterArchiveFactParticipant(fact_id=fact.id, character_id=character.id, position=1))
    chapter.active_archive_revision_id = revision.id
    chapter.archive_status = "complete"
    db.flush()
    revision.input_fingerprint = archive_input_fingerprint(chapter)
    chapter.archive_input_fingerprint = revision.input_fingerprint


def _strict_health(db, chapters: list[Chapter]) -> dict[str, tuple[str, str]]:
    """The old detail-grade decision, used as an equivalence oracle."""
    result: dict[str, tuple[str, str]] = {}
    for chapter in chapters:
        revision = active_archive_revision(db, chapter)
        if revision is not None:
            result[chapter.id] = ("v2", "complete")
        elif chapter.status == "finalized" and chapter.legacy_archive_eligible:
            result[chapter.id] = ("legacy", "complete")
        else:
            result[chapter.id] = ("none", chapter.archive_status)
    return result


def _seed_long_book(count: int) -> str:
    with db_module.SessionLocal() as db:
        book = Book(title=f"长书 {count}")
        db.add(book)
        db.flush()
        character = Character(book_id=book.id, name="林昭")
        db.add(character)
        db.flush()
        for index in range(1, count + 1):
            chapter = Chapter(
                book_id=book.id,
                index=index,
                title=f"第 {index} 章",
                draft_text=f"第 {index} 章正文。",
                status="finalized",
            )
            db.add(chapter)
            db.flush()
            _accepted_archive(db, chapter, character)
            if index == 1:
                revision = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id)
                assert revision is not None
                fact = db.scalars(
                    select(ChapterArchiveFact).where(ChapterArchiveFact.revision_id == revision.id)
                ).one()
                db.add(
                    ChapterArchiveStateDelta(
                        revision_id=revision.id,
                        fact_id=fact.id,
                        position=1,
                        character_id=character.id,
                        other_character_id=None,
                        scope="persistent",
                        slot="当前目标",
                        operation="set",
                        value="抵达旧城",
                        batch_id="",
                    )
                )
                db.flush()
        db.commit()
        return book.id


def _health_statement_count(book_id: str) -> tuple[int, dict[str, tuple[str, str]]]:
    engine = db_module.engine
    count = 0

    def observe(*_args, **_kwargs):
        nonlocal count
        count += 1

    with db_module.SessionLocal() as db:
        chapters = db.scalars(
            select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index)
        ).all()
        event.listen(engine, "before_cursor_execute", observe)
        try:
            health = archive_health_summaries(db, chapters)
        finally:
            event.remove(engine, "before_cursor_execute", observe)
        return count, {
            chapter.id: (health[chapter.id]["archive_schema"], health[chapter.id]["archive_status"])
            for chapter in chapters
        }


def test_archive_health_list_is_equivalent_to_strict_detail_and_has_fixed_query_bound(client):
    small_book = _seed_long_book(4)
    large_book = _seed_long_book(40)
    small_count, small_health = _health_statement_count(small_book)
    large_count, large_health = _health_statement_count(large_book)

    # The list path has five prefetch queries (revisions, active deltas,
    # legacy rows, links, characters), regardless of chapter count.
    assert small_count == large_count == 5
    with db_module.SessionLocal() as db:
        for book_id, listed in ((small_book, small_health), (large_book, large_health)):
            chapters = db.scalars(
                select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index)
            ).all()
            assert listed == _strict_health(db, chapters)


def _zip_entries(package: bytes) -> dict[str, bytes]:
    with zipfile.ZipFile(io.BytesIO(package)) as archive:
        return {name: archive.read(name) for name in archive.namelist()}


def _repack(entries: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, value in entries.items():
            archive.writestr(name, value)
    return buffer.getvalue()


def _refresh_manifest(entries: dict[str, bytes]) -> None:
    manifest = json.loads(entries["manifest.json"])
    for name, raw in entries.items():
        if name == "manifest.json":
            continue
        manifest["entries"][name] = {"sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw)}
    entries["manifest.json"] = json.dumps(
        manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def test_project_package_round_trip_rebuilds_visible_data_and_excludes_hidden_records(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "备份书", "world_setting": "旧城"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林昭", "role": "主角"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "开端", "user_prompt": "雨夜", "character_links": [{"character_id": character["id"]}]},
    ).json()
    with db_module.SessionLocal() as db:
        row = db.get(Chapter, chapter["id"])
        person = db.get(Character, character["id"])
        assert row is not None and person is not None
        row.draft_text = "林昭在雨夜抵达旧城。"
        row.status = "finalized"
        _accepted_archive(db, row)  # link already belongs to the chapter
        db.add(
            ChapterDraftCandidate(
                chapter_id=row.id,
                attempt=1,
                draft_text="绝不能出现在备份中的隐藏候选",
                non_whitespace_count=999,
                checker_result={"draft_evidence": "绝不能出现在备份中的拒绝证据"},
            )
        )
        db.add(
            BookAgentModelBinding(
                book_id=book["id"], agent_role="writer", llm_profile_id=None,
                thinking_enabled=False, reasoning_effort=None, temperature=0.7,
            )
        )
        db.commit()

    exported = client.get(f"/api/v1/books/{book['id']}/project-export", headers=auth_headers)
    assert exported.status_code == 200
    assert exported.headers["content-type"].startswith("application/vnd.ictw.project+zip")
    entries = _zip_entries(exported.content)
    visible_payload = b"".join(entries.values()).decode("utf-8")
    assert "绝不能出现在备份中的隐藏候选" not in visible_payload
    assert "draft_evidence" not in visible_payload
    assert set(entries) == {
        "manifest.json", "book.json", "characters.json", "chapters.json", "archives.json", "personas.json", "model-bindings.json"
    }

    restored = client.post(
        "/api/v1/books/project-import",
        headers={**auth_headers, "Content-Type": "application/vnd.ictw.project+zip"},
        content=exported.content,
    )
    assert restored.status_code == 201, restored.text
    restored_book = restored.json()
    assert restored_book["book_id"] != book["id"]
    assert restored_book["title"] == "备份书"
    chapters = client.get(f"/api/v1/books/{restored_book['book_id']}/chapters", headers=auth_headers).json()
    assert len(chapters) == 1
    detail = client.get(f"/api/v1/chapters/{chapters[0]['id']}", headers=auth_headers).json()
    assert detail["draft_text"] == "林昭在雨夜抵达旧城。"
    assert detail["archive"]["schema"] == "v2"
    search = client.get(
        "/api/v1/search", params={"q": "雨夜", "book_id": restored_book["book_id"]}, headers=auth_headers
    ).json()
    assert any(item["chapter_id"] == chapters[0]["id"] for item in search["items"])
    restored_characters = client.get(f"/api/v1/books/{restored_book['book_id']}/characters", headers=auth_headers).json()
    assert restored_characters[0]["id"] != character["id"]
    bindings = client.get(
        f"/api/v1/books/{restored_book['book_id']}/agent-model-bindings", headers=auth_headers
    ).json()
    assert next(item for item in bindings if item["agent_role"] == "writer")["book_binding"]["temperature"] == 0.7


def test_project_import_rejects_tampering_and_path_escape_without_partial_write(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "原书"}).json()
    package = client.get(f"/api/v1/books/{book['id']}/project-export", headers=auth_headers).content
    original_count = len(client.get("/api/v1/books", headers=auth_headers).json())
    entries = _zip_entries(package)
    entries["book.json"] = json.dumps({"title": "被篡改", "world_setting": ""}).encode()
    tampered = client.post("/api/v1/books/project-import", headers=auth_headers, content=_repack(entries))
    assert tampered.status_code == 422
    assert len(client.get("/api/v1/books", headers=auth_headers).json()) == original_count

    escaped = io.BytesIO()
    with zipfile.ZipFile(escaped, "w") as archive:
        archive.writestr("../book.json", b"{}")
    escaped_response = client.post("/api/v1/books/project-import", headers=auth_headers, content=escaped.getvalue())
    assert escaped_response.status_code == 422
    assert len(client.get("/api/v1/books", headers=auth_headers).json()) == original_count


def test_project_import_skips_model_override_when_its_global_profile_is_missing(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "模型恢复"}).json()
    package = client.get(f"/api/v1/books/{book['id']}/project-export", headers=auth_headers).content
    entries = _zip_entries(package)
    entries["model-bindings.json"] = json.dumps(
        [
            {
                "agent_role": "writer",
                "llm_profile_id": "profile-not-present-on-this-server",
                "thinking_enabled": False,
                "reasoning_effort": None,
                "temperature": 0.6,
            }
        ],
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    _refresh_manifest(entries)
    response = client.post("/api/v1/books/project-import", headers=auth_headers, content=_repack(entries))
    assert response.status_code == 201, response.text
    restored = response.json()
    assert [warning["code"] for warning in restored["warnings"]] == ["model_binding_profile_missing"]
    bindings = client.get(
        f"/api/v1/books/{restored['book_id']}/agent-model-bindings", headers=auth_headers
    ).json()
    assert next(item for item in bindings if item["agent_role"] == "writer")["book_binding"] is None


def test_export_data_is_one_server_aggregate_for_client_prose_composition(client, auth_headers):
    book = client.post(
        "/api/v1/books", headers=auth_headers, json={"title": "聚合导出", "world_setting": "沿海城市"}
    ).json()
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林昭", "role": "主角", "fixed_profile": "谨慎"},
    )
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"title": "开端"}
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "正文"}
    )
    response = client.get(f"/api/v1/books/{book['id']}/export-data", headers=auth_headers)
    assert response.status_code == 200
    data = response.json()
    assert data["world_setting"] == "沿海城市"
    assert data["chapters"] == [{"id": chapter["id"], "index": 1, "title": "开端", "draft_text": "正文", "status": "draft_ready"}]
    assert data["characters"] == [{"id": data["characters"][0]["id"], "name": "林昭", "role": "主角", "fixed_profile": "谨慎"}]
    assert client.get(f"/api/v1/books/{book['id']}/export-data").status_code == 401
