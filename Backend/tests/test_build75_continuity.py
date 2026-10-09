"""Neutral fixtures prove contracts and lifecycle, never literary quality."""
from copy import deepcopy
import hashlib
import io
import json
import shutil
import sqlite3
import zipfile
from types import SimpleNamespace

import pytest
from alembic import command
from alembic.config import Config
from sqlalchemy import select

import app.db as db_module
from app.config import get_settings
from app.agents.extractor import extractor_v2_schema
from app.agents.memory_selector import MemorySelectorAgent
from app.llm.base import LLMError
from app.models import Book, Chapter, Character, ChapterArchiveRevision, ChapterDraftCandidate, AgentPersona, BookAgentPersona, JobRun
from app.services.archive_v2 import (
    CONTINUITY_KEYS, ArchiveV2ValidationError, validate_archive_output,
    create_archive_revision, mark_revision_extracting, activate_archive_revision,
    archive_input_fingerprint, archive_read_model,
    build_archive_user_message,
)
from app.services.chapter_continuity import (
    previous_chapter_context, distant_candidates, complete_ending,
    SELECTOR_CONTRACT_VERSION, source_selection_problem,
)
from app.services.production_context import (
    freeze_manual_checker_input, freeze_selected_write_input, is_frozen_input_current,
    prepare_selected_write_input, bind_selected_candidate_draft, rewrite_reference_key,
    freeze_selector_input, is_frozen_selector_input_current, reusable_write_memory,
    production_readiness,
)
from app.services.checker_validation import validate_checker_result, CheckerValidationError
from app.services.project_packages import export_project_package, import_project_package, ProjectPackageError
from app.services.personas import seed_defaults, PROGRAM_PROTOCOLS


def _output(*, fact_type="剧情", text="已完成一次交接。", refs=None):
    return {"summary": "交接完成，最后停在门边。", "facts": [{
        "fact_ref": "alias", "type": fact_type, "importance": 3, "text": text,
        "participant_names": [], "start_id": "P0001-S01", "end_id": "P0001-S01",
    }], "end_state_delta": [], "continuity": {key: list((refs or {}).get(key, [])) for key in CONTINUITY_KEYS}}


def _archive(db, chapter, *, contract="archive-v2.2", output=None):
    payload = output or _output(refs={"completed_fact_refs": ["alias"]})
    if contract != "archive-v2.2":
        payload = {key: value for key, value in payload.items() if key != "continuity"}
    revision = create_archive_revision(db, chapter, provenance="manual_retry")
    revision.contract_version = contract
    revision.input_fingerprint = archive_input_fingerprint(chapter, contract_version=contract)
    db.flush()
    mark_revision_extracting(revision, chapter)
    db.commit()
    activate_archive_revision(db, chapter, revision, validate_archive_output(chapter, payload, contract_version=contract), model_name="fake")
    db.commit()
    return revision


def _story(db, *, old=False):
    book = Book(title="中性样本", world_setting="只有普通档案室。")
    db.add(book)
    db.flush()
    first = Chapter(book=book, index=1, title="准备", status="finalized", draft_text="记录已经登记。")
    previous = Chapter(book=book, index=2, title="交接", status="finalized", draft_text="交接完成。最后停在门边。")
    current = Chapter(book=book, index=3, title="核对", user_prompt="先核对记录，再离开。", draft_text="再次第一次完成交接。")
    db.add_all([first, previous, current])
    db.commit()
    _archive(db, first)
    _archive(db, previous, contract="archive-v2.1" if old else "archive-v2.2")
    return book, first, previous, current


def test_v22_alias_rebinding_and_old_contract_schema_are_explicit():
    chapter = SimpleNamespace(draft_text="记录已知。", character_links=[])
    output = _output(fact_type="认知", refs={"known_fact_refs": ["alias", "duplicate", "alias"]})
    output["facts"].append(dict(output["facts"][0], fact_ref="duplicate"))
    validated = validate_archive_output(chapter, output)
    assert validated.continuity["known_fact_refs"] == ["F1"]
    assert len(validated.facts) == 1
    assert "continuity" in extractor_v2_schema([])["required"]
    for contract in ("archive-v2.0", "archive-v2.1"):
        assert "continuity" not in extractor_v2_schema([], contract_version=contract)["properties"]
        old = {key: value for key, value in _output().items() if key != "continuity"}
        assert validate_archive_output(chapter, old, contract_version=contract).continuity is None
    with pytest.raises(ArchiveV2ValidationError):
        validate_archive_output(chapter, old)


def test_continuity_can_reference_one_canonical_fact_in_multiple_categories(client):
    with db_module.SessionLocal() as db:
        _, _, previous, _ = _story(db)
        output = _output(fact_type="认知", refs={key: ["alias"] for key in CONTINUITY_KEYS[:3]})
        validated = validate_archive_output(previous, output)
        assert len(validated.facts) == 1
        assert all(validated.continuity[key] == ["F1"] for key in CONTINUITY_KEYS[:3])
        for prompt in (PROGRAM_PROTOCOLS["extractor"], build_archive_user_message(previous, {})):
            assert "同一fact_ref可同时被多个continuity类别引用" in prompt
            assert "类别内不得重复引用" in prompt
            assert "不得将同一事实重复到多个数组" not in prompt


@pytest.mark.parametrize("change", ["missing", "extra", "null", "type", "unknown", "known_type", "open_type", "completed_open"])
def test_v22_rejects_bad_reference_contract(change):
    output = _output()
    if change == "missing": output["continuity"].pop("open_fact_refs")
    elif change == "extra": output["continuity"]["extra"] = []
    elif change == "null": output["continuity"] = None
    elif change == "type": output["continuity"]["open_fact_refs"] = "alias"
    elif change == "unknown": output["continuity"]["last_landing_fact_refs"] = ["missing"]
    elif change == "known_type": output["continuity"]["known_fact_refs"] = ["alias"]
    elif change == "open_type": output["continuity"]["open_fact_refs"] = ["alias"]
    else:
        output["facts"][0]["type"] = "未决"
        output["continuity"]["completed_fact_refs"] = ["alias"]
    with pytest.raises(ArchiveV2ValidationError):
        validate_archive_output(SimpleNamespace(draft_text="交接完成。", character_links=[]), output)


@pytest.mark.parametrize("old", [False, True])
def test_previous_archive_complete_direct_delivery_and_public_refs(client, old):
    with db_module.SessionLocal() as db:
        _, first, previous, current = _story(db, old=old)
        context = previous_chapter_context(db, current)
        snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        assert context["mode"] == "v2"
        assert previous.active_archive_revision_id == context["revision_id"]
        assert context["sources"][0]["text"].endswith("交接完成，最后停在门边。")
        assert any("已完成一次交接。" in row["text"] for row in context["sources"])
        assert context["previous_ending"] == "交接完成。\n最后停在门边。"
        assert all(block.chapter_index == first.index for block in distant_candidates(db, current))
        assert all(row["text"] in snapshot["reference_context"] for row in context["sources"])
        assert all(row["id"] in {item["id"] for item in snapshot["source_catalog"]} for row in context["sources"])
        read = archive_read_model(db, previous)
        if old:
            assert read["continuity"] is None
            assert "旧归档无承接分类" in snapshot["reference_context"]
        else:
            assert read["continuity"]["completed_fact_refs"] == [read["facts"][0]["id"]]


@pytest.mark.parametrize("change", ["reopen", "draft", "classification", "delete"])
def test_previous_change_invalidates_v3_without_replacing_frozen_text(client, change):
    with db_module.SessionLocal() as db:
        _, _, previous, current = _story(db)
        snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        reference = snapshot["reference_context"]
        assert is_frozen_input_current(db, current, snapshot)
        if change == "reopen": previous.status = "draft_ready"
        elif change == "draft": previous.draft_text += "新结尾。"
        elif change == "delete": db.delete(previous)
        else:
            revision = db.get(ChapterArchiveRevision, previous.active_archive_revision_id)
            revision.continuity = {key: [] for key in CONTINUITY_KEYS}
        db.commit()
        assert not is_frozen_input_current(db, current, snapshot)
        assert snapshot["reference_context"] == reference


def test_no_previous_becoming_previous_invalidates_and_never_skips_gap(client):
    with db_module.SessionLocal() as db:
        book = Book(title="缺章")
        db.add(book); db.flush()
        current = Chapter(book=book, index=3, draft_text="核对。")
        db.add(current); db.commit()
        snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        assert snapshot["previous_chapter_context"]["mode"] == "unavailable"
        db.add(Chapter(book=book, index=2, status="draft", draft_text="尚未接受。")); db.commit()
        assert not is_frozen_input_current(db, current, snapshot)
        assert previous_chapter_context(db, current)["sources"] == []


def test_equivalent_rearchive_rebinds_v3_and_rewrite_selection(client):
    with db_module.SessionLocal() as db:
        _, first, previous, current = _story(db)
        candidates = distant_candidates(db, current)
        manifest = {"selector_contract_version": SELECTOR_CONTRACT_VERSION,
                    "memory_brief": [{"text": block.text, "source_ids": [block.id]} for block in candidates], "conflicts": []}
        frozen_selector = freeze_selector_input(db, current, candidates)
        key = rewrite_reference_key(db, current, candidates)
        prepared = prepare_selected_write_input(db, current, memory_manifest=manifest, selector_candidates=candidates)
        snapshot = bind_selected_candidate_draft(prepared, "中性稿。"); snapshot["rewrite_reference_key"] = key
        db.add(JobRun(chapter_id=current.id, kind="write", phase="done", input_snapshot=snapshot,
                      memory_context=snapshot["memory_manifest"]))
        db.commit()
        _archive(db, first); _archive(db, previous)
        db.expire_all()
        assert is_frozen_selector_input_current(db, current, frozen_selector)
        assert is_frozen_input_current(db, current, snapshot)
        assert rewrite_reference_key(db, current, distant_candidates(db, current)) == key
        reused = reusable_write_memory(db, current, key)
        assert reused is not None
        assert reused["memory_brief"][0]["source_ids"] != manifest["memory_brief"][0]["source_ids"]
        assert prepare_selected_write_input(db, current, memory_manifest=reused)["reference_context"] == prepared["reference_context"]


def test_distant_fact_classification_is_part_of_original_source_and_invalidates_v2_v3(client):
    with db_module.SessionLocal() as db:
        _, first, _, current = _story(db)
        candidates = distant_candidates(db, current)
        selector_snapshot = freeze_selector_input(db, current, candidates)
        current_snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        old_snapshot = freeze_manual_checker_input(db, current, current.draft_text, protocol_version="production-input-v2")
        assert is_frozen_input_current(db, current, old_snapshot)
        assert any("剧情事实" in item.text for item in candidates)
        key = rewrite_reference_key(db, current, candidates)
        revision = db.get(ChapterArchiveRevision, first.active_archive_revision_id)
        revision.facts[0].fact_type = "未决"
        revision.continuity = {key: [] for key in CONTINUITY_KEYS}
        db.commit()
        assert not is_frozen_selector_input_current(db, current, selector_snapshot)
        assert not is_frozen_input_current(db, current, current_snapshot)
        assert rewrite_reference_key(db, current, distant_candidates(db, current)) != key
        assert any("未决事实" in item.text for item in distant_candidates(db, current))
        assert not is_frozen_input_current(db, current, old_snapshot)


def test_ending_only_legacy_gap_and_complete_sentence_budget(client):
    assert complete_ending("长" * 701 + "。") == ""
    assert complete_ending("长" * 701 + "。最后落点。") == "最后落点。"
    with db_module.SessionLocal() as db:
        _, _, previous, current = _story(db)
        revision = db.get(ChapterArchiveRevision, previous.active_archive_revision_id)
        revision.is_active = False; revision.status = "failed"
        previous.active_archive_revision_id = None; previous.archive_status = "failed"
        db.commit()
        assert previous_chapter_context(db, current)["mode"] == "ending_only"
        previous.legacy_archive_eligible = True; previous.long_summary = "完整旧摘要。"
        previous.atomic_memories = [{"text": "超" * 8000}, {"text": "短旧事实。"}]
        db.commit()
        context = previous_chapter_context(db, current)
        assert context["mode"] == "legacy"
        assert any("短旧事实" in row["text"] for row in context["sources"])
        assert context["limitations"]


@pytest.mark.parametrize("contract", ["archive-v2.0", "archive-v2.1", "archive-v2.2"])
@pytest.mark.parametrize("payload", [{}, {"author_note": "中性备注"}, {"draft_text": "交接完成。最后停在门边。"}])
def test_build76_metadata_or_unchanged_patch_preserves_archive(client, auth_headers, contract, payload):
    with db_module.SessionLocal() as db:
        _, _, previous, current = _story(db)
        archive = _archive(db, previous, contract=contract)
        chapter_id, archive_id = previous.id, archive.id
        fingerprint, body = previous.archive_input_fingerprint, previous.draft_text
        snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        revision = previous.content_revision
    response = client.patch(f"/api/v1/chapters/{chapter_id}", json=payload,
                            headers={**auth_headers, "If-Match": f'"{revision}"'})
    assert response.status_code == 200, response.text
    with db_module.SessionLocal() as db:
        previous = db.get(Chapter, chapter_id)
        archive = db.get(ChapterArchiveRevision, archive_id)
        assert previous.status == "finalized" and previous.draft_text == body
        assert previous.archive_status == "complete"
        assert previous.active_archive_revision_id == archive_id
        assert previous.archive_input_fingerprint == fingerprint
        assert archive.is_active and archive.status == "complete"
        current = db.get(Chapter, snapshot["chapter"]["id"])
        assert is_frozen_input_current(db, current, snapshot)
        assert previous_chapter_context(db, current)["revision_id"] == archive_id


@pytest.mark.parametrize("contract", ["archive-v2.0", "archive-v2.1", "archive-v2.2"])
@pytest.mark.parametrize("change", ["draft", "whitelist"])
def test_build76_actual_input_patch_still_invalidates_archive(client, auth_headers, contract, change):
    with db_module.SessionLocal() as db:
        book, _, previous, _ = _story(db)
        archive = _archive(db, previous, contract=contract)
        character = Character(book_id=book.id, name="测试人物")
        db.add(character); db.commit()
        chapter_id, archive_id, revision = previous.id, archive.id, previous.content_revision
        payload = {"draft_text": "正文实际变化。"} if change == "draft" else {
            "character_links": [{"character_id": character.id}]
        }
    response = client.patch(f"/api/v1/chapters/{chapter_id}", json=payload,
                            headers={**auth_headers, "If-Match": f'"{revision}"'})
    assert response.status_code == 200, response.text
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        archive = db.get(ChapterArchiveRevision, archive_id)
        assert chapter.status != "finalized" and chapter.archive_status == "stale"
        assert chapter.active_archive_revision_id is None
        assert not archive.is_active and archive.status == "stale"


@pytest.mark.parametrize("opening,closing", [("“", "”"), ("‘", "’"), ("「", "」"), ("『", "』"), ('"', '"'), ("'", "'"), ("“『", "』”")])
def test_build76_quoted_ending_keeps_closers_and_budget(opening, closing):
    prefix = "他说：" + opening
    exactly_fits = prefix + "长" * (700 - len(prefix) - len(closing) - 1) + "。" + closing
    oversized = prefix + "长" * 705 + "。" + closing
    assert complete_ending(exactly_fits) == exactly_fits
    assert complete_ending(oversized) == ""
    assert complete_ending(oversized + "最后落点。") == "最后落点。"


def test_build76_sentence_punctuation_is_not_an_independent_ending():
    assert complete_ending("长" * 705 + "！？") == ""
    assert complete_ending("他说：“完成了！？”最后落点。") == "他说：“完成了！？”\n最后落点。"


def test_build76_oversized_quoted_ending_is_missing_in_actual_context(client):
    with db_module.SessionLocal() as db:
        _, _, previous, current = _story(db)
        previous.draft_text = "他说：“" + "长" * 705 + "。”"
        _archive(db, previous)
        context = previous_chapter_context(db, current)
        snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        assert context["previous_ending"] == ""
        assert any(item["kind"] == "previous_ending_unavailable" for item in context["limitations"])
        assert not any(item["kind"] == "ending" for item in context["sources"])
        assert not any(item["id"].endswith(":ending") for item in snapshot["source_catalog"])
        assert context["sources"]  # Valid facts remain available despite the missing ending.


def test_oversized_distant_source_is_omitted_whole_without_rearchive_guidance(client):
    with db_module.SessionLocal() as db:
        _, first, _, current = _story(db)
        first.active_archive_revision_id = None
        for revision in first.archive_revisions:
            revision.is_active = False
        first.legacy_archive_eligible = True
        first.long_summary = "超" * 2401
        first.atomic_memories = [{"text": "完整短条目。"}]
        db.commit()
        candidates = distant_candidates(db, current)
        assert all("超" not in item.text for item in candidates)
        assert any("完整短条目。" in item.text for item in candidates)
        readiness = production_readiness(db, current)
        assert any(item["kind"] == "history_source_over_budget" for item in readiness["context_limitations"])
        assert readiness["recommended_recovery"] is None


def test_invalid_v22_single_extraction_preserves_accepted_prose_and_old_active_archive(client, auth_headers, wait_for_terminal):
    from app.llm.factory import get_extractor_client, get_checker_client
    calls = []
    with db_module.SessionLocal() as db:
        _, _, previous, _ = _story(db)
        cid, old_revision, original = previous.id, previous.active_archive_revision_id, previous.draft_text
    class BadExtractor:
        def complete_json(self, **kwargs):
            calls.append(kwargs)
            output = _output()
            output["continuity"]["completed_fact_refs"] = ["missing"]
            return output
    def forbidden(): raise AssertionError("archive retry must not rerun Checker")
    client.app.dependency_overrides[get_extractor_client] = BadExtractor
    client.app.dependency_overrides[get_checker_client] = forbidden
    client.post(f"/api/v1/chapters/{cid}/archive/retry", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, cid, auth_headers)
    assert result["phase"] == "failed"
    assert len(calls) == 1
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, cid)
        assert chapter.status == "finalized" and chapter.draft_text == original
        assert chapter.active_archive_revision_id == old_revision
        assert db.get(ChapterArchiveRevision, old_revision).is_active
        latest = max(chapter.archive_revisions, key=lambda item: item.revision)
        assert latest.contract_version == "archive-v2.2" and not latest.is_active
        assert latest.continuity is None


@pytest.mark.parametrize("output", [
    {"selected_source_ids": ["M1"], "conflict_source_ids": []},
    {"selected_source_ids": ["M1", "M1"], "conflict_source_ids": []},
    {"selected_source_ids": ["M1"], "conflict_source_ids": ["M1"]},
    {"selected_source_ids": ["missing"], "conflict_source_ids": []},
    {"selected_source_ids": ["M1"], "conflict_source_ids": [], "text": "后来又过了一周"},
])
def test_selector_only_source_handles_and_no_time_rewriting(output):
    from app.services.context import MemoryBlock
    calls = []
    class Fake:
        def complete_json(self, **kwargs): calls.append(kwargs); return deepcopy(output)
    blocks = [MemoryBlock(id="canonical", text="一周内完成登记。", chapter_index=1)]
    agent = MemorySelectorAgent(Fake(), "作者自定义")
    if output == {"selected_source_ids": ["M1"], "conflict_source_ids": []}:
        result = agent.select_sources("中性输入", candidates=blocks)
        assert result.briefs == [{"text": blocks[0].text, "source_ids": ["canonical"]}]
        assert len(calls) == 1
    else:
        with pytest.raises(LLMError) as exc: agent.select_sources("中性输入", candidates=blocks)
        assert exc.value.code == "memory_selection_invalid"
        assert len(calls) == 2


def test_source_budget_rejects_whole_selection_without_truncation():
    from app.services.context import MemoryBlock
    blocks = [MemoryBlock(id="a", text="甲" * 1200, chapter_index=1), MemoryBlock(id="b", text="乙" * 1201, chapter_index=1)]
    rows = [{"text": block.text, "source_ids": [block.id]} for block in blocks]
    assert source_selection_problem(blocks, rows, [])
    blocks[1] = MemoryBlock(id="b", text="乙" * 1200, chapter_index=1)
    rows[1]["text"] = blocks[1].text
    assert source_selection_problem(blocks, rows, []) is None


@pytest.mark.parametrize("kind,source_kind", [("continuity_repeated_progress", "history"), ("continuity_repeated_progress", "draft"),
    ("continuity_known_reset", "history"), ("continuity_timeline_conflict", "draft"), ("required_order_conflict", "bible")])
def test_checker_new_kind_source_matrix_and_evidence(client, kind, source_kind):
    with db_module.SessionLocal() as db:
        _, _, _, current = _story(db)
        snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        source = next(row for row in snapshot["source_catalog"] if row["kind"] == source_kind)
        issue = {"kind": kind, "reason": "有明确冲突", "source_kind": source_kind, "source_id": source["id"],
                 "source_evidence": source["text"], "draft_evidence": current.draft_text,
                 "bible_evidence": source["text"] if source_kind == "bible" else ""}
        raw = {"verdict": "violation", "issues": [issue], "name_uses": []}
        assert validate_checker_result(raw, snapshot)["verdict"] == "violation"
        issue["source_kind"] = "world"; issue["source_id"] = "world"; issue["source_evidence"] = snapshot["world"]
        with pytest.raises(CheckerValidationError): validate_checker_result(raw, snapshot)


def test_checker_pending_fact_is_not_definite_contradiction(client):
    with db_module.SessionLocal() as db:
        _, _, previous, current = _story(db)
        _archive(db, previous, output=_output(fact_type="未决", text="是否离开尚未决定。", refs={"open_fact_refs": ["alias"]}))
        snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        source = next(row for row in snapshot["source_catalog"] if row.get("uncertain"))
        issue = {"kind": "continuity_known_reset", "reason": "不应重置", "source_kind": "history", "source_id": source["id"],
                 "source_evidence": source["text"], "draft_evidence": current.draft_text, "bible_evidence": ""}
        with pytest.raises(CheckerValidationError, match="未决"): validate_checker_result({"verdict": "violation", "issues": [issue], "name_uses": []}, snapshot)


def test_protocols_allow_recollection_and_seed_preserves_all_existing_personas(client):
    for role in ("writer", "checker"):
        for phrase in ("回忆", "日常重复", "渐进", "倒叙", "插叙"):
            assert phrase in PROGRAM_PROTOCOLS[role]
    with db_module.SessionLocal() as db:
        for row in db.scalars(select(AgentPersona)):
            row.system_prompt = "  作者原有文本\nBibleFocus追加文本  "
        book = Book(title="人格"); db.add(book); db.flush()
        db.add(BookAgentPersona(book_id=book.id, agent_role="writer", editable_persona="单书人格\n追加指导")); db.commit()
        before = [(row.agent_role, row.system_prompt) for row in db.scalars(select(AgentPersona))]
        seed_defaults(db)
        assert [(row.agent_role, row.system_prompt) for row in db.scalars(select(AgentPersona))] == before
        assert db.scalar(select(BookAgentPersona)).editable_persona == "单书人格\n追加指导"


def test_empty_bible_still_checks_history_and_rejects_invented_order(client):
    with db_module.SessionLocal() as db:
        _, _, _, current = _story(db)
        current.user_prompt = "  "
        snapshot = freeze_manual_checker_input(db, current, current.draft_text)
        source = next(row for row in snapshot["source_catalog"] if row["kind"] == "history")
        issue = {"kind": "continuity_repeated_progress", "reason": "同一结果再次首次化", "source_kind": "history",
                 "source_id": source["id"], "source_evidence": source["text"], "draft_evidence": current.draft_text, "bible_evidence": ""}
        raw = {"verdict": "violation", "issues": [issue], "name_uses": []}
        assert validate_checker_result(raw, snapshot)["verdict"] == "violation"
        issue.update(kind="required_order_conflict", source_kind="bible", source_id="bible", source_evidence="先核对", bible_evidence="先核对")
        with pytest.raises(CheckerValidationError): validate_checker_result(raw, snapshot)


@pytest.mark.parametrize("has_distant,mutate_previous", [(False, False), (True, False), (True, True)])
def test_writer_checker_share_frozen_reference_and_changed_previous_cannot_promote(client, auth_headers, wait_for_terminal, has_distant, mutate_previous):
    from app.llm.factory import get_memory_selector_client, get_writer_client, get_checker_client
    messages = {}
    with db_module.SessionLocal() as db:
        _, _, previous, current = _story(db, old=True)
        if not has_distant:
            # Make the first accepted chapter the exact previous source.
            current.index = 4; db.flush()
            previous.index = 3; db.flush()
            current.index = 4
            earlier = db.scalar(select(Chapter).where(Chapter.book_id == current.book_id, Chapter.index == 1))
            db.delete(earlier); db.flush()
        current.draft_text = "原有中性稿。"; current.status = "draft_ready"
        db.commit(); cid, pid = current.id, previous.id
    class Selector:
        def complete_json(self, **kwargs):
            messages["selector"] = kwargs
            return {"selected_source_ids": ["M1"], "conflict_source_ids": []}
    def selector_resolver():
        if not has_distant: raise AssertionError("zero distant candidates must skip Selector")
        return Selector()
    class Writer:
        last_finish_reason = "stop"
        def complete_stream(self, **kwargs):
            messages["writer"] = kwargs
            if mutate_previous:
                with db_module.SessionLocal() as db:
                    previous = db.get(Chapter, pid)
                    previous.draft_text += "已修改。"; db.commit()
            yield "中性稿。" * 1000
    class Checker:
        def complete_json(self, **kwargs):
            messages["checker"] = kwargs
            return {"verdict": "passed", "issues": [], "name_uses": []}
    client.app.dependency_overrides[get_memory_selector_client] = selector_resolver
    client.app.dependency_overrides[get_writer_client] = Writer
    client.app.dependency_overrides[get_checker_client] = Checker
    response = client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers, json={"replace_draft": True})
    response.raise_for_status()
    terminal = wait_for_terminal(client, cid, auth_headers)
    with db_module.SessionLocal() as db:
        run = db.get(JobRun, terminal["job_id"])
        reference = run.input_snapshot["reference_context"]
        assert reference in messages["writer"]["user"] and reference in messages["checker"]["user"]
        assert "只输出完整小说正文，不输出分析或提纲" in messages["writer"]["user"]
        assert "continuity_known_reset" in messages["checker"]["system"]
        if mutate_previous:
            assert terminal["phase"] != "done"
            assert db.get(Chapter, cid).draft_text == "原有中性稿。"
        else:
            assert terminal["phase"] == "done"
            assert terminal["memory_context"]["previous_chapter_context"]["chapter_id"] == pid
            assert "中性稿。" * 1000 not in json.dumps(terminal["memory_context"], ensure_ascii=False)


@pytest.mark.parametrize("protocol", ["production-input-v1", "production-input-v2"])
def test_old_hidden_candidate_retries_checker_with_own_frozen_contract(client, auth_headers, wait_for_terminal, protocol):
    from app.llm.factory import get_memory_selector_client, get_writer_client, get_checker_client
    from conftest import FakeWriter
    with db_module.SessionLocal() as db:
        _, _, _, current = _story(db, old=True); cid = current.id
    class InvalidChecker:
        def complete_json(self, **kwargs): return {"invalid": True}
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("中性稿。" * 1000)
    client.app.dependency_overrides[get_checker_client] = InvalidChecker
    client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers, json={"replace_draft": True}).raise_for_status()
    terminal = wait_for_terminal(client, cid, auth_headers)
    assert terminal["can_retry_checker"]
    with db_module.SessionLocal() as db:
        current = db.get(Chapter, cid); run = db.get(JobRun, terminal["job_id"])
        candidate = db.get(ChapterDraftCandidate, run.candidate_id)
        snapshot = freeze_selected_write_input(db, current, candidate.draft_text,
            memory_manifest={"memory_brief": [], "conflicts": [], "previous_ending_start_id": None}, protocol_version=protocol)
        run.input_snapshot = snapshot; run.input_fingerprint = snapshot["input_fingerprint"]
        candidate.checker_input_snapshot = snapshot; candidate.checker_input_fingerprint = snapshot["input_fingerprint"]
        db.commit()
    captured = []
    class PassingChecker:
        def complete_json(self, **kwargs):
            captured.append(kwargs["user"])
            return {"verdict": "passed", "issues": [], "name_uses": []}
    def forbidden(): raise AssertionError("old Checker retry must not call Writer or Selector")
    client.app.dependency_overrides[get_writer_client] = forbidden
    client.app.dependency_overrides[get_memory_selector_client] = forbidden
    client.app.dependency_overrides[get_checker_client] = PassingChecker
    client.post(f"/api/v1/chapters/{cid}/checker/retry", headers=auth_headers,
                json={"source_job_id": terminal["checker_source_job_id"]}).raise_for_status()
    result = wait_for_terminal(client, cid, auth_headers)
    assert result["phase"] == "done"
    with db_module.SessionLocal() as db:
        retry = db.get(JobRun, result["job_id"])
        assert retry.input_snapshot["protocol_version"] == protocol
        assert retry.input_snapshot["reference_context"] == snapshot["reference_context"]
        assert snapshot["reference_context"] in captured[0]


def test_v4_package_roundtrip_and_invalid_reference_is_atomic(client):
    with db_module.SessionLocal() as db:
        book, _, _, _ = _story(db)
        package = export_project_package(db, book)
        with zipfile.ZipFile(io.BytesIO(package)) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        assert json.loads(entries["manifest.json"])["format_version"] == 4
        archives = json.loads(entries["archives.json"])
        assert archives[0]["continuity"]["completed_fact_refs"] == [1]
        imported, _ = import_project_package(db, package)
        imported_previous = db.scalar(select(Chapter).where(Chapter.book_id == imported.id, Chapter.index == 2))
        read = archive_read_model(db, imported_previous)
        assert read["continuity"]["completed_fact_refs"] == [read["facts"][0]["id"]]
        before = len(list(db.scalars(select(Book))))
        archives[0]["continuity"]["completed_fact_refs"] = [1, 1]
        def repack_archives():
            entries["archives.json"] = json.dumps(archives).encode()
            manifest = json.loads(entries["manifest.json"])
            manifest["entries"]["archives.json"]["sha256"] = hashlib.sha256(entries["archives.json"]).hexdigest()
            manifest["entries"]["archives.json"]["size"] = len(entries["archives.json"])
            entries["manifest.json"] = json.dumps(manifest).encode()
            buf = io.BytesIO()
            with zipfile.ZipFile(buf, "w") as archive:
                for name, payload in entries.items(): archive.writestr(name, payload)
            return buf.getvalue()
        deduped, _ = import_project_package(db, repack_archives())
        imported_first = db.scalar(select(Chapter).where(Chapter.book_id == deduped.id, Chapter.index == 1))
        assert db.get(ChapterArchiveRevision, imported_first.active_archive_revision_id).continuity["completed_fact_refs"] == ["F1"]
        before += 1
        archives[0]["continuity"]["completed_fact_refs"] = [99]
        with pytest.raises(ProjectPackageError): import_project_package(db, repack_archives())
        assert len(list(db.scalars(select(Book)))) == before


def test_0016_isolated_upgrade_downgrade_gate_and_backup_restore(tmp_path, monkeypatch):
    path = tmp_path / "synthetic.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite:///{path}"); get_settings.cache_clear()
    config = Config("alembic.ini")
    command.upgrade(config, "20260929_0015")
    with sqlite3.connect(path) as db:
        db.execute("INSERT INTO books(id,title,world_setting,created_at,updated_at,content_revision) VALUES('book','中性','',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,1)")
        db.execute("INSERT INTO chapters(id,book_id,\"index\",title,user_prompt,target_word_count,author_note,draft_text,headline,long_summary,status,archive_status,legacy_archive_eligible,write_generation,source,created_at,updated_at,content_revision,state_changes,unresolved_items,atomic_memories,exempted_character_names) VALUES('c','book',1,'','','3000','','中性。','','','finalized','complete',0,0,'user',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,1,'[]','[]','[]','[]')")
        db.execute("INSERT INTO chapter_archive_revisions(id,chapter_id,revision,schema_version,provenance,input_fingerprint,status,is_active,summary,contract_version,validation_errors,diagnostics,state_uncertainties,created_at,updated_at) VALUES('old-r','c',1,2,'live','x','complete',0,'旧中性归档','archive-v2.1','[]','[]','[]',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
    command.upgrade(config, "head")
    with sqlite3.connect(path) as db:
        assert db.execute("SELECT title FROM books").fetchone()[0] == "中性"
        assert db.execute("SELECT summary,continuity FROM chapter_archive_revisions WHERE id='old-r'").fetchone() == ("旧中性归档", None)
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert not db.execute("PRAGMA foreign_key_check").fetchall()
    command.downgrade(config, "20260929_0015"); command.upgrade(config, "head")
    with sqlite3.connect(path) as db:
        db.execute("INSERT INTO chapter_archive_revisions(id,chapter_id,revision,schema_version,provenance,input_fingerprint,status,is_active,summary,contract_version,validation_errors,diagnostics,state_uncertainties,created_at,updated_at,continuity) VALUES('r','c',2,2,'live','x','complete',1,'中性','archive-v2.2','[]','[]','[]',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,?)", (json.dumps({key: [] for key in CONTINUITY_KEYS}),))
    backup = tmp_path / "verified-backup.db"; shutil.copy2(path, backup)
    before = path.read_bytes()
    with pytest.raises(RuntimeError, match="archive-v2.2 data exists"): command.downgrade(config, "20260929_0015")
    assert path.read_bytes() == before
    restored = tmp_path / "restore.db"; shutil.copy2(backup, restored)
    with sqlite3.connect(restored) as db:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert not db.execute("PRAGMA foreign_key_check").fetchall()
        assert db.execute("SELECT version_num FROM alembic_version").fetchone()[0] == "20261002_0016"
        assert db.execute("SELECT summary,continuity FROM chapter_archive_revisions WHERE id='old-r'").fetchone() == ("旧中性归档", None)
        assert json.loads(db.execute("SELECT continuity FROM chapter_archive_revisions WHERE id='r'").fetchone()[0]) == {key: [] for key in CONTINUITY_KEYS}
