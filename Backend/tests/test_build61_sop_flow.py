"""Regression cases from the Sept 23 production stalls; no real prose/providers."""
import pytest
from app.agents.memory_selector import MemorySelectorAgent
from app.llm.base import LLMError
from app.services.context import MemoryBlock, memory_selection_problem, pack_selector_context
from app.services.checker_validation import validate_checker_result
from test_v2_2_checker_context import _story, _ordinary_raw
from app.services.production_context import freeze_manual_checker_input
from app.models import Chapter
import app.db as db_module


class SelectionLLM:
    def __init__(self, response):
        self.response = response
        self.calls = 0

    def complete_json(self, **kwargs):
        self.calls += 1
        return self.response


def choose(blocks, response):
    llm = SelectionLLM(response)
    selection = MemorySelectorAgent(llm, "").select(
        "synthetic", candidates=blocks,
        validator=lambda s: memory_selection_problem(blocks, s.briefs, s.conflicts, s.previous_ending_start_id),
    )
    return selection, llm


def test_short_source_ids_and_bad_ending_keep_exact_history_without_retry():
    blocks = [MemoryBlock("fact:123:summary", "归还钥匙。", 1),
              MemoryBlock("previous_ending:123:p1", "他走到门口。", 1, memory_type="previous_ending")]
    selected, llm = choose(blocks, {"briefs": [{"text": "钥匙已归还。", "source_ids": ["M1", "M1"]}],
                                   "conflicts": [], "previous_ending_start_id": "nonexistent"})
    assert llm.calls == 1
    assert selected.briefs[0]["source_ids"] == [blocks[0].id]
    assert selected.previous_ending_start_id == blocks[1].id
    assert set(selected.diagnostics) == {"previous_ending_defaulted", "duplicate_source_ids_removed"}
    packed = pack_selector_context(blocks, selected.briefs, [], selected.previous_ending_start_id)
    assert packed.previous_ending == "他走到门口。"


def test_eighteen_real_sources_within_actual_budget_do_not_abort_writing():
    blocks = [MemoryBlock(f"fact:{i}", f"既有事实{i}", 1) for i in range(18)]
    briefs = [{"text": f"有关事实{i}", "source_ids": [f"M{j+1}" for j in range(i, i+6)]} for i in range(0, 18, 6)]
    selected, llm = choose(blocks, {"briefs": briefs, "conflicts": [], "previous_ending_start_id": None})
    assert llm.calls == 1
    assert len({id for item in selected.briefs for id in item["source_ids"]}) == 18


def test_unknown_or_ambiguous_ids_still_fail_without_discarding_facts():
    for source in ["not-a-source", "summary", "12345678-1234-1234-1234-123456789012"]:
        blocks = [MemoryBlock("fact:12345678-1234-1234-1234-123456789012:summary", "事实甲", 1),
                  MemoryBlock("fact:12345678-1234-1234-1234-123456789012:headline", "事实乙", 1)]
        with pytest.raises(LLMError) as error:
            choose(blocks, {"briefs": [{"text": "未证实事实", "source_ids": [source]}], "conflicts": [], "previous_ending_start_id": None})
        assert error.value.code == "memory_selection_invalid"
        assert source not in str(error.value)


def test_budget_remains_a_real_bound():
    with pytest.raises(LLMError):
        choose([MemoryBlock("fact:1", "原始事实", 1)], {"briefs": [{"text": "字" * 2401, "source_ids": ["M1"]}],
                                                         "conflicts": [], "previous_ending_start_id": None})


@pytest.mark.parametrize("source", ["bible", "draft"])
@pytest.mark.parametrize("classification,verdict", [("character", "violation"), ("uncertain", "suspect")])
def test_identity_classification_gets_program_evidence_instead_of_invalid_response(client, source, classification, verdict):
    chapter_id, _, _ = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.user_prompt = "夏天到场。" if source == "bible" else "林夕回家。"
        text = "林夕回家。" if source == "bible" else "夏天到场。"
        snapshot = freeze_manual_checker_input(db, chapter, text)
        raw = _ordinary_raw(snapshot)
        raw["name_uses"][0]["classification"] = classification
        result = validate_checker_result(raw, snapshot)
        assert result["verdict"] == verdict
        assert len(result["identity_issues"]) == 1
        issue = result["issues"][0]
        assert issue["source_id"] == source and issue["source_evidence"] == "夏天"
        assert issue["draft_evidence"] == ("夏天" if source == "draft" else "")
        assert issue["bible_evidence"] == ("夏天" if source == "bible" else "")


def test_usable_legacy_memory_does_not_force_confirmation_but_empty_archive_does(client):
    from app.services.production_context import production_readiness
    chapter_id, prior_id, _ = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        prior = db.get(Chapter, prior_id)
        prior.legacy_archive_eligible = True
        db.commit()
        assert production_readiness(db, chapter)["is_complete"]
        prior.long_summary = ""
        prior.headline = ""
        db.commit()
        readiness = production_readiness(db, chapter)
        assert not readiness["is_complete"]
        assert readiness["context_limitations"][0]["kind"] == "missing_memory"


@pytest.mark.parametrize("selected_endpoint,effective,expected", [(False, True, False), (True, True, True), (True, False, False)])
def test_only_current_relevant_unknown_states_require_confirmation(client, monkeypatch, selected_endpoint, effective, expected):
    from types import SimpleNamespace
    from app.services import production_context as context, archive_v2
    chapter_id, prior_id, _ = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        selected_id = chapter.character_links[0].character_id
        unknown = {"character_id": "unselected", "other_character_id": selected_id if selected_endpoint else "also-unselected",
                   "scope": "relationship", "slot": "关系"}
        revision = SimpleNamespace(state_uncertainties=[unknown], summary="有效事实", id="test-revision")
        monkeypatch.setattr(archive_v2, "active_archive_revision", lambda db, ch: revision)
        monkeypatch.setattr(context, "memory_candidates", lambda db, ch: [])
        monkeypatch.setattr(context, "_projection_before", lambda db, ch: ({}, [unknown] if effective else []))
        readiness = context.production_readiness(db, chapter)
        assert bool(readiness["context_limitations"]) is expected


def test_readiness_copy_change_does_not_strand_a_frozen_check_candidate(client):
    from app.services import production_context as context
    chapter_id, _, _ = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
        snapshot["context_limitations"] = [{"kind": "legacy_memory", "reason": "旧版兼容提示"}]
        snapshot["input_fingerprint"] = context._input_fingerprint(snapshot)
        assert context.is_frozen_input_current(db, chapter, snapshot)
        chapter.book.world_setting = "世界观已实际修改。"
        assert not context.is_frozen_input_current(db, chapter, snapshot)


def test_generation_validation_failure_is_specific_audited_and_retryable(client, auth_headers, wait_for_terminal, caplog):
    from conftest import FakeWriter
    from sqlalchemy import select
    from app.llm.factory import get_writer_client, get_checker_client
    from app.models import LLMCallAudit
    chapter_id, _, _ = _story()

    class InvalidChecker:
        model_name = "synthetic-checker"
        def complete_json(self, **kwargs):
            return {"verdict": "passed", "issues": [], "private_raw": "never-log-this-secret"}

    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("林夕在雨后回家。" * 600)
    client.app.dependency_overrides[get_checker_client] = InvalidChecker
    readiness = client.get(f"/api/v1/chapters/{chapter_id}/production-readiness", headers=auth_headers).json()
    response = client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers,
                           json={"acknowledged_context_token": readiness["context_token"]})
    assert response.status_code == 200
    status = wait_for_terminal(client, chapter_id, auth_headers)
    assert status["error_code"] == "checker_invalid_response"
    assert "Checker 返回字段不符合协议" in status["error_message"]
    assert status["error_context"]["model_name"] == "synthetic-checker"
    assert status["can_retry_checker"]
    assert "never-log-this-secret" not in str(status) + caplog.text
    with db_module.SessionLocal() as db:
        audits = db.scalars(select(LLMCallAudit).where(LLMCallAudit.agent_role == "checker")).all()
        assert len(audits) == 1 and audits[0].error_code == "checker_invalid_response"


def test_hidden_identity_check_only_exposes_kind_reason_while_visible_keeps_repair_choices(client, auth_headers, wait_for_terminal):
    from conftest import FakeWriter
    from app.llm.factory import get_writer_client, get_checker_client
    chapter_id, _, _ = _story()
    with db_module.SessionLocal() as db:
        db.get(Chapter, chapter_id).user_prompt = "夏天到场。"
        db.commit()

    class IdentityChecker:
        def complete_json(self, **kwargs):
            return {"verdict": "passed", "issues": [], "name_uses": [
                {"hit_ids": ["n1"], "classification": "character", "reason": "人名"},
            ]}

    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("林夕在雨后回家。" * 600)
    client.app.dependency_overrides[get_checker_client] = IdentityChecker
    response = client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers)
    assert response.status_code == 200
    status = wait_for_terminal(client, chapter_id, auth_headers)
    assert status["error_code"] == "checker_rejected"
    assert status["checker_result"]["verdict"] == "violation"
    assert "identity_issues" not in status["checker_result"]
    assert "name_uses" not in status["checker_result"]
    assert all(set(issue) == {"kind", "reason"} for issue in status["checker_result"]["issues"])
    with db_module.SessionLocal() as db:
        db.get(Chapter, chapter_id).draft_text = "林夕在雨后回家。"
        db.commit()
    visible = client.post(f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers)
    assert visible.status_code == 200
    assert visible.json()["checker_result"]["identity_issues"][0]["name"] == "夏天"


@pytest.mark.parametrize("change", ["world", "generation"])
def test_job_retry_capability_matches_endpoint_after_input_changes(client, auth_headers, wait_for_terminal, change):
    from conftest import FakeWriter
    from app.llm.factory import get_writer_client, get_checker_client
    from app.models import JobRun, ChapterDraftCandidate
    from app.services.production_context import _input_fingerprint
    chapter_id, _, _ = _story()

    class BrokenChecker:
        def complete_json(self, **kwargs):
            return {"verdict": "passed", "issues": []}

    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("林夕在雨后回家。" * 600)
    client.app.dependency_overrides[get_checker_client] = BrokenChecker
    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    status = wait_for_terminal(client, chapter_id, auth_headers)
    assert status["can_retry_checker"]
    source_id = status["checker_source_job_id"]
    with db_module.SessionLocal() as db:
        run = db.get(JobRun, source_id)
        candidate = db.get(ChapterDraftCandidate, run.candidate_id)
        snapshot = dict(run.input_snapshot)
        snapshot["context_limitations"] = [{"kind": "legacy_memory", "reason": "升级前的兼容提示"}]
        snapshot["input_fingerprint"] = _input_fingerprint(snapshot)
        run.input_snapshot = snapshot
        run.input_fingerprint = snapshot["input_fingerprint"]
        candidate.checker_input_snapshot = snapshot
        candidate.checker_input_fingerprint = snapshot["input_fingerprint"]
        db.commit()
    # Only advisory wording changed: the retained candidate remains usable.
    assert client.get(f"/api/v1/chapters/{chapter_id}/job", headers=auth_headers).json()["can_retry_checker"]
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        if change == "world":
            chapter.book.world_setting = "世界观发生实际变化。"
        else:
            chapter.write_generation += 1
        db.commit()
    for _ in range(2):
        current = client.get(f"/api/v1/chapters/{chapter_id}/job", headers=auth_headers).json()
        assert not current["can_retry_checker"] and current["checker_source_job_id"] is None
    refused = client.post(f"/api/v1/chapters/{chapter_id}/checker/retry", headers=auth_headers,
                          json={"source_job_id": source_id})
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "checker_retry_input_changed"
