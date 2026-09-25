"""Regression cases from the Sept 23 production stalls; no real prose/providers."""
import pytest
from sqlalchemy import select
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


def test_background_visible_checker_keeps_finalized_prose_and_archive(client, auth_headers, wait_for_terminal):
    from app.llm.factory import get_checker_client

    class PassingChecker:
        model_name = "synthetic-checker"

        def complete_json(self, **kwargs):
            return {"verdict": "passed", "issues": [], "name_uses": []}

    chapter_id, _, _ = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        chapter.status = "finalized"
        chapter.draft_text = "林夕在雨后回家。"
        original_text = chapter.draft_text
        original_revision = chapter.content_revision
        original_archive = chapter.archive_status
        db.commit()
    client.app.dependency_overrides[get_checker_client] = PassingChecker
    started = client.post(f"/api/v1/chapters/{chapter_id}/check/start", headers=auth_headers)
    assert started.status_code == 200
    assert started.json()["phase"] == "checking"
    assert started.json()["checker_target"] == "visible_draft"
    status = wait_for_terminal(client, chapter_id, auth_headers)
    assert status["kind"] == "check" and status["phase"] == "done"
    assert status["checker_target"] == "visible_draft"
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        assert chapter.status == "finalized"
        assert chapter.draft_text == original_text
        assert chapter.content_revision == original_revision
        assert chapter.archive_status == original_archive


def test_selector_input_change_stops_before_writer_and_keeps_old_draft(client, auth_headers, wait_for_terminal, monkeypatch):
    """A changed projected end state is Selector input, not a rebindable ID change."""
    from app.llm.factory import get_checker_client, get_memory_selector_client, get_writer_client
    from app.services import production_context as context

    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        selected_id = chapter.character_links[0].character_id
    state = {"changed": False}

    def projected(_db, _chapter):
        return ({selected_id: {"章前状态": "已改变" if state["changed"] else "原状态"}}, [])

    class MutatingSelector:
        model_name = "synthetic-selector"
        calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            state["changed"] = True
            return {"briefs": [], "conflicts": [], "previous_ending_start_id": None}

    class CountingWriter:
        model_name = "synthetic-writer"
        calls = 0

        def complete_stream(self, **_kwargs):
            self.calls += 1
            yield "不应调用"

    selector = MutatingSelector()
    writer = CountingWriter()
    monkeypatch.setattr(context, "_projection_before", projected)
    client.app.dependency_overrides[get_memory_selector_client] = lambda: selector
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    client.app.dependency_overrides[get_checker_client] = lambda: type("PassingChecker", (), {
        "complete_json": lambda self, **_kwargs: {"verdict": "passed", "issues": [], "name_uses": []},
    })()

    started = client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers)
    assert started.status_code == 200
    status = wait_for_terminal(client, chapter_id, auth_headers)
    assert status["phase"] == "failed" and status["error_code"] == "production_input_changed"
    assert selector.calls == 1 and writer.calls == 0


def test_selector_receives_readable_unselected_relationship_identity(client, auth_headers, wait_for_terminal, monkeypatch):
    from app.llm.factory import get_checker_client, get_memory_selector_client, get_writer_client
    from app.services import production_context as context
    from conftest import FakeWriter
    from app.models import Character

    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        selected_id = chapter.character_links[0].character_id
        other = db.scalars(
            select(Character).where(Character.book_id == chapter.book_id, Character.id != selected_id)
        ).first()
        assert other is not None
        other_id = other.id

    monkeypatch.setattr(
        context,
        "_projection_before",
        lambda _db, _chapter: ({selected_id: {f"relationship:{other_id}": "旧友"}}, []),
    )

    class CapturingSelector:
        model_name = "synthetic-selector"
        user = ""

        def complete_json(self, *, user, **_kwargs):
            self.user = user
            return {"briefs": [], "conflicts": [], "previous_ending_start_id": None}

    selector = CapturingSelector()
    client.app.dependency_overrides[get_memory_selector_client] = lambda: selector
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: type("PassingChecker", (), {
        "complete_json": lambda self, **_kwargs: {"verdict": "passed", "issues": [], "name_uses": []},
    })()

    assert client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).status_code == 200
    assert wait_for_terminal(client, chapter_id, auth_headers)["phase"] == "done"
    assert "与夏天的关系：旧友" in selector.user
    assert other_id not in selector.user


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
    assert "尚未得到可用结论" in status["error_message"]
    assert status["error_context"]["model_name"] == "synthetic-checker"
    assert status["can_retry_checker"]
    assert "never-log-this-secret" not in str(status) + caplog.text
    with db_module.SessionLocal() as db:
        audits = db.scalars(select(LLMCallAudit).where(LLMCallAudit.agent_role == "checker")).all()
        assert len(audits) == 1 and audits[0].error_code == "checker_invalid_response"


def test_hidden_checker_unavailability_never_uses_rejection_copy_on_first_or_retry(client, auth_headers, wait_for_terminal):
    from conftest import FakeWriter
    from app.llm.factory import get_checker_client, get_writer_client

    class TimeoutChecker:
        model_name = "synthetic-checker"

        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            raise LLMError("provider timeout", code="llm_timeout")

    chapter_id, _prior_id, _future_id = _story()
    checker = TimeoutChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    assert client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).status_code == 200
    first = wait_for_terminal(client, chapter_id, auth_headers)
    assert first["error_code"] == "llm_timeout"
    assert "检查未能完成，生成稿已保留，当前正文未变" in first["error_message"]
    assert "Checker 未通过" not in first["error_message"]

    retried = client.post(
        f"/api/v1/chapters/{chapter_id}/checker/retry", headers=auth_headers,
        json={"source_job_id": first["checker_source_job_id"]},
    )
    assert retried.status_code == 200
    second = wait_for_terminal(client, chapter_id, auth_headers)
    assert second["error_code"] == "llm_timeout"
    assert "检查未能完成，生成稿已保留，当前正文未变" in second["error_message"]
    assert "Checker 未通过" not in second["error_message"]
    assert checker.calls == 2


def test_hidden_checker_retry_execution_failure_stays_retryable_and_unavailable(
    client, auth_headers, wait_for_terminal, monkeypatch,
):
    """An unexpected retry persistence failure is not a story rejection."""
    from conftest import FakeWriter
    from app.llm.factory import get_checker_client, get_writer_client
    from app.services import write_jobs

    class FirstInvalidThenPassingChecker:
        model_name = "synthetic-checker"

        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            if self.calls == 1:
                return {"verdict": "passed", "issues": []}
            return {"verdict": "passed", "issues": [], "name_uses": []}

    chapter_id, _prior_id, _future_id = _story()
    checker = FirstInvalidThenPassingChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    failed = wait_for_terminal(client, chapter_id, auth_headers)
    assert failed["can_retry_checker"] is True

    original_begin = write_jobs._begin_final_checker_cas
    invoked = False

    def fail_once(db):
        nonlocal invoked
        if not invoked:
            invoked = True
            raise RuntimeError("synthetic retry persistence interruption")
        return original_begin(db)

    monkeypatch.setattr(write_jobs, "_begin_final_checker_cas", fail_once)
    client.post(
        f"/api/v1/chapters/{chapter_id}/checker/retry", headers=auth_headers,
        json={"source_job_id": failed["checker_source_job_id"]},
    ).raise_for_status()
    unavailable = wait_for_terminal(client, chapter_id, auth_headers)
    assert unavailable["error_code"] == "checker_retry_failed"
    assert unavailable["checker_result"]["status"] == "unavailable"
    assert unavailable["can_retry_checker"] is True
    assert "检查未能完成" in unavailable["error_message"]
    assert "Checker 未通过" not in unavailable["error_message"]

    monkeypatch.setattr(write_jobs, "_begin_final_checker_cas", original_begin)
    client.post(
        f"/api/v1/chapters/{chapter_id}/checker/retry", headers=auth_headers,
        json={"source_job_id": failed["checker_source_job_id"]},
    ).raise_for_status()
    recovered = wait_for_terminal(client, chapter_id, auth_headers)
    assert recovered["phase"] == "done"
    assert checker.calls == 3


def test_hidden_candidate_retry_cannot_replace_finalized_manuscript(client, auth_headers, wait_for_terminal):
    from conftest import FakeExtractor, FakeWriter
    from app.llm.factory import get_checker_client, get_extractor_client, get_writer_client

    class InvalidChecker:
        model_name = "synthetic-checker"

        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            # A malformed reply creates a retryable hidden candidate without
            # exposing it as a visible manuscript conclusion.
            return {"verdict": "passed", "issues": []}

    chapter_id, _prior_id, _future_id = _story()
    original = "原" * 4000
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        chapter.draft_text = original
        chapter.status = "draft_ready"
        original_revision = chapter.content_revision
        db.commit()

    checker = InvalidChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("新" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.app.dependency_overrides[get_extractor_client] = lambda: FakeExtractor()
    assert client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).status_code == 200
    failed = wait_for_terminal(client, chapter_id, auth_headers)
    assert failed["phase"] == "failed" and failed["can_retry_checker"]

    accepted = client.post(
        f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers,
        json={"override_checker": True},
    )
    assert accepted.status_code == 200
    assert wait_for_terminal(client, chapter_id, auth_headers)["phase"] == "done"
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None and chapter.status == "finalized"
        finalized_revision = chapter.content_revision
        finalized_archive = chapter.archive_status

    refused = client.post(
        f"/api/v1/chapters/{chapter_id}/checker/retry", headers=auth_headers,
        json={"source_job_id": failed["checker_source_job_id"]},
    )
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "checker_retry_not_available"
    assert checker.calls == 1
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        assert chapter.draft_text == original
        assert chapter.status == "finalized"
        assert chapter.content_revision == finalized_revision
        assert chapter.archive_status == finalized_archive
        assert chapter.content_revision > original_revision


def test_visible_checker_claim_invalidates_an_older_hidden_retry_lineage(client, auth_headers, wait_for_terminal):
    """A later visible reread owns the chapter over a retained hidden draft."""
    from conftest import FakeWriter
    from app.llm.factory import get_checker_client, get_writer_client

    class SequencedChecker:
        model_name = "synthetic-checker"

        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            if self.calls == 1:
                # A malformed hidden response leaves a retryable private
                # candidate while the author still sees the original prose.
                return {"verdict": "passed", "issues": []}
            return {"verdict": "passed", "issues": [], "name_uses": []}

    chapter_id, _prior_id, _future_id = _story()
    original = "原" * 4000
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        chapter.draft_text = original
        chapter.status = "draft_ready"
        db.commit()

    checker = SequencedChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("新" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    hidden_failure = wait_for_terminal(client, chapter_id, auth_headers)
    assert hidden_failure["can_retry_checker"] is True

    visible = client.post(f"/api/v1/chapters/{chapter_id}/check/start", headers=auth_headers)
    assert visible.status_code == 200
    visible_done = wait_for_terminal(client, chapter_id, auth_headers)
    assert visible_done["phase"] == "done"
    assert visible_done["checker_target"] == "visible_draft"

    refused = client.post(
        f"/api/v1/chapters/{chapter_id}/checker/retry", headers=auth_headers,
        json={"source_job_id": hidden_failure["checker_source_job_id"]},
    )
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "checker_retry_input_changed"
    assert checker.calls == 2
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        assert chapter.draft_text == original
        assert chapter.status == "draft_ready"


def test_new_writer_claim_invalidates_an_older_hidden_retry_lineage(client, auth_headers, wait_for_terminal):
    """A completed later Writer must also own the chapter over hidden A."""
    from conftest import FakeWriter
    from app.llm.factory import get_checker_client, get_writer_client

    class FirstInvalidThenPassingChecker:
        model_name = "synthetic-checker"

        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            if self.calls == 1:
                return {"verdict": "passed", "issues": []}
            return {"verdict": "passed", "issues": [], "name_uses": []}

    chapter_id, _prior_id, _future_id = _story()
    checker = FirstInvalidThenPassingChecker()
    writer_outputs = iter(["甲" * 4000, "乙" * 4000])
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter(next(writer_outputs))
    client.app.dependency_overrides[get_checker_client] = lambda: checker

    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    hidden_failure = wait_for_terminal(client, chapter_id, auth_headers)
    assert hidden_failure["can_retry_checker"] is True

    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    current = wait_for_terminal(client, chapter_id, auth_headers)
    assert current["phase"] == "done"
    assert current["chapter"]["draft_text"] == "乙" * 4000

    refused = client.post(
        f"/api/v1/chapters/{chapter_id}/checker/retry", headers=auth_headers,
        json={"source_job_id": hidden_failure["checker_source_job_id"]},
    )
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "checker_retry_input_changed"
    assert checker.calls == 2
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None and chapter.draft_text == "乙" * 4000


def test_new_writer_failure_still_invalidates_an_older_hidden_retry_lineage(client, auth_headers, wait_for_terminal):
    """Starting Writer B is enough to retire hidden A, even when B fails."""
    from conftest import FakeWriter
    from app.llm.base import LLMError
    from app.llm.factory import get_checker_client, get_writer_client

    class InvalidThenUnavailableChecker:
        model_name = "synthetic-checker"

        def __init__(self) -> None:
            self.calls = 0

        def complete_json(self, **_kwargs):
            self.calls += 1
            if self.calls == 1:
                return {"verdict": "passed", "issues": []}
            raise LLMError("synthetic timeout", code="llm_timeout")

    chapter_id, _prior_id, _future_id = _story()
    checker = InvalidThenUnavailableChecker()
    writer_outputs = iter(["甲" * 4000, "乙" * 4000])
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter(next(writer_outputs))
    client.app.dependency_overrides[get_checker_client] = lambda: checker

    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    hidden_a = wait_for_terminal(client, chapter_id, auth_headers)
    assert hidden_a["can_retry_checker"] is True
    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    failed_b = wait_for_terminal(client, chapter_id, auth_headers)
    assert failed_b["phase"] == "failed" and failed_b["error_code"] == "llm_timeout"

    refused = client.post(
        f"/api/v1/chapters/{chapter_id}/checker/retry", headers=auth_headers,
        json={"source_job_id": hidden_a["checker_source_job_id"]},
    )
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "checker_retry_input_changed"
    assert checker.calls == 2


def test_visible_checker_rebuilds_holder_when_bible_changes_and_survives_later_job(client, auth_headers, wait_for_terminal):
    from conftest import FakeExtractor
    from app.llm.factory import get_checker_client, get_extractor_client
    from app.models import ChapterDraftCandidate

    class PassingChecker:
        model_name = "synthetic-checker"

        def complete_json(self, **_kwargs):
            return {"verdict": "passed", "issues": [], "name_uses": []}

    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        chapter.draft_text = "文" * 4000
        chapter.status = "draft_ready"
        db.commit()
    client.app.dependency_overrides[get_checker_client] = PassingChecker
    client.app.dependency_overrides[get_extractor_client] = lambda: FakeExtractor()

    assert client.post(f"/api/v1/chapters/{chapter_id}/check/start", headers=auth_headers).status_code == 200
    assert wait_for_terminal(client, chapter_id, auth_headers)["phase"] == "done"
    with db_module.SessionLocal() as db:
        first = db.scalars(
            select(ChapterDraftCandidate).where(
                ChapterDraftCandidate.chapter_id == chapter_id,
                ChapterDraftCandidate.is_current.is_(True),
            )
        ).one()
        first_id = first.id

    client.patch(
        f"/api/v1/chapters/{chapter_id}", headers=auth_headers,
        json={"user_prompt": "更新后的本章意图"},
    ).raise_for_status()
    assert client.post(f"/api/v1/chapters/{chapter_id}/check/start", headers=auth_headers).status_code == 200
    checked = wait_for_terminal(client, chapter_id, auth_headers)
    assert checked["phase"] == "done"
    visible = client.get(f"/api/v1/chapters/{chapter_id}/job", headers=auth_headers).json()
    assert visible["visible_checker_result"]["verdict"] == "passed"
    with db_module.SessionLocal() as db:
        current = db.scalars(
            select(ChapterDraftCandidate).where(
                ChapterDraftCandidate.chapter_id == chapter_id,
                ChapterDraftCandidate.is_current.is_(True),
            )
        ).one()
        assert current.id != first_id

    assert client.post(f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers).status_code == 200
    archived = wait_for_terminal(client, chapter_id, auth_headers)
    assert archived["kind"] == "extract" and archived["visible_checker_result"]["verdict"] == "passed"


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
                {"group_id": "g1", "classification": "character", "reason": "人名"},
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


def test_sync_visible_checker_rebuilds_holder_when_bible_changes(client, auth_headers):
    """Build62's synchronous check must use the same fresh holder rule as /check/start."""
    from app.llm.factory import get_checker_client
    from app.models import ChapterDraftCandidate

    class PassingChecker:
        model_name = "synthetic-checker"

        def complete_json(self, **_kwargs):
            return {"verdict": "passed", "issues": [], "name_uses": []}

    chapter_id, _prior_id, _future_id = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        chapter.draft_text = "文" * 4000
        chapter.status = "draft_ready"
        db.commit()
    client.app.dependency_overrides[get_checker_client] = PassingChecker

    client.post(f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers).raise_for_status()
    with db_module.SessionLocal() as db:
        first = db.scalars(
            select(ChapterDraftCandidate).where(
                ChapterDraftCandidate.chapter_id == chapter_id,
                ChapterDraftCandidate.is_current.is_(True),
            )
        ).one()
        first_id = first.id

    client.patch(
        f"/api/v1/chapters/{chapter_id}", headers=auth_headers,
        json={"user_prompt": "同步入口也必须重新检查的新意图"},
    ).raise_for_status()
    second = client.post(f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers)
    assert second.status_code == 200 and second.json()["checker_result"]["verdict"] == "passed"
    with db_module.SessionLocal() as db:
        current = db.scalars(
            select(ChapterDraftCandidate).where(
                ChapterDraftCandidate.chapter_id == chapter_id,
                ChapterDraftCandidate.is_current.is_(True),
            )
        ).one()
        assert current.id != first_id
        assert current.checker_result is not None


def test_selector_relationship_identity_disambiguates_duplicate_names(client, auth_headers, wait_for_terminal, monkeypatch):
    """Selector sees an author-readable relation label without authorizing that card."""
    from app.llm.factory import get_checker_client, get_memory_selector_client, get_writer_client
    from app.models import Character
    from app.services import production_context as context
    from conftest import FakeWriter

    chapter_id, _prior_id, _future_id = _story(duplicate_name=True)
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        selected_id = chapter.character_links[0].character_id
        other = db.scalars(
            select(Character).where(
                Character.book_id == chapter.book_id,
                Character.name == "夏天",
            ).order_by(Character.id)
        ).first()
        assert other is not None
        other_id = other.id

    monkeypatch.setattr(
        context,
        "_projection_before",
        lambda _db, _chapter: ({selected_id: {f"relationship:{other_id}": "旧友"}}, []),
    )

    class CapturingSelector:
        model_name = "synthetic-selector"
        user = ""

        def complete_json(self, *, user, **_kwargs):
            self.user = user
            return {"briefs": [], "conflicts": [], "previous_ending_start_id": None}

    selector = CapturingSelector()
    client.app.dependency_overrides[get_memory_selector_client] = lambda: selector
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: type("PassingChecker", (), {
        "complete_json": lambda self, **_kwargs: {"verdict": "passed", "issues": [], "name_uses": []},
    })()

    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter_id, auth_headers)["phase"] == "done"
    assert f"与夏天（ID:{other_id[:8]}）的关系：旧友" in selector.user
    assert other_id not in selector.user


def test_selector_relationship_identity_marks_deleted_card_without_uuid_prompt(client, auth_headers, wait_for_terminal, monkeypatch):
    from app.llm.factory import get_checker_client, get_memory_selector_client, get_writer_client
    from app.services import production_context as context
    from conftest import FakeWriter

    chapter_id, _prior_id, _future_id = _story()
    missing_id = "removed-character-identity"
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter is not None
        selected_id = chapter.character_links[0].character_id

    monkeypatch.setattr(
        context,
        "_projection_before",
        lambda _db, _chapter: ({selected_id: {f"relationship:{missing_id}": "旧友"}}, []),
    )

    class CapturingSelector:
        model_name = "synthetic-selector"
        user = ""

        def complete_json(self, *, user, **_kwargs):
            self.user = user
            return {"briefs": [], "conflicts": [], "previous_ending_start_id": None}

    selector = CapturingSelector()
    client.app.dependency_overrides[get_memory_selector_client] = lambda: selector
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("文" * 4000)
    client.app.dependency_overrides[get_checker_client] = lambda: type("PassingChecker", (), {
        "complete_json": lambda self, **_kwargs: {"verdict": "passed", "issues": [], "name_uses": []},
    })()

    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter_id, auth_headers)["phase"] == "done"
    assert "与关系对象已不可用（ID:removed-）的关系：旧友" in selector.user
    assert missing_id not in selector.user
