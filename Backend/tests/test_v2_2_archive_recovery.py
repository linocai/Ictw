from __future__ import annotations

import hashlib
import io
import json
import zipfile
from copy import deepcopy
from types import SimpleNamespace

import pytest

import app.db as db_module
from app.models import (
    Chapter,
    ChapterArchiveRevision,
    ChapterCharacter,
    ChapterArchiveStateDelta,
    Character,
    CharacterStateChange,
)
from app.agents.extractor import extractor_v2_schema
from app.services.archive_v2 import (
    ARCHIVE_CONTRACT_VERSION,
    LEGACY_ARCHIVE_CONTRACT_VERSION,
    MAX_RAW_FACTS,
    MAX_RAW_STATE_DELTAS,
    MAX_STATE_DELTAS,
    ArchiveV2ValidationError,
    active_archive_revision,
    archive_input_fingerprint,
    archive_input_fingerprint_for_projection,
    build_archive_user_message,
    validate_archive_output,
)
from app.services.character_state_projection import (
    StateProjectionCursor,
    StateUncertainty,
    project_state_changes,
)


def _chapter() -> SimpleNamespace:
    character = SimpleNamespace(id="character-a", name="甲")
    return SimpleNamespace(
        draft_text="甲在门边等待。随后甲决定前往旧城。",
        character_links=[SimpleNamespace(character_id=character.id, character=character)],
    )


def _fact(ref: str) -> dict:
    return {
        "fact_ref": ref,
        "type": "状态",
        "importance": 2,
        "text": "甲决定前往旧城。",
        "participant_names": ["甲"],
        "start_id": "P0001-S02",
        "end_id": "P0001-S02",
    }


def _delta(ref: str, value: object = "前往旧城") -> dict:
    return {
        "fact_ref": ref,
        "character_name": "甲",
        "slot": "当前目标",
        "operation": "set",
        "value": value,
    }


def _state_uncertainty_slots(characters: list[object], count: int) -> list[dict]:
    slots = [
        ("snapshot", "当前位置"), ("snapshot", "当前行动"), ("snapshot", "情绪状态"),
        ("persistent", "身体状态"), ("persistent", "当前目标"), ("persistent", "秘密状态"),
    ]
    records = []
    for character in characters:
        for scope, slot in slots:
            records.append(
                {
                    "code": "state_slot_uncertain", "severity": "warning",
                    "character_id": character.id, "character_name": character.name,
                    "other_character_id": None, "other_character_name": None,
                    "scope": scope, "slot": slot, "fact_refs": [], "span_ids": [], "variants": [],
                    "message": f"本章中{character.name}的{slot}无法确定。",
                    "recovery": "请重新整理本章。",
                }
            )
    return records[:count]


def test_v21_validates_every_raw_item_before_deduplicating_and_remaps_aliases():
    chapter = _chapter()
    output = {
        "summary": "甲决定前往旧城。",
        "facts": [_fact(f"alias-{index}") for index in range(9)],
        "end_state_delta": [_delta(f"alias-{index % 9}") for index in range(19)],
    }
    validated = validate_archive_output(chapter, output)
    assert [fact.fact_ref for fact in validated.facts] == ["F1"]
    assert [(delta.fact_ref, delta.value) for delta in validated.deltas] == [("F1", "前往旧城")]

    # An invalid evidence span cannot hide behind an otherwise identical fact.
    invalid = deepcopy(output)
    invalid["facts"][-1]["start_id"] = "P9999-S01"
    with pytest.raises(ArchiveV2ValidationError, match="source span does not exist"):
        validate_archive_output(chapter, invalid)
    schema = extractor_v2_schema(["甲"])
    assert schema["properties"]["facts"]["maxItems"] == MAX_RAW_FACTS
    assert schema["properties"]["end_state_delta"]["maxItems"] == MAX_RAW_STATE_DELTAS


def test_v21_same_fact_ref_accepts_only_an_identical_duplicate_after_validation():
    chapter = _chapter()
    output = {
        "summary": "甲决定前往旧城。",
        "facts": [_fact("F1"), _fact("F1")],
        "end_state_delta": [_delta("F1")],
    }
    validated = validate_archive_output(chapter, output)
    assert [fact.fact_ref for fact in validated.facts] == ["F1"]
    assert [delta.fact_ref for delta in validated.deltas] == ["F1"]

    conflicting = deepcopy(output)
    conflicting["facts"][1]["text"] = "甲决定留在旧城。"
    with pytest.raises(ArchiveV2ValidationError, match="duplicate fact_ref"):
        validate_archive_output(chapter, conflicting)


def test_v21_localizes_only_state_slot_problems_and_rejects_whole_placeholders():
    chapter = _chapter()
    output = {
        "summary": "甲准备继续调查。",
        "facts": [_fact("F1")],
        "end_state_delta": [_delta("F1", "调查身份未知的来客")],
    }
    assert validate_archive_output(chapter, output).deltas[0].value == "调查身份未知的来客"

    output["end_state_delta"] = [_delta("F1", "未知。")]
    validated = validate_archive_output(chapter, output)
    assert not validated.deltas
    uncertainty = validated.state_uncertainties[0].payload
    assert uncertainty["code"] == "state_slot_uncertain"
    assert uncertainty["slot"] == "当前目标"
    assert uncertainty["fact_refs"] == ["F1"]
    assert "无法确定" in uncertainty["message"]

    output["end_state_delta"] = [_delta("F1", "“待定”")]
    assert not validate_archive_output(chapter, output).deltas


def test_v21_unknown_state_prompt_and_fingerprint_share_one_selected_bounded_set():
    chapter = _chapter()
    gaps = [
        {
            "character_id": "character-a",
            "other_character_id": None,
            "scope": "persistent",
            "slot": f"slot-{index:02}",
            "character_name": "旧名",
        }
        for index in range(10)
    ]
    prompt = build_archive_user_message(chapter, {}, prior_state_uncertainties=gaps)
    assert prompt.count("尚无法确定") == 8
    fingerprint = archive_input_fingerprint_for_projection(
        chapter, {}, character_ids=["character-a"], state_uncertainties=gaps
    )
    ignored_tail = deepcopy(gaps)
    ignored_tail[-1]["slot"] = "slot-99"
    assert archive_input_fingerprint_for_projection(
        chapter, {}, character_ids=["character-a"], state_uncertainties=ignored_tail
    ) == fingerprint
    unrelated = deepcopy(gaps)
    unrelated.append(
        {
            "character_id": "character-b", "other_character_id": None,
            "scope": "persistent", "slot": "当前目标", "character_name": "乙",
        }
    )
    assert archive_input_fingerprint_for_projection(
        chapter, {}, character_ids=["character-a"], state_uncertainties=unrelated
    ) == fingerprint


def test_v21_retry_feedback_regenerates_renamed_state_uncertainty_text():
    chapter = _chapter()
    prompt = build_archive_user_message(
        chapter,
        {},
        previous_diagnostics=[
            {
                "code": "state_slot_uncertain", "severity": "warning",
                "character_id": "character-a", "character_name": "旧甲",
                "other_character_id": None, "other_character_name": None,
                "scope": "persistent", "slot": "当前目标",
                "fact_refs": ["F1"], "span_ids": ["P0001-S01"], "variants": [],
                "message": "本章中旧甲的当前目标无法确定。",
                "recovery": "旧甲请重试。",
            }
        ],
    )
    assert "旧甲" not in prompt
    assert "甲的当前目标有多个不一致或不完整的结果" in prompt


def test_v21_state_event_budget_preserves_thirteen_unknown_slots_without_truncation():
    characters = [
        SimpleNamespace(id=f"character-{index}", name=name)
        for index, name in enumerate(("甲", "乙", "丙"), start=1)
    ]
    chapter = SimpleNamespace(
        draft_text="三人留在门边。",
        character_links=[SimpleNamespace(character_id=item.id, character=item) for item in characters],
    )
    fact = {
        "fact_ref": "F1", "type": "状态", "importance": 2, "text": "三人留在门边。",
        "participant_names": [item.name for item in characters], "start_id": "P0001-S01", "end_id": "P0001-S01",
    }
    state_slots = [
        (item.name, scope, slot)
        for item in characters
        for scope, slot in (
            ("snapshot", "当前位置"), ("snapshot", "当前行动"), ("snapshot", "情绪状态"),
            ("persistent", "身体状态"), ("persistent", "当前目标"), ("persistent", "秘密状态"),
        )
    ]
    unknown_deltas = [
        {"fact_ref": "F1", "character_name": name, "slot": slot, "operation": "set", "value": "未知。"}
        for name, _scope, slot in state_slots[:13]
    ]
    validated = validate_archive_output(
        chapter, {"summary": "三人状态待整理。", "facts": [fact], "end_state_delta": unknown_deltas}
    )
    assert not validated.deltas
    assert len(validated.state_uncertainties) == 13
    assert len(validated.diagnostics) == 13

    over_budget = unknown_deltas + [
        {"fact_ref": "F1", "character_name": name, "slot": slot, "operation": "set", "value": "已确认"}
        for name, _scope, slot in state_slots[13:]
    ] + [{"fact_ref": "F2", "slot": "relationship", "operation": "set", "value": "已确认"}]
    relationship_fact = {
        "fact_ref": "F2", "type": "关系", "importance": 2, "text": "甲与乙确认彼此同在。",
        "participant_names": ["甲", "乙"], "start_id": "P0001-S01", "end_id": "P0001-S01",
    }
    with pytest.raises(ArchiveV2ValidationError, match=f"limit {MAX_STATE_DELTAS}"):
        validate_archive_output(
            chapter, {"summary": "三人状态待整理。", "facts": [fact, relationship_fact], "end_state_delta": over_budget}
        )


def test_uncertainty_masks_prior_projection_until_a_later_reliable_delta():
    character = Character(id="character-a", book_id="book", name="甲")
    cursor = StateProjectionCursor.for_characters([character])
    cursor.apply(
        CharacterStateChange(
            id="old", book_id="book", chapter_id="one", character_id=character.id,
            scope="persistent", slot="当前目标", operation="set", value="留在旧城", evidence="合成", batch_id="",
        )
    )
    cursor.apply(
        StateUncertainty(
            character_id=character.id,
            other_character_id=None,
            scope="persistent",
            slot="当前目标",
            payload={
                "code": "state_slot_uncertain", "severity": "warning", "character_id": character.id,
                "character_name": "甲", "other_character_id": None, "other_character_name": None,
                "scope": "persistent", "slot": "当前目标", "fact_refs": ["F1"], "span_ids": ["P0001-S01"],
                "variants": [{"operation": "set", "value": "留在旧城"}, {"operation": "set", "value": "离开旧城"}],
                "message": "本章中甲的当前目标无法确定。", "recovery": "重新整理本章。",
            },
        )
    )
    assert "当前目标" not in cursor.materialize_fields()[character.id]
    assert len(cursor.materialize_uncertainties()) == 1
    _, effective_ids = project_state_changes(
        [
            ChapterArchiveStateDelta(
                id="old", revision_id="revision", fact_id="fact", position=1,
                character_id=character.id, other_character_id=None, scope="persistent",
                slot="当前目标", operation="set", value="留在旧城", batch_id="",
            ),
            StateUncertainty(
                character_id=character.id, other_character_id=None, scope="persistent",
                slot="当前目标", payload={"character_id": character.id, "scope": "persistent", "slot": "当前目标"},
            ),
        ],
        [character],
    )
    assert "old" not in effective_ids

    cursor.apply(
        ChapterArchiveStateDelta(
            id="later", revision_id="revision", fact_id="fact", position=1, character_id=character.id,
            other_character_id=None, scope="persistent", slot="当前目标", operation="set", value="前往新城", batch_id="",
        )
    )
    assert cursor.materialize_fields()[character.id]["当前目标"] == "前往新城"
    assert cursor.materialize_uncertainties() == []
    _, effective_ids = project_state_changes(
        [
            ChapterArchiveStateDelta(
                id="old", revision_id="revision", fact_id="fact", position=1,
                character_id=character.id, other_character_id=None, scope="persistent",
                slot="当前目标", operation="set", value="留在旧城", batch_id="",
            ),
            StateUncertainty(
                character_id=character.id, other_character_id=None, scope="persistent",
                slot="当前目标", payload={"character_id": character.id, "scope": "persistent", "slot": "当前目标"},
            ),
            ChapterArchiveStateDelta(
                id="later", revision_id="revision", fact_id="fact", position=2,
                character_id=character.id, other_character_id=None, scope="persistent",
                slot="当前目标", operation="set", value="前往新城", batch_id="",
            ),
        ],
        [character],
    )
    assert effective_ids == {"later"}


def _seed_active_revision(
    client, auth_headers, *, contract_version: str, state_uncertainties: list[dict] | None = None
) -> tuple[dict, dict]:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "归档恢复"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "甲"}
    ).json()
    chapter_data = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "第一章", "character_links": [{"character_id": character["id"]}]},
    ).json()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_data["id"])
        assert chapter is not None
        chapter.draft_text = "甲在门边等待。"
        chapter.status = "finalized"
        revision = ChapterArchiveRevision(
            chapter_id=chapter.id,
            revision=1,
            provenance="manual_retry",
            input_fingerprint="0" * 64,
            contract_version=contract_version,
            status="complete",
            is_active=True,
            summary="甲在门边等待。",
            state_uncertainties=state_uncertainties or [],
            diagnostics=state_uncertainties or [],
        )
        db.add(revision)
        db.flush()
        chapter.active_archive_revision_id = revision.id
        chapter.archive_status = "partial" if state_uncertainties else "complete"
        revision.input_fingerprint = archive_input_fingerprint(
            chapter, contract_version=contract_version
        )
        chapter.archive_input_fingerprint = revision.input_fingerprint
        db.commit()
    return book, {**chapter_data, "character_id": character["id"]}


def test_old_v20_active_hash_remains_usable_and_latest_failure_stays_visible(client, auth_headers):
    _book, chapter_data = _seed_active_revision(
        client, auth_headers, contract_version=LEGACY_ARCHIVE_CONTRACT_VERSION
    )
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_data["id"])
        assert chapter is not None
        assert active_archive_revision(db, chapter) is not None
        latest = ChapterArchiveRevision(
            chapter_id=chapter.id, revision=2, provenance="manual_retry", input_fingerprint="different",
            contract_version=ARCHIVE_CONTRACT_VERSION, status="failed", error_code="archive_config_invalid",
            error_message="整理配置不可用",
        )
        db.add(latest)
        db.commit()
    detail = client.get(f"/api/v1/chapters/{chapter_data['id']}", headers=auth_headers).json()["archive"]
    assert detail["effective_status"] == "full"
    assert detail["status"] == "complete"
    assert detail["latest_attempt"]["status"] == "failed"
    assert detail["can_retry"] is True


def test_format2_round_trips_all_thirteen_active_unknown_slots(client, auth_headers):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "十三个未知槽"}).json()
    characters = [
        client.post(
            f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": name}
        ).json()
        for name in ("甲", "乙", "丙")
    ]
    chapter_data = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": "第一章", "character_links": [{"character_id": item["id"]} for item in characters]},
    ).json()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_data["id"])
        assert chapter is not None
        chapter.draft_text = "三人留在门边。"
        chapter.status = "finalized"
        rows = _state_uncertainty_slots(
            [SimpleNamespace(id=item["id"], name=item["name"]) for item in characters], 13
        )
        revision = ChapterArchiveRevision(
            chapter_id=chapter.id, revision=1, provenance="manual_retry", input_fingerprint="0" * 64,
            contract_version=ARCHIVE_CONTRACT_VERSION, status="complete", is_active=True,
            summary="三人状态待整理。", state_uncertainties=rows, diagnostics=deepcopy(rows),
        )
        db.add(revision)
        db.flush()
        chapter.active_archive_revision_id = revision.id
        chapter.archive_status = "partial"
        revision.input_fingerprint = archive_input_fingerprint(chapter, contract_version=ARCHIVE_CONTRACT_VERSION)
        chapter.archive_input_fingerprint = revision.input_fingerprint
        db.commit()

    detail = client.get(f"/api/v1/chapters/{chapter_data['id']}", headers=auth_headers).json()["archive"]
    assert detail["effective_status"] == "with_state_gaps"
    assert len(detail["state_uncertainties"]) == 13
    assert len(detail["diagnostics"]) == 13
    package = client.get(f"/api/v1/books/{book['id']}/project-export", headers=auth_headers)
    assert package.status_code == 200, package.text
    exported = json.loads(_zip_entries(package.content)["archives.json"])[0]
    assert len(exported["state_uncertainties"]) == 13
    restored = client.post("/api/v1/books/project-import", headers=auth_headers, content=package.content)
    assert restored.status_code == 201, restored.text
    restored_chapter = client.get(
        f"/api/v1/books/{restored.json()['book_id']}/chapters", headers=auth_headers
    ).json()[0]
    restored_detail = client.get(
        f"/api/v1/chapters/{restored_chapter['id']}", headers=auth_headers
    ).json()["archive"]
    assert len(restored_detail["state_uncertainties"]) == 13
    assert len(restored_detail["diagnostics"]) == 13


def _zip_entries(payload: bytes) -> dict[str, bytes]:
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        return {name: archive.read(name) for name in archive.namelist()}


def _repack(entries: dict[str, bytes]) -> bytes:
    target = io.BytesIO()
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return target.getvalue()


def _refresh_manifest(entries: dict[str, bytes], *, format_version: int) -> None:
    manifest = json.loads(entries["manifest.json"])
    manifest["format_version"] = format_version
    manifest["entries"] = {
        name: {"sha256": hashlib.sha256(entries[name]).hexdigest(), "size": len(entries[name])}
        for name in ("book.json", "characters.json", "chapters.json", "archives.json", "personas.json", "model-bindings.json")
    }
    entries["manifest.json"] = json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def test_project_format2_preserves_unknown_slot_ids_and_format1_still_imports(client, auth_headers):
    source_book, source_chapter = _seed_active_revision(
        client,
        auth_headers,
        contract_version=ARCHIVE_CONTRACT_VERSION,
        state_uncertainties=[
            {
                "code": "state_slot_uncertain", "severity": "warning", "character_id": "placeholder",
                "character_name": "甲", "other_character_id": None, "other_character_name": None,
                "scope": "persistent", "slot": "当前目标", "fact_refs": [], "span_ids": [], "variants": [],
                "message": "本章中甲的当前目标无法确定。", "recovery": "重新整理本章。",
            }
        ],
    )
    # Replace the synthetic ID with the source book's real character ID before export.
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, source_chapter["id"])
        revision = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id)
        revision.state_uncertainties = [
            {**revision.state_uncertainties[0], "character_id": source_chapter["character_id"]}
        ]
        revision.diagnostics = [
            {**revision.diagnostics[0], "character_id": source_chapter["character_id"]}
        ]
        character = db.get(Character, source_chapter["character_id"])
        assert character is not None
        character.name = "甲（改名后）"
        db.commit()

    package = client.get(f"/api/v1/books/{source_book['id']}/project-export", headers=auth_headers).content
    entries = _zip_entries(package)
    assert json.loads(entries["manifest.json"])["format_version"] == 2
    exported_issue = json.loads(entries["archives.json"])[0]["state_uncertainties"][0]
    assert exported_issue["character_name"] == "甲（改名后）"
    assert exported_issue["message"] == "本章中甲（改名后）的当前目标有多个不一致或不完整的结果，当前无法确定章末状态。"
    source_rows = client.get(f"/api/v1/books/{source_book['id']}/chapters", headers=auth_headers).json()
    assert source_rows[0]["archive_can_retry"] is True
    restored = client.post("/api/v1/books/project-import", headers=auth_headers, content=package)
    assert restored.status_code == 201, restored.text
    restored_chapter = client.get(
        f"/api/v1/books/{restored.json()['book_id']}/chapters", headers=auth_headers
    ).json()[0]
    detail = client.get(f"/api/v1/chapters/{restored_chapter['id']}", headers=auth_headers).json()["archive"]
    assert detail["effective_status"] == "with_state_gaps"
    assert detail["can_retry"] is True
    assert detail["state_uncertainties"][0]["character_id"] != source_chapter["character_id"]
    assert detail["state_uncertainties"][0]["character_name"] == "甲（改名后）"
    assert detail["state_uncertainties"][0]["message"] == exported_issue["message"]

    archives = json.loads(entries["archives.json"])
    for archive in archives:
        archive.pop("contract_version")
        archive.pop("state_uncertainties")
        archive.pop("diagnostics")
    entries["archives.json"] = json.dumps(archives, ensure_ascii=False, separators=(",", ":")).encode()
    _refresh_manifest(entries, format_version=1)
    legacy_restore = client.post("/api/v1/books/project-import", headers=auth_headers, content=_repack(entries))
    assert legacy_restore.status_code == 201, legacy_restore.text


def test_format2_import_rejects_archive_records_that_live_validation_cannot_activate(client, auth_headers):
    source_book, source_chapter = _seed_active_revision(
        client, auth_headers, contract_version=ARCHIVE_CONTRACT_VERSION
    )
    outsider = client.post(
        f"/api/v1/books/{source_book['id']}/characters", headers=auth_headers, json={"name": "乙"}
    ).json()
    package = client.get(f"/api/v1/books/{source_book['id']}/project-export", headers=auth_headers).content
    base_entries = _zip_entries(package)
    original_count = len(client.get("/api/v1/books", headers=auth_headers).json())

    def rejected(mutator):
        entries = deepcopy(base_entries)
        archives = json.loads(entries["archives.json"])
        mutator(archives[0])
        entries["archives.json"] = json.dumps(archives, ensure_ascii=False, separators=(",", ":")).encode()
        _refresh_manifest(entries, format_version=2)
        response = client.post("/api/v1/books/project-import", headers=auth_headers, content=_repack(entries))
        assert response.status_code == 422, response.text
        assert response.json()["detail"]["code"] == "project_import_invalid"
        assert len(client.get("/api/v1/books", headers=auth_headers).json()) == original_count

    def add_fact(archive, participant_id):
        archive["facts"] = [
            {
                "fact_ref": "F1", "type": "状态", "importance": 2, "text": "甲在门边等待。",
                "start_id": "P0001-S01", "end_id": "P0001-S01", "participant_ids": [participant_id],
            }
        ]

    rejected(lambda archive: add_fact(archive, outsider["id"]))
    rejected(lambda archive: add_fact(archive, ["not-a-character-id"]))

    rejected(
        lambda archive: archive.update(
            {
                "state_uncertainties": [
                    {
                        "code": "state_slot_uncertain", "severity": "warning",
                        "character_id": None, "character_name": "甲",
                        "scope": "persistent", "slot": "当前目标",
                        "fact_refs": [], "span_ids": [], "variants": [],
                        "message": "本章中甲的当前目标无法确定。", "recovery": "重试",
                    }
                ]
            }
        )
    )

    def placeholder_delta(archive):
        add_fact(archive, source_chapter["character_id"])
        archive["deltas"] = [
            {
                "fact_position": 1, "position": 1, "character_id": source_chapter["character_id"],
                "other_character_id": None, "scope": "persistent", "slot": "当前目标",
                "operation": "set", "value": "“待定”", "batch_id": "",
            }
        ]

    rejected(placeholder_delta)

    def duplicate_slot(archive):
        add_fact(archive, source_chapter["character_id"])
        archive["deltas"] = [
            {
                "fact_position": 1, "position": position, "character_id": source_chapter["character_id"],
                "other_character_id": None, "scope": "persistent", "slot": "当前目标",
                "operation": "set", "value": value, "batch_id": "",
            }
            for position, value in ((1, "留在门边"), (2, "前往旧城"))
        ]

    rejected(duplicate_slot)
    rejected(lambda archive: archive.update({"contract_version": LEGACY_ARCHIVE_CONTRACT_VERSION,
                                             "state_uncertainties": [{
                                                 "code": "state_slot_uncertain", "severity": "warning",
                                                 "character_id": source_chapter["character_id"],
                                                 "character_name": "甲", "scope": "persistent", "slot": "当前目标",
                                                 "fact_refs": [], "span_ids": [], "variants": [],
                                                 "message": "待整理", "recovery": "重试",
                                             }]}))
