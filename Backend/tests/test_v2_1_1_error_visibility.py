from __future__ import annotations

import json

import pytest
from sqlalchemy import select

import app.db as db_module
from app.llm.base import LLMError
from app.llm.factory import get_checker_client
from app.main import recover_interrupted_chapters
from app.models import Book, Chapter, ChapterArchiveRevision, ChapterDraftCandidate, Character, JobRun, LLMCallAudit
from app.services.archive_v2 import ARCHIVE_CONTRACT_VERSION, archive_input_fingerprint


def story(text="雨落在屋檐。" * 1000):
    with db_module.SessionLocal() as db:
        book = Book(title="隔离错误回归")
        db.add(book)
        db.flush()
        chapter = Chapter(book_id=book.id, index=1, draft_text=text, status="draft_ready")
        db.add(chapter)
        db.commit()
        return chapter.id, book.id


class CheckerStub:
    model_name = "test-checker"
    last_finish_reason = "stop"
    last_usage = {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5}

    def __init__(self, result=None, error=None):
        self.result = result if result is not None else {"verdict": "passed", "issues": [], "name_uses": []}
        self.error = error
        self.calls = 0

    def complete_json(self, **kwargs):
        self.calls += 1
        if self.error:
            raise self.error
        return self.result


@pytest.mark.parametrize("code", [
    "llm_content_blocked", "llm_timeout", "llm_rate_limited", "llm_upstream_rejected",
    "llm_invalid_response", "llm_output_truncated",
])
def test_manual_checker_retains_safe_failure_and_audits_once(client, auth_headers, caplog, code):
    chapter_id, _ = story()
    secret = "private-prompt-body-api-key-must-not-escape"
    stub = CheckerStub(error=LLMError(
        secret, code=code, status_code=403, block_reason="PROHIBITED_CONTENT",
        finish_reason="content_filter", upstream_reason="content_policy_violation",
        agent_role="writer", model_name="incorrect-provider-stamp",
    ))
    client.app.dependency_overrides[get_checker_client] = lambda: stub
    response = client.post(f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers)
    assert response.status_code == 200 and stub.calls == 1
    result = response.json()["checker_result"]
    assert result["status"] == "unavailable" and result["error_code"] == code
    assert result["error_message"]
    assert result["error_context"] == {
        "agent_role": "checker", "model_name": "test-checker", "http_status": 403,
        "block_reason": "PROHIBITED_CONTENT", "finish_reason": "content_filter",
        "upstream_reason": "content_policy",
    }
    assert secret not in response.text + caplog.text
    assert response.json()["draft_text"] == ""
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        assert chapter.status == "draft_ready" and chapter.draft_text == "雨落在屋檐。" * 1000
        candidate = db.scalars(select(ChapterDraftCandidate)).one()
        assert candidate.draft_text == chapter.draft_text and candidate.checker_result == result
        audit = db.scalars(select(LLMCallAudit)).one()
        assert audit.chapter_id == chapter_id and audit.agent_role == "checker"
        assert audit.error_code == code and audit.model_name == "test-checker"
        assert audit.upstream_reason == "content_policy" and audit.total_tokens == 5
        assert secret not in json.dumps(audit.upstream_reason)
    # unavailable never authorizes acceptance; the author must decide explicitly.
    refused = client.post(f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers)
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "checker_override_required"


@pytest.mark.parametrize("result,error,expected", [
    ({"verdict": "made-up", "issues": []}, None, "checker_invalid_response"),
    ({"verdict": "passed", "issues": None}, None, "checker_invalid_response"),
    ({"verdict": "passed"}, None, "checker_invalid_response"),
    ({"verdict": "passed", "issues": "bad"}, None, "checker_invalid_response"),
    ({"verdict": "passed", "issues": {}}, None, "checker_invalid_response"),
    ({"verdict": "passed", "issues": 1}, None, "checker_invalid_response"),
    (None, RuntimeError("private unexpected payload"), "checker_invalid_response"),
    (None, LLMError("private response", code="private unknown error code",
                    upstream_reason="private provider body"), "llm_upstream_error"),
])
def test_manual_checker_invalid_or_unknown_error_is_safe(client, auth_headers, result, error, expected):
    chapter_id, _ = story()
    stub = CheckerStub(result, error)
    client.app.dependency_overrides[get_checker_client] = lambda: stub
    response = client.post(f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers)
    assert response.status_code == 200 and stub.calls == 1
    assert response.json()["checker_result"]["error_code"] == expected
    assert "private" not in response.text
    with db_module.SessionLocal() as db:
        assert db.scalars(select(LLMCallAudit)).one().error_code == expected
    refused = client.post(f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers)
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "checker_override_required"


def test_manual_checker_success_audits_one_call_without_failure_fields(client, auth_headers):
    chapter_id, _ = story()
    stub = CheckerStub()
    client.app.dependency_overrides[get_checker_client] = lambda: stub
    response = client.post(f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers)
    assert response.status_code == 200 and stub.calls == 1
    assert response.json()["checker_result"]["verdict"] == "passed"
    assert "error_context" not in response.json()["checker_result"]
    with db_module.SessionLocal() as db:
        audit = db.scalars(select(LLMCallAudit)).one()
        assert audit.error_code is None and audit.agent_role == "checker"


@pytest.mark.parametrize("violation", ["minimum_length", "unselected_character", "ambiguous_character"])
def test_manual_check_defers_length_and_name_identity_to_checker(client, auth_headers, violation):
    text = "短稿。" if violation == "minimum_length" else "隔离人物在等雨。" + "雨落。" * 1400
    chapter_id, book_id = story(text)
    if violation != "minimum_length":
        with db_module.SessionLocal() as db:
            db.add(Character(book_id=book_id, name="隔离人物"))
            if violation == "ambiguous_character":
                db.add(Character(book_id=book_id, name="隔离人物"))
            db.commit()
    stub = CheckerStub()
    client.app.dependency_overrides[get_checker_client] = lambda: stub
    response = client.post(f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers)
    assert response.status_code == 200 and stub.calls == 1
    result = response.json()["checker_result"]
    if violation == "minimum_length":
        assert result["verdict"] == "passed"
    else:
        # A generic fixture that declines to classify the supplied name is not
        # a valid conclusion; the route persists it as unavailable rather than
        # guessing from a raw substring.
        assert result["error_code"] == "checker_invalid_response"
    with db_module.SessionLocal() as db:
        assert len(db.scalars(select(LLMCallAudit)).all()) == 1


@pytest.mark.parametrize("phase,role", [
    ("selecting_memory", "memory_selector"), ("writing", "writer"),
    ("validating", "writer"), ("checking", "checker"), ("extracting", "extractor"),
])
def test_restart_public_job_retains_stage_without_changing_accepted_prose(client, auth_headers, phase, role):
    chapter_id, _ = story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.status = "finalized" if phase == "extracting" else "writing"
        revision_id = None
        if phase == "extracting":
            chapter.archive_status = "extracting"
            revision = ChapterArchiveRevision(
                chapter_id=chapter_id, revision=1, provenance="live",
                input_fingerprint=archive_input_fingerprint(chapter),
                contract_version=ARCHIVE_CONTRACT_VERSION,
                status="extracting",
            )
            db.add(revision)
            db.flush()
            revision_id = revision.id
        db.add(JobRun(
            chapter_id=chapter_id, kind="extract" if revision_id else "write", phase=phase,
            archive_revision_id=revision_id, error_context={"model_name": "test-model"},
        ))
        db.commit()
        recover_interrupted_chapters(db)
    response = client.get(f"/api/v1/chapters/{chapter_id}/job", headers=auth_headers)
    assert response.status_code == 200
    status = response.json()
    assert status["phase"] == "failed" and status["error_code"] == "interrupted"
    assert status["error_context"] == {
        "interrupted_phase": phase, "agent_role": role, "model_name": "test-model",
    }
    assert status["outcome_current"] is True
    visible = client.get(f"/api/v1/chapters/{chapter_id}", headers=auth_headers).json()
    assert visible["draft_text"] == "雨落在屋檐。" * 1000
    assert visible["status"] == ("finalized" if revision_id else "draft_ready")
    if revision_id:
        assert visible["archive"]["status"] == "failed"
        assert visible["archive"]["can_retry"] is True
