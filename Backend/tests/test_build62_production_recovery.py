"""Real HTTP/SQLite concurrency, synthetic prose/models, no external requests."""
from concurrent.futures import ThreadPoolExecutor, TimeoutError
from threading import Event, local

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

import app.db as db_module
import app.routers.chapters as routes
import app.services.archive_v2 as archives
import app.services.content_revisions as revisions
import app.services.write_jobs as jobs
from app.llm.factory import get_checker_client, get_extractor_client, get_writer_client
from app.models import Chapter, ChapterArchiveRevision, ChapterDraftCandidate, JobRun
from test_v1_8_archive import V2Extractor, _book_character_chapter
from conftest import FakeWriter


def current(client, headers, chapter_id):
    response = client.get(f"/api/v1/chapters/{chapter_id}", headers=headers)
    response.raise_for_status()
    return response.json()


def conditional(headers, chapter):
    return {**headers, "If-Match": str(chapter["content_revision"])}


def accept(client, headers, chapter_id):
    response = client.post(
        f"/api/v1/chapters/{chapter_id}/accept",
        headers=conditional(headers, current(client, headers, chapter_id)),
        json={"override_checker": True, "allow_short_draft": True},
    )
    response.raise_for_status()
    return response.json()


@pytest.mark.parametrize("edit_prior", [False, True])
def test_archive_final_proof_serializes_concurrent_edit(
    client, auth_headers, wait_for_terminal, monkeypatch, edit_prior,
):
    book, character, first = _book_character_chapter(client, auth_headers)
    client.app.dependency_overrides[get_extractor_client] = lambda: V2Extractor(with_state=True)
    target = first
    if edit_prior:
        accept(client, auth_headers, first["id"])
        assert wait_for_terminal(client, first["id"], auth_headers)["phase"] == "done"
        response = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
                               json={"user_prompt": "继续等待", "character_links": [{"character_id": character["id"]}]})
        response.raise_for_status()
        target = response.json()
        client.post(f"/api/v1/chapters/{target['id']}/import", headers=auth_headers,
                    json={"draft_text": "林夕继续等待。"}).raise_for_status()

    proof, release, contender = Event(), Event(), Event()
    worker = local()
    original_activate = jobs.activate_archive_revision
    original_fingerprint = archives.archive_input_fingerprint
    original_cas = revisions.begin_sqlite_write_cas

    def activate(*args, **kwargs):
        worker.activating = True
        try:
            return original_activate(*args, **kwargs)
        finally:
            worker.activating = False

    def fingerprint(chapter, **kwargs):
        result = original_fingerprint(chapter, **kwargs)
        if getattr(worker, "activating", False) and chapter.id == target["id"]:
            proof.set()
            assert release.wait(8)
        return result

    def competing_cas(db):
        if proof.is_set():
            contender.set()
        return original_cas(db)

    monkeypatch.setattr(jobs, "activate_archive_revision", activate)
    monkeypatch.setattr(archives, "archive_input_fingerprint", fingerprint)
    monkeypatch.setattr(revisions, "begin_sqlite_write_cas", competing_cas)
    accepted = accept(client, auth_headers, target["id"])
    assert proof.wait(5)
    edited = first if edit_prior else target
    headers = conditional(auth_headers, current(client, auth_headers, edited["id"]))
    with ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(
            client.post if edit_prior else client.patch,
            f"/api/v1/chapters/{edited['id']}" + ("/reopen" if edit_prior else ""),
            headers=headers, **({} if edit_prior else {"json": {"draft_text": "林夕离开门边。"}}),
        )
        try:
            assert contender.wait(3), "competing request must reach its real SQLite CAS"
            with pytest.raises(TimeoutError):
                future.result(timeout=0.2)
        finally:
            release.set()
        response = future.result(timeout=8)
    jobs.write_registry.get(target["id"]).thread.join(timeout=5)
    assert response.status_code == (200 if edit_prior else 409)
    result = current(client, auth_headers, target["id"])
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, target["id"])
        run = db.get(JobRun, accepted["job_id"])
        revision = db.get(ChapterArchiveRevision, run.archive_revision_id)
        assert not revision.is_active or revision.input_fingerprint == original_fingerprint(chapter)
    if edit_prior:
        assert result["archive"]["status"] == "stale"
        assert result["archive"]["can_retry"] is True
    else:
        assert result["archive"]["status"] == "complete"
        assert result["draft_text"] != "林夕离开门边。"


@pytest.mark.parametrize("with_revision", [False, True])
@pytest.mark.parametrize("owner_kind", ["accept", "extract"])
def test_replace_write_cannot_cancel_accept_or_extract_owner(
    client, auth_headers, owner_kind, with_revision,
):
    _, _, chapter = _book_character_chapter(client, auth_headers)
    owner = jobs.WriteJob(chapter_id=chapter["id"], job_id="protected-owner", kind=owner_kind)
    jobs.write_registry.reserve(owner)
    headers = conditional(auth_headers, current(client, auth_headers, chapter["id"])) if with_revision else auth_headers
    try:
        response = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=headers,
                               json={"replace_draft": True})
        assert response.status_code == 409
        assert jobs.write_registry.get_live(chapter["id"]) is owner
        assert not owner.cancel_event.is_set()
    finally:
        owner.mark_terminal("done")


def test_legacy_write_racing_accept_rechecks_finalized_under_lock(
    client, auth_headers, wait_for_terminal, monkeypatch,
):
    _, _, chapter = _book_character_chapter(client, auth_headers)
    entered, release, writer_started = Event(), Event(), Event()
    original_start = routes._start_archive_job
    original_cas = routes._begin_short_write_cas

    def start(*args, **kwargs):
        entered.set()  # accept owns its final SQLite transaction
        assert release.wait(8)
        return original_start(*args, **kwargs)

    def cas(db):
        if entered.is_set():
            writer_started.set()
        return original_cas(db)

    monkeypatch.setattr(routes, "_start_archive_job", start)
    monkeypatch.setattr(routes, "_begin_short_write_cas", cas)
    with ThreadPoolExecutor(max_workers=2) as pool:
        accepting = pool.submit(accept, client, auth_headers, chapter["id"])
        assert entered.wait(3)
        writing = pool.submit(client.post, f"/api/v1/chapters/{chapter['id']}/write",
                              headers=auth_headers, json={"replace_draft": True})
        try:
            assert writer_started.wait(3)
        finally:
            release.set()
        accepting.result(timeout=8)
        response = writing.result(timeout=8)
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "chapter_finalized"
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    assert current(client, auth_headers, chapter["id"])["status"] == "finalized"


def test_preexisting_mismatched_complete_archive_has_explicit_recovery(
    client, auth_headers, wait_for_terminal,
):
    from app.services.character_state_projection import projected_state_before_chapter
    book, character, chapter = _book_character_chapter(client, auth_headers)
    client.app.dependency_overrides[get_extractor_client] = lambda: V2Extractor(with_state=True, state_location="北境")
    accept(client, auth_headers, chapter["id"])
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    response = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
                           json={"character_links": [{"character_id": character["id"]}]})
    response.raise_for_status()
    later_id = response.json()["id"]
    with db_module.SessionLocal() as db:
        revision = db.scalars(select(ChapterArchiveRevision).where(ChapterArchiveRevision.chapter_id == chapter["id"])).one()
        revision.input_fingerprint = "synthetic-preexisting-race"
        db.commit()
        fields, uncertainties = projected_state_before_chapter(db, db.get(Chapter, later_id))
        assert fields[character["id"]] == {} and uncertainties == []
    result = current(client, auth_headers, chapter["id"])
    assert result["archive"]["status"] == "stale"
    assert result["archive"]["schema"] == "none"
    assert result["archive"]["facts"] == []
    assert result["archive"]["can_retry"] is True
    listing = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    listed = next(item for item in listing if item["id"] == chapter["id"])
    assert listed["archive_status"] == "stale" and listed["archive_can_retry"] is True
    client.app.dependency_overrides[get_extractor_client] = lambda: V2Extractor(invalid_span=True)
    client.post(f"/api/v1/chapters/{chapter['id']}/archive/retry",
                headers=conditional(auth_headers, result), json={}).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "failed"
    result = current(client, auth_headers, chapter["id"])
    assert result["archive"]["status"] != "complete"
    assert result["archive"]["schema"] == "none" and result["archive"]["can_retry"] is True
    listing = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    listed = next(item for item in listing if item["id"] == chapter["id"])
    assert listed["archive_status"] == result["archive"]["status"]
    assert listed["archive_can_retry"] is True
    client.app.dependency_overrides[get_extractor_client] = lambda: V2Extractor(with_state=True, state_location="南境")
    client.post(f"/api/v1/chapters/{chapter['id']}/archive/retry",
                headers=conditional(auth_headers, result), json={}).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    assert current(client, auth_headers, chapter["id"])["archive"]["schema"] == "v2"
    with db_module.SessionLocal() as db:
        fields, _ = projected_state_before_chapter(db, db.get(Chapter, later_id))
        assert fields[character["id"]]["当前位置"] == "南境"


@pytest.mark.parametrize("commit_fails", [False, True])
def test_conditional_replacement_settles_both_jobs_without_waiting_on_its_own_lock(
    client, auth_headers, wait_for_terminal, monkeypatch, commit_fails,
):
    _, _, chapter = _book_character_chapter(client, auth_headers)
    started, release = Event(), Event()

    class BlockedWriter(FakeWriter):
        def complete_stream(self, **kwargs):
            started.set()
            assert release.wait(8)
            yield from super().complete_stream(**kwargs)

    client.app.dependency_overrides[get_writer_client] = lambda: BlockedWriter("夜色渐深。" * 1000)
    path = f"/api/v1/chapters/{chapter['id']}/write"
    first = client.post(path, headers=auth_headers, json={"replace_draft": True})
    first.raise_for_status()
    assert started.wait(3)
    old = jobs.write_registry.get(chapter["id"])
    before = current(client, auth_headers, chapter["id"])
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("风声渐弱。" * 1000)
    original_commit = Session.commit
    failed_once = False

    def fail_replacement_commit(db):
        nonlocal failed_once
        if commit_fails and old.cancel_event.is_set() and not failed_once:
            failed_once = True
            raise RuntimeError("synthetic replacement commit failure")
        return original_commit(db)

    monkeypatch.setattr(Session, "commit", fail_replacement_commit)
    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            request = pool.submit(client.post, path, headers=conditional(auth_headers, before),
                                  json={"replace_draft": True})
            if commit_fails:
                with pytest.raises(RuntimeError, match="replacement commit failure"):
                    request.result(timeout=3)
            else:
                request.result(timeout=3).raise_for_status()
                assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    finally:
        release.set()
        old.thread.join(timeout=5)
    with db_module.SessionLocal() as db:
        old_run = db.get(JobRun, first.json()["job_id"])
        assert old_run.phase in {"cancelled", "failed"}
    final = current(client, auth_headers, chapter["id"])
    assert final["status"] == "draft_ready"
    if commit_fails:
        assert final["draft_text"] == before["draft_text"]
        assert jobs.write_registry.get_live(chapter["id"]) is None
    else:
        assert final["draft_text"] == "风声渐弱。" * 1000


def test_cancelled_checker_cannot_promote_during_replacement_rollback_recovery(
    client, auth_headers, wait_for_terminal, monkeypatch,
):
    _, _, chapter = _book_character_chapter(client, auth_headers)
    baseline = current(client, auth_headers, chapter["id"])["draft_text"]
    started, release, compensating, compensate = Event(), Event(), Event(), Event()

    class RetryChecker:
        calls = 0

        def complete_json(self, **kwargs):
            self.calls += 1
            if self.calls == 1:
                return {"verdict": "passed", "issues": []}  # unavailable: missing required name classification
            started.set()
            assert release.wait(8)
            return {"verdict": "passed", "issues": [], "name_uses": []}

    checker = RetryChecker()
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.app.dependency_overrides[get_writer_client] = lambda: FakeWriter("风吹过原野。" * 800)
    path = f"/api/v1/chapters/{chapter['id']}"
    first = client.post(path + "/write", headers=auth_headers, json={"replace_draft": True})
    first.raise_for_status()
    failed = wait_for_terminal(client, chapter["id"], auth_headers)
    assert failed["phase"] == "failed" and failed["can_retry_checker"] is True
    retry = client.post(path + "/checker/retry", headers=auth_headers,
                        json={"source_job_id": first.json()["job_id"]})
    retry.raise_for_status()
    assert started.wait(3)
    old = jobs.write_registry.get(chapter["id"])
    assert old.kind == "check"
    original_commit, original_compensate = Session.commit, routes.fail_unlaunched_job
    failed_once = False

    def fail_commit(db):
        nonlocal failed_once
        if old.cancel_event.is_set() and not failed_once:
            failed_once = True
            raise RuntimeError("synthetic check replacement failure")
        return original_commit(db)

    def delay_compensation(sf, job, **kwargs):
        if job is old:
            compensating.set()
            assert compensate.wait(8)
        return original_compensate(sf, job, **kwargs)

    monkeypatch.setattr(Session, "commit", fail_commit)
    monkeypatch.setattr(routes, "fail_unlaunched_job", delay_compensation)
    with ThreadPoolExecutor(max_workers=1) as pool:
        request = pool.submit(client.post, path + "/write",
                              headers=conditional(auth_headers, current(client, auth_headers, chapter["id"])),
                              json={"replace_draft": True})
        try:
            assert compensating.wait(3)
            release.set()
            old.thread.join(timeout=4)
            assert not old.thread.is_alive()
            with db_module.SessionLocal() as db:
                run = db.get(JobRun, old.job_id)
                candidate = db.get(ChapterDraftCandidate, run.candidate_id)
                assert run.phase == "cancelled" and not candidate.is_current
                assert db.get(Chapter, chapter["id"]).draft_text == baseline
        finally:
            release.set()
            compensate.set()
        with pytest.raises(RuntimeError, match="synthetic check replacement failure"):
            request.result(timeout=5)
    assert jobs.write_registry.get_live(chapter["id"]) is None
    assert current(client, auth_headers, chapter["id"])["draft_text"] == baseline
