from __future__ import annotations

import copy
import hashlib
import json

import pytest
from sqlalchemy import select

import app.db as db_module
from app.services import production_context as production_context_service
from app.agents.memory_selector import MemorySelectorAgent
from app.models import Book, Chapter, ChapterCharacter, Character
from app.services.checker_validation import CheckerValidationError, validate_checker_result
from app.services.context import (
    MEMORY_BUDGET_CHARS,
    MemoryBlock,
    memory_selection_problem,
    memory_selector_user_message,
    pack_selector_context,
    checker_user_message,
    writing_reference_context,
)
from app.services.production_context import (
    freeze_manual_checker_input,
    freeze_selected_write_input,
    is_frozen_input_current,
    bind_selected_candidate_draft,
    prepare_selected_write_input,
    production_readiness,
)


def _story(*, duplicate_name: bool = False) -> tuple[str, str, str]:
    with db_module.SessionLocal() as db:
        book = Book(title="快照书", world_setting="现代，没有超自然力量。")
        db.add(book)
        db.flush()
        summer = Character(book_id=book.id, name="夏天", fixed_profile="本书人物夏天。")
        selected = Character(book_id=book.id, name="林夕", fixed_profile="本章主角。")
        db.add_all([summer, selected])
        if duplicate_name:
            db.add(Character(book_id=book.id, name="夏天", fixed_profile="同名人物。"))
        db.flush()
        prior = Chapter(
            book_id=book.id, index=1, status="finalized", long_summary="林夕已归还钥匙。",
            draft_text="林夕在雨中归还钥匙。",
        )
        current = Chapter(book_id=book.id, index=2, title="等雨", user_prompt="林夕在雨后回家。")
        future = Chapter(book_id=book.id, index=3, status="finalized", long_summary="后章秘密。")
        db.add_all([prior, current, future])
        db.flush()
        current.character_links.append(ChapterCharacter(character_id=selected.id))
        db.commit()
        return current.id, prior.id, future.id


def _ordinary_raw(snapshot: dict) -> dict:
    return {
        "verdict": "passed",
        "issues": [],
        "name_uses": [
            {
                "hit_ids": group["hit_ids"],
                "classification": "ordinary_word",
                "reason": "这里描述季节，不是人物出场。",
            }
            for group in snapshot["name_groups"]
        ],
    }


def _group_for_hit(snapshot: dict, hit: dict) -> dict:
    return next(group for group in snapshot["name_groups"] if hit["hit_id"] in group["hit_ids"])


def test_checker_evidence_and_name_use_contract_are_strict(client) -> None:
    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        text = "今年夏天天气很热。林夕在雨后回家。"
        chapter.draft_text = text
        db.commit()
        snapshot = freeze_manual_checker_input(db, chapter, text)
        assert len(snapshot["name_hits"]) == 1
        accepted = validate_checker_result(_ordinary_raw(snapshot), snapshot, check_attempt_id="check-1")
        assert accepted["verdict"] == "passed"
        assert accepted["check_attempt_id"] == "check-1"

        passed_with_issue = _ordinary_raw(snapshot)
        passed_with_issue["issues"] = [{
            "kind": "world_conflict", "reason": "不符合世界观", "draft_evidence": "今年夏天",
            "bible_evidence": "", "source_kind": "world", "source_id": "world", "source_evidence": "没有超自然力量",
        }]
        with pytest.raises(CheckerValidationError, match="passed"):
            validate_checker_result(passed_with_issue, snapshot)

        forged = _ordinary_raw(snapshot)
        forged["verdict"] = "violation"
        forged["issues"] = [{
            "kind": "world_conflict", "reason": "不符合世界观", "draft_evidence": "不存在的正文",
            "bible_evidence": "", "source_kind": "world", "source_id": "world", "source_evidence": "不存在的来源",
        }]
        with pytest.raises(CheckerValidationError, match="引文"):
            validate_checker_result(forged, snapshot)

        missing_name_use = _ordinary_raw(snapshot)
        missing_name_use["name_uses"] = []
        with pytest.raises(CheckerValidationError, match="未逐项"):
            validate_checker_result(missing_name_use, snapshot)


def test_character_and_uncertain_name_uses_need_explicit_identity_issue(client) -> None:
    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        text = "夏天说：今天不要回家。"
        chapter.draft_text = text
        db.commit()
        snapshot = freeze_manual_checker_input(db, chapter, text)
        hit = snapshot["name_hits"][0]
        raw = {
            "verdict": "violation",
            "issues": [{
                "kind": "unselected_character", "reason": "夏天未被选择。", "draft_evidence": "夏天说",
                "bible_evidence": "", "source_kind": "authorization", "source_id": "authorization",
                "source_evidence": "selected_character_ids",
            }],
            "name_uses": [{
                "hit_ids": _group_for_hit(snapshot, hit)["hit_ids"], "classification": "character",
                "reason": "这里是说话的人物。", "character_id": hit["candidate_character_ids"][0],
            }],
        }
        validated = validate_checker_result(raw, snapshot)
        assert validated["verdict"] == "violation"
        assert validated["identity_issues"] == [{
            "kind": "unselected_character",
            "match_id": hit["hit_id"],
            "name": "夏天",
            "name_candidates": [{
                "character_id": hit["candidate_character_ids"][0],
                "name": "夏天", "role": "", "fixed_profile": "本书人物夏天。",
            }],
        }]
        raw["issues"][0]["kind"] = "world_conflict"
        with pytest.raises(CheckerValidationError, match="身份问题"):
            validate_checker_result(raw, snapshot)


def test_same_name_occurrences_are_classified_at_their_own_frozen_offsets(client) -> None:
    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.draft_text = "今年夏天天气很热。夏天说道：回家。"
        db.commit()
        snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        draft_hits = [item for item in snapshot["name_hits"] if item["source_id"] == "draft"]
        assert len(draft_hits) == 2
        season, speaker = draft_hits
        assert season["source_start"] < speaker["source_start"]
        assert "夏天" in season["local_excerpt"] and "夏天" in speaker["local_excerpt"]
        raw = {
            "verdict": "violation",
            "issues": [{
                "kind": "unselected_character", "reason": "说话的夏天未获选择。", "draft_evidence": "夏天说道",
                "bible_evidence": "", "source_kind": "authorization", "source_id": "authorization",
                "source_evidence": "selected_character_ids",
            }],
            "name_uses": [
                {
                    "hit_ids": _group_for_hit(snapshot, season)["hit_ids"], "classification": "ordinary_word",
                    "reason": "这里指季节。",
                },
                {
                    "hit_ids": _group_for_hit(snapshot, speaker)["hit_ids"], "classification": "character",
                    "reason": "这里是说话者。", "character_id": speaker["candidate_character_ids"][0],
                },
            ],
        }
        assert validate_checker_result(raw, snapshot)["verdict"] == "violation"

        forged = copy.deepcopy(raw)
        forged["name_uses"][1]["hit_ids"] = _group_for_hit(snapshot, season)["hit_ids"] + _group_for_hit(snapshot, speaker)["hit_ids"]
        with pytest.raises(CheckerValidationError, match="不能跨"):
            validate_checker_result(forged, snapshot)


def test_name_groups_preserve_different_sentences_with_identical_short_excerpts(client) -> None:
    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        shared = "经过很长时间的等待以及漫长而又无声的旅途之后终于等到了"
        chapter.draft_text = f"他们谈论的是季节，{shared}夏天。她是那个女孩，{shared}夏天。"
        db.commit()
        snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        assert len(snapshot["name_hits"]) == 2
        assert len(snapshot["name_groups"]) == 2
        first, second = snapshot["name_groups"]
        assert first["local_context"] == second["local_context"]
        assert first["hit_ids"] != second["hit_ids"]


def test_compact_name_groups_handle_500_mixed_uses_without_prompt_or_reply_blowup(client) -> None:
    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        # 250 seasonal words plus 250 speaking characters exercise the path
        # that previously repeated local evidence/offsets 500 times.
        chapter.draft_text = ("今年夏天天气很热。夏天说道：回家。" * 250)
        db.commit()
        snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        assert len(snapshot["name_hits"]) == 500
        assert len(snapshot["name_groups"]) == 2
        speaking = next(group for group in snapshot["name_groups"] if "说道" in group["local_context"])
        seasonal = next(group for group in snapshot["name_groups"] if "天气很热" in group["local_context"])
        raw = {
            "verdict": "violation",
            "issues": [{
                "kind": "unselected_character", "reason": "说话的夏天未获本章授权。", "draft_evidence": "夏天说道",
                "bible_evidence": "", "source_kind": "authorization", "source_id": "authorization",
                "source_evidence": "selected_character_ids",
            }],
            "name_uses": [
                {"hit_ids": seasonal["hit_ids"], "classification": "ordinary_word", "reason": "这里指季节。"},
                {
                    "hit_ids": speaking["hit_ids"], "classification": "character", "reason": "这里是说话者。",
                    "character_id": snapshot["name_hits"][0]["candidate_character_ids"][0],
                },
            ],
        }
        message = checker_user_message(
            chapter, chapter.draft_text, snapshot["bible"], reference_context=snapshot["reference_context"],
            source_catalog=snapshot["source_catalog"], name_hits=snapshot["name_hits"],
            name_groups=snapshot["name_groups"], name_candidate_groups=snapshot["name_candidate_groups"],
        )
        assert len(message) < 20_000
        assert len(json.dumps(raw, ensure_ascii=False)) < 6_000
        checked = validate_checker_result(raw, snapshot)
        assert len(checked["name_uses"]) == 500
        assert sum(item["classification"] == "ordinary_word" for item in checked["name_uses"]) == 250

        unknown = copy.deepcopy(raw)
        unknown["name_uses"][0]["hit_ids"] = ["n404404"]
        with pytest.raises(CheckerValidationError, match="未知命中"):
            validate_checker_result(unknown, snapshot)
        duplicate = copy.deepcopy(raw)
        duplicate["name_uses"][0]["hit_ids"].append(duplicate["name_uses"][0]["hit_ids"][0])
        with pytest.raises(CheckerValidationError, match="缺少分组"):
            validate_checker_result(duplicate, snapshot)


def test_bible_only_unselected_name_uses_bible_evidence_without_fabricating_draft(client) -> None:
    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.user_prompt = "夏天必须在雨后回家。"
        chapter.draft_text = "林夕在雨后回家。"
        db.commit()
        snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        hit = next(item for item in snapshot["name_hits"] if item["source_id"] == "bible")
        raw = {
            "verdict": "violation",
            "issues": [{
                "kind": "unselected_character", "reason": "Bible 中的夏天未获本章人物授权。",
                "draft_evidence": "", "bible_evidence": "夏天必须在雨后回家",
                "source_kind": "bible", "source_id": "bible", "source_evidence": "夏天必须在雨后回家",
            }],
            "name_uses": [{
                "hit_ids": _group_for_hit(snapshot, hit)["hit_ids"], "classification": "character",
                "reason": "这里是人物承担行动。", "character_id": hit["candidate_character_ids"][0],
            }],
        }
        assert validate_checker_result(raw, snapshot)["verdict"] == "violation"


def test_exemption_precedes_same_name_ambiguity(client) -> None:
    chapter_id, _prior_id, _future_id = _story(duplicate_name=True)
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.exempted_character_names = ["夏天"]
        chapter.draft_text = "夏天说：雨要停了。"
        db.commit()
        snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        assert snapshot["name_hits"] == []
        assert validate_checker_result(
            {"verdict": "passed", "issues": [], "name_uses": []}, snapshot,
        )["verdict"] == "passed"


def test_snapshot_follows_prior_sources_not_future_changes_and_hidden_candidate_is_supported(client) -> None:
    chapter_id, prior_id, future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.draft_text = "林夕在雨后回家。"
        db.commit()
        manual = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        assert is_frozen_input_current(db, chapter, manual)

        future = db.get(Chapter, future_id)
        future.long_summary = "后章改变不会影响前章检查。"
        db.commit()
        assert is_frozen_input_current(db, chapter, manual)

        prior = db.get(Chapter, prior_id)
        prior.long_summary = "林夕并未归还钥匙。"
        db.commit()
        assert not is_frozen_input_current(db, chapter, manual)

        candidates = []
        hidden_text = "夏天在雨后出现。" + "雨。" * 30
        manifest = {
            "memory_brief": [], "conflicts": [], "previous_ending_start_id": None,
            "selection_mode": "test",
        }
        # A frozen generated candidate is intentionally compared by its caller
        # against its private candidate row, not the still-visible chapter text.
        selected = freeze_selected_write_input(db, chapter, hidden_text, memory_manifest=manifest)
        assert selected["draft"]["source"] == "candidate"
        assert selected["name_hits"]
        assert is_frozen_input_current(db, chapter, selected)


def test_unselected_profile_metadata_does_not_stale_a_snapshot_but_identity_does(client) -> None:
    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        chapter.draft_text = "夏天在雨后回家。"
        db.commit()
        snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        summer = db.scalar(
            select(Character).where(Character.book_id == chapter.book_id, Character.name == "夏天")
        )
        assert summer is not None

        # An unselected card's role/profile is not in the Writer/Checker
        # prompt.  It is retained only as a UI repair label, so this edit must
        # not cancel a live run.
        summer.fixed_profile = "更新后的路人介绍。"
        db.commit()
        assert is_frozen_input_current(db, chapter, snapshot)

        db.add(Character(book_id=chapter.book_id, name="从未出现", fixed_profile="无关人物。"))
        db.commit()
        assert is_frozen_input_current(db, chapter, snapshot)

        # Only a name that changes the actual program-owned hit set stales it.
        summer.name = "夏雨"
        db.commit()
        assert not is_frozen_input_current(db, chapter, snapshot)


def test_selected_write_input_freezes_before_writer_and_binds_candidate_without_db_read(client) -> None:
    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        manifest = {
            "memory_brief": [], "conflicts": [], "previous_ending_start_id": None,
            "selection_mode": "test",
        }
        prepared = prepare_selected_write_input(db, chapter, memory_manifest=manifest)
        assert prepared["draft"] == {"sha256": hashlib.sha256(b"").hexdigest(), "source": "candidate_pending"}
        reference_context = prepared["reference_context"]
        candidate = bind_selected_candidate_draft(prepared, "夏天说道：雨后回家。")
        assert candidate["draft"]["source"] == "candidate"
        assert candidate["reference_context"] == reference_context
        assert candidate["source_catalog"][0]["text"] == "夏天说道：雨后回家。"
        assert candidate["name_hits"]
        assert is_frozen_input_current(db, chapter, candidate)

        # Binding observes no new DB state.  A subsequent upstream change is
        # detected by the final CAS rather than silently rewritten into input.
        chapter.user_prompt = "新的 Bible。"
        db.commit()
        assert not is_frozen_input_current(db, chapter, candidate)


def test_selector_validation_uses_independent_700_and_2400_budgets_and_one_correction() -> None:
    blocks = [
        MemoryBlock("previous_ending:one", "尾" * 700, 1, memory_type="previous_ending"),
        MemoryBlock("fact", "原始事实", 1),
    ]
    briefs = [{"text": "简" * 1800, "source_ids": ["fact"]}]
    assert memory_selection_problem(blocks, briefs, [], "previous_ending:one") is None
    packed = pack_selector_context(blocks, briefs, [], "previous_ending:one")
    assert len(packed.previous_ending) == 700
    assert sum(len(item.text) for item in packed.memories) == 1800
    assert memory_selection_problem(blocks, briefs, [], "missing") is not None

    class CorrectingLLM:
        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            return {
                "briefs": [{"text": "事实", "source_ids": ["bad" if self.calls == 1 else "fact"]}],
                "conflicts": [], "previous_ending_start_id": None,
            }

    llm = CorrectingLLM()
    selection = MemorySelectorAgent(llm, "selector").select(
        "候选", validator=lambda item: memory_selection_problem(blocks, item.briefs, item.conflicts, item.previous_ending_start_id),
    )
    assert llm.calls == 2 and selection.briefs[0]["source_ids"] == ["fact"]


def test_selector_whitespace_source_id_is_corrected_before_packing() -> None:
    blocks = [MemoryBlock("fact", "原始事实", 1)]

    class WhitespaceCorrectingLLM:
        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            source_id = " fact " if self.calls == 1 else "fact"
            return {
                "briefs": [{"text": "事实", "source_ids": [source_id]}],
                "conflicts": [], "previous_ending_start_id": None,
            }

    llm = WhitespaceCorrectingLLM()
    selection = MemorySelectorAgent(llm, "selector").select(
        "候选",
        validator=lambda item: memory_selection_problem(
            blocks, item.briefs, item.conflicts, item.previous_ending_start_id,
        ),
    )
    assert llm.calls == 2
    assert selection.briefs == [{"text": "事实", "source_ids": ["fact"]}]
    assert pack_selector_context(blocks, selection.briefs, selection.conflicts, selection.previous_ending_start_id).memories[0].id == "fact"


def test_readiness_reports_incomplete_history_with_refreshable_token(client) -> None:
    chapter_id, prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        prior = db.get(Chapter, prior_id)
        prior.legacy_archive_eligible = False
        prior.archive_input_fingerprint = "attempted"
        prior.archive_status = "failed"
        db.commit()
        readiness = production_readiness(db, chapter)
        assert readiness["is_complete"] is False
        assert readiness["context_limitations"][0]["chapter_id"] == prior_id
        assert readiness["recommended_recovery"]["kind"] == "missing_memory"
        stale_token = readiness["context_token"]
        prior.archive_status = "stale"
        db.commit()
        assert production_readiness(db, chapter)["context_token"] != stale_token


def test_unknown_prior_state_is_visible_and_never_falls_back_to_current_card(client, monkeypatch) -> None:
    with db_module.SessionLocal() as db:
        book = Book(title="状态书")
        db.add(book)
        db.flush()
        character = Character(
            book_id=book.id, name="林夕", fixed_profile="主角", dynamic_fields={"当前行动": "未来的全书当前值"},
        )
        chapter = Chapter(book_id=book.id, index=2, title="本章", user_prompt="继续")
        db.add_all([character, chapter])
        db.flush()
        chapter.character_links.append(ChapterCharacter(character_id=character.id))
        db.commit()
        unknown = [{
            "character_id": character.id, "character_name": "林夕", "scope": "snapshot", "slot": "当前行动",
            "message": "第 1 章该状态存在多个结果，尚无法确定",
        }]
        reference = writing_reference_context(
            book, chapter, dynamic_fields_by_character={character.id: {}}, unknown_state_slots=unknown,
        )
        selector = memory_selector_user_message(
            chapter, [], MEMORY_BUDGET_CHARS,
            dynamic_fields_by_character={character.id: {}}, unknown_state_slots=unknown,
        )
        chapter.draft_text = "林夕继续前行。"
        monkeypatch.setattr(
            production_context_service,
            "_projection_before",
            lambda _db, _chapter: ({character.id: {}}, unknown),
        )
        snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
    assert "未来的全书当前值" not in reference
    assert "林夕 的 当前行动：待定" in reference
    assert "林夕 的 当前行动：待定" in selector
    unknown_source = next(item for item in snapshot["source_catalog"] if item["id"] == "prior_state:unknown")
    assert unknown_source["kind"] == "prior_state"
    assert "当前行动" in unknown_source["text"]
    with pytest.raises(CheckerValidationError, match="待定状态只说明资料范围"):
        validate_checker_result(
            {
                "verdict": "violation",
                "issues": [{
                    "kind": "state_conflict", "reason": "待定不能当作相反状态。", "draft_evidence": "林夕继续",
                    "bible_evidence": "", "source_kind": "prior_state", "source_id": "prior_state:unknown",
                    "source_evidence": "当前行动",
                }],
                "name_uses": [],
            },
            snapshot,
        )
