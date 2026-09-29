"""Regressions for ownership at archive startup and first automatic Checker failure."""
from concurrent.futures import ThreadPoolExecutor
from threading import Event

import httpx
import pytest
from fastapi import HTTPException
from sqlalchemy import select

import app.db as db_module
import app.routers.chapters as routes
import app.services.archive_v2 as archive
from app.llm.factory import get_checker_client, get_extractor_client, get_writer_client
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models import Chapter, ChapterArchiveRevision, ChapterDraftCandidate, JobRun
from app.services.write_jobs import write_registry
from conftest import FakeChecker, FakeExtractor, FakeWriter
from test_build65_sop_recovery import manuscript


@pytest.mark.parametrize('failure', ['execution', 'deep_json'])
def test_first_checker_exception_keeps_candidate_only_retry(client, auth_headers, wait_for_terminal, monkeypatch, failure):
    cid = manuscript()
    calls = []
    class Writer(FakeWriter):
        def complete_stream(self, **kwargs):
            calls.append('writer')
            yield from super().complete_stream(**kwargs)
    client.app.dependency_overrides[get_writer_client] = lambda: Writer('稿' * 4000)
    if failure == 'execution':
        class Checker:
            def complete_json(self, **kwargs):
                raise RuntimeError('synthetic-private-error')
        checker = Checker()
    else:
        checker = OpenAICompatibleClient(base_url='https://synthetic.invalid', api_key='synthetic', model_name='synthetic')
        monkeypatch.setattr(httpx, 'post', lambda *a, **k: httpx.Response(200, json={
            'choices': [{'message': {'content': '[' * 2000 + '0' + ']' * 2000}, 'finish_reason': 'stop'}],
        }))
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f'/api/v1/chapters/{cid}/write', headers=auth_headers).raise_for_status()
    failed = wait_for_terminal(client, cid, auth_headers)
    assert failed['phase'] == 'failed' and failed['checker_result']['status'] == 'unavailable'
    assert failed['can_retry_checker'] and failed['checker_source_job_id'] == failed['job_id']
    assert failed['error_context']['agent_role'] == 'checker'
    assert 'synthetic-private-error' not in str(failed)
    assert write_registry.get_live(cid) is None
    with db_module.SessionLocal() as db:
        run = db.get(JobRun, failed['job_id'])
        candidate = db.get(ChapterDraftCandidate, run.candidate_id)
        assert candidate.draft_text == '稿' * 4000 and candidate.checker_input_snapshot
        assert db.get(Chapter, cid).draft_text == '文' * 4000
    client.app.dependency_overrides[get_checker_client] = FakeChecker
    client.post(f'/api/v1/chapters/{cid}/checker/retry', headers=auth_headers,
                json={'source_job_id': failed['checker_source_job_id']}).raise_for_status()
    passed = wait_for_terminal(client, cid, auth_headers)
    assert passed['phase'] == 'done' and passed['chapter']['draft_text'] == '稿' * 4000
    assert calls == ['writer']


@pytest.mark.parametrize('new_archive', [False, True])
def test_archive_start_failure_serializes_with_reopen(client, auth_headers, wait_for_terminal, monkeypatch, new_archive):
    cid = manuscript()
    entered, release, reopening = Event(), Event(), Event()
    original = archive.mark_revision_failed
    def paused(*args, **kwargs):
        entered.set()
        assert release.wait(5)
        return original(*args, **kwargs)
    monkeypatch.setattr(archive, 'mark_revision_failed', paused)
    def invalid_config():
        raise HTTPException(409, detail={'code': 'llm_profile_not_configured', 'message': '合成配置错误'})
    client.app.dependency_overrides[get_extractor_client] = invalid_config
    def reopen():
        reopening.set()
        return client.post(f'/api/v1/chapters/{cid}/reopen', headers=auth_headers)
    with ThreadPoolExecutor(max_workers=2) as pool:
        accepted = pool.submit(client.post, f'/api/v1/chapters/{cid}/accept', headers=auth_headers,
                               json={'override_checker': True})
        try:
            assert entered.wait(5)
            reopened = pool.submit(reopen)
            assert reopening.wait(5)
            # A reserved SQLite write transaction must prevent the intervening
            # reopen from committing while the old failure is about to write.
            from concurrent.futures import wait
            assert not wait([reopened], timeout=0.15).done
        finally:
            release.set()
        accepted.result(timeout=5).raise_for_status()
        reopened.result(timeout=5).raise_for_status()
    if new_archive:
        client.app.dependency_overrides[get_extractor_client] = FakeExtractor
        client.post(f'/api/v1/chapters/{cid}/accept', headers=auth_headers,
                    json={'override_checker': True}).raise_for_status()
        assert wait_for_terminal(client, cid, auth_headers)['phase'] == 'done'
    def state():
        with db_module.SessionLocal() as db:
            chapter = db.get(Chapter, cid)
            runs = list(db.scalars(select(JobRun).where(JobRun.chapter_id == cid).order_by(JobRun.created_at)))
            old = runs[0]
            revision = db.get(ChapterArchiveRevision, old.archive_revision_id)
            return (chapter.status, chapter.archive_status, chapter.content_revision,
                    chapter.draft_text, old.phase, revision.status), old.id
    before, old_id = state()
    assert before[:2] == (('finalized', 'complete') if new_archive else ('draft_ready', 'stale'))
    # A delayed/repeated failure after a new owner has completed must be a no-op.
    routes._mark_archive_start_failed(old_id, 'archive_start_failed', '合成旧失败', {})
    assert state()[0] == before
