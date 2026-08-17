"""v2.0.4: the last-chapter delete gate and the read-only rewrite preview."""

from __future__ import annotations

import re
import sqlite3
from threading import Event

import pytest
from sqlalchemy import event, select
from sqlalchemy.exc import OperationalError

import app.db as db_module
import app.routers.chapters as chapters_router
from app.llm.factory import get_extractor_client, get_writer_client
from app.models import Chapter, JobRun
from app.services.write_jobs import write_registry


class SnapshotExtractor:
    """v2 Extractor stub emitting one traceable fact and a controlled snapshot."""

    def __init__(self, character_name: str, fields: dict[str, str | None]) -> None:
        self.character_name = character_name
        self.fields = fields

    def complete_json(self, *, user: str, **kwargs):
        span_id = re.search(r"\[(P\d{4}-S\d{2})\]", user).group(1)
        fact = {
            "fact_ref": "F1",
            "type": "状态",
            "importance": 3,
            "text": f"{self.character_name}的章末状态发生变化。",
            "participant_names": [self.character_name],
            "start_id": span_id,
            "end_id": span_id,
        }
        deltas = [
            {
                "fact_ref": "F1",
                "character_name": self.character_name,
                "other_character_name": None,
                "scope": "snapshot",
                "slot": slot,
                "operation": "set" if self.fields.get(slot) else "clear",
                "value": self.fields.get(slot),
            }
            for slot in ("当前位置", "当前行动", "情绪状态")
        ]
        return {"summary": "梗概。", "facts": [fact], "end_state_delta": deltas}


class BlockingWriter:
    """Holds the write job open until the test releases it."""

    def __init__(self, text: str = "候选" * 2000) -> None:
        self.text = text
        self.last_finish_reason = "stop"
        self.started = Event()
        self.release = Event()

    def complete_stream(self, **_kwargs):
        self.started.set()
        assert self.release.wait(timeout=3)
        yield from self.text

    def complete(self, **_kwargs):
        return self.text

    def complete_json(self, **_kwargs):
        return {}


class CancellableWriter:
    """Blocks inside the writer until the job is cancelled.

    Unlike `BlockingWriter` this one watches the job's cancel event, so a
    handler that really cancels lets it finish immediately while a handler that
    forgets leaves `saw_cancel` false until the timeout expires.
    """

    def __init__(self, text: str = "候选" * 2000) -> None:
        self.text = text
        self.last_finish_reason = "stop"
        self.started = Event()
        self.saw_cancel = False

    def complete_stream(self, *, cancel_event=None, **_kwargs):
        self.started.set()
        self.saw_cancel = bool(cancel_event is not None and cancel_event.wait(timeout=3))
        yield from self.text

    def complete(self, **_kwargs):
        return self.text

    def complete_json(self, **_kwargs):
        return {}


def _book(client, auth_headers) -> dict:
    return client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()


def _character(client, auth_headers, book_id: str, name: str) -> dict:
    return client.post(
        f"/api/v1/books/{book_id}/characters", headers=auth_headers, json={"name": name}
    ).json()


def _chapter(client, auth_headers, book_id: str, title: str, character_ids: list[str]) -> dict:
    return client.post(
        f"/api/v1/books/{book_id}/chapters",
        headers=auth_headers,
        json={
            "title": title,
            "user_prompt": "行动",
            "character_links": [{"character_id": cid} for cid in character_ids],
        },
    ).json()


def _accept(client, auth_headers, wait_for_terminal, chapter_id, *, draft, name, fields):
    client.app.dependency_overrides[get_extractor_client] = lambda: SnapshotExtractor(name, fields)
    client.post(
        f"/api/v1/chapters/{chapter_id}/import", headers=auth_headers, json={"draft_text": draft}
    ).raise_for_status()
    client.post(
        f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers, json={"override_checker": True}
    ).raise_for_status()
    assert wait_for_terminal(client, chapter_id, auth_headers)["phase"] == "done"


def _archive(client, auth_headers, chapter_id: str) -> dict:
    return client.get(f"/api/v1/chapters/{chapter_id}", headers=auth_headers).json()["archive"]


def _preview(client, auth_headers, chapter_id: str) -> dict:
    response = client.get(f"/api/v1/chapters/{chapter_id}/rewrite-preview", headers=auth_headers)
    response.raise_for_status()
    return response.json()


def _fields(client, auth_headers, character_id: str) -> dict:
    return client.get(f"/api/v1/characters/{character_id}", headers=auth_headers).json()["dynamic_fields"]


def _job_run_states(chapter_ids: list[str]) -> list[tuple[str, str | None]]:
    """Read job_runs straight from storage; there is no public API for them."""
    db = db_module.SessionLocal()
    try:
        runs = db.scalars(
            select(JobRun).where(JobRun.chapter_id.in_(chapter_ids)).order_by(JobRun.chapter_id)
        ).all()
        return [(run.phase, run.error_code) for run in runs]
    finally:
        db.close()


def test_delete_rejected_request_does_not_cancel_live_write(client, auth_headers, wait_for_terminal):
    # The pre-v2.0.4 handler cancelled the live job before deciding anything,
    # so a delete that was about to be refused still destroyed the author's
    # running generation. The gate must come first.
    book = _book(client, auth_headers)
    first = _chapter(client, auth_headers, book["id"], "第一章", [])
    _chapter(client, auth_headers, book["id"], "第二章", [])

    writer = BlockingWriter()
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    started = client.post(f"/api/v1/chapters/{first['id']}/write", headers=auth_headers).json()
    assert started["job_id"]
    assert writer.started.wait(timeout=3)

    rejected = client.delete(f"/api/v1/chapters/{first['id']}", headers=auth_headers)
    assert rejected.status_code == 409
    assert rejected.json()["detail"]["code"] == "chapter_not_last"

    writer.release.set()
    live = write_registry.get(first["id"])
    if live is not None and live.thread is not None:
        live.thread.join(timeout=5)
    terminal = wait_for_terminal(client, first["id"], auth_headers)
    assert terminal["phase"] == "done"
    assert terminal["job_id"] == started["job_id"]
    assert client.get(f"/api/v1/chapters/{first['id']}", headers=auth_headers).json()["draft_text"] == writer.text


def test_accepted_delete_cancels_the_live_write_job(client, auth_headers):
    # The mirror image of the test above, and the reason the cancel block still
    # earns its place: once the gate lets the delete through, a write job still
    # running against the chapter must be stopped and waited for, so nothing is
    # racing toward a commit as the row disappears.
    book = _book(client, auth_headers)
    _chapter(client, auth_headers, book["id"], "第一章", [])
    last = _chapter(client, auth_headers, book["id"], "第二章", [])

    writer = CancellableWriter()
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    started = client.post(f"/api/v1/chapters/{last['id']}/write", headers=auth_headers).json()
    assert started["job_id"]
    assert writer.started.wait(timeout=3)
    job = write_registry.get(last["id"])
    assert job is not None and not job.is_terminal

    assert client.delete(f"/api/v1/chapters/{last['id']}", headers=auth_headers).status_code == 204

    assert writer.saw_cancel is True
    assert job.phase == "cancelled"
    assert job.is_terminal is True
    # Waited for, not merely signalled.
    assert job.thread is not None and not job.thread.is_alive()

    # Nothing the cancelled job was carrying reached storage.
    assert client.get(f"/api/v1/chapters/{last['id']}", headers=auth_headers).status_code == 404
    listed = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    assert [item["index"] for item in listed] == [1]
    assert _job_run_states([last["id"]]) == []


def test_delete_reindexes_and_invalidates_writer_inputs_of_later_chapters(client, auth_headers):
    """Cover the reindex + M6 branch of `delete_chapter` by racing its gate.

    On the normal path the last-chapter gate keeps `following` empty. The gate's
    SELECT runs outside any transaction though -- pysqlite opens one only at the
    first DML -- so a chapter created by another session between the gate and
    `db.delete` really is renumbered by that loop, and really can be holding an
    in-flight write job. Reproduce exactly that window with a `before_flush`
    hook: at that point the deleting session has issued nothing but SELECTs and
    holds no write lock, so the second session's commit goes through.
    """
    book = _book(client, auth_headers)
    doomed = _chapter(client, auth_headers, book["id"], "第一章", [])
    created: list[str] = []

    session = db_module.SessionLocal()

    def _create_later_chapters(_session, _flush_context, _instances) -> None:
        if created:
            return
        other = db_module.SessionLocal()
        try:
            for index, title in ((2, "第二章"), (3, "第三章")):
                chapter = Chapter(book_id=book["id"], index=index, title=title, status="writing")
                other.add(chapter)
                other.flush()
                other.add(
                    JobRun(
                        chapter_id=chapter.id,
                        kind="write",
                        phase="writing",
                        chapter_write_generation=chapter.write_generation,
                    )
                )
                created.append(chapter.id)
            other.commit()
        finally:
            other.close()

    event.listen(session, "before_flush", _create_later_chapters)
    try:
        response = chapters_router.delete_chapter(doomed["id"], session)
    finally:
        event.remove(session, "before_flush", _create_later_chapters)
        session.close()
    assert response.status_code == 204
    assert len(created) == 2

    listed = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    assert [(item["id"], item["index"]) for item in listed] == [(created[0], 1), (created[1], 2)]

    fresh = db_module.SessionLocal()
    try:
        rows = fresh.scalars(
            select(Chapter).where(Chapter.id.in_(created)).order_by(Chapter.index)
        ).all()
        # M6: the renumbered chapters' persistent write generation advances, so
        # a Writer thread still holding the old token can no longer promote.
        assert [row.write_generation for row in rows] == [1, 1]
        assert [row.status for row in rows] == ["draft", "draft"]
    finally:
        fresh.close()
    assert _job_run_states(created) == [("cancelled", "chapter_changed")] * 2


def test_rewrite_preview_matches_actual_reopen_cascade(client, auth_headers, wait_for_terminal):
    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"], "林夕")
    chapters = [
        _chapter(client, auth_headers, book["id"], title, [character["id"]])
        for title in ("第一章", "第二章", "第三章")
    ]
    for chapter, place in zip(chapters, ("北境", "南港", "东海")):
        _accept(
            client, auth_headers, wait_for_terminal, chapter["id"],
            draft="林夕行动", name="林夕", fields={"当前位置": place},
        )

    preview = _preview(client, auth_headers, chapters[0]["id"])
    assert preview["chapter_id"] == chapters[0]["id"]
    assert preview["index"] == 1
    assert [(item["id"], item["index"], item["title"]) for item in preview["affected_chapters"]] == [
        (chapters[1]["id"], 2, "第二章"),
        (chapters[2]["id"], 3, "第三章"),
    ]

    # Now really do it, and hold the preview to the outcome.
    client.post(f"/api/v1/chapters/{chapters[0]['id']}/reopen", headers=auth_headers).raise_for_status()
    listed = client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json()
    actually_stale = [
        item["id"] for item in listed if item["index"] > 1 and item["archive_status"] == "stale"
    ]
    assert actually_stale == [item["id"] for item in preview["affected_chapters"]]


def test_rewrite_preview_excludes_independent_storyline(client, auth_headers, wait_for_terminal):
    # Staleness follows the `prior_state` fingerprint, which covers only each
    # chapter's own selected characters. A downstream chapter that shares no
    # character with the rewritten one keeps its archive, so an implementation
    # that answers "every later chapter" fails here.
    book = _book(client, auth_headers)
    lin = _character(client, auth_headers, book["id"], "林夕")
    shen = _character(client, auth_headers, book["id"], "沈舟")
    first = _chapter(client, auth_headers, book["id"], "林夕线", [lin["id"]])
    second = _chapter(client, auth_headers, book["id"], "沈舟线", [shen["id"]])
    _accept(
        client, auth_headers, wait_for_terminal, first["id"],
        draft="林夕行动", name="林夕", fields={"当前位置": "北境"},
    )
    _accept(
        client, auth_headers, wait_for_terminal, second["id"],
        draft="沈舟行动", name="沈舟", fields={"当前位置": "南港"},
    )
    assert _archive(client, auth_headers, second["id"])["status"] == "complete"

    assert _preview(client, auth_headers, first["id"])["affected_chapters"] == []

    # And the real reopen agrees: the independent line survives untouched.
    client.post(f"/api/v1/chapters/{first['id']}/reopen", headers=auth_headers).raise_for_status()
    assert _archive(client, auth_headers, second["id"])["status"] == "complete"


def test_rewrite_preview_splits_a_mixed_downstream(client, auth_headers, wait_for_terminal):
    # The two tests either side of this one cover the extremes: everything
    # downstream shares the rewritten chapter's character, or nothing does. The
    # answer that actually needs the server is the mixed one, where the preview
    # has to name a strict subset of the later chapters.
    book = _book(client, auth_headers)
    lin = _character(client, auth_headers, book["id"], "林夕")
    shen = _character(client, auth_headers, book["id"], "沈舟")
    first = _chapter(client, auth_headers, book["id"], "林夕线一", [lin["id"]])
    dependent = _chapter(client, auth_headers, book["id"], "林夕线二", [lin["id"]])
    independent = _chapter(client, auth_headers, book["id"], "沈舟线", [shen["id"]])
    _accept(
        client, auth_headers, wait_for_terminal, first["id"],
        draft="林夕行动", name="林夕", fields={"当前位置": "北境"},
    )
    _accept(
        client, auth_headers, wait_for_terminal, dependent["id"],
        draft="林夕行动", name="林夕", fields={"当前位置": "南港"},
    )
    _accept(
        client, auth_headers, wait_for_terminal, independent["id"],
        draft="沈舟行动", name="沈舟", fields={"当前位置": "东海"},
    )

    preview = _preview(client, auth_headers, first["id"])
    assert [(item["id"], item["index"]) for item in preview["affected_chapters"]] == [
        (dependent["id"], 2)
    ]

    client.post(f"/api/v1/chapters/{first['id']}/reopen", headers=auth_headers).raise_for_status()
    dependent_archive = _archive(client, auth_headers, dependent["id"])
    assert dependent_archive["status"] == "stale"
    assert dependent_archive["error_code"] == "prior_state_changed"
    # The later, unrelated chapter keeps its archive even though it sits behind
    # the staled one: index order is not what drives the cascade.
    assert _archive(client, auth_headers, independent["id"])["status"] == "complete"


def test_rewrite_preview_reports_a_busy_database_instead_of_a_bare_500(
    client, auth_headers, monkeypatch
):
    # The cascade flushes, so the preview takes SQLite's write lock and can
    # collide with a live Writer/Extractor commit. Provoking a real lock would
    # cost pysqlite's five-second busy timeout per run, so the collision is
    # injected at the one call that flushes; what is under test is the error
    # surface, not SQLite.
    book = _book(client, auth_headers)
    chapter = _chapter(client, auth_headers, book["id"], "第一章", [])

    def _locked(*_args, **_kwargs):
        raise OperationalError("UPDATE …", {}, sqlite3.OperationalError("database is locked"))

    monkeypatch.setattr(chapters_router, "invalidate_downstream_archives", _locked)
    response = client.get(f"/api/v1/chapters/{chapter['id']}/rewrite-preview", headers=auth_headers)
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "rewrite_preview_busy"

    def _broken(*_args, **_kwargs):
        raise OperationalError("SELECT 1", {}, sqlite3.OperationalError("no such column: nope"))

    # Only lock contention is transient. Anything else must stay loud rather
    # than be relabelled as a retryable conflict.
    monkeypatch.setattr(chapters_router, "invalidate_downstream_archives", _broken)
    with pytest.raises(OperationalError):
        client.get(f"/api/v1/chapters/{chapter['id']}/rewrite-preview", headers=auth_headers)


def test_rewrite_preview_is_read_only(client, auth_headers, wait_for_terminal):
    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"], "林夕")
    chapters = [
        _chapter(client, auth_headers, book["id"], title, [character["id"]])
        for title in ("第一章", "第二章")
    ]
    for chapter, place in zip(chapters, ("北境", "南港")):
        _accept(
            client, auth_headers, wait_for_terminal, chapter["id"],
            draft="林夕行动", name="林夕", fields={"当前位置": place},
        )

    def snapshot() -> dict:
        return {
            "archives": {
                chapter["id"]: {
                    key: _archive(client, auth_headers, chapter["id"])[key]
                    for key in ("status", "revision_id", "revision", "summary")
                }
                for chapter in chapters
            },
            "fields": _fields(client, auth_headers, character["id"]),
            "chapters": client.get(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers).json(),
        }

    before = snapshot()
    assert before["archives"][chapters[1]["id"]]["status"] == "complete"
    assert before["fields"] == {"当前位置": "南港"}

    first_call = _preview(client, auth_headers, chapters[0]["id"])
    second_call = _preview(client, auth_headers, chapters[0]["id"])
    # A preview that committed anything would report an empty cascade the
    # second time round, because the first call would already have staled it.
    assert first_call == second_call
    assert first_call["affected_chapters"] != []
    assert snapshot() == before


def test_rewrite_preview_for_last_chapter_is_empty_and_unknown_chapter_404(
    client, auth_headers, wait_for_terminal
):
    book = _book(client, auth_headers)
    character = _character(client, auth_headers, book["id"], "林夕")
    chapters = [
        _chapter(client, auth_headers, book["id"], title, [character["id"]])
        for title in ("第一章", "第二章")
    ]
    for chapter, place in zip(chapters, ("北境", "南港")):
        _accept(
            client, auth_headers, wait_for_terminal, chapter["id"],
            draft="林夕行动", name="林夕", fields={"当前位置": place},
        )

    last = _preview(client, auth_headers, chapters[1]["id"])
    assert last["chapter_id"] == chapters[1]["id"]
    assert last["index"] == 2
    assert last["affected_chapters"] == []

    missing = client.get("/api/v1/chapters/does-not-exist/rewrite-preview", headers=auth_headers)
    assert missing.status_code == 404
    assert missing.json()["detail"] == "chapter not found"
