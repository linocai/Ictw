"""Build69 regressions for canonical references, live memory and portable backups."""
from __future__ import annotations
from functools import partial


import hashlib
import io
import json
import zipfile
from copy import deepcopy
from types import SimpleNamespace

import pytest
from sqlalchemy import event as sqlalchemy_event, select

import app.db as db_module
import app.routers.characters as character_routes
import app.services.project_packages as packages
from app.llm.factory import get_extractor_client
from app.models import (
    Book, Chapter, ChapterArchiveFact, ChapterArchiveFactParticipant,
    ChapterArchiveRevision, ChapterArchiveStateDelta, ChapterCharacter,
    Character, CharacterEvent, CharacterStateChange, SearchDocument,
)
from app.services.archive_v2 import (
    ARCHIVE_CONTRACT_VERSION, ArchiveV2ValidationError, archive_input_fingerprint,
    validate_archive_output,
)
from app.services.character_state_projection import rebuild_book_projection
from app.services.context import memory_candidates
from app.services.search_index import rebuild_all_search_indexes, rebuild_book_search_index


def _fact(ref, span):
    return {
        "fact_ref": ref, "type": "状态", "importance": 2,
        "text": "林夕决定前往旧城。", "participant_names": ["林夕"],
        "start_id": span, "end_id": span,
    }


def _alias_output(order=("F1", "F2", "F2")):
    by_ref = {"F1": _fact("F1", "P0001-S01"), "F2": _fact("F2", "P0001-S02")}
    return {
        "summary": "林夕决定前往旧城。",
        "facts": [deepcopy(by_ref[ref]) for ref in order],
        "end_state_delta": [{
            "fact_ref": ref, "character_name": "林夕", "slot": "当前目标",
            "operation": "set", "value": "前往旧城",
        } for ref in order],
    }


# This suite tests the retained v2.1 validator, not the new v2.2 root fields.
validate_archive_output = partial(validate_archive_output, contract_version="archive-v2.1")

def _synthetic_chapter():
    person = SimpleNamespace(id="person", name="林夕")
    return SimpleNamespace(
        draft_text="林夕决定前往旧城。林夕再次决定前往旧城。",
        character_links=[SimpleNamespace(character_id=person.id, character=person)],
    )


@pytest.mark.parametrize("order", [
    ("F1", "F2", "F2"), ("F2", "F1", "F2", "F1"), ("F1", "F2", "F2", "F2"),
])
def test_alias_duplicate_uses_its_own_verified_source_payload(order):
    validated = validate_archive_output(_synthetic_chapter(), _alias_output(order))
    assert len(validated.facts) == len(validated.deltas) == 1
    assert validated.deltas[0].fact_ref == validated.facts[0].fact_ref == "F1"
    assert not validated.state_uncertainties


@pytest.mark.parametrize("field,value", [
    ("text", "林夕决定留在原地。"), ("importance", 3),
    ("participant_names", []), ("start_id", "P0001-S01"),
])
def test_same_ref_still_rejects_a_real_payload_conflict(field, value):
    output = _alias_output()
    output["facts"][-1][field] = value
    with pytest.raises(ArchiveV2ValidationError, match="duplicate fact_ref"):
        validate_archive_output(_synthetic_chapter(), output)


def _http_book_chapter(client, headers, text="林夕决定前往旧城。林夕再次决定前往旧城。"):
    book = client.post("/api/v1/books", headers=headers, json={"title": "合成书"}).json()
    person = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=headers, json={"name": "林夕"},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=headers,
        json={"title": "合成章", "character_links": [{"character_id": person["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=headers, json={"draft_text": text},
    ).raise_for_status()
    return book["id"], person["id"], chapter["id"]


def test_alias_duplicate_full_accept_activates_and_enters_selector(client, auth_headers, wait_for_terminal):
    book_id, _, chapter_id = _http_book_chapter(client, auth_headers)

    class Extractor:
        calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            output = _alias_output()
            output["continuity"] = {key: [] for key in ("completed_fact_refs", "known_fact_refs", "last_landing_fact_refs", "open_fact_refs")}
            return output

    extractor = Extractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: extractor
    client.post(
        f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers,
        json={"override_checker": True},
    ).raise_for_status()
    terminal = wait_for_terminal(client, chapter_id, auth_headers)
    assert terminal["phase"] == "done", terminal.get("error_message")
    detail = client.get(f"/api/v1/chapters/{chapter_id}", headers=auth_headers).json()
    assert detail["archive"]["schema"] == "v2"
    assert detail["archive"]["status"] == "complete"
    assert len(detail["archive"]["facts"]) == extractor.calls == 1
    with db_module.SessionLocal() as db:
        later = Chapter(book_id=book_id, index=2)
        db.add(later)
        db.flush()
        facts = [block for block in memory_candidates(db, later) if block.memory_type == "canonical_fact"]
        assert len(facts) == 1 and "前往旧城" in facts[0].text


def _seed_memory_book(*, second_archive=False):
    with db_module.SessionLocal() as db:
        book = Book(title="历史合成书")
        db.add(book)
        db.flush()
        person = Character(book_id=book.id, name="林夕")
        db.add(person)
        db.flush()
        first = Chapter(
            book_id=book.id, index=1, draft_text="林夕停下。", status="finalized",
            legacy_archive_eligible=True, long_summary="旧档独有摘要", archive_status="legacy",
        )
        db.add(first)
        db.flush()
        db.add(ChapterCharacter(chapter_id=first.id, character_id=person.id))
        event = CharacterEvent(
            book_id=book.id, chapter_id=first.id, character_id=person.id,
            event_type="行动", event_text="旧档独有行动",
        )
        db.add(event)
        db.add(CharacterStateChange(
            book_id=book.id, chapter_id=first.id, character_id=person.id,
            scope="persistent", slot="当前目标", operation="set", value="旧城",
            batch_id="", evidence="林夕停下。",
        ))
        later = Chapter(book_id=book.id, index=2, draft_text="林夕继续走。")
        db.add(later)
        db.flush()
        if second_archive:
            later.status = "finalized"
            db.add(ChapterCharacter(chapter_id=later.id, character_id=person.id))
            db.flush()
            revision = ChapterArchiveRevision(
                chapter_id=later.id, revision=1, provenance="manual_retry",
                contract_version=ARCHIVE_CONTRACT_VERSION, status="complete", is_active=True,
                input_fingerprint=archive_input_fingerprint(later), summary="新档独有摘要",
            )
            db.add(revision)
            db.flush()
            fact = ChapterArchiveFact(
                revision_id=revision.id, position=1, fact_ref="F1", fact_type="状态",
                importance=2, fact_text="新档独有行动", start_id="P0001-S01", end_id="P0001-S01",
            )
            db.add(fact)
            db.flush()
            db.add(ChapterArchiveFactParticipant(fact_id=fact.id, character_id=person.id, position=1))
            db.add(ChapterArchiveStateDelta(
                revision_id=revision.id, fact_id=fact.id, position=1, character_id=person.id,
                scope="persistent", slot="当前目标", operation="set", value="新城", batch_id="",
            ))
            later.active_archive_revision_id = revision.id
            later.archive_input_fingerprint = revision.input_fingerprint
            later.archive_status = "complete"
        db.flush()
        rebuild_book_projection(db, book.id)
        rebuild_book_search_index(db, book.id)
        db.commit()
        return book.id, person.id, first.id, later.id, event.id


def _search(client, headers, book_id, query):
    response = client.get("/api/v1/search", headers=headers, params={"book_id": book_id, "q": query})
    response.raise_for_status()
    return response.json()


@pytest.mark.parametrize("second_archive", [False, True])
def test_reopened_legacy_and_downstream_memory_leave_live_lists_without_erasing_audit(
    client, auth_headers, second_archive,
):
    book_id, person_id, first_id, later_id, event_id = _seed_memory_book(second_archive=second_archive)
    before = client.get(f"/api/v1/characters/{person_id}", headers=auth_headers).json()
    assert len(before["events"]) == (2 if second_archive else 1)
    assert _search(client, auth_headers, book_id, "旧档独有")["total"] == 1
    client.post(f"/api/v1/chapters/{first_id}/reopen", headers=auth_headers).raise_for_status()
    after = client.get(f"/api/v1/characters/{person_id}", headers=auth_headers).json()
    listed = client.get(f"/api/v1/books/{book_id}/characters", headers=auth_headers).json()[0]
    assert after["events"] == listed["events"] == []
    assert after["dynamic_fields"] == {} and after["dynamic_fields_updated_chapter_index"] is None
    assert _search(client, auth_headers, book_id, "旧档独有")["total"] == 0
    assert _search(client, auth_headers, book_id, "新档独有")["total"] == 0
    # Direct old-event access remains an audit API, not a source for live lists.
    assert client.get(f"/api/v1/character-events/{event_id}", headers=auth_headers).status_code == 200
    with db_module.SessionLocal() as db:
        assert db.get(CharacterEvent, event_id) is not None
        later = db.get(Chapter, later_id)
        assert not any("档独有" in item.text for item in memory_candidates(db, later))


@pytest.mark.parametrize("invalidity", ["draft_status", "fingerprint"])
def test_active_flags_alone_cannot_publish_invalid_v2_memory(client, auth_headers, invalidity):
    book_id, person_id, _, later_id, _ = _seed_memory_book(second_archive=True)
    with db_module.SessionLocal() as db:
        later = db.get(Chapter, later_id)
        if invalidity == "draft_status":
            later.status = "draft_ready"
        else:
            later.draft_text = "林夕换了一条路。"
        db.flush()
        rebuild_book_search_index(db, book_id)
        db.commit()
    detail = client.get(f"/api/v1/characters/{person_id}", headers=auth_headers).json()
    assert [item["source"] for item in detail["events"]] == ["legacy"]
    assert detail["dynamic_fields_updated_chapter_index"] == 1
    assert _search(client, auth_headers, book_id, "新档独有")["total"] == 0
    assert _search(client, auth_headers, book_id, "旧档独有")["total"] == 1
    chapters = client.get(f"/api/v1/books/{book_id}/chapters", headers=auth_headers).json()
    assert next(item for item in chapters if item["id"] == later_id)["archive_schema"] == "none"


def test_event_patch_and_delete_update_search_in_the_same_transaction(client, auth_headers):
    book_id, _, _, _, event_id = _seed_memory_book()
    client.patch(
        f"/api/v1/character-events/{event_id}", headers=auth_headers,
        json={"event_text": "改稿独有行动"},
    ).raise_for_status()
    assert _search(client, auth_headers, book_id, "旧档独有")["total"] == 0
    assert _search(client, auth_headers, book_id, "改稿独有")["total"] == 1
    removed = client.delete(f"/api/v1/character-events/{event_id}", headers=auth_headers)
    assert removed.status_code == 204
    assert client.get(f"/api/v1/character-events/{event_id}", headers=auth_headers).status_code == 404
    assert _search(client, auth_headers, book_id, "改稿独有")["total"] == 0


def test_event_delete_rollback_restores_event_and_index(client, auth_headers, monkeypatch):
    book_id, _, _, _, event_id = _seed_memory_book()
    original = character_routes.rebuild_book_search_index

    def failed_projection(db, book_id):
        original(db, book_id)
        db.flush()
        raise RuntimeError("synthetic projection failure")

    monkeypatch.setattr(character_routes, "rebuild_book_search_index", failed_projection)
    with pytest.raises(RuntimeError, match="synthetic projection failure"):
        client.delete(f"/api/v1/character-events/{event_id}", headers=auth_headers)
    assert client.get(f"/api/v1/character-events/{event_id}", headers=auth_headers).status_code == 200
    assert _search(client, auth_headers, book_id, "旧档独有")["total"] == 1


def test_upgrade_rebuild_removes_existing_old_indexes_without_changing_source_records(client, auth_headers):
    book_id, person_id, first_id, _, event_id = _seed_memory_book(second_archive=True)
    with db_module.SessionLocal() as db:
        first = db.get(Chapter, first_id)
        first.status = "draft_ready"
        first.legacy_archive_eligible = False
        # Simulate already persisted Build64 indexes after a legacy reopen and
        # an earlier delete. The later active pointer is now fingerprint-stale.
        db.add(SearchDocument(
            id="character-event:previously-deleted", book_id=book_id, chapter_id=first_id,
            character_id=person_id, result_type="character", title="林夕", body="删档独有行动",
        ))
        db.commit()

    def source_snapshot(db):
        return (
            list(db.execute(select(*Chapter.__table__.columns).where(Chapter.book_id == book_id))),
            list(db.execute(select(*ChapterArchiveRevision.__table__.columns)
                            .join(Chapter).where(Chapter.book_id == book_id))),
            list(db.execute(select(*ChapterArchiveFact.__table__.columns)
                            .join(ChapterArchiveRevision).join(Chapter).where(Chapter.book_id == book_id))),
            list(db.execute(select(*ChapterArchiveStateDelta.__table__.columns)
                            .join(ChapterArchiveRevision).join(Chapter).where(Chapter.book_id == book_id))),
            list(db.execute(select(*CharacterEvent.__table__.columns).where(CharacterEvent.book_id == book_id))),
            list(db.execute(select(*CharacterStateChange.__table__.columns).where(CharacterStateChange.book_id == book_id))),
            list(db.execute(select(*Character.__table__.columns).where(Character.book_id == book_id))),
        )

    for query in ("旧档独有", "新档独有", "删档独有"):
        assert _search(client, auth_headers, book_id, query)["total"] > 0
    with db_module.SessionLocal() as db:
        before = source_snapshot(db)
        rebuild_all_search_indexes(db)
        db.commit()
        assert source_snapshot(db) == before
        assert db.get(CharacterEvent, event_id) is not None
    for query in ("旧档独有", "新档独有", "删档独有"):
        assert _search(client, auth_headers, book_id, query)["total"] == 0
    # Current author text remains independently searchable.
    assert _search(client, auth_headers, book_id, "林夕继续走")["total"] == 1


def test_character_list_shares_one_book_replay_across_all_characters(client, auth_headers):
    book_id, _, _, _, _ = _seed_memory_book(second_archive=True)

    def measured_list():
        statements = 0

        def observe(*_args):
            nonlocal statements
            statements += 1

        sqlalchemy_event.listen(db_module.engine, "before_cursor_execute", observe)
        try:
            response = client.get(f"/api/v1/books/{book_id}/characters", headers=auth_headers)
            response.raise_for_status()
            return response.json(), statements
        finally:
            sqlalchemy_event.remove(db_module.engine, "before_cursor_execute", observe)

    single, single_queries = measured_list()
    with db_module.SessionLocal() as db:
        db.add_all([Character(book_id=book_id, name=f"合成人物{index}") for index in range(5)])
        db.commit()
    multiple, multiple_queries = measured_list()
    print(f"character list queries: 1 person={single_queries}; 6 people={multiple_queries}")
    assert len(single) == 1 and len(multiple) == 6
    assert single[0] == multiple[0]
    # Added character rows need their own event/card queries, not another
    # replay of every chapter and archive in the book.
    assert multiple_queries <= single_queries + 5 * 4


def _entries(payload):
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        return {name: archive.read(name) for name in archive.namelist()}


def _repack(entries):
    manifest = json.loads(entries["manifest.json"])
    manifest["entries"] = {
        name: {"sha256": hashlib.sha256(raw).hexdigest(), "size": len(raw)}
        for name, raw in entries.items() if name != "manifest.json"
    }
    entries["manifest.json"] = json.dumps(manifest, ensure_ascii=False).encode()
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, raw in entries.items():
            archive.writestr(name, raw)
    return buffer.getvalue()


def test_200001_character_manuscript_round_trips_through_real_http(client, auth_headers):
    text = "文" * 200_000 + "终"
    book_id, _, _ = _http_book_chapter(client, auth_headers, text)
    count = len(client.get("/api/v1/books", headers=auth_headers).json())
    exported = client.get(f"/api/v1/books/{book_id}/project-export", headers=auth_headers)
    assert exported.status_code == 200, exported.text
    assert len(client.get("/api/v1/books", headers=auth_headers).json()) == count
    serialized = json.loads(_entries(exported.content)["chapters.json"])[0]["draft_text"]
    assert serialized.encode() == text.encode()
    restored = client.post("/api/v1/books/project-import", headers=auth_headers, content=exported.content)
    assert restored.status_code == 201, restored.text
    chapters = client.get(f"/api/v1/books/{restored.json()['book_id']}/chapters", headers=auth_headers).json()
    detail = client.get(f"/api/v1/chapters/{chapters[0]['id']}", headers=auth_headers).json()
    assert detail["draft_text"].encode() == text.encode()


@pytest.mark.parametrize("field", ["world_setting", "user_prompt", "author_note"])
def test_export_rejects_data_that_the_restore_contract_cannot_accept(client, auth_headers, field):
    book_id, _, chapter_id = _http_book_chapter(client, auth_headers)
    with db_module.SessionLocal() as db:
        row = db.get(Book, book_id) if field == "world_setting" else db.get(Chapter, chapter_id)
        setattr(row, field, "文" * 200_001)
        db.commit()
    count = len(client.get("/api/v1/books", headers=auth_headers).json())
    exported = client.get(f"/api/v1/books/{book_id}/project-export", headers=auth_headers)
    assert exported.status_code == 422
    assert exported.json()["detail"]["code"] == "project_export_invalid"
    assert len(client.get("/api/v1/books", headers=auth_headers).json()) == count


def test_exact_entry_byte_limit_is_shared_by_export_and_import(client, auth_headers):
    book_id, _, chapter_id = _http_book_chapter(client, auth_headers, "")
    with db_module.SessionLocal() as db:
        book, chapter = db.get(Book, book_id), db.get(Chapter, chapter_id)
        overhead = len(packages._package_entries(db, book)["chapters.json"])
        chapter.draft_text = "x" * (packages._MAX_ENTRY_BYTES - overhead)
        db.commit()
    exported = client.get(f"/api/v1/books/{book_id}/project-export", headers=auth_headers)
    assert exported.status_code == 200, exported.text
    entries = _entries(exported.content)
    assert len(entries["chapters.json"]) == 20 * 1024 * 1024
    restored = client.post("/api/v1/books/project-import", headers=auth_headers, content=exported.content)
    assert restored.status_code == 201, restored.text
    count = len(client.get("/api/v1/books", headers=auth_headers).json())
    chapter_records = json.loads(entries["chapters.json"])
    chapter_records[0]["draft_text"] += "x"
    entries["chapters.json"] = packages._json_bytes(chapter_records)
    rejected = client.post("/api/v1/books/project-import", headers=auth_headers, content=_repack(entries))
    assert rejected.status_code == 422
    with db_module.SessionLocal() as db:
        db.get(Chapter, chapter_id).draft_text += "x"
        db.commit()
    rejected = client.get(f"/api/v1/books/{book_id}/project-export", headers=auth_headers)
    assert rejected.status_code == 422
    assert len(client.get("/api/v1/books", headers=auth_headers).json()) == count


@pytest.mark.parametrize("limit", ["_MAX_TOTAL_UNCOMPRESSED_BYTES", "_MAX_PACKAGE_BYTES"])
def test_package_capacity_limits_reject_both_directions(client, auth_headers, monkeypatch, limit):
    monkeypatch.setattr(packages, "datetime", SimpleNamespace(
        now=lambda _tz: SimpleNamespace(isoformat=lambda: "2026-09-29T00:00:00+00:00"),
    ))
    book_id, _, _ = _http_book_chapter(client, auth_headers)
    exported = client.get(f"/api/v1/books/{book_id}/project-export", headers=auth_headers)
    exported.raise_for_status()
    size = len(exported.content) if limit == "_MAX_PACKAGE_BYTES" else sum(map(len, _entries(exported.content).values()))
    monkeypatch.setattr(packages, limit, size)
    client.get(f"/api/v1/books/{book_id}/project-export", headers=auth_headers).raise_for_status()
    client.post("/api/v1/books/project-import", headers=auth_headers, content=exported.content).raise_for_status()
    monkeypatch.setattr(packages, limit, size - 1)
    count = len(client.get("/api/v1/books", headers=auth_headers).json())
    rejected_export = client.get(f"/api/v1/books/{book_id}/project-export", headers=auth_headers)
    assert rejected_export.status_code == 422
    rejected_import = client.post("/api/v1/books/project-import", headers=auth_headers, content=exported.content)
    assert rejected_import.status_code == 422
    assert len(client.get("/api/v1/books", headers=auth_headers).json()) == count
