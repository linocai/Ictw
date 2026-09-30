"""Build 72: failures retain a truthful, safe reason through the real SOP."""

from __future__ import annotations

import copy
import json

import pytest
from fastapi.testclient import TestClient

import app.db as db_module
from app.llm.factory import get_checker_client, get_writer_client
from app.models import Chapter, ChapterArchiveRevision, JobRun
from app.routers.chapters import _public_error_context, _redacted_checker_result
from app.services.archive_v2 import ARCHIVE_CONTRACT_VERSION, archive_input_fingerprint
from app.services.checker_validation import (
    CHECKER_REASON_MESSAGES,
    CheckerValidationError,
    checker_failure_message,
    validate_checker_result,
)
from app.services.write_jobs import _apply_job_phase, write_registry


def _snapshot() -> dict:
    return {
        "bible": "必须归还钥匙。",
        "source_catalog": [
            {"kind": "draft", "id": "draft", "text": "她按约归还了钥匙。"},
            {"kind": "world", "id": "world", "text": "钥匙只能交给本人。"},
            {"kind": "bible", "id": "bible", "text": "必须归还钥匙。"},
        ],
        "name_hits": [], "name_groups": [],
    }


def _issue() -> dict:
    return {
        "kind": "world_conflict", "reason": "TEST_SECRET_BEARER_APIKEY 原因",
        "draft_evidence": "归还了钥匙", "bible_evidence": "",
        "source_kind": "world", "source_id": "world",
        "source_evidence": "钥匙只能交给本人",
    }


@pytest.mark.parametrize(("field", "value", "reason"), [
    ("draft_evidence", "凭空拼接 TEST_SECRET_BEARER_APIKEY", "draft_evidence_not_found"),
    ("source_evidence", "虚构来源 TEST_SECRET_BEARER_APIKEY", "source_evidence_not_found"),
    ("source_id", "missing", "source_not_found"),
    ("bible_evidence", "伪造 Bible", "non_bible_evidence"),
    ("draft_evidence", "", "draft_evidence_missing"),
])
def test_checker_reasons_are_specific_and_never_echo_model_text(field, value, reason) -> None:
    issue = _issue()
    issue[field] = value
    with pytest.raises(CheckerValidationError) as raised:
        validate_checker_result({"verdict": "violation", "issues": [issue], "name_uses": []}, _snapshot())
    exc = raised.value
    assert exc.reason_code == reason
    assert exc.diagnostics["issue_index"] == 0
    assert reason in CHECKER_REASON_MESSAGES
    assert "TEST_SECRET_BEARER_APIKEY" not in checker_failure_message(exc)
    assert "TEST_SECRET_BEARER_APIKEY" not in json.dumps(exc.diagnostics)


def test_checker_structure_bible_and_snapshot_errors_remain_distinct() -> None:
    snapshot = _snapshot()
    cases = [
        ({"verdict": "passed", "issues": []}, snapshot, "invalid_top_level"),
        ({"verdict": "passed", "issues": [_issue()], "name_uses": []}, snapshot, "invalid_verdict_issues"),
        ({"verdict": "violation", "issues": [{**_issue(), "source_kind": "bible", "source_id": "bible", "source_evidence": "必须归还钥匙", "bible_evidence": "错误的 Bible 引文"}], "name_uses": []}, snapshot, "bible_evidence_not_found"),
        ({"verdict": "passed", "issues": [], "name_uses": []}, {**snapshot, "source_catalog": None}, "invalid_source_catalog"),
    ]
    for raw, frozen, expected in cases:
        with pytest.raises(CheckerValidationError) as raised:
            validate_checker_result(raw, frozen)
        assert raised.value.reason_code == expected
    bad = copy.deepcopy(snapshot)
    bad["name_groups"] = "invalid"
    with pytest.raises(CheckerValidationError) as raised:
        validate_checker_result({"verdict": "passed", "issues": [], "name_uses": []}, bad)
    assert raised.value.reason_code == "invalid_name_catalog"


def test_checker_public_projection_whitelists_context_without_evidence() -> None:
    private = {
        "status": "unavailable", "error_code": "checker_invalid_response",
        "error_message": CHECKER_REASON_MESSAGES["draft_evidence_not_found"],
        "error_context": {
            "reason_code": "draft_evidence_not_found", "failure_stage": "checking",
            "manuscript_state": "generated_candidate_retained", "agent_role": "checker",
            "raw_reply": "TEST_SECRET_BEARER_APIKEY", "unexpected": {"draft_text": "秘密正文"},
        },
        "_validation_diagnostics": {"reason_code": "draft_evidence_not_found", "issue_index": 0},
    }
    public = _redacted_checker_result(private)
    assert public["error_context"]["reason_code"] == "draft_evidence_not_found"
    assert public["error_context"]["manuscript_state"] == "generated_candidate_retained"
    assert "_validation_diagnostics" not in public
    assert "TEST_SECRET_BEARER_APIKEY" not in json.dumps(public)
    assert _public_error_context({"reason_code": "untrusted-code", "failure_stage": "fake", "manuscript_state": "fake"}) == {}


class _Writer:
    def __init__(self) -> None:
        self.calls = 0
        self.last_finish_reason = "stop"

    def complete_stream(self, **_kwargs):
        self.calls += 1
        yield from ("文" * 4000)


class _Checker:
    def __init__(self) -> None:
        self.prompts: list[str] = []

    def complete_json(self, **kwargs):
        self.prompts.append(kwargs["user"])
        if len(self.prompts) == 1:
            return {"verdict": "violation", "issues": [{
                "kind": "world_conflict", "reason": "TEST_SECRET_BEARER_APIKEY",
                "draft_evidence": "不存在的正文 TEST_SECRET_BEARER_APIKEY",
                "bible_evidence": "行动", "source_kind": "bible",
                "source_id": "bible", "source_evidence": "行动",
            }], "name_uses": []}
        return {"verdict": "passed", "issues": [], "name_uses": []}


def test_failed_generated_checker_has_safe_reason_and_manual_retry_only_calls_checker(
    client, auth_headers, wait_for_terminal, caplog,
) -> None:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "合成书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"user_prompt": "行动"},
    ).json()
    writer, checker = _Writer(), _Checker()
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    started = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    started.raise_for_status()
    failed = wait_for_terminal(client, chapter["id"], auth_headers)
    assert failed["phase"] == "failed" and failed["error_code"] == "checker_invalid_response"
    assert failed["error_context"]["reason_code"] == "draft_evidence_not_found"
    assert failed["error_context"]["failure_stage"] == "checking"
    assert failed["error_context"]["manuscript_state"] == "generated_candidate_retained"
    assert failed["can_retry_checker"] is True
    assert failed["checker_result"]["error_context"]["reason_code"] == "draft_evidence_not_found"
    assert "TEST_SECRET_BEARER_APIKEY" not in json.dumps(failed, ensure_ascii=False)
    assert "TEST_SECRET_BEARER_APIKEY" not in caplog.text
    with db_module.SessionLocal() as db:
        run = db.get(JobRun, failed["job_id"])
        assert run.checker_result["_validation_diagnostics"]["reason_code"] == "draft_evidence_not_found"
        assert run.checker_result["_validation_diagnostics"]["issue_index"] == 0
    before = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["draft_text"]
    retried = client.post(
        f"/api/v1/chapters/{chapter['id']}/checker/retry", headers=auth_headers,
        json={"source_job_id": failed["checker_source_job_id"]},
    )
    retried.raise_for_status()
    done = wait_for_terminal(client, chapter["id"], auth_headers)
    assert done["phase"] == "done"
    assert writer.calls == 1 and len(checker.prompts) == 2
    assert "逐条核对 draft_evidence" in checker.prompts[1]
    assert "逐一覆盖程序给出的 group_id" not in checker.prompts[1]
    assert before == "" and done["chapter"]["draft_text"] == "文" * 4000


def test_sop_http_failure_provides_real_request_id_and_conservative_state(client, auth_headers) -> None:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "合成书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={}).json()
    response = client.post(f"/api/v1/chapters/{chapter['id']}/check/start", headers=auth_headers)
    assert response.status_code == 409
    context = response.json()["detail"]["error_context"]
    assert context["request_id"] == response.headers["X-Request-ID"]
    assert len(context["request_id"]) == 36
    assert context["failure_stage"] == "checking"
    assert context["manuscript_state"] == "unknown"


def test_visible_recheck_uses_only_same_input_failure_hint(client, auth_headers) -> None:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "合成书"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"user_prompt": "行动"},
    ).json()
    client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers,
        json={"draft_text": "她按约完成了行动。"},
    ).raise_for_status()
    checker = _Checker()
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    first = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    first.raise_for_status()
    assert first.json()["checker_result"]["error_context"]["reason_code"] == "draft_evidence_not_found"
    assert first.json()["checker_result"]["error_context"]["manuscript_state"] == "unchanged"
    second = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    second.raise_for_status()
    assert second.json()["checker_result"]["verdict"] == "passed"
    assert "逐条核对 draft_evidence" in checker.prompts[1]
    client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers,
        json={"draft_text": "她决定明天再行动。"},
    ).raise_for_status()
    third = client.post(f"/api/v1/chapters/{chapter['id']}/check", headers=auth_headers)
    third.raise_for_status()
    assert "上次正文引文未通过校验" not in checker.prompts[2]


def test_unexpected_start_failure_returns_safe_request_reference(
    client, auth_headers, monkeypatch,
) -> None:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "合成书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={}).json()
    client.app.dependency_overrides[get_writer_client] = lambda: _Writer()

    def fail_launch(_job, _factory):
        raise RuntimeError("TEST_SECRET_BEARER_APIKEY 原始异常")

    monkeypatch.setattr(write_registry, "launch", fail_launch)
    with TestClient(client.app, raise_server_exceptions=False) as safe_client:
        response = safe_client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    assert response.status_code == 500
    detail = response.json()["detail"]
    assert detail["code"] == "request_failed"
    assert detail["error_context"]["request_id"] == response.headers["X-Request-ID"]
    assert detail["error_context"]["failure_stage"] == "preflight"
    assert detail["error_context"]["manuscript_state"] == "unknown"
    assert "TEST_SECRET_BEARER_APIKEY" not in response.text


def test_archive_latest_attempt_has_real_job_reference_and_accepted_state(client, auth_headers) -> None:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "合成书"}).json()
    created = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={}).json()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, created["id"])
        chapter.draft_text = "这是一份已接受的合成稿。"
        chapter.status = "finalized"
        chapter.archive_status = "failed"
        revision = ChapterArchiveRevision(
            chapter_id=chapter.id, revision=1, provenance="live",
            input_fingerprint=archive_input_fingerprint(chapter),
            contract_version=ARCHIVE_CONTRACT_VERSION,
            status="failed", error_code="llm_timeout", error_message="归档模型请求超时",
        )
        db.add(revision)
        db.flush()
        run = JobRun(
            chapter_id=chapter.id, kind="extract", phase="failed",
            archive_revision_id=revision.id, error_code="llm_timeout",
            error_context={"failure_stage": "extracting", "manuscript_state": "accepted", "raw_reply": "TEST_SECRET_BEARER_APIKEY"},
        )
        db.add(run)
        db.commit()
        job_id = run.id
    response = client.get(f"/api/v1/chapters/{created['id']}", headers=auth_headers)
    response.raise_for_status()
    latest = response.json()["archive"]["latest_attempt"]
    assert latest["job_id"] == job_id
    assert latest["error_context"] == {"failure_stage": "extracting", "manuscript_state": "accepted"}
    assert "TEST_SECRET_BEARER_APIKEY" not in response.text


def test_checker_persistence_failure_is_not_labeled_as_model_failure(client, auth_headers) -> None:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "合成书"}).json()
    created = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={}).json()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, created["id"])
        chapter.draft_text = "当前正文已保存。"
        chapter.status = "draft_ready"
        run = JobRun(chapter_id=chapter.id, kind="check", phase="checking")
        db.add(run)
        db.flush()
        assert _apply_job_phase(
            db, run.id, "failed", error_code="checker_retry_failed",
            error_message="检查结果保存失败",
            error_context={"agent_role": "checker", "failure_stage": "persisting"},
        )
        db.commit()
        run_id = run.id
    public = client.get(f"/api/v1/chapters/{created['id']}/job", headers=auth_headers).json()
    assert public["job_id"] == run_id
    assert public["error_context"]["failure_stage"] == "persisting"
    assert public["error_context"]["manuscript_state"] == "unchanged"
