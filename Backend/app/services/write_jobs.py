from __future__ import annotations

import threading
import time
from typing import Any

from sqlalchemy.orm import Session, sessionmaker

from app.agents.memory_selector import MemorySelectorAgent
from app.agents.reviser import ReviserAgent
from app.agents.writer import WriterAgent
from app.llm.base import LLMError
from app.models import Chapter, JobRun
from app.models.entities import utc_now
from app.services.audit import record_llm_call
from app.services.context import (
    MEMORY_BUDGET_CHARS,
    MemoryBlock,
    draft_violations,
    pack_selected_memories,
    reviser_user_message,
    writer_user_message,
)
from app.services.extraction import apply_extractor_output


TERMINAL_PHASES = {"done", "failed", "cancelled"}


class WriteJobConflict(Exception):
    pass


class WriteJob:
    """In-memory handle for a running write/extract task.

    It only carries what the registry needs for concurrency control and
    cancellation. The authoritative, pollable status lives in `job_runs`.
    """

    def __init__(
        self,
        chapter_id: str,
        writer: WriterAgent | None = None,
        reviser: ReviserAgent | None = None,
        memory_selector: MemorySelectorAgent | None = None,
        selector_user_message: str = "",
        memory_candidates: list[MemoryBlock] | None = None,
        memory_budget: int = MEMORY_BUDGET_CHARS,
        baseline_text: str = "",
        baseline_status: str = "draft",
        job_id: str = "",
        kind: str = "write",
        extractor: Any | None = None,
        extractor_user_message: str = "",
        selected_character_ids: list[str] | None = None,
        # Compatibility for the old direct unit-test constructor.
        writer_user_message: str | None = None,
        compressor: Any | None = None,
    ) -> None:
        self.chapter_id = chapter_id
        self.job_id = job_id
        self.kind = kind
        self.writer = writer
        self.reviser = reviser or compressor
        self.memory_selector = memory_selector
        self.selector_user_message = selector_user_message
        self.memory_candidates = memory_candidates or []
        self.memory_budget = memory_budget
        self.baseline_text = baseline_text
        self.baseline_status = baseline_status
        self.legacy_writer_user_message = writer_user_message
        self.extractor = extractor
        self.extractor_user_message = extractor_user_message
        self.selected_character_ids = selected_character_ids or []
        self.cancel_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.discard_on_cancel = False
        self._lock = threading.Lock()
        self._terminal = False
        self.phase = "extracting" if kind == "extract" else (
            "selecting_memory" if memory_selector is not None else "writing"
        )

    @property
    def is_terminal(self) -> bool:
        with self._lock:
            return self._terminal or self.phase in TERMINAL_PHASES

    def mark_terminal(self, phase: str | None = None) -> None:
        with self._lock:
            if phase is not None and self.phase not in TERMINAL_PHASES:
                self.phase = phase
            self._terminal = True

    def mark_cancelled(self) -> None:
        with self._lock:
            if self.phase not in TERMINAL_PHASES:
                self.phase = "cancelled"
            self._terminal = True


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
        job.discard_on_cancel = discard
        job.cancel_event.set()
        job.mark_cancelled()

    def launch(self, job: WriteJob, session_factory: sessionmaker[Session]) -> None:
        target = _run_extract_job if job.kind == "extract" else _run_job
        thread = threading.Thread(target=target, args=(job, session_factory), daemon=True)
        job.thread = thread
        thread.start()


write_registry = WriteJobRegistry()


# --- Persisted job_runs helpers ------------------------------------------------


def record_job_phase(
    session_factory: sessionmaker[Session],
    job_id: str,
    phase: str,
    **fields: Any,
) -> None:
    """Update the persisted job_runs row. Never overwrites a terminal row.

    Runs in its own short session, independent of the worker's chapter
    transaction, so the polling endpoint reads committed intermediate phases.
    """
    if not job_id:
        return
    db = session_factory()
    try:
        run = db.get(JobRun, job_id)
        if run is None or run.phase in TERMINAL_PHASES:
            return
        run.phase = phase
        run.attempt = fields.get("attempt")
        run.violations = fields.get("violations")
        run.error_code = fields.get("error_code")
        run.error_message = fields.get("error_message")
        run.error_context = fields.get("error_context")
        run.updated_character_ids = fields.get("updated_character_ids")
        run.added_event_ids = fields.get("added_event_ids")
        if phase in TERMINAL_PHASES:
            run.finished_at = utc_now()
        db.commit()
    finally:
        db.close()


def _error_context(exc: LLMError) -> dict[str, Any]:
    """Build the additive job_runs.error_context payload for an LLMError.

    Mirrors LLMError.safe_details()'s "only if not None" shape so a partially
    stamped exception (e.g. one raised before an agent_role could be attached)
    never writes literal Nones into the persisted JSON.
    """
    return {
        key: value
        for key, value in {
            "agent_role": exc.agent_role,
            "model_name": exc.model_name,
            "http_status": exc.status_code,
            "upstream_reason": exc.upstream_reason,
            "finish_reason": exc.finish_reason,
            "block_reason": exc.block_reason,
        }.items()
        if value is not None
    }


def _record_llm(
    session_factory: sessionmaker[Session],
    agent_role: str,
    client: Any,
    start: float,
    error_code: str | None,
    job: WriteJob,
    *,
    upstream_reason: str | None = None,
) -> None:
    duration_ms = int((time.monotonic() - start) * 1000)
    record_llm_call(
        session_factory,
        agent_role=agent_role,
        client=client,
        duration_ms=duration_ms,
        error_code=error_code,
        chapter_id=job.chapter_id,
        job_id=job.job_id,
        upstream_reason=upstream_reason,
    )


# --- Timed, audited agent calls ------------------------------------------------


def _run_memory_selector(job: WriteJob, session_factory: sessionmaker[Session]) -> list[str]:
    start = time.monotonic()
    client = getattr(job.memory_selector, "llm", None)
    try:
        result = job.memory_selector.select(job.selector_user_message)
    except LLMError as exc:
        _record_llm(session_factory, "memory_selector", client, start, exc.code, job, upstream_reason=exc.upstream_reason)
        exc.agent_role = "memory_selector"
        exc.model_name = getattr(client, "model_name", None)
        raise
    _record_llm(session_factory, "memory_selector", client, start, None, job)
    return result


def _run_writer(job: WriteJob, session_factory: sessionmaker[Session], message: str) -> str:
    start = time.monotonic()
    client = getattr(job.writer, "llm", None)
    chunks: list[str] = []
    try:
        for token in job.writer.stream(message, cancel_event=job.cancel_event):
            chunks.append(token)
            if _should_stop(job):
                break
    except LLMError as exc:
        _record_llm(session_factory, "writer", client, start, exc.code, job, upstream_reason=exc.upstream_reason)
        exc.agent_role = "writer"
        exc.model_name = getattr(client, "model_name", None)
        raise
    _record_llm(session_factory, "writer", client, start, None, job)
    return "".join(chunks)


def _run_reviser(job: WriteJob, session_factory: sessionmaker[Session], message: str) -> str:
    start = time.monotonic()
    client = getattr(job.reviser, "llm", None)
    try:
        result = job.reviser.revise(message)
    except LLMError as exc:
        _record_llm(session_factory, "reviser", client, start, exc.code, job, upstream_reason=exc.upstream_reason)
        exc.agent_role = "reviser"
        exc.model_name = getattr(client, "model_name", None)
        raise
    _record_llm(session_factory, "reviser", client, start, None, job)
    return result


# --- Workers -------------------------------------------------------------------


def _run_job(job: WriteJob, session_factory: sessionmaker[Session]) -> None:
    db = session_factory()
    try:
        chapter = db.get(Chapter, job.chapter_id)
        if chapter is None:
            record_job_phase(session_factory, job.job_id, "failed", error_code="chapter_missing", error_message="章节不存在")
            job.mark_terminal("failed")
            return
        memories: list[MemoryBlock] = []
        if job.memory_selector is not None:
            record_job_phase(session_factory, job.job_id, "selecting_memory")
            selected_ids = _run_memory_selector(job, session_factory)
            memories = pack_selected_memories(job.memory_candidates, selected_ids, job.memory_budget)
        if _should_stop(job):
            _restore_baseline(db, job)
            job.mark_terminal()
            return

        record_job_phase(session_factory, job.job_id, "writing")
        message = job.legacy_writer_user_message or writer_user_message(chapter.book, chapter, memories)
        current_text = _run_writer(job, session_factory, message)
        if _should_stop(job):
            _restore_baseline(db, job)
            job.mark_terminal()
            return

        violations = draft_violations(db, chapter, current_text, job.writer.finish_reason)
        for attempt in range(1, 3):
            if not violations:
                break
            if job.reviser is None:
                break
            record_job_phase(session_factory, job.job_id, "revising", attempt=attempt, violations=violations)
            current_text = _run_reviser(job, session_factory, reviser_user_message(chapter, current_text, violations))
            if _should_stop(job):
                _restore_baseline(db, job)
                job.mark_terminal()
                return
            finish_reason = getattr(getattr(job.reviser, "llm", None), "last_finish_reason", None)
            violations = draft_violations(db, chapter, current_text, finish_reason)
        if violations:
            _restore_baseline(db, job)
            reviser_context: dict[str, Any] = {"agent_role": "reviser"}
            reviser_model = getattr(getattr(job.reviser, "llm", None), "model_name", None)
            if reviser_model:
                reviser_context["model_name"] = reviser_model
            record_job_phase(
                session_factory,
                job.job_id,
                "failed",
                error_code="revision_failed",
                error_message="修订两次后仍未通过程序校验，请调整本章剧情后重新生成",
                violations=violations,
                error_context=reviser_context,
            )
            job.mark_terminal("failed")
            return
        if not write_registry.is_current(job):
            _restore_baseline(db, job)
            job.mark_terminal()
            return

        # The old draft remains in storage during generation. Only a fully
        # validated final result crosses this commit boundary.
        chapter.draft_text = current_text
        chapter.status = "draft_ready"
        db.commit()
        record_job_phase(session_factory, job.job_id, "done")
        job.mark_terminal("done")
    except LLMError as exc:
        db.rollback()
        _restore_baseline(db, job)
        record_job_phase(
            session_factory,
            job.job_id,
            "failed",
            error_code=exc.code,
            error_message=str(exc),
            error_context=_error_context(exc),
        )
        job.mark_terminal("failed")
    except Exception as exc:  # noqa: BLE001 - converted to a stable failed job_run
        db.rollback()
        _restore_baseline(db, job)
        record_job_phase(session_factory, job.job_id, "failed", error_code="write_failed", error_message=str(exc))
        job.mark_terminal("failed")
    finally:
        db.close()


def _run_extract_job(job: WriteJob, session_factory: sessionmaker[Session]) -> None:
    db = session_factory()
    try:
        chapter = db.get(Chapter, job.chapter_id)
        if chapter is None:
            record_job_phase(session_factory, job.job_id, "failed", error_code="chapter_missing", error_message="章节不存在")
            job.mark_terminal("failed")
            return
        start = time.monotonic()
        client = getattr(job.extractor, "llm", None)
        try:
            output = job.extractor.extract(job.extractor_user_message, job.selected_character_ids)
        except LLMError as exc:
            _record_llm(session_factory, "extractor", client, start, exc.code, job, upstream_reason=exc.upstream_reason)
            exc.agent_role = "extractor"
            exc.model_name = getattr(client, "model_name", None)
            raise
        _record_llm(session_factory, "extractor", client, start, None, job)
        if job.cancel_event.is_set() or not write_registry.is_current(job):
            db.rollback()
            job.mark_terminal()
            return
        updated_ids, event_ids = apply_extractor_output(db, chapter, output)
        db.commit()
        record_job_phase(
            session_factory,
            job.job_id,
            "done",
            updated_character_ids=updated_ids,
            added_event_ids=event_ids,
        )
        job.mark_terminal("done")
    except LLMError as exc:
        db.rollback()
        _restore_draft_ready(db, job)
        record_job_phase(
            session_factory,
            job.job_id,
            "failed",
            error_code=exc.code,
            error_message=str(exc),
            error_context=_error_context(exc),
        )
        job.mark_terminal("failed")
    except Exception as exc:  # noqa: BLE001 - keep the chapter editable on failure
        db.rollback()
        _restore_draft_ready(db, job)
        record_job_phase(session_factory, job.job_id, "failed", error_code="extract_failed", error_message=f"提取失败：{exc}")
        job.mark_terminal("failed")
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


def _restore_draft_ready(db: Session, job: WriteJob) -> None:
    if not write_registry.is_current(job):
        return
    chapter = db.get(Chapter, job.chapter_id)
    if chapter is None:
        return
    chapter.status = "draft_ready"
    db.commit()
