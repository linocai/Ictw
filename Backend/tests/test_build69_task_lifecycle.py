"""Build69 task ownership and accept/import regressions on synthetic data."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event

import pytest
from sqlalchemy import select

import app.db as db_module
import app.routers.chapters as routes
from app.llm.base import LLMError
from app.llm.factory import get_checker_client, get_extractor_client, get_writer_client
from app.models import Chapter, ChapterArchiveRevision, Character, JobRun, SearchDocument
from app.models.entities import utc_now
from app.services.archive_v2 import archive_input_fingerprint
from app.services.production_context import freeze_manual_checker_input
from app.services.write_jobs import write_registry
from conftest import FakeChecker, FakeExtractor, FakeWriter
from test_v1_8_archive import V2Extractor, _book_character_chapter


def _manuscript(client, headers, text="原稿。"):
    book = client.post("/api/v1/books", headers=headers, json={"title": "合成测试书"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=headers, json={}).json()
    imported = client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=headers,
                           json={"draft_text": text})
    imported.raise_for_status()
    return imported.json()


def _state(chapter_id):
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        return (chapter.draft_text, chapter.status, chapter.write_generation,
                chapter.content_revision, chapter.archive_status, chapter.active_archive_revision_id)


class _BlockedWriter(FakeWriter):
    def __init__(self):
        super().__init__("旧" * 4000)
        self.entered, self.release = Event(), Event()

    def complete_stream(self, **kwargs):
        self.entered.set()
        assert self.release.wait(10)
        # An upstream response may arrive despite its caller having cancelled.
        kwargs["cancel_event"] = None
        yield from super().complete_stream(**kwargs)


class _BlockedChecker(FakeChecker):
    def __init__(self):
        self.entered, self.release = Event(), Event()

    def complete_json(self, **kwargs):
        self.entered.set()
        assert self.release.wait(10)
        return super().complete_json(**kwargs)


class _BlockedExtractor(FakeExtractor):
    def __init__(self):
        super().__init__()
        self.entered, self.release = Event(), Event()

    def complete_json(self, **kwargs):
        self.entered.set()
        assert self.release.wait(10)
        return super().complete_json(**kwargs)


def _gate_join(monkeypatch, job):
    entered, release = Event(), Event()
    original_join = job.thread.join

    def gated_join(*args, **kwargs):
        entered.set()
        assert release.wait(10)

    monkeypatch.setattr(job.thread, "join", gated_join)
    return entered, release, original_join


@pytest.mark.parametrize("new_running", [False, True])
@pytest.mark.parametrize("old_kind", ["writer", "writer_check", "candidate_check", "visible_check"])
def test_old_cancel_join_cannot_invalidate_new_writer(
    client, auth_headers, wait_for_terminal, monkeypatch, old_kind, new_running,
):
    chapter = _manuscript(client, auth_headers)
    cid = chapter["id"]
    blocked = _BlockedWriter() if old_kind == "writer" else _BlockedChecker()
    if old_kind == "candidate_check":
        class InvalidChecker:
            def complete_json(self, **kwargs):
                return {}

        client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("候选" * 2000)
        client.app.dependency_overrides[get_checker_client] = InvalidChecker
        client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers).raise_for_status()
        source = wait_for_terminal(client, cid, auth_headers)
        assert source["can_retry_checker"]
        client.app.dependency_overrides[get_checker_client] = lambda: blocked
        started = client.post(f"/api/v1/chapters/{cid}/checker/retry", headers=auth_headers,
                              json={"source_job_id": source["job_id"]})
    elif old_kind == "visible_check":
        client.app.dependency_overrides[get_checker_client] = lambda: blocked
        started = client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers)
    else:
        client.app.dependency_overrides[get_writer_client] = (
            (lambda: blocked) if old_kind == "writer" else (lambda: FakeWriter("候选" * 2000))
        )
        client.app.dependency_overrides[get_checker_client] = (
            FakeChecker if old_kind == "writer" else (lambda: blocked)
        )
        started = client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers)
    started.raise_for_status()
    assert blocked.entered.wait(5)
    old = write_registry.get_live(cid)
    assert old is not None and old.job_id == started.json()["job_id"]
    joined, release_cancel, old_join = _gate_join(monkeypatch, old)
    new_writer = _BlockedWriter() if new_running else FakeWriter("新" * 4000)
    new_writer.text = "新" * 4000
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            cancelling = pool.submit(client.post, f"/api/v1/chapters/{cid}/write/cancel", headers=auth_headers)
            try:
                assert joined.wait(5)
                client.app.dependency_overrides[get_writer_client] = lambda: new_writer
                client.app.dependency_overrides[get_checker_client] = FakeChecker
                newer = client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers)
                newer.raise_for_status()
                if new_running:
                    assert new_writer.entered.wait(5)
                    assert _state(cid)[1] == "writing"
                else:
                    terminal = wait_for_terminal(client, cid, auth_headers)
                    assert terminal["phase"] == "done" and terminal["job_id"] == newer.json()["job_id"]
                completed = _state(cid)
            finally:
                release_cancel.set()
            cancelled = cancelling.result(5)
            cancelled.raise_for_status()
        assert _state(cid) == completed
        assert cancelled.json()["draft_text"] == completed[0]
        blocked.release.set()
        old_join(5)
        assert not old.thread.is_alive()
        assert _state(cid) == completed
        if new_running:
            new_writer.release.set()
            assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
            assert _state(cid)[:2] == ("新" * 4000, "draft_ready")
        with db_module.SessionLocal() as db:
            assert db.get(JobRun, old.job_id).phase == "cancelled"
            assert db.get(JobRun, newer.json()["job_id"]).phase == "done"
    finally:
        release_cancel.set()
        blocked.release.set()
        if new_running:
            new_writer.release.set()
        old_join(5)


def test_old_cancel_and_late_writer_cannot_reopen_newly_accepted_baseline(
    client, auth_headers, wait_for_terminal, monkeypatch,
):
    cid = _manuscript(client, auth_headers)["id"]
    blocked = _BlockedWriter()
    client.app.dependency_overrides[get_writer_client] = lambda: blocked
    client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers).raise_for_status()
    assert blocked.entered.wait(5)
    old = write_registry.get_live(cid)
    joined, release_cancel, old_join = _gate_join(monkeypatch, old)
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            cancelling = pool.submit(client.post, f"/api/v1/chapters/{cid}/write/cancel", headers=auth_headers)
            try:
                assert joined.wait(5)
                accepted = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                                       json={"override_checker": True})
                accepted.raise_for_status()
                assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
                completed = _state(cid)
            finally:
                release_cancel.set()
            cancelling.result(5).raise_for_status()
        blocked.release.set()
        old_join(5)
        assert _state(cid) == completed and completed[1] == "finalized"
        with db_module.SessionLocal() as db:
            assert db.get(JobRun, old.job_id).phase == "cancelled"
    finally:
        release_cancel.set()
        blocked.release.set()
        old_join(5)


def test_cancel_that_loses_finalization_does_not_invalidate_completed_writer(
    client, auth_headers, wait_for_terminal, monkeypatch,
):
    cid = _manuscript(client, auth_headers)["id"]
    finalizing, release_finish = Event(), Event()
    original_finish = write_registry.finish_if_current

    def gated_finish(job, persist, *, phase):
        if job.kind == "write" and phase == "done":
            def gated_persist():
                finalizing.set()
                assert release_finish.wait(10)
                return persist()
            return original_finish(job, gated_persist, phase=phase)
        return original_finish(job, persist, phase=phase)

    monkeypatch.setattr(write_registry, "finish_if_current", gated_finish)
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("新" * 4000)
    client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers).raise_for_status()
    assert finalizing.wait(5)
    job = write_registry.get_live(cid)
    joined, release_cancel, original_join = _gate_join(monkeypatch, job)
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            cancelling = pool.submit(client.post, f"/api/v1/chapters/{cid}/write/cancel", headers=auth_headers)
            try:
                assert joined.wait(5)
                assert not job.cancel_event.is_set()
                release_finish.set()
                original_join(5)
                assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
                completed = _state(cid)
            finally:
                release_cancel.set()
            cancelling.result(5).raise_for_status()
        assert _state(cid) == completed
    finally:
        release_finish.set()
        release_cancel.set()
        original_join(5)


@pytest.mark.parametrize("finalized", [False, True])
def test_cancel_visible_check_is_idempotent_and_preserves_acceptance(
    client, auth_headers, wait_for_terminal, monkeypatch, finalized,
):
    cid = _manuscript(client, auth_headers)["id"]
    if finalized:
        client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                    json={"override_checker": True}).raise_for_status()
        assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
    blocked = _BlockedChecker()
    client.app.dependency_overrides[get_checker_client] = lambda: blocked
    started = client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers)
    started.raise_for_status()
    assert blocked.entered.wait(5)
    job = write_registry.get_live(cid)
    original_join = job.thread.join
    monkeypatch.setattr(job.thread, "join", lambda **kwargs: None)
    before = _state(cid)
    try:
        cancelled = client.post(f"/api/v1/chapters/{cid}/write/cancel", headers=auth_headers)
        cancelled.raise_for_status()
        assert _state(cid) == before
        client.post(f"/api/v1/chapters/{cid}/write/cancel", headers=auth_headers).raise_for_status()
        assert _state(cid) == before
        blocked.release.set()
        original_join(5)
        assert _state(cid) == before
        with db_module.SessionLocal() as db:
            assert db.get(JobRun, started.json()["job_id"]).phase == "cancelled"
    finally:
        blocked.release.set()
        original_join(5)


def test_cancel_extractor_preserves_accepted_prose_and_durable_terminal(
    client, auth_headers, monkeypatch,
):
    cid = _manuscript(client, auth_headers)["id"]
    blocked = _BlockedExtractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: blocked
    started = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                          json={"override_checker": True})
    started.raise_for_status()
    assert blocked.entered.wait(5)
    job = write_registry.get_live(cid)
    original_join = job.thread.join
    monkeypatch.setattr(job.thread, "join", lambda **kwargs: None)
    try:
        cancelled = client.post(f"/api/v1/chapters/{cid}/write/cancel", headers=auth_headers)
        cancelled.raise_for_status()
        cancelled_state = _state(cid)
        assert cancelled_state[:2] == ("原稿。", "finalized")
        assert cancelled.json()["archive"]["status"] == "failed"
        client.post(f"/api/v1/chapters/{cid}/write/cancel", headers=auth_headers).raise_for_status()
        blocked.release.set()
        original_join(5)
        assert _state(cid) == cancelled_state
        with db_module.SessionLocal() as db:
            run = db.get(JobRun, started.json()["job_id"])
            assert run.phase == "cancelled" and run.finished_at is not None
            assert db.get(ChapterArchiveRevision, run.archive_revision_id).status == "failed"
    finally:
        blocked.release.set()
        original_join(5)


def test_old_extractor_cancel_cannot_revoke_new_accept(
    client, auth_headers, wait_for_terminal, monkeypatch,
):
    cid = _manuscript(client, auth_headers)["id"]
    blocked = _BlockedExtractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: blocked
    accepted = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                           json={"override_checker": True})
    accepted.raise_for_status()
    assert blocked.entered.wait(5)
    old = write_registry.get_live(cid)
    joined, release_cancel, old_join = _gate_join(monkeypatch, old)
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            cancelling = pool.submit(client.post, f"/api/v1/chapters/{cid}/write/cancel", headers=auth_headers)
            try:
                assert joined.wait(5)
                client.post(f"/api/v1/chapters/{cid}/reopen", headers=auth_headers).raise_for_status()
                client.app.dependency_overrides[get_extractor_client] = FakeExtractor
                newer = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                                    json={"override_checker": True})
                newer.raise_for_status()
                assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
                completed = _state(cid)
            finally:
                release_cancel.set()
            cancelling.result(5).raise_for_status()
        blocked.release.set()
        old_join(5)
        assert _state(cid) == completed and completed[1:2] == ("finalized",)
        with db_module.SessionLocal() as db:
            old_run = db.get(JobRun, accepted.json()["job_id"])
            assert old_run.phase == "cancelled"
            assert db.get(ChapterArchiveRevision, old_run.archive_revision_id).status == "stale"
            assert db.get(JobRun, newer.json()["job_id"]).phase == "done"
    finally:
        release_cancel.set()
        blocked.release.set()
        old_join(5)


@pytest.mark.parametrize("kind", ["unselected_character", "ambiguous_character"])
@pytest.mark.parametrize("override_checker,allow_short_draft", [(False, False), (False, True), (True, False), (True, True)])
def test_current_checker_identity_issue_without_name_hits_blocks_all_overrides(
    client, auth_headers, wait_for_terminal, kind, override_checker, allow_short_draft,
):
    chapter = _manuscript(client, auth_headers, "那岑说道，门灯亮着。")
    cid = chapter["id"]
    client.post(f"/api/v1/books/{chapter['book_id']}/characters", headers=auth_headers,
                json={"name": "岑"}).raise_for_status()
    if kind == "ambiguous_character":
        client.post(f"/api/v1/books/{chapter['book_id']}/characters", headers=auth_headers,
                    json={"name": "岑"}).raise_for_status()

    class IdentityChecker:
        def complete_json(self, **kwargs):
            return {"verdict": "violation", "name_uses": [], "issues": [{
                "kind": kind, "reason": "本章人物身份未获确认。", "draft_evidence": "那岑说道",
                "bible_evidence": "", "source_kind": "draft", "source_id": "draft",
                "source_evidence": "那岑说道",
            }]}

    client.app.dependency_overrides[get_checker_client] = IdentityChecker
    client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, cid, auth_headers)["visible_checker_result"]["verdict"] == "violation"
    with db_module.SessionLocal() as db:
        assert freeze_manual_checker_input(db, db.get(Chapter, cid), chapter["draft_text"])["name_hits"] == []
    refused = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                          json={"override_checker": override_checker, "allow_short_draft": allow_short_draft})
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "accept_identity_unresolved"
    with db_module.SessionLocal() as db:
        assert db.scalar(select(JobRun.id).where(JobRun.chapter_id == cid, JobRun.kind == "extract")) is None
        assert db.get(Chapter, cid).status == "draft_ready"


@pytest.mark.parametrize("repair", ["selected", "exempt", "new_draft"])
def test_obsolete_checker_identity_issue_does_not_block_repaired_input(
    client, auth_headers, wait_for_terminal, repair,
):
    chapter = _manuscript(client, auth_headers, "那岑说道，门灯亮着。")
    cid = chapter["id"]
    character = client.post(f"/api/v1/books/{chapter['book_id']}/characters", headers=auth_headers,
                            json={"name": "岑"}).json()

    class IdentityChecker:
        def complete_json(self, **kwargs):
            return {"verdict": "violation", "name_uses": [], "issues": [{
                "kind": "unselected_character", "reason": "未选人物。", "draft_evidence": "那岑说道",
                "bible_evidence": "", "source_kind": "draft", "source_id": "draft",
                "source_evidence": "那岑说道",
            }]}

    client.app.dependency_overrides[get_checker_client] = IdentityChecker
    client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
    patch = ({"character_links": [{"character_id": character["id"]}]} if repair == "selected"
             else {"exempted_character_names": ["岑"]} if repair == "exempt"
             else {"draft_text": "门灯亮着。"})
    client.patch(f"/api/v1/chapters/{cid}", headers=auth_headers, json=patch).raise_for_status()
    if repair != "new_draft":
        client.app.dependency_overrides[get_checker_client] = FakeChecker
        client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers).raise_for_status()
        assert wait_for_terminal(client, cid, auth_headers)["visible_checker_result"]["verdict"] == "passed"
    accepted = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                           json={"override_checker": repair == "new_draft", "allow_short_draft": True})
    accepted.raise_for_status()
    assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"


@pytest.mark.parametrize("checker_available", [True, False])
def test_ordinary_word_and_unavailable_checker_keep_legal_short_draft_override(
    client, auth_headers, wait_for_terminal, checker_available,
):
    chapter = _manuscript(client, auth_headers, "今年夏天天气很热。" if checker_available else "门灯亮着。")
    cid = chapter["id"]
    if checker_available:
        client.post(f"/api/v1/books/{chapter['book_id']}/characters", headers=auth_headers,
                    json={"name": "夏天"}).raise_for_status()
        with db_module.SessionLocal() as db:
            snapshot = freeze_manual_checker_input(db, db.get(Chapter, cid), chapter["draft_text"])
        assert snapshot["name_hits"]

    class Checker:
        def complete_json(self, **kwargs):
            if not checker_available:
                return {}
            return {"verdict": "passed", "issues": [], "name_uses": [
                {"group_id": f"g{index}", "classification": "ordinary_word", "reason": "此处描述季节。"}
                for index, _group in enumerate(snapshot["name_groups"], start=1)
            ]}

    client.app.dependency_overrides[get_checker_client] = Checker
    client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers).raise_for_status()
    status = wait_for_terminal(client, cid, auth_headers)
    assert status["phase"] == ("done" if checker_available else "failed")
    accepted = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                           json={"override_checker": not checker_available, "allow_short_draft": True})
    accepted.raise_for_status()
    assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"


def test_identical_finalized_import_invalidates_own_and_dependent_archives(
    client, auth_headers, wait_for_terminal,
):
    book, character, first = _book_character_chapter(client, auth_headers)
    extractor = V2Extractor(with_state=True)
    client.app.dependency_overrides[get_extractor_client] = lambda: extractor
    client.post(f"/api/v1/chapters/{first['id']}/accept", headers=auth_headers,
                json={"override_checker": True}).raise_for_status()
    assert wait_for_terminal(client, first["id"], auth_headers)["phase"] == "done"
    later = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
                        json={"character_links": [{"character_id": character["id"]}]}).json()
    client.post(f"/api/v1/chapters/{later['id']}/import", headers=auth_headers,
                json={"draft_text": "林夕在门边等待。"}).raise_for_status()
    client.post(f"/api/v1/chapters/{later['id']}/accept", headers=auth_headers,
                json={"override_checker": True}).raise_for_status()
    assert wait_for_terminal(client, later["id"], auth_headers)["phase"] == "done"
    before = client.get(f"/api/v1/chapters/{first['id']}", headers=auth_headers).json()
    later_before = client.get(f"/api/v1/chapters/{later['id']}", headers=auth_headers).json()
    calls = extractor.calls
    imported = client.post(f"/api/v1/chapters/{first['id']}/import", headers={
        **auth_headers, "If-Match": str(before["content_revision"]),
    }, json={"draft_text": before["draft_text"]})
    imported.raise_for_status()
    assert imported.json()["status"] == "draft_ready"
    assert imported.json()["archive"]["status"] == "stale"
    after = client.get(f"/api/v1/chapters/{later['id']}", headers=auth_headers).json()
    assert after["archive"]["status"] == "stale"
    assert after["content_revision"] > later_before["content_revision"]
    with db_module.SessionLocal() as db:
        revisions = db.scalars(select(ChapterArchiveRevision).where(
            ChapterArchiveRevision.chapter_id.in_([first["id"], later["id"]]),
        )).all()
        assert all(row.status == "stale" and not row.is_active for row in revisions)
        assert not db.get(Chapter, first["id"]).legacy_archive_eligible
        assert db.get(Character, character["id"]).dynamic_fields == {}
        archive_documents = db.scalars(select(SearchDocument).where(
            SearchDocument.book_id == book["id"], SearchDocument.result_type.in_(["archive_fact", "archive_summary"]),
        )).all()
        assert not archive_documents
    stale = client.post(f"/api/v1/chapters/{first['id']}/import", headers={
        **auth_headers, "If-Match": str(before["content_revision"]),
    }, json={"draft_text": "过时稿"})
    assert stale.status_code == 409 and stale.json()["detail"]["code"] == "write_conflict"
    repeated = client.post(f"/api/v1/chapters/{first['id']}/import", headers={
        **auth_headers, "If-Match": str(imported.json()["content_revision"]),
    }, json={"draft_text": before["draft_text"]})
    repeated.raise_for_status()
    assert extractor.calls == calls


def test_import_stales_every_unfinished_revision_even_without_registered_task(client, auth_headers):
    chapter = _manuscript(client, auth_headers)
    cid = chapter["id"]
    with db_module.SessionLocal() as db:
        stored = db.get(Chapter, cid)
        stored.status = "finalized"
        for number, phase in enumerate(["pending", "extracting", "pending"], start=1):
            revision = ChapterArchiveRevision(
                chapter_id=cid, revision=number, status=phase,
                input_fingerprint=archive_input_fingerprint(stored), provenance="live",
            )
            db.add(revision)
            db.flush()
            if number < 3:
                db.add(JobRun(chapter_id=cid, kind="extract", phase=phase, archive_revision_id=revision.id))
        db.commit()
    imported = client.post(f"/api/v1/chapters/{cid}/import", headers=auth_headers,
                           json={"draft_text": chapter["draft_text"]})
    imported.raise_for_status()
    with db_module.SessionLocal() as db:
        revisions = db.scalars(select(ChapterArchiveRevision).where(ChapterArchiveRevision.chapter_id == cid)).all()
        runs = db.scalars(select(JobRun).where(JobRun.chapter_id == cid)).all()
        assert len(revisions) == 3 and len(runs) == 2
        assert all(row.status == "stale" and row.finished_at is not None for row in revisions)
        assert all(row.phase == "cancelled" and row.finished_at is not None for row in runs)


@pytest.mark.parametrize("late_failure", [False, True])
def test_import_during_model_call_never_reactivates_old_archive(
    client, auth_headers, wait_for_terminal, late_failure,
):
    cid = _manuscript(client, auth_headers)["id"]

    class Extractor(_BlockedExtractor):
        def complete_json(self, **kwargs):
            self.entered.set()
            assert self.release.wait(10)
            if late_failure:
                raise LLMError("合成迟到失败", code="llm_timeout")
            return FakeExtractor.complete_json(self, **kwargs)

    blocked = Extractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: blocked
    accepted = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                           json={"override_checker": True})
    accepted.raise_for_status()
    assert blocked.entered.wait(5)
    old = write_registry.get_live(cid)
    try:
        before = client.get(f"/api/v1/chapters/{cid}", headers=auth_headers).json()
        imported = client.post(f"/api/v1/chapters/{cid}/import", headers={
            **auth_headers, "If-Match": str(before["content_revision"]),
        }, json={"draft_text": before["draft_text"]})
        imported.raise_for_status()
        reopened = _state(cid)
        client.app.dependency_overrides[get_extractor_client] = FakeExtractor
        client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers).raise_for_status()
        assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
        resumed = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                              json={"allow_short_draft": True})
        resumed.raise_for_status()
        assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
        completed = _state(cid)
        assert completed[1] == "finalized" and completed[2] >= reopened[2]
        blocked.release.set()
        old.thread.join(5)
        assert not old.thread.is_alive() and _state(cid) == completed
        with db_module.SessionLocal() as db:
            old_run = db.get(JobRun, accepted.json()["job_id"])
            assert old_run.phase == "cancelled" and old_run.error_code == "archive_reopened"
            assert db.get(ChapterArchiveRevision, old_run.archive_revision_id).status == "stale"
    finally:
        blocked.release.set()
        old.thread.join(5)


@pytest.mark.parametrize("reopen_path", ["import", "reopen", "patch"])
def test_post_commit_reopen_cancellation_uses_frozen_task_ids(
    client, auth_headers, wait_for_terminal, monkeypatch, reopen_path,
):
    cid = _manuscript(client, auth_headers)["id"]
    old_extractor, new_extractor = _BlockedExtractor(), _BlockedExtractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: old_extractor
    old_response = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                               json={"override_checker": True})
    old_response.raise_for_status()
    assert old_extractor.entered.wait(5)
    old = write_registry.get_live(cid)
    committed, release_cancel = Event(), Event()
    original_cancel = routes._cancel_local_job_ids
    frozen_ids = []

    def delayed_cancel(chapter_id, job_ids):
        frozen_ids.extend(job_ids)
        committed.set()
        assert release_cancel.wait(10)
        original_cancel(chapter_id, job_ids)

    monkeypatch.setattr(routes, "_cancel_local_job_ids", delayed_cancel)
    url = f"/api/v1/chapters/{cid}" + ("" if reopen_path == "patch" else f"/{reopen_path}")
    request = client.patch if reopen_path == "patch" else client.post
    payload = {"draft_text": "改稿。" if reopen_path == "patch" else "原稿。"} if reopen_path != "reopen" else {}
    new = None
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            reopening = pool.submit(request, url, headers=auth_headers, json=payload)
            try:
                assert committed.wait(5)
                assert old.job_id in frozen_ids
                assert _state(cid)[1] == "draft_ready"
                old_extractor.release.set()
                old.thread.join(5)
                assert not old.thread.is_alive() and old.is_terminal
                client.app.dependency_overrides[get_extractor_client] = lambda: new_extractor
                new_response = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                                           json={"override_checker": True})
                new_response.raise_for_status()
                assert new_extractor.entered.wait(5)
                new = write_registry.get_live(cid)
                assert new is not None and new.job_id not in frozen_ids
                new_state = _state(cid)
            finally:
                release_cancel.set()
            reopening.result(5).raise_for_status()
        assert _state(cid) == new_state and not new.cancel_event.is_set()
        with db_module.SessionLocal() as db:
            assert db.get(JobRun, old.job_id).phase == "cancelled"
            assert db.get(JobRun, new.job_id).phase == "extracting"
        new_extractor.release.set()
        assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
    finally:
        release_cancel.set()
        old_extractor.release.set()
        new_extractor.release.set()
        old.thread.join(5)
        if new is not None:
            new.thread.join(5)


@pytest.mark.parametrize("registration_stage", ["before_reserve", "before_worker"])
def test_import_ends_committed_unregistered_extractor_and_allows_next_accept(
    client, auth_headers, wait_for_terminal, monkeypatch, registration_stage,
):
    chapter = _manuscript(client, auth_headers)
    cid = chapter["id"]
    entered, release = Event(), Event()
    extractor = V2Extractor()
    late_jobs = []
    original_launch = write_registry.launch

    def blocked_config():
        entered.set()
        assert release.wait(10)
        return extractor

    def blocked_launch(job, session_factory):
        if job.kind == "extract":
            late_jobs.append(job)
            entered.set()
            assert release.wait(10)
        original_launch(job, session_factory)

    client.app.dependency_overrides[get_extractor_client] = (
        blocked_config if registration_stage == "before_reserve" else (lambda: extractor)
    )
    if registration_stage == "before_worker":
        monkeypatch.setattr(write_registry, "launch", blocked_launch)
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            accepting = pool.submit(client.post, f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                                    json={"override_checker": True})
            try:
                assert entered.wait(5)
                accepted = client.get(f"/api/v1/chapters/{cid}", headers=auth_headers).json()
                assert accepted["status"] == "finalized"
                imported = client.post(f"/api/v1/chapters/{cid}/import", headers={
                    **auth_headers, "If-Match": str(accepted["content_revision"]),
                }, json={"draft_text": accepted["draft_text"]})
                imported.raise_for_status()
                assert imported.json()["archive"]["status"] == "stale"
                with db_module.SessionLocal() as db:
                    old_run = db.scalar(select(JobRun).where(JobRun.chapter_id == cid, JobRun.kind == "extract"))
                    old_id = old_run.id
                    assert old_run.phase == "cancelled" and old_run.finished_at is not None
                    assert db.get(ChapterArchiveRevision, old_run.archive_revision_id).status == "stale"
            finally:
                release.set()
            accepting.result(5).raise_for_status()
        for job in late_jobs:
            job.thread.join(5)
        old = write_registry.get(cid)
        if old is not None and old.thread is not None:
            old.thread.join(5)
        assert _state(cid)[1] == "draft_ready" and extractor.calls == 0
        with db_module.SessionLocal() as db:
            assert db.get(JobRun, old_id).phase == "cancelled"
        monkeypatch.setattr(write_registry, "launch", original_launch)
        client.app.dependency_overrides[get_extractor_client] = FakeExtractor
        client.post(f"/api/v1/chapters/{cid}/check/start", headers=auth_headers).raise_for_status()
        assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
        resumed = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                              json={"allow_short_draft": True})
        resumed.raise_for_status()
        assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
    finally:
        release.set()


@pytest.mark.parametrize("prior_reopened", [False, True])
def test_extract_startup_prior_state_drift_finishes_archive_and_allows_retry(
    client, auth_headers, wait_for_terminal, monkeypatch, prior_reopened,
):
    book, character, first = _book_character_chapter(client, auth_headers)
    extractor = V2Extractor(with_state=True)
    client.app.dependency_overrides[get_extractor_client] = lambda: extractor
    client.post(f"/api/v1/chapters/{first['id']}/accept", headers=auth_headers,
                json={"override_checker": True}).raise_for_status()
    assert wait_for_terminal(client, first["id"], auth_headers)["phase"] == "done"
    later = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
                        json={"character_links": [{"character_id": character["id"]}]}).json()
    cid = later["id"]
    client.post(f"/api/v1/chapters/{cid}/import", headers=auth_headers,
                json={"draft_text": "林夕继续在门边等待。"}).raise_for_status()
    queued = []
    original_launch = write_registry.launch

    def delayed_launch(job, session_factory):
        queued.append((job, session_factory))

    monkeypatch.setattr(write_registry, "launch", delayed_launch)
    accepted = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                           json={"override_checker": True})
    accepted.raise_for_status()
    assert len(queued) == 1
    before = client.get(f"/api/v1/chapters/{cid}", headers=auth_headers).json()
    if prior_reopened:
        client.post(f"/api/v1/chapters/{first['id']}/reopen", headers=auth_headers).raise_for_status()
    calls_before = extractor.calls
    job, session_factory = queued[0]
    original_launch(job, session_factory)
    job.thread.join(5)
    assert not job.thread.is_alive()
    detail = client.get(f"/api/v1/chapters/{cid}", headers=auth_headers).json()
    listing = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    summary = next(row for row in listing if row["id"] == cid)
    assert detail["status"] == "finalized" and detail["draft_text"] == before["draft_text"]
    with db_module.SessionLocal() as db:
        run = db.get(JobRun, accepted.json()["job_id"])
        revision = db.get(ChapterArchiveRevision, run.archive_revision_id)
        assert run.phase == ("cancelled" if prior_reopened else "done")
        assert revision.status == ("stale" if prior_reopened else "complete")
        assert revision.finished_at is not None and run.finished_at is not None
        assert revision.is_active is not prior_reopened
        assert db.get(Chapter, cid).archive_status == revision.status
        assert not db.scalar(select(ChapterArchiveRevision.id).where(
            ChapterArchiveRevision.chapter_id == cid,
            ChapterArchiveRevision.status.in_(("pending", "extracting")),
        ))
    assert detail["archive"]["status"] == ("stale" if prior_reopened else "complete")
    assert detail["archive"]["can_retry"] is prior_reopened
    assert summary["archive_can_retry"] is prior_reopened
    assert extractor.calls == calls_before + (0 if prior_reopened else 1)
    if prior_reopened:
        assert detail["content_revision"] > before["content_revision"]
        monkeypatch.setattr(write_registry, "launch", original_launch)
        readiness = client.get(f"/api/v1/chapters/{cid}/production-readiness", headers=auth_headers).json()
        retry = client.post(f"/api/v1/chapters/{cid}/archive/retry", headers={
            **auth_headers, "If-Match": str(detail["content_revision"]),
        }, json={"acknowledged_context_token": readiness["context_token"]})
        retry.raise_for_status()
        assert retry.json()["job_id"] != accepted.json()["job_id"]
        assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
        recovered = client.get(f"/api/v1/chapters/{cid}", headers=auth_headers).json()
        assert recovered["status"] == "finalized" and recovered["draft_text"] == before["draft_text"]
        assert recovered["archive"]["status"] == "complete" and extractor.calls == calls_before + 1


@pytest.mark.parametrize("old_revision_status", ["pending", "extracting"])
@pytest.mark.parametrize("new_running", [False, True])
def test_stale_extract_startup_only_finishes_its_frozen_revision(
    client, auth_headers, wait_for_terminal, monkeypatch, old_revision_status, new_running,
):
    cid = _manuscript(client, auth_headers)["id"]
    old_extractor = V2Extractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: old_extractor
    queued = []
    original_launch = write_registry.launch
    monkeypatch.setattr(write_registry, "launch", lambda job, sf: queued.append((job, sf)))
    accepted = client.post(f"/api/v1/chapters/{cid}/accept", headers=auth_headers,
                           json={"override_checker": True})
    accepted.raise_for_status()
    old, session_factory = queued[0]
    # Reproduce the durable orphan left by the previous startup guard. An
    # explicit retry may already own a newer revision when this old worker is
    # eventually scheduled; cleaning its old revision must not end that retry.
    with db_module.SessionLocal() as db:
        run = db.get(JobRun, old.job_id)
        run.phase = "cancelled"
        run.error_code = "synthetic_registered_stopped"
        run.finished_at = utc_now()
        db.get(ChapterArchiveRevision, run.archive_revision_id).status = old_revision_status
        db.commit()
    old.mark_terminal("cancelled")
    monkeypatch.setattr(write_registry, "launch", original_launch)
    newer_extractor = _BlockedExtractor() if new_running else FakeExtractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: newer_extractor
    newer_response = client.post(f"/api/v1/chapters/{cid}/archive/retry", headers=auth_headers)
    newer_response.raise_for_status()
    newer = write_registry.get(cid)
    assert newer is not old
    try:
        if new_running:
            assert newer_extractor.entered.wait(5)
        else:
            assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
        owned_state = _state(cid)
        original_launch(old, session_factory)
        old.thread.join(5)
        assert not old.thread.is_alive() and _state(cid) == owned_state
        assert not newer.cancel_event.is_set() and old_extractor.calls == 0
        with db_module.SessionLocal() as db:
            old_run = db.get(JobRun, old.job_id)
            old_revision = db.get(ChapterArchiveRevision, old_run.archive_revision_id)
            new_run = db.get(JobRun, newer_response.json()["job_id"])
            new_revision = db.get(ChapterArchiveRevision, new_run.archive_revision_id)
            assert old_run.phase == "cancelled" and old_run.error_code == "synthetic_registered_stopped"
            assert old_revision.status == "stale" and old_revision.finished_at is not None
            assert not old_revision.is_active
            assert new_run.phase == ("extracting" if new_running else "done")
            assert new_revision.status == ("extracting" if new_running else "complete")
        if new_running:
            newer_extractor.release.set()
            assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
        detail = client.get(f"/api/v1/chapters/{cid}", headers=auth_headers).json()
        assert detail["status"] == "finalized" and detail["draft_text"] == "原稿。"
        assert detail["archive"]["status"] == "complete"
    finally:
        if new_running:
            newer_extractor.release.set()
        if old.thread is not None:
            old.thread.join(5)
        newer.thread.join(5)
