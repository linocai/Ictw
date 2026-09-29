"""Build65 recovery regressions: synthetic chapters/providers only."""
from threading import Event

import httpx
import pytest

import app.db as db_module
from app.agents.extractor import ExtractorContractError
from app.llm.base import LLMError
from app.llm.factory import get_checker_client, get_extractor_client, get_writer_client
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models import Chapter, ChapterArchiveRevision, JobRun
from app.services.archive_v2 import ArchiveFingerprintMismatch, ArchiveV2ValidationError, archive_validation_message
from app.services.write_jobs import write_registry
from conftest import FakeChecker, FakeExtractor, FakeWriter
from test_v2_2_checker_context import _story


def manuscript():
    cid, _, _ = _story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, cid)
        chapter.draft_text = "文" * 4000
        chapter.status = "draft_ready"
        db.commit()
    return cid


@pytest.mark.parametrize("verdict", ["suspect", "violation"])
def test_manual_concrete_verdict_completes_and_author_can_accept(client, auth_headers, wait_for_terminal, verdict):
    cid = manuscript()

    class Checker:
        def complete_json(self, **kwargs):
            return {"verdict": verdict, "name_uses": [], "issues": [{
                "kind": "bible_conflict", "reason": "正文没有按要求推进。",
                "draft_evidence": "文", "bible_evidence": "林夕在雨后回家。",
                "source_kind": "bible", "source_id": "bible", "source_evidence": "林夕在雨后回家。",
            }]}

    client.app.dependency_overrides[get_checker_client] = Checker
    client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers).raise_for_status()
    status = wait_for_terminal(client, cid, auth_headers)
    assert status["phase"] == "done"
    assert status["visible_checker_result"]["verdict"] == verdict
    assert status["chapter"]["draft_text"] == "文" * 4000
    assert not status["can_retry_checker"]
    client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                json={"override_checker": True}).raise_for_status()
    assert wait_for_terminal(client, cid, auth_headers)["kind"] == "extract"


@pytest.mark.parametrize("failure", ["malformed_provider", "unexpected"])
@pytest.mark.parametrize("target", ["visible", "hidden"])
def test_checker_abnormal_response_ends_and_releases_owner(client, auth_headers, wait_for_terminal, monkeypatch, failure, target):
    cid = manuscript()
    source_id = None
    if target == "hidden":
        class Invalid:
            def complete_json(self, **kwargs):
                return {}
        client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("稿" * 4000)
        client.app.dependency_overrides[get_checker_client] = Invalid
        client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers).raise_for_status()
        source_id = wait_for_terminal(client, cid, auth_headers)["checker_source_job_id"]
        assert source_id
    if failure == "malformed_provider":
        checker = OpenAICompatibleClient(base_url="https://synthetic.invalid", api_key="synthetic", model_name="synthetic")
        monkeypatch.setattr(httpx, "post", lambda *a, **k: httpx.Response(200, json={"choices": [None]}))
    else:
        class Unexpected:
            def complete_json(self, **kwargs):
                raise RuntimeError("synthetic-private-error")
        checker = Unexpected()
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    def start():
        return client.post(f"/api/v1/chapters/{cid}/" + ("checker/retry" if source_id else "check/start"),
                           headers=auth_headers, json={"source_job_id": source_id} if source_id else {})
    start().raise_for_status()
    status = wait_for_terminal(client, cid, auth_headers)
    assert status["phase"] == "failed" and status["checker_result"]["status"] == "unavailable"
    assert "synthetic-private-error" not in str(status)
    assert write_registry.get_live(cid) is None
    assert status["can_retry_checker"] == (target == "hidden")
    client.app.dependency_overrides[get_checker_client] = FakeChecker
    start().raise_for_status()
    assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"


def test_legacy_visible_failure_never_gets_hidden_retry(client, auth_headers, wait_for_terminal):
    cid = manuscript()
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("稿" * 4000)
    client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers).raise_for_status()
    source = wait_for_terminal(client, cid, auth_headers)["job_id"]
    class Invalid:
        def complete_json(self, **kwargs):
            return {}
    client.app.dependency_overrides[get_checker_client] = Invalid
    client.post(f"/api/v1/chapters/{cid}/check", headers=auth_headers).raise_for_status()
    status = client.get(f"/api/v1/chapters/{cid}/job", headers=auth_headers).json()
    # Also cover records persisted by Build64's synchronous compatibility route.
    with db_module.SessionLocal() as db:
        db.get(JobRun, status["job_id"]).parent_job_id = source
        db.commit()
    status = client.get(f"/api/v1/chapters/{cid}/job", headers=auth_headers).json()
    assert status["checker_target"] == "visible_draft" and not status["can_retry_checker"]
    refused = client.post(f"/api/v1/chapters/{cid}/checker/retry", headers=auth_headers,
                          json={"source_job_id": source})
    assert refused.status_code == 409


@pytest.mark.parametrize("failure", ["llm", "contract", "validation", "fingerprint", "unexpected"])
@pytest.mark.parametrize("new_status", ["extracting", "partial"])
def test_cancelled_extractor_failure_cannot_mutate_new_archive(client, auth_headers, wait_for_terminal, failure, new_status):
    cid = manuscript()
    entered, release, newer_entered, newer_release = (Event() for _ in range(4))
    errors = {
        "llm": LLMError("synthetic timeout", code="llm_timeout"),
        "contract": ExtractorContractError("synthetic contract failure"),
        "validation": ArchiveV2ValidationError("relationship fact must have exactly two participants"),
        "fingerprint": ArchiveFingerprintMismatch("前置有效状态已变化"),
        "unexpected": RuntimeError("synthetic persistence failure"),
    }
    class Old:
        def complete_json(self, **kwargs):
            entered.set()
            assert release.wait(10)
            raise errors[failure]
    class New:
        def complete_json(self, **kwargs):
            newer_entered.set()
            if new_status == "partial":
                return {"summary": "测试摘要", "facts": "invalid", "end_state_delta": []}
            assert newer_release.wait(10)
            return FakeExtractor().complete_json(**kwargs)
    old_job = new_job = None
    try:
        client.app.dependency_overrides[get_extractor_client] = Old
        client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                    json={"override_checker": True}).raise_for_status()
        assert entered.wait(5)
        old_job = write_registry.get(cid)
        client.post(f"/api/v1/chapters/{cid}/reopen", headers=auth_headers).raise_for_status()
        client.app.dependency_overrides[get_extractor_client] = New
        client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                    json={"override_checker": True}).raise_for_status()
        assert newer_entered.wait(5)
        new_job = write_registry.get(cid)
        if new_status == "partial":
            wait_for_terminal(client, cid, auth_headers)
        def state():
            with db_module.SessionLocal() as db:
                chapter = db.get(Chapter, cid)
                old = db.get(ChapterArchiveRevision, old_job.archive_revision_id)
                return chapter.archive_status, chapter.content_revision, old.status, chapter.draft_text
        before = state()
        assert before[0] == new_status and before[2] == "stale"
        release.set()
        old_job.thread.join(5)
        assert not old_job.thread.is_alive()
        assert state() == before
    finally:
        release.set(); newer_release.set()
        for job in (old_job, new_job):
            if job and job.thread:
                job.thread.join(5)


def test_archive_errors_are_readable_and_unknown_protocol_is_not_exposed():
    assert archive_validation_message("relationship fact must have exactly two participants") == "人物关系记录未明确对应的两个人物"
    assert "两个人物" in archive_validation_message("归档未通过确定性校验：relationship fact must have exactly two participants")
    assert "opaque_secret_field" not in archive_validation_message("unknown opaque_secret_field")
    assert archive_validation_message("人物状态所引用的事实未包含该人物") == "人物状态所引用的事实未包含该人物"
    from app.services.archive_v2 import canonicalize_archive_diagnostics
    old = [{"code": "archive_validation_failed", "severity": "error",
            "message": "relationship fact must have exactly two participants", "recovery": "请重新整理"}]
    assert canonicalize_archive_diagnostics(old, character_names={})[0]["message"] == "人物关系记录未明确对应的两个人物"
