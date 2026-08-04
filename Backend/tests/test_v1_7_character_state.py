from __future__ import annotations

from copy import deepcopy

import pytest

from app.agents.extractor import ExtractorContractError, bind_extractor_character_names
from app.models import Chapter, ChapterCharacter, Character, CharacterStateChange
from app.services.character_state_projection import project_state_changes, rebuild_book_projection
from app.services.extraction import (
    ExtractorValidationError,
    salvage_online_extractor_state_output,
    salvage_state_rebuild_output,
    validate_extractor_output,
    validate_state_rebuild_output,
)


def _change(character_id: str, *, scope: str, slot: str, operation: str, value: str | None, batch_id: str = "", other: str | None = None) -> CharacterStateChange:
    return CharacterStateChange(
        id=f"{character_id}-{scope}-{slot}-{batch_id or operation}-{value or 'clear'}",
        book_id="book", chapter_id="chapter", character_id=character_id, other_character_id=other,
        scope=scope, slot=slot, operation=operation, value=value, evidence="合成证据", batch_id=batch_id,
    )


def test_projection_replaces_snapshot_preserves_persistent_and_mirrors_one_relationship():
    from app.models import Character

    left = Character(id="a", book_id="book", name="甲")
    right = Character(id="b", book_id="book", name="乙")
    changes = [
        _change("a", scope="snapshot", slot="当前位置", operation="set", value="地点 A", batch_id="one"),
        _change("a", scope="snapshot", slot="当前行动", operation="set", value="睡觉", batch_id="one"),
        _change("a", scope="snapshot", slot="情绪状态", operation="clear", value=None, batch_id="one"),
        _change("a", scope="persistent", slot="身体状态", operation="set", value="受伤"),
        _change("a", scope="relationship", slot="relationship", operation="set", value="敌对", other="b"),
        _change("a", scope="snapshot", slot="当前位置", operation="set", value="地点 B", batch_id="two"),
        _change("a", scope="snapshot", slot="当前行动", operation="set", value="起床", batch_id="two"),
        _change("a", scope="snapshot", slot="情绪状态", operation="set", value="警觉", batch_id="two"),
        _change("a", scope="persistent", slot="身体状态", operation="clear", value=None),
        _change("a", scope="relationship", slot="relationship", operation="set", value="合作", other="b"),
    ]
    projected, effective = project_state_changes(changes, [left, right])
    assert projected["a"] == {"当前位置": "地点 B", "当前行动": "起床", "情绪状态": "警觉", "与乙关系": "合作"}
    assert projected["b"] == {"与甲关系": "合作"}
    assert len(effective) == 5


def test_relationship_binding_deduplicates_identical_pair_but_rejects_conflict():
    output = {
        "headline": "关系变化",
        "long_summary": "甲与乙合作。",
        "state_changes": [], "unresolved_items": [], "atomic_memories": [], "character_events": [],
        "state_updates": [
            {
                "character_name": "甲", "snapshot": None, "persistent_ops": [],
                "relationship_ops": [{"other_character_name": "乙", "operation": "set", "value": "合作", "evidence": "甲与乙合作。"}],
            },
            {
                "character_name": "乙", "snapshot": None, "persistent_ops": [],
                "relationship_ops": [{"other_character_name": "甲", "operation": "set", "value": "合作", "evidence": "甲与乙合作。"}],
            },
        ],
    }
    bound = bind_extractor_character_names(deepcopy(output), [("a", "甲"), ("b", "乙")])
    assert sum(len(item["relationship_ops"]) for item in bound["state_updates"]) == 1

    conflicting = deepcopy(output)
    conflicting["state_updates"][1]["relationship_ops"][0]["value"] = "敌对"
    with pytest.raises(ExtractorContractError, match="conflicting duplicate"):
        bind_extractor_character_names(deepcopy(conflicting), [("a", "甲"), ("b", "乙")])
    salvaged = bind_extractor_character_names(
        conflicting,
        [("a", "甲"), ("b", "乙")],
        drop_conflicting_relationships=True,
    )
    assert sum(len(item["relationship_ops"]) for item in salvaged["state_updates"]) == 0


def test_state_rebuild_salvage_drops_invalid_snapshot_but_keeps_valid_persistent_state():
    character = Character(id="a", book_id="book", name="甲")
    chapter = Chapter(
        id="chapter", book_id="book", index=1, title="章", draft_text="甲受了伤。" + "风" * 120 + "乙站在北门。",
        user_prompt="", status="finalized",
    )
    chapter.character_links = [ChapterCharacter(chapter_id=chapter.id, character_id=character.id, character=character)]
    output = {"state_updates": [{
        "character_id": "a",
        "snapshot": {
            "presence_evidence": "甲受了伤。",
            "当前位置": {"operation": "set", "value": "北门", "evidence": "乙站在北门。"},
            "当前行动": {"operation": "clear", "value": None, "evidence": "甲受了伤。"},
            "情绪状态": {"operation": "clear", "value": None, "evidence": "甲受了伤。"},
        },
        "persistent_ops": [{"slot": "身体状态", "operation": "set", "value": "受伤", "evidence": "甲受了伤。"}],
        "relationship_ops": [],
    }]}
    cleaned, dropped = salvage_state_rebuild_output(chapter, output)
    validated = validate_state_rebuild_output(chapter, cleaned)
    assert dropped == 1
    assert len(validated.state_changes) == 1
    assert validated.state_changes[0].slot == "身体状态"


def test_online_salvage_only_drops_state_after_all_archives_and_events_validate():
    character = Character(id="a", book_id="book", name="甲")
    chapter = Chapter(
        id="chapter", book_id="book", index=1, title="章",
        draft_text="甲受了伤。" + "风" * 120 + "随后，他留在门边。",
        user_prompt="", status="draft_ready",
    )
    chapter.character_links = [ChapterCharacter(chapter_id=chapter.id, character_id=character.id, character=character)]
    output = {
        "headline": "甲负伤后停留。",
        "long_summary": "甲受伤并留在门边。",
        "state_changes": [], "unresolved_items": [], "atomic_memories": [],
        "character_events": [{
            "character_id": "a", "event_type": "状态", "event_text": "甲受了伤。", "evidence": "甲受了伤。",
        }],
        "state_updates": [{
            "character_id": "a",
            "snapshot": {
                "presence_evidence": "甲受了伤。",
                "当前位置": {"operation": "clear", "value": None, "evidence": "甲受了伤。"},
                "当前行动": {"operation": "set", "value": "留在门边", "evidence": "随后，他留在门边。"},
                "情绪状态": {"operation": "clear", "value": None, "evidence": "甲受了伤。"},
            },
            "persistent_ops": [{"slot": "身体状态", "operation": "set", "value": "受伤", "evidence": "甲受了伤。"}],
            "relationship_ops": [],
        }],
    }
    cleaned, dropped_reasons = salvage_online_extractor_state_output(chapter, output)
    validated = validate_extractor_output(chapter, cleaned)
    assert dropped_reasons == ["snapshot 当前行动 evidence context must identify its owner"]
    assert [change.slot for change in validated.state_changes] == ["身体状态"]
    assert len(validated.events) == 1

    bad_archive = deepcopy(output)
    bad_archive["character_events"][0]["evidence"] = "没有出现在正文里的证据"
    with pytest.raises(ExtractorValidationError):
        salvage_online_extractor_state_output(chapter, bad_archive)


def test_character_rename_and_delete_reprojects_relationship(client, auth_headers):
    import app.db as db_module
    from app.models import Chapter

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "关系投影"}).json()
    left = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers,
        json={"name": "甲", "dynamic_fields": {"污染": "不会写入"}},
    ).json()
    right = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers,
        json={"name": "乙", "dynamic_fields": {}},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"user_prompt": "关系变化", "character_links": []},
    ).json()
    db = db_module.SessionLocal()
    try:
        orm_chapter = db.get(Chapter, chapter["id"])
        orm_chapter.status = "finalized"
        left_id, right_id = sorted((left["id"], right["id"]))
        db.add(CharacterStateChange(
            book_id=book["id"], chapter_id=chapter["id"], character_id=left_id,
            other_character_id=right_id, scope="relationship", slot="relationship",
            operation="set", value="合作", evidence="甲与乙开始合作。", batch_id="",
        ))
        db.flush()
        rebuild_book_projection(db, book["id"])
        db.commit()
    finally:
        db.close()

    assert client.get(f"/api/v1/characters/{left['id']}", headers=auth_headers).json()["dynamic_fields"] == {"与乙关系": "合作"}
    renamed = client.patch(
        f"/api/v1/characters/{right['id']}", headers=auth_headers,
        json={"name": "乙改名"},
    )
    renamed.raise_for_status()
    assert client.get(f"/api/v1/characters/{left['id']}", headers=auth_headers).json()["dynamic_fields"] == {"与乙改名关系": "合作"}

    client.delete(f"/api/v1/characters/{right['id']}", headers=auth_headers).raise_for_status()
    assert client.get(f"/api/v1/characters/{left['id']}", headers=auth_headers).json()["dynamic_fields"] == {}
