"""Synthetic regressions for Build66 admission, memory eligibility and recovery."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier, Event
from uuid import uuid4

import pytest
from fastapi import HTTPException
from sqlalchemy import event
from sqlalchemy import func, select

import app.db as db_module
from app.llm.factory import get_checker_client, get_extractor_client, get_writer_client
from app.models import Book, Character, CharacterEvent, Chapter, ChapterArchiveRevision, CharacterStateChange, JobRun
from app.services.archive_v2 import archive_read_model, archive_health_summaries
from app.services.character_state_projection import projected_fields_before_chapter
from app.services.context import memory_candidates
from app.services.production_context import production_readiness
from conftest import FakeChecker, FakeExtractor, FakeWriter
from test_build65_sop_recovery import manuscript
from test_v2_2_checker_context import _story


def test_imported_ineligible_legacy_is_missing_not_silently_used(client, auth_headers):
    current_id, prior_id, _ = _story()
    with db_module.SessionLocal() as db:
        book_id = db.get(Chapter, current_id).book_id
        # Format3 preserves eligible legacy memory; this case verifies ineligible history.
        db.get(Chapter, prior_id).legacy_archive_eligible = False
        db.commit()
    exported = client.get(f"/api/v1/books/{book_id}/project-export", headers=auth_headers)
    exported.raise_for_status()
    restored = client.post('/api/v1/books/project-import', content=exported.content,
                           headers={**auth_headers, 'Content-Type': 'application/vnd.ictw.project+zip'})
    restored.raise_for_status()
    with db_module.SessionLocal() as db:
        chapters = list(db.scalars(select(Chapter).where(Chapter.book_id == restored.json()['book_id']).order_by(Chapter.index)))
        prior, current = chapters[:2]
        assert not prior.legacy_archive_eligible and prior.archive_input_fingerprint is None
        assert archive_read_model(db, prior)['effective_status'] == 'none'
        assert archive_read_model(db, prior)['can_retry']
        assert not any('已归还钥匙' in block.text for block in memory_candidates(db, current))
        readiness = production_readiness(db, current)
        assert not readiness['is_complete']
        assert readiness['recommended_recovery']['chapter_id'] == prior.id


def test_ineligible_legacy_state_does_not_project_without_fingerprint(client):
    current_id, prior_id, _ = _story()
    with db_module.SessionLocal() as db:
        current, prior = db.get(Chapter, current_id), db.get(Chapter, prior_id)
        person = current.character_links[0].character_id
        prior.legacy_archive_eligible = False
        db.add(CharacterStateChange(book_id=prior.book_id, chapter_id=prior.id, character_id=person,
                                   scope='snapshot', slot='当前位置', operation='set', value='失效旧地点', evidence='合成证据', batch_id='synthetic-batch'))
        db.commit()
        assert '失效旧地点' not in str(projected_fields_before_chapter(db, current))


@pytest.mark.parametrize('eligible', [False, True])
def test_empty_legacy_has_consistent_recovery_in_detail_rail_and_readiness(client, auth_headers, wait_for_terminal, eligible):
    current_id, prior_id, _ = _story()
    with db_module.SessionLocal() as db:
        prior = db.get(Chapter, prior_id)
        prior.long_summary = ''
        prior.headline = ''
        prior.archive_status = 'legacy' if eligible else 'stale'
        prior.legacy_archive_eligible = eligible
        book_id = prior.book_id
        db.commit()
        readiness = production_readiness(db, db.get(Chapter, current_id))
        assert readiness['recommended_recovery']['chapter_id'] == prior_id
    detail = client.get(f'/api/v1/chapters/{prior_id}', headers=auth_headers).json()
    rail = client.get(f'/api/v1/books/{book_id}/chapters', headers=auth_headers).json()
    row = next(item for item in rail if item['id'] == prior_id)
    assert detail['archive']['can_retry'] and detail['archive']['status'] == 'stale'
    assert detail['archive']['effective_status'] == 'none'
    assert row['archive_can_retry'] and row['archive_effective_status'] == 'none'
    client.post(f'/api/v1/chapters/{prior_id}/archive/retry', headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, prior_id, auth_headers)['phase'] == 'done'


def test_real_eligible_legacy_remains_available_without_reextract(client):
    current_id, prior_id, _ = _story()
    with db_module.SessionLocal() as db:
        archive = archive_read_model(db, db.get(Chapter, prior_id))
        assert archive['effective_status'] == 'full' and not archive['can_retry']
        assert production_readiness(db, db.get(Chapter, current_id))['is_complete']


@pytest.mark.parametrize('conditional', [False, True])
def test_concurrent_archive_retries_share_one_admission(client, auth_headers, wait_for_terminal, conditional):
    _, cid, _ = _story()
    started, release = Event(), Event()
    calls = []
    class Blocking(FakeExtractor):
        def complete_json(self, **kwargs):
            calls.append(1)
            started.set()
            assert release.wait(5)
            return super().complete_json(**kwargs)
    client.app.dependency_overrides[get_extractor_client] = Blocking
    chapter = client.get(f'/api/v1/chapters/{cid}', headers=auth_headers).json()
    headers = dict(auth_headers)
    if conditional:
        headers['If-Match'] = str(chapter['content_revision'])
    barrier = Barrier(2)
    def retry():
        barrier.wait(timeout=5)
        return client.post(f'/api/v1/chapters/{cid}/archive/retry', headers=headers)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(retry) for _ in range(2)]
            responses = [item.result(timeout=5) for item in futures]
        assert started.wait(5)
        assert [r.status_code for r in responses] == [200, 200], [r.text for r in responses]
        assert len({r.json()['job_id'] for r in responses}) == 1
        with db_module.SessionLocal() as db:
            assert db.scalar(select(func.count()).select_from(ChapterArchiveRevision).where(ChapterArchiveRevision.chapter_id == cid)) == 1
        assert len(calls) == 1
    finally:
        release.set()
    assert wait_for_terminal(client, cid, auth_headers)['phase'] == 'done'


def test_hidden_retry_is_idempotent_during_execution_and_after_promotion(client, auth_headers, wait_for_terminal):
    cid = manuscript()
    class Invalid:
        def complete_json(self, **kwargs): return {}
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter('稿' * 4000)
    client.app.dependency_overrides[get_checker_client] = Invalid
    client.post(f'/api/v1/chapters/{cid}/write', headers=auth_headers).raise_for_status()
    source = wait_for_terminal(client, cid, auth_headers)['checker_source_job_id']
    started, release = Event(), Event()
    calls = []
    class Blocking(FakeChecker):
        def complete_json(self, **kwargs):
            calls.append(1)
            started.set()
            assert release.wait(5)
            return super().complete_json(**kwargs)
    client.app.dependency_overrides[get_checker_client] = Blocking
    chapter = client.get(f'/api/v1/chapters/{cid}', headers=auth_headers).json()
    headers = {**auth_headers, 'If-Match': str(chapter['content_revision'])}
    request_id = str(uuid4())
    payload = {'source_job_id': source, 'request_id': request_id}
    try:
        first = client.post(f'/api/v1/chapters/{cid}/checker/retry', json=payload, headers=headers)
        first.raise_for_status()
        assert started.wait(5)
        def unavailable():
            raise HTTPException(status_code=409, detail={"code": "llm_profile_not_configured"})
        client.app.dependency_overrides[get_checker_client] = unavailable
        replay = client.post(f'/api/v1/chapters/{cid}/checker/retry', json=payload, headers=headers)
        replay.raise_for_status()
        assert first.json()['job_id'] == replay.json()['job_id'] == request_id
        assert len(calls) == 1
    finally:
        release.set()
    final = wait_for_terminal(client, cid, auth_headers)
    assert final['phase'] == 'done' and final['chapter']['draft_text'] == '稿' * 4000
    replay = client.post(f'/api/v1/chapters/{cid}/checker/retry', json=payload, headers=headers)
    replay.raise_for_status()
    assert replay.json()['phase'] == 'done' and replay.json()['job_id'] == request_id
    assert len(calls) == 1
    wrong_source = client.post(f'/api/v1/chapters/{cid}/checker/retry', json={**payload, 'source_job_id': 'other'}, headers=headers)
    assert wrong_source.status_code == 409


def test_legacy_health_queries_are_bounded_and_event_only_memory_matches_detail(client):
    def count_health(size):
        with db_module.SessionLocal() as db:
            book = Book(title="Synthetic legacy")
            db.add(book)
            db.flush()
            character = Character(book_id=book.id, name="甲")
            db.add(character)
            db.flush()
            chapters = [Chapter(book_id=book.id, index=i + 1, title="合成", status="finalized",
                                legacy_archive_eligible=True, archive_status="legacy") for i in range(size)]
            db.add_all(chapters)
            db.flush()
            db.add_all([CharacterEvent(book_id=book.id, chapter_id=c.id, character_id=character.id,
                                       event_text="有效事件" if i % 2 else " \n ") for i, c in enumerate(chapters)])
            db.commit()
            chapters = list(db.scalars(select(Chapter).where(Chapter.book_id == book.id).order_by(Chapter.index)))
            queries = []
            def observe(*args): queries.append(1)
            event.listen(db.bind, 'before_cursor_execute', observe)
            try:
                health = archive_health_summaries(db, chapters)
            finally:
                event.remove(db.bind, 'before_cursor_execute', observe)
            for i, chapter in enumerate(chapters):
                detail = archive_read_model(db, chapter)
                assert health[chapter.id]['archive_effective_status'] == detail['effective_status'] == ('full' if i % 2 else 'none')
                assert health[chapter.id]['archive_can_retry'] == detail['can_retry'] == (not bool(i % 2))
            return len(queries)
    assert count_health(4) == count_health(40)
