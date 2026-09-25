from __future__ import annotations

import copy
from dataclasses import replace

import pytest

import app.db as db_module
from app.models import (
    Book,
    Chapter,
    ChapterArchiveFact,
    ChapterArchiveFactParticipant,
    ChapterArchiveRevision,
    ChapterCharacter,
    Character,
)
from app.services import production_context as production_context_service
from app.services.context import MEMORY_BUDGET_CHARS, memory_selector_user_message, prefilter_memory_candidates_v1
from app.services.production_context import (
    PRODUCTION_INPUT_V1,
    _candidate_range_v1,
    _revision_v1_blocks,
    freeze_manual_checker_input,
    freeze_selector_input,
    is_frozen_input_current,
    is_frozen_selector_input_current,
)


def _v1_story() -> tuple[str, str, str]:
    with db_module.SessionLocal() as db:
        book = Book(title="v1 兼容", world_setting="无超自然力量。")
        selected = Character(book=book, name="林夕")
        prior = Chapter(book=book, index=1, status="finalized", draft_text="前章正文。")
        current = Chapter(book=book, index=2, title="继续", user_prompt="继续当前情节。", draft_text="林夕继续。")
        db.add_all([book, selected, prior, current])
        db.flush()
        current.character_links.append(ChapterCharacter(character_id=selected.id))
        db.commit()
        return book.id, prior.id, current.id


def _revision_with_facts(
    db, chapter: Chapter, *, revision_number: int, prefix: str, texts: list[str], active: bool,
) -> ChapterArchiveRevision:
    revision = ChapterArchiveRevision(
        id=f"revision-{prefix}",
        chapter_id=chapter.id,
        revision=revision_number,
        provenance="manual_retry",
        input_fingerprint="f" * 64,
        status="complete",
        is_active=active,
        contract_version="archive-v2.1",
    )
    db.add(revision)
    db.flush()
    for position, text in enumerate(texts, start=1):
        db.add(ChapterArchiveFact(
            id=f"fact-{prefix}-{position:04d}",
            revision_id=revision.id,
            position=position,
            fact_ref=f"F{position}",
            fact_type="剧情",
            importance=1,
            fact_text=text,
            start_id="P0001-S01",
            end_id="P0001-S01",
        ))
    db.flush()
    return revision


@pytest.mark.parametrize(
    ("texts", "label"),
    [
        ([f"同分事实{index:03d}" for index in range(301)], "over_300"),
        (["甲" * 16_000, "乙" * 16_000], "over_30k"),
    ],
)
def test_v1_rearchive_proof_keeps_boundary_selection_without_loosening_changes(
    client, monkeypatch, texts: list[str], label: str,
) -> None:
    """Only a retained full source proof can bridge v1 UUID tie-break changes."""
    _book_id, prior_id, current_id = _v1_story()
    with db_module.SessionLocal() as db:
        prior = db.get(Chapter, prior_id)
        current = db.get(Chapter, current_id)
        assert prior is not None and current is not None
        historic = _revision_with_facts(db, prior, revision_number=1, prefix=f"old-{label}", texts=texts, active=False)
        # The exact same fact rows receive reversed new UUID order. At a v1
        # gate the old and current filtered ranges differ even though the full
        # source multiset does not.
        current_revision = _revision_with_facts(
            db, prior, revision_number=2, prefix=f"new-{label}", texts=list(reversed(texts)), active=True,
        )
        prior.active_archive_revision_id = current_revision.id
        db.commit()

        historic_blocks = _revision_v1_blocks(prior, historic)
        current_blocks = _revision_v1_blocks(prior, current_revision)
        selected_ids = {link.character_id for link in current.character_links}
        historic_range = _candidate_range_v1(prefilter_memory_candidates_v1(
            historic_blocks, chapter=current, selected_character_ids=selected_ids,
        ))
        current_range = _candidate_range_v1(prefilter_memory_candidates_v1(
            current_blocks, chapter=current, selected_character_ids=selected_ids,
        ))
        assert historic_range != current_range
        monkeypatch.setattr(production_context_service, "memory_candidates", lambda _db, _chapter: current_blocks)

        modern = freeze_manual_checker_input(db, current, current.draft_text)
        legacy = copy.deepcopy(modern)
        legacy["protocol_version"] = PRODUCTION_INPUT_V1
        legacy.pop("relationship_identities", None)
        legacy["selector_candidate_range"] = historic_range
        legacy["input_fingerprint"] = production_context_service._input_fingerprint(legacy)
        assert is_frozen_input_current(db, current, legacy)

        baseline_blocks = list(current_blocks)
        # No current-source change can be hidden outside the frozen 300/30k
        # range merely because the old range did not serialize database IDs.
        current_blocks.append(type(current_blocks[0])(
            id=f"archive_v2_fact:added-{label}",
            text="第 1 章剧情事实：真实新增事实。",
            chapter_index=1,
            memory_type="canonical_fact",
            source_chapter_id=prior.id,
        ))
        assert not is_frozen_input_current(db, current, legacy)
        current_blocks[:] = baseline_blocks

        current_blocks[0] = replace(current_blocks[0], text=current_blocks[0].text + "已改文。")
        assert not is_frozen_input_current(db, current, legacy)
        current_blocks[:] = baseline_blocks

        current_blocks.pop()
        assert not is_frozen_input_current(db, current, legacy)
        current_blocks[:] = baseline_blocks

        current_blocks[0] = replace(current_blocks[0], character_id="changed-participant")
        assert not is_frozen_input_current(db, current, legacy)
        current_blocks[:] = baseline_blocks

        current_revision.is_active = False
        db.flush()
        assert not is_frozen_input_current(db, current, legacy)


def test_v1_full_untruncated_pool_allows_one_rearchive_among_unchanged_history(client, monkeypatch) -> None:
    """A complete frozen v1 range proves all sources without revision guesses."""
    _book_id, prior_id, current_id = _v1_story()
    with db_module.SessionLocal() as db:
        prior = db.get(Chapter, prior_id)
        current = db.get(Chapter, current_id)
        assert prior is not None and current is not None
        earlier = Chapter(book_id=current.book_id, index=0, status="finalized", draft_text="更早正文。")
        db.add(earlier)
        db.flush()
        unchanged = _revision_with_facts(
            db, earlier, revision_number=1, prefix="unchanged", texts=["未重归档事实"], active=True,
        )
        earlier.active_archive_revision_id = unchanged.id
        historic = _revision_with_facts(
            db, prior, revision_number=1, prefix="small-old", texts=["甲事实", "乙事实"], active=False,
        )
        rearchived = _revision_with_facts(
            db, prior, revision_number=2, prefix="small-new", texts=["乙事实", "甲事实"], active=True,
        )
        prior.active_archive_revision_id = rearchived.id
        db.commit()

        old_blocks = [*_revision_v1_blocks(earlier, unchanged), *_revision_v1_blocks(prior, historic)]
        new_blocks = [*_revision_v1_blocks(earlier, unchanged), *_revision_v1_blocks(prior, rearchived)]
        selected_ids = {link.character_id for link in current.character_links}
        frozen_range = _candidate_range_v1(prefilter_memory_candidates_v1(
            old_blocks, chapter=current, selected_character_ids=selected_ids,
        ))
        assert frozen_range != _candidate_range_v1(prefilter_memory_candidates_v1(
            new_blocks, chapter=current, selected_character_ids=selected_ids,
        ))
        monkeypatch.setattr(production_context_service, "memory_candidates", lambda _db, _chapter: new_blocks)

        modern = freeze_manual_checker_input(db, current, current.draft_text)
        legacy = copy.deepcopy(modern)
        legacy["protocol_version"] = PRODUCTION_INPUT_V1
        legacy.pop("relationship_identities", None)
        legacy["selector_candidate_range"] = frozen_range
        legacy["input_fingerprint"] = production_context_service._input_fingerprint(legacy)
        assert is_frozen_input_current(db, current, legacy)


@pytest.mark.parametrize(
    ("texts", "expected_rows"),
    [
        ([f"等价重归档事实{index:03d}" for index in range(301)], 300),
        (["甲" * 16_000, "乙" * 16_000], 2),
    ],
)
@pytest.mark.parametrize("fixed_history", ["same", "different", "none"])
def test_v1_truncated_pool_keeps_frozen_active_only_source_with_one_equivalent_rearchive(
    client, monkeypatch, texts: list[str], expected_rows: int, fixed_history: str,
) -> None:
    """A complete fixed source survives any irrelevant older revision shape."""
    _book_id, prior_id, current_id = _v1_story()
    with db_module.SessionLocal() as db:
        prior = db.get(Chapter, prior_id)
        current = db.get(Chapter, current_id)
        assert prior is not None and current is not None
        selected_id = current.character_links[0].character_id
        earlier = Chapter(book_id=current.book_id, index=0, status="finalized", draft_text="更早正文。")
        db.add(earlier)
        db.flush()
        if fixed_history != "none":
            fixed_old = _revision_with_facts(
                db,
                earlier,
                revision_number=1,
                prefix=f"truncated-fixed-{fixed_history}-old",
                texts=["固定前章事实" if fixed_history == "same" else "远古且不同的前章事实"],
                active=False,
            )
            db.add(ChapterArchiveFactParticipant(
                fact_id=fixed_old.facts[0].id, character_id=selected_id, position=1,
            ))
        active_only = _revision_with_facts(
            db,
            earlier,
            revision_number=2 if fixed_history != "none" else 1,
            prefix=f"truncated-active-only-{fixed_history}",
            texts=["固定前章事实"],
            active=True,
        )
        fixed_fact = active_only.facts[0]
        db.add(ChapterArchiveFactParticipant(
            fact_id=fixed_fact.id, character_id=selected_id, position=1,
        ))
        earlier.active_archive_revision_id = active_only.id
        historic = _revision_with_facts(
            db, prior, revision_number=1, prefix="truncated-old", texts=texts, active=False,
        )
        rearchived = _revision_with_facts(
            db, prior, revision_number=2, prefix="truncated-new", texts=list(reversed(texts)), active=True,
        )
        prior.active_archive_revision_id = rearchived.id
        db.commit()

        old_blocks = [*_revision_v1_blocks(earlier, active_only), *_revision_v1_blocks(prior, historic)]
        new_blocks = [*_revision_v1_blocks(earlier, active_only), *_revision_v1_blocks(prior, rearchived)]
        selected_ids = {link.character_id for link in current.character_links}
        frozen_range = _candidate_range_v1(prefilter_memory_candidates_v1(
            old_blocks, chapter=current, selected_character_ids=selected_ids,
        ))
        current_range = _candidate_range_v1(prefilter_memory_candidates_v1(
            new_blocks, chapter=current, selected_character_ids=selected_ids,
        ))
        assert len(frozen_range) == expected_rows
        assert frozen_range != current_range
        assert _candidate_range_v1(_revision_v1_blocks(earlier, active_only)) == [frozen_range[0]]
        monkeypatch.setattr(production_context_service, "memory_candidates", lambda _db, _chapter: new_blocks)

        modern = freeze_manual_checker_input(db, current, current.draft_text)
        legacy = copy.deepcopy(modern)
        legacy["protocol_version"] = PRODUCTION_INPUT_V1
        legacy.pop("relationship_identities", None)
        legacy["selector_candidate_range"] = frozen_range
        legacy["input_fingerprint"] = production_context_service._input_fingerprint(legacy)
        assert is_frozen_input_current(db, current, legacy)


@pytest.mark.parametrize(
    ("fixed_history", "expected_current"),
    [("same", True), ("different", False), ("none", False)],
)
def test_v1_truncated_pool_rejects_partially_frozen_fixed_source_without_equivalent_revision(
    client, monkeypatch, fixed_history: str, expected_current: bool,
) -> None:
    """Only a full fixed contribution, or an equal old revision, proves v1 input."""
    _book_id, prior_id, current_id = _v1_story()
    with db_module.SessionLocal() as db:
        prior = db.get(Chapter, prior_id)
        current = db.get(Chapter, current_id)
        assert prior is not None and current is not None
        selected_id = current.character_links[0].character_id
        earlier = Chapter(book_id=current.book_id, index=0, status="finalized", draft_text="更早正文。")
        db.add(earlier)
        db.flush()
        fixed_texts = [f"固定前章事实{index:03d}" for index in range(301)]
        if fixed_history != "none":
            fixed_old = _revision_with_facts(
                db,
                earlier,
                revision_number=1,
                prefix=f"partial-fixed-{fixed_history}-old",
                texts=fixed_texts if fixed_history == "same" else [f"远古不同事实{index:03d}" for index in range(301)],
                active=False,
            )
            for fact in fixed_old.facts:
                db.add(ChapterArchiveFactParticipant(
                    fact_id=fact.id, character_id=selected_id, position=1,
                ))
        active_only = _revision_with_facts(
            db,
            earlier,
            revision_number=2 if fixed_history != "none" else 1,
            prefix=f"partial-fixed-{fixed_history}-active",
            texts=fixed_texts,
            active=True,
        )
        for fact in active_only.facts:
            db.add(ChapterArchiveFactParticipant(
                fact_id=fact.id, character_id=selected_id, position=1,
            ))
        earlier.active_archive_revision_id = active_only.id

        rearchive_texts = [f"等价重归档事实{index:03d}" for index in range(299)]
        historic = _revision_with_facts(
            db, prior, revision_number=1, prefix="partial-old", texts=rearchive_texts, active=False,
        )
        rearchived = _revision_with_facts(
            db, prior, revision_number=2, prefix="partial-new", texts=list(reversed(rearchive_texts)), active=True,
        )
        for revision in (historic, rearchived):
            for fact in revision.facts:
                db.add(ChapterArchiveFactParticipant(
                    fact_id=fact.id, character_id=selected_id, position=1,
                ))
        prior.active_archive_revision_id = rearchived.id
        db.commit()

        old_blocks = [*_revision_v1_blocks(earlier, active_only), *_revision_v1_blocks(prior, historic)]
        new_blocks = [*_revision_v1_blocks(earlier, active_only), *_revision_v1_blocks(prior, rearchived)]
        selected_ids = {link.character_id for link in current.character_links}
        frozen_range = _candidate_range_v1(prefilter_memory_candidates_v1(
            old_blocks, chapter=current, selected_character_ids=selected_ids,
        ))
        assert frozen_range != _candidate_range_v1(prefilter_memory_candidates_v1(
            new_blocks, chapter=current, selected_character_ids=selected_ids,
        ))
        assert len(frozen_range) == 300
        assert sum(row["chapter_index"] == earlier.index for row in frozen_range) == 1
        monkeypatch.setattr(production_context_service, "memory_candidates", lambda _db, _chapter: new_blocks)

        modern = freeze_manual_checker_input(db, current, current.draft_text)
        legacy = copy.deepcopy(modern)
        legacy["protocol_version"] = PRODUCTION_INPUT_V1
        legacy.pop("relationship_identities", None)
        legacy["selector_candidate_range"] = frozen_range
        legacy["input_fingerprint"] = production_context_service._input_fingerprint(legacy)
        assert is_frozen_input_current(db, current, legacy) is expected_current


def test_pending_relationship_identity_uses_current_names_without_raw_ids(client, monkeypatch) -> None:
    with db_module.SessionLocal() as db:
        book = Book(title="待定关系", world_setting="现代。")
        selected = Character(book=book, name="甲")
        other = Character(book=book, name="同名")
        duplicate = Character(book=book, name="同名")
        chapter = Chapter(book=book, index=1, title="本章", user_prompt="继续。", draft_text="甲继续。")
        db.add_all([book, selected, other, duplicate, chapter])
        db.flush()
        chapter.character_links.append(ChapterCharacter(character_id=selected.id))
        db.commit()

        raw_unknown = [{
            "character_id": selected.id,
            "character_name": "旧甲",
            "other_character_id": other.id,
            "other_character_name": "旧同名",
            "scope": "relationship",
            "slot": "relationship",
            "message": "旧甲与旧同名关系待定。",
        }]
        monkeypatch.setattr(
            production_context_service,
            "_projection_before",
            lambda _db, _chapter: ({}, raw_unknown),
        )
        selector_snapshot = freeze_selector_input(db, chapter, [])
        displayed = selector_snapshot["unknown_state_slots"]
        assert selector_snapshot["unknown_state_slot_identity"] == raw_unknown
        assert displayed == [{
            "scope": "relationship",
            "slot": "relationship",
            "character_name": "甲",
            "other_character_name": f"同名（ID:{other.id[:8]}）",
            "message": "该关系的章末状态尚无法确定",
        }]
        model_slots = str(displayed)
        assert selected.id not in model_slots and other.id not in model_slots
        assert "旧甲" not in model_slots and "旧同名" not in model_slots
        selector_prompt = memory_selector_user_message(
            chapter, [], MEMORY_BUDGET_CHARS,
            dynamic_fields_by_character=selector_snapshot["prior_state"],
            unknown_state_slots=displayed,
        )
        assert f"甲 与 同名（ID:{other.id[:8]}） 的关系：待定" in selector_prompt

        production_snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        unknown_catalog = next(item for item in production_snapshot["source_catalog"] if item["id"] == "prior_state:unknown")
        assert other.id not in unknown_catalog["text"]
        assert "旧同名" not in unknown_catalog["text"]
        assert is_frozen_selector_input_current(db, chapter, selector_snapshot)
        assert is_frozen_input_current(db, chapter, production_snapshot)

        other.name = "改名后"
        db.commit()
        assert not is_frozen_selector_input_current(db, chapter, selector_snapshot)
        assert not is_frozen_input_current(db, chapter, production_snapshot)

        db.delete(other)
        db.commit()
        removed = freeze_selector_input(db, chapter, [])
        removed_slot = removed["unknown_state_slots"][0]
        assert removed_slot["other_character_name"].startswith("关系对象已不可用（ID:")
        assert other.id not in str(removed_slot)


def test_pending_plain_state_uses_current_selected_name_without_raw_ids(client, monkeypatch) -> None:
    with db_module.SessionLocal() as db:
        book = Book(title="待定状态", world_setting="现代。")
        selected = Character(book=book, name="林夕")
        chapter = Chapter(book=book, index=1, title="本章", user_prompt="继续。")
        db.add_all([book, selected, chapter])
        db.flush()
        chapter.character_links.append(ChapterCharacter(character_id=selected.id))
        db.commit()
        raw_unknown = [{
            "character_id": selected.id,
            "character_name": "旧名",
            "scope": "snapshot",
            "slot": "当前行动",
            "message": "旧名状态待定。",
        }]
        monkeypatch.setattr(
            production_context_service,
            "_projection_before",
            lambda _db, _chapter: ({}, raw_unknown),
        )
        snapshot = freeze_selector_input(db, chapter, [])
        assert snapshot["unknown_state_slots"] == [{
            "scope": "snapshot",
            "slot": "当前行动",
            "character_name": "林夕",
            "message": "该状态尚无法确定",
        }]
        assert selected.id not in str(snapshot["unknown_state_slots"])
