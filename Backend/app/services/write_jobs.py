from __future__ import annotations

import json
import threading
import time
from collections.abc import Iterator
from typing import Any

from sqlalchemy.orm import Session, sessionmaker

from app.agents.memory_selector import MemorySelectorAgent
from app.agents.reviser import ReviserAgent
from app.agents.writer import WriterAgent
from app.llm.base import LLMError
from app.models import Chapter
from app.schemas.chapter import ChapterRead
from app.services.context import (
    MemoryBlock,
    draft_violations,
    pack_selected_memories,
    reviser_user_message,
    writer_user_message,
)


class WriteJobConflict(Exception):
    pass


class WriteJob:
    def __init__(
        self,
        chapter_id: str,
        writer: WriterAgent,
        reviser: ReviserAgent | None = None,
        memory_selector: MemorySelectorAgent | None = None,
        selector_user_message: str = "",
        memory_candidates: list[MemoryBlock] | None = None,
        memory_budget: int = 600,
        baseline_text: str = "",
        baseline_status: str = "draft",
        # Compatibility for the old direct unit-test constructor.
        writer_user_message: str | None = None,
        compressor: Any | None = None,
    ) -> None:
        self.chapter_id = chapter_id
        self.writer = writer
        self.reviser = reviser or compressor
        self.memory_selector = memory_selector
        self.selector_user_message = selector_user_message
        self.memory_candidates = memory_candidates or []
        self.memory_budget = memory_budget
        self.baseline_text = baseline_text
        self.baseline_status = baseline_status
        self.legacy_writer_user_message = writer_user_message
        self.condition = threading.Condition()
        self.cancel_event = threading.Event()
        self.phase = "selecting_memory" if memory_selector is not None else "writing"
        self.phase_details: dict[str, Any] = {}
        self.buffer: list[str] = []
        self.error_code: str | None = None
        self.error: str | None = None
        self.error_details: dict[str, Any] = {}
        self.done_chapter: dict[str, Any] | None = None
        self.thread: threading.Thread | None = None
        self.terminal_at: float | None = None
        self.discard_on_cancel = False

    @property
    def is_terminal(self) -> bool:
        return self.phase in {"done", "failed", "cancelled"}


class WriteJobRegistry:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jobs: dict[str, WriteJob] = {}

    def clear(self) -> None:
        with self._lock:
            self._jobs.clear()

    def reserve(self, job: WriteJob) -> None:
        with self._lock:
            existing = self._jobs.get(job.chapter_id)
            if existing is not None and not existing.is_terminal:
                raise WriteJobConflict()
            self._jobs[job.chapter_id] = job

    def get(self, chapter_id: str) -> WriteJob | None:
        with self._lock:
            return self._jobs.get(chapter_id)

    def get_live(self, chapter_id: str) -> WriteJob | None:
        job = self.get(chapter_id)
        return job if job is not None and not job.is_terminal else None

    def is_current(self, job: WriteJob) -> bool:
        with self._lock:
            return self._jobs.get(job.chapter_id) is job

    def cancel(self, job: WriteJob, *, discard: bool = False) -> None:
        job.cancel_event.set()
        with job.condition:
            job.discard_on_cancel = discard
            if not job.is_terminal:
                job.phase = "cancelled"
                job.error_code = "write_cancelled"
                job.error = "写作已取消"
                job.terminal_at = time.monotonic()
                job.condition.notify_all()

    def launch(self, job: WriteJob, session_factory: sessionmaker[Session]) -> None:
        thread = threading.Thread(target=_run_job, args=(job, session_factory), daemon=True)
        job.thread = thread
        thread.start()


write_registry = WriteJobRegistry()


def _run_job(job: WriteJob, session_factory: sessionmaker[Session]) -> None:
    db = session_factory()
    try:
        chapter = db.get(Chapter, job.chapter_id)
        if chapter is None:
            _mark_failed(job, "chapter_missing", "章节不存在")
            return
        memories: list[MemoryBlock] = []
        if job.memory_selector is not None:
            _set_phase(job, "selecting_memory")
            selected_ids = job.memory_selector.select(job.selector_user_message)
            memories = pack_selected_memories(job.memory_candidates, selected_ids, job.memory_budget)
        if _should_stop(job):
            _restore_baseline(db, job)
            return

        _set_phase(job, "writing")
        message = job.legacy_writer_user_message or writer_user_message(chapter.book, chapter, memories)
        for token in job.writer.stream(message, cancel_event=job.cancel_event):
            if _should_stop(job):
                _restore_baseline(db, job)
                return
            with job.condition:
                job.buffer.append(token)
                job.condition.notify_all()
        current_text = "".join(job.buffer)
        if _should_stop(job):
            _restore_baseline(db, job)
            return

        violations = draft_violations(db, chapter, current_text, job.writer.finish_reason)
        for attempt in range(1, 3):
            if not violations:
                break
            if job.reviser is None:
                break
            _set_phase(
                job,
                "revising",
                attempt=attempt,
                current_chars=sum(1 for ch in current_text if not ch.isspace()),
                violations=violations,
            )
            current_text = job.reviser.revise(reviser_user_message(chapter, current_text, violations))
            if _should_stop(job):
                _restore_baseline(db, job)
                return
            finish_reason = getattr(getattr(job.reviser, "llm", None), "last_finish_reason", None)
            violations = draft_violations(db, chapter, current_text, finish_reason)
        if violations:
            _restore_baseline(db, job)
            _mark_failed(
                job,
                "revision_failed",
                "修订两次后仍未通过程序校验，请调整本章剧情后重新生成",
                {"violations": violations},
            )
            return
        if not write_registry.is_current(job):
            _restore_baseline(db, job)
            return

        # The old draft remains in storage during generation. Only a fully
        # validated final result crosses this commit boundary.
        chapter.draft_text = current_text
        chapter.status = "draft_ready"
        db.commit()
        db.refresh(chapter)
        _mark_done(job, _chapter_payload(chapter))
    except LLMError as exc:
        db.rollback()
        _restore_baseline(db, job)
        _mark_failed(job, exc.code, str(exc), exc.safe_details())
    except Exception as exc:  # noqa: BLE001 - converted to stable SSE envelope
        db.rollback()
        _restore_baseline(db, job)
        _mark_failed(job, "write_failed", str(exc))
    finally:
        db.close()


def _should_stop(job: WriteJob) -> bool:
    return job.cancel_event.is_set() or not write_registry.is_current(job)


def _restore_baseline(db: Session, job: WriteJob) -> None:
    # A cancelled upstream request may take longer than the router's bounded
    # join. Once a replacement job owns this chapter, the stale worker must not
    # wake up later and overwrite the replacement's validated result.
    if not write_registry.is_current(job):
        return
    chapter = db.get(Chapter, job.chapter_id)
    if chapter is None:
        return
    chapter.draft_text = job.baseline_text
    chapter.status = job.baseline_status
    db.commit()


def _set_phase(job: WriteJob, phase: str, **details: Any) -> None:
    with job.condition:
        if job.is_terminal:
            return
        job.phase = phase
        job.phase_details = details
        job.condition.notify_all()


def _mark_done(job: WriteJob, chapter_payload: dict[str, Any]) -> None:
    with job.condition:
        job.phase = "done"
        job.done_chapter = chapter_payload
        job.terminal_at = time.monotonic()
        job.condition.notify_all()


def _mark_failed(job: WriteJob, code: str, error: str, details: dict[str, Any] | None = None) -> None:
    with job.condition:
        if job.phase == "cancelled":
            return
        job.phase = "failed"
        job.error_code = code
        job.error = error
        job.error_details = details or {}
        job.terminal_at = time.monotonic()
        job.condition.notify_all()


def _chapter_payload(chapter: Chapter) -> dict[str, Any]:
    note = str(getattr(chapter, "author_note", getattr(chapter, "chapter_style", "")) or "")
    return ChapterRead(
        id=chapter.id,
        book_id=chapter.book_id,
        index=chapter.index,
        title=chapter.title,
        user_prompt=chapter.user_prompt,
        target_word_count=chapter.target_word_count,
        author_note=note,
        chapter_style=note,
        draft_text=chapter.draft_text,
        summary=chapter.summary,
        headline=chapter.headline,
        status=chapter.status,
        source=chapter.source,
        created_at=chapter.created_at,
        updated_at=chapter.updated_at,
        character_links=[{"character_id": link.character_id, "chapter_note": ""} for link in chapter.character_links],
    ).model_dump(mode="json")


def sse_event(event: str, data: dict[str, Any]) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


def _phase_event(job: WriteJob) -> str | None:
    if job.phase not in {"selecting_memory", "writing", "revising"}:
        return None
    return sse_event(job.phase, {"chapter_id": job.chapter_id, **job.phase_details})


def stream_job(job: WriteJob, *, snapshot: bool) -> Iterator[str]:
    yield sse_event("started", {"chapter_id": job.chapter_id})
    sent = 0
    with job.condition:
        phase = _phase_event(job)
        last_phase = job.phase
        last_details = dict(job.phase_details)
        snapshot_text = "".join(job.buffer) if snapshot and job.buffer else None
        if snapshot_text is not None:
            sent = len(job.buffer)
    if phase is not None:
        yield phase
    if snapshot_text is not None:
        yield sse_event("snapshot", {"text": snapshot_text, "chars": len(snapshot_text)})

    while True:
        events: list[str] = []
        terminal = False
        with job.condition:
            while (
                not job.is_terminal
                and sent == len(job.buffer)
                and last_phase == job.phase
                and last_details == job.phase_details
            ):
                job.condition.wait(timeout=1.0)
            if job.phase != last_phase or job.phase_details != last_details:
                last_phase = job.phase
                last_details = dict(job.phase_details)
                event = _phase_event(job)
                if event is not None:
                    events.append(event)
            while sent < len(job.buffer):
                token = job.buffer[sent]
                sent += 1
                events.append(sse_event("token", {"text": token}))
            if job.is_terminal:
                if job.phase == "done" and job.done_chapter is not None:
                    events.append(sse_event("done", {"chapter": job.done_chapter}))
                else:
                    events.append(
                        sse_event(
                            "error",
                            {
                                "code": job.error_code or "write_failed",
                                "message": job.error or "write failed",
                                "details": job.error_details,
                            },
                        )
                    )
                terminal = True
        yield from events
        if terminal:
            return
