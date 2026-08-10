from __future__ import annotations

import hashlib
import json
import logging
import threading
import time
from collections.abc import Callable
from typing import Any

from sqlalchemy import select, update
from sqlalchemy.orm import Session, sessionmaker

from app.agents.checker import CheckerAgent
from app.agents.extractor import ExtractorContractError
from app.agents.memory_selector import MemorySelection, MemorySelectorAgent
from app.agents.writer import WriterAgent
from app.llm.base import LLMError, safe_block_reason, safe_finish_reason, safe_upstream_reason
from app.models import Chapter, ChapterArchiveRevision, ChapterDraftCandidate, JobRun
from app.models.entities import utc_now
from app.services.audit import record_llm_call
from app.services.context import (
    MAX_MEMORY_CONFLICTS,
    MEMORY_BUDGET_CHARS,
    MemoryBlock,
    checker_user_message,
    draft_fingerprint,
    draft_violations,
    nonspace_len,
    pack_memory_brief,
    pack_writer_context,
    writer_user_message,
)
from app.services.archive_v2 import (
    ArchiveFingerprintMismatch,
    ArchiveV2ValidationError,
    activate_archive_revision,
    invalidate_downstream_archives,
    mark_revision_extracting,
    mark_revision_failed,
    mark_revision_partial,
    validate_archive_output,
)
from app.services.character_state_projection import rebuild_book_projection
from app.services.write_ownership import (
    cancel_local_writer_jobs,
    chapters_for_character,
    invalidate_writer_inputs,
)


TERMINAL_PHASES = {"done", "failed", "cancelled"}
logger = logging.getLogger(__name__)


class WriteJobConflict(Exception):
    pass


class WriteJob:
    """In-memory cancellation handle; job_runs remains the source of truth."""

    def __init__(
        self,
        chapter_id: str,
        writer: WriterAgent | None = None,
        memory_selector: MemorySelectorAgent | None = None,
        checker: CheckerAgent | None = None,
        selector_user_message: str = "",
        memory_candidates: list[MemoryBlock] | None = None,
        memory_budget: int = MEMORY_BUDGET_CHARS,
        baseline_text: str = "",
        baseline_status: str = "draft",
        job_id: str = "",
        kind: str = "write",
        extractor: Any | None = None,
        extractor_user_message: str = "",
        selected_characters: list[tuple[str, str]] | None = None,
        bible_snapshot: str = "",
        bible_sha256: str = "",
        archive_revision_id: str = "",
        chapter_write_generation: int | None = None,
    ) -> None:
        self.chapter_id = chapter_id
        self.job_id = job_id
        self.kind = kind
        self.writer = writer
        self.memory_selector = memory_selector
        self.checker = checker
        self.selector_user_message = selector_user_message
        self.memory_candidates = memory_candidates or []
        self.memory_budget = memory_budget
        self.baseline_text = baseline_text
        self.baseline_status = baseline_status
        self.extractor = extractor
        self.extractor_user_message = extractor_user_message
        self.selected_characters = selected_characters or []
        self.bible_snapshot = bible_snapshot
        self.bible_sha256 = bible_sha256 or hashlib.sha256(bible_snapshot.encode()).hexdigest()
        self.archive_revision_id = archive_revision_id
        self.chapter_write_generation = chapter_write_generation
        self.cancel_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.discard_on_cancel = False
        self._lock = threading.Lock()
        self._terminal = False
        self.phase = "extracting" if kind == "extract" else ("selecting_memory" if memory_selector else "writing")

    @property
    def is_terminal(self) -> bool:
        with self._lock:
            return self._terminal or self.phase in TERMINAL_PHASES

    def mark_terminal(self, phase: str | None = None) -> None:
        with self._lock:
            if phase and self.phase not in TERMINAL_PHASES:
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

    def cancel(self, job: WriteJob, *, discard: bool = False) -> bool:
        with self._lock:
            if self._jobs.get(job.chapter_id) is not job or job.is_terminal:
                return False
            job.discard_on_cancel = discard
            job.cancel_event.set()
            job.mark_cancelled()
            return True

    def finish_if_current(self, job: WriteJob, persist: Callable[[], None], *, phase: str) -> bool:
        """Persist a terminal result only while this job exclusively owns the chapter.

        Cancellation, replacement and terminal persistence share the registry lock.
        The callback must commit the chapter/candidate and JobRun terminal state in
        one database transaction before the in-memory job becomes terminal.
        """
        with self._lock:
            if (
                self._jobs.get(job.chapter_id) is not job
                or job.cancel_event.is_set()
                or job.is_terminal
            ):
                return False
            if persist() is False:
                return False
            job.mark_terminal(phase)
            return True

    def launch(self, job: WriteJob, session_factory: sessionmaker[Session]) -> None:
        target = _run_extract_job if job.kind == "extract" else _run_job
        job.thread = threading.Thread(target=target, args=(job, session_factory), daemon=True)
        job.thread.start()


write_registry = WriteJobRegistry()


def _apply_job_phase(db: Session, job_id: str, phase: str, **fields: Any) -> bool:
    if not job_id:
        return False
    run = db.get(JobRun, job_id)
    if run is None or run.phase in TERMINAL_PHASES:
        return False
    run.phase = phase
    for key in (
        "attempt", "violations", "error_code", "error_message", "error_context",
        "updated_character_ids", "added_event_ids", "memory_context", "checker_result",
        "bible_sha256", "draft_fingerprint",
    ):
        if key in fields:
            setattr(run, key, fields[key])
    if phase in TERMINAL_PHASES:
        run.finished_at = utc_now()
    return True


def record_job_phase(session_factory: sessionmaker[Session], job_id: str, phase: str, **fields: Any) -> None:
    db = session_factory()
    try:
        if _apply_job_phase(db, job_id, phase, **fields):
            db.commit()
    finally:
        db.close()


def _error_context(exc: LLMError) -> dict[str, Any]:
    return {key: value for key, value in {
        "agent_role": exc.agent_role, "model_name": exc.model_name, "http_status": exc.status_code,
        "upstream_reason": safe_upstream_reason(exc.upstream_reason),
        "finish_reason": safe_finish_reason(exc.finish_reason),
        "block_reason": safe_block_reason(exc.block_reason),
    }.items() if value is not None}


def _log_archive_failure(
    job: WriteJob,
    *,
    stage: str,
    error_code: str,
    reason: str | None = None,
    client: Any | None = None,
    error_context: dict[str, Any] | None = None,
    exception_type: str | None = None,
) -> None:
    """Emit only operational metadata; never include prompts, prose or model output."""
    payload: dict[str, Any] = {
        "event": "archive_job_failed",
        "chapter_id": job.chapter_id,
        "job_id": job.job_id,
        "revision_id": job.archive_revision_id,
        "stage": stage,
        "error_code": error_code,
        "attempts": 1,
    }
    if reason:
        payload["reason"] = reason
    if client is not None:
        payload["model_name"] = str(getattr(client, "model_name", "") or "")
    if error_context:
        payload.update(error_context)
    if exception_type:
        payload["exception_type"] = exception_type
    logger.warning("archive_job_failure %s", json.dumps(payload, ensure_ascii=False, sort_keys=True))


def _record_llm(session_factory: sessionmaker[Session], agent_role: str, client: Any, start: float,
                error_code: str | None, job: WriteJob, *, upstream_reason: str | None = None) -> None:
    record_llm_call(session_factory, agent_role=agent_role, client=client, duration_ms=int((time.monotonic() - start) * 1000),
                    error_code=error_code, chapter_id=job.chapter_id, job_id=job.job_id, upstream_reason=upstream_reason)


def _call(job: WriteJob, session_factory: sessionmaker[Session], role: str, method: Any, *args: Any) -> Any:
    start = time.monotonic()
    agent = {"memory_selector": job.memory_selector, "writer": job.writer, "checker": job.checker}[role]
    client = getattr(agent, "llm", None)
    try:
        result = method(*args)
    except LLMError as exc:
        _record_llm(session_factory, role, client, start, exc.code, job, upstream_reason=exc.upstream_reason)
        exc.agent_role, exc.model_name = role, getattr(client, "model_name", None)
        raise
    _record_llm(session_factory, role, client, start, None, job)
    return result


def _run_memory_selector(job: WriteJob, sf: sessionmaker[Session]) -> MemorySelection:
    assert job.memory_selector is not None
    return _call(job, sf, "memory_selector", job.memory_selector.select, job.selector_user_message)


def _run_writer(job: WriteJob, sf: sessionmaker[Session], message: str) -> str:
    assert job.writer is not None
    start, client, chunks = time.monotonic(), job.writer.llm, []
    try:
        for token in job.writer.stream(message, cancel_event=job.cancel_event):
            chunks.append(token)
            if _should_stop(job):
                break
    except LLMError as exc:
        _record_llm(sf, "writer", client, start, exc.code, job, upstream_reason=exc.upstream_reason)
        exc.agent_role, exc.model_name = "writer", getattr(client, "model_name", None)
        raise
    _record_llm(sf, "writer", client, start, None, job)
    return "".join(chunks)


def _normal_finish_or_raise(job: WriteJob, role: str, agent: Any) -> None:
    reason = str(getattr(getattr(agent, "llm", None), "last_finish_reason", "") or "").lower()
    if reason in {"sensitive", "content_filter", "safety"}:
        exc = LLMError("LLM blocked the request", code="llm_content_blocked", block_reason=reason, finish_reason=reason)
        exc.agent_role, exc.model_name = role, getattr(getattr(agent, "llm", None), "model_name", None)
        raise exc


def _persist_candidate(db: Session, job: WriteJob, chapter: Chapter, text: str, attempt: int,
                       violations: list[dict[str, Any]]) -> ChapterDraftCandidate:
    finish_reason = getattr(job.writer, "finish_reason", None)
    candidate = ChapterDraftCandidate(chapter_id=chapter.id, job_id=job.job_id, attempt=attempt, draft_text=text,
                                      non_whitespace_count=nonspace_len(text), finish_reason=finish_reason,
                                      deterministic_violations=violations, bible_sha256=job.bible_sha256,
                                      draft_fingerprint=draft_fingerprint(chapter, text, bible=job.bible_snapshot))
    db.add(candidate)
    db.commit()
    return candidate


def _valid_checker_result(raw: Any, fingerprint: str) -> dict[str, Any]:
    if not isinstance(raw, dict) or raw.get("verdict") not in {"passed", "suspect", "violation"}:
        raise ValueError("Checker 返回结构无效")
    issues: list[dict[str, str]] = []
    for item in raw.get("issues", []):
        if not isinstance(item, dict):
            continue
        required = [item.get(key) for key in ("kind", "draft_evidence", "bible_evidence", "reason")]
        if all(isinstance(value, str) and value.strip() for value in required):
            issues.append({key: item[key].strip() for key in ("kind", "draft_evidence", "bible_evidence", "reason")})
    if raw["verdict"] == "violation" and not issues:
        return {"verdict": "suspect", "issues": [], "draft_fingerprint": fingerprint, "invalid_evidence": True}
    return {"verdict": raw["verdict"], "issues": issues, "draft_fingerprint": fingerprint}


def _run_job(job: WriteJob, sf: sessionmaker[Session]) -> None:
    db = sf()
    try:
        chapter = db.get(Chapter, job.chapter_id)
        if chapter is None:
            record_job_phase(sf, job.job_id, "failed", error_code="chapter_missing", error_message="章节不存在")
            job.mark_terminal("failed")
            return
        if not _generation_matches(db, job):
            _mark_chapter_changed(sf, job)
            job.mark_terminal("cancelled")
            return
        # The snapshot must still match before any model output can affect storage.
        if hashlib.sha256(chapter.user_prompt.encode()).hexdigest() != job.bible_sha256:
            if not _restore_baseline(
                db, job, phase="cancelled", error_code="bible_changed",
                error_message="Bible 已变更，已取消旧写作任务",
            ):
                _mark_chapter_changed(sf, job)
            job.mark_terminal("cancelled")
            return
        memories: list[MemoryBlock] = []
        previous_ending = ""
        conflicts: list[dict[str, Any]] = []
        if job.memory_selector:
            record_job_phase(sf, job.job_id, "selecting_memory", bible_sha256=job.bible_sha256)
            selection = _run_memory_selector(job, sf)
            packed_ending = pack_writer_context(job.memory_candidates, [], selection.previous_ending_start_id, job.memory_budget)
            remaining = max(0, job.memory_budget - nonspace_len(packed_ending.previous_ending))
            memories = pack_memory_brief(job.memory_candidates, selection.briefs, remaining)
            previous_ending = packed_ending.previous_ending
            valid_conflicts = pack_memory_brief(
                job.memory_candidates,
                selection.conflicts,
                remaining,
                max_items=MAX_MEMORY_CONFLICTS,
            )
            conflicts = [{"text": item.text, "source_ids": item.id.split("|")} for item in valid_conflicts]
            source_by_id = {block.id: block for block in job.memory_candidates}
            used_source_ids = [source_id for item in memories + valid_conflicts for source_id in item.id.split("|")]
            manifest = {**packed_ending.manifest(), "memory_brief": [
                {"text": item.text, "source_ids": item.id.split("|"), "chapter_index": item.chapter_index,
                 "memory_type": item.memory_type} for item in memories], "conflicts": conflicts}
            manifest["memory_non_whitespace_count"] = sum(nonspace_len(item.text) for item in memories)
            manifest["sources"] = [
                {"id": source_id, "chapter_index": source_by_id[source_id].chapter_index,
                 "memory_type": source_by_id[source_id].memory_type, "source_excerpt": source_by_id[source_id].text}
                for source_id in dict.fromkeys(used_source_ids) if source_id in source_by_id
            ]
            record_job_phase(sf, job.job_id, "writing", memory_context=manifest, bible_sha256=job.bible_sha256)
        if _should_stop(job):
            if not _restore_baseline(
                db, job, phase="cancelled", error_code="write_cancelled", error_message="写作任务已取消"
            ):
                _mark_chapter_changed(sf, job)
            job.mark_terminal(); return
        from app.services.character_state_projection import projected_fields_before_chapter
        message = writer_user_message(
            chapter.book, chapter, memories, previous_ending, bible=job.bible_snapshot,
            dynamic_fields_by_character=projected_fields_before_chapter(db, chapter),
        )
        last_candidate: ChapterDraftCandidate | None = None
        for attempt in (1, 2):
            record_job_phase(sf, job.job_id, "writing", attempt=attempt)
            text = _run_writer(job, sf, message)
            if _should_stop(job):
                if not _restore_baseline(
                    db, job, phase="cancelled", error_code="write_cancelled", error_message="写作任务已取消"
                ):
                    _mark_chapter_changed(sf, job)
                job.mark_terminal(); return
            _normal_finish_or_raise(job, "writer", job.writer)
            violations = draft_violations(db, chapter, text, job.writer.finish_reason if job.writer else None)
            last_candidate = _persist_candidate(db, job, chapter, text, attempt, violations)
            length_only = all(item["code"] in {"empty_body", "minimum_length", "length_truncated"} for item in violations)
            if not violations:
                break
            if attempt == 1 and length_only:
                continue  # exact same original input; never expand the first text.
            code = "writer_minimum_failed" if length_only else "writer_validation_failed"
            if not _restore_baseline(
                db, job, phase="failed", attempt=attempt, violations=violations, error_code=code,
                error_message="整章生成未通过确定性校验；失败稿已后台留档，未替换当前正文",
                error_context={"agent_role": "writer"},
            ):
                _mark_chapter_changed(sf, job)
                job.mark_terminal("cancelled")
                return
            job.mark_terminal("failed")
            return
        assert last_candidate is not None
        db.refresh(chapter)
        if (
            hashlib.sha256(chapter.user_prompt.encode()).hexdigest() != job.bible_sha256
            or not _generation_matches(db, job)
            or _should_stop(job)
        ):
            if not _restore_baseline(
                db, job, phase="cancelled", error_code="write_cancelled", error_message="写作任务已取消"
            ):
                _mark_chapter_changed(sf, job)
            job.mark_terminal("cancelled")
            return
        # Keep the candidate backend-only until Checker explicitly passes it.
        # The visible chapter stays on its pre-generation baseline throughout
        # checking, so rejected/unavailable output can never flash into the UI.
        fingerprint = last_candidate.draft_fingerprint
        record_job_phase(sf, job.job_id, "checking", attempt=last_candidate.attempt, draft_fingerprint=fingerprint)
        try:
            assert job.checker is not None
            raw = _call(
                job,
                sf,
                "checker",
                job.checker.check,
                checker_user_message(chapter, last_candidate.draft_text, job.bible_snapshot),
            )
            checker_result = _valid_checker_result(raw, fingerprint)
        except LLMError as exc:
            checker_result = {"status": "unavailable", "draft_fingerprint": fingerprint, "error_code": exc.code, "error_context": _error_context(exc)}
        except Exception as exc:  # malformed checker output never destroys the Writer candidate
            checker_result = {
                "status": "unavailable",
                "draft_fingerprint": fingerprint,
                "error_code": "checker_invalid",
                "error_message": "Checker 返回无效结果",
            }
        if checker_result.get("verdict") == "passed":
            def persist_passed() -> bool:
                # The candidate, visible chapter and terminal JobRun are one
                # transaction.  The database generation is the authorization;
                # the registry merely narrows same-process cancellation races.
                result = db.execute(
                    update(Chapter)
                    .where(
                        Chapter.id == chapter.id,
                        Chapter.write_generation == job.chapter_write_generation,
                    )
                    .values(draft_text=last_candidate.draft_text, status="draft_ready", updated_at=utc_now())
                )
                if result.rowcount != 1:
                    db.rollback()
                    return False
                last_candidate.checker_result = checker_result
                db.execute(
                    update(ChapterDraftCandidate)
                    .where(ChapterDraftCandidate.chapter_id == chapter.id)
                    .values(is_current=False)
                )
                last_candidate.is_current = True
                db.flush()
                if not _apply_job_phase(
                    db,
                    job.job_id,
                    "done",
                    checker_result=checker_result,
                    bible_sha256=job.bible_sha256,
                    draft_fingerprint=fingerprint,
                ):
                    raise RuntimeError("write job terminal row is no longer writable")
                db.commit()
                return True

            if not write_registry.finish_if_current(job, persist_passed, phase="done"):
                db.rollback()
                _mark_chapter_changed(sf, job)
                job.mark_terminal("cancelled")
                return
        else:
            error_code = checker_result.get("error_code") or "checker_rejected"
            issue_reasons = [
                item.get("reason", "").strip()
                for item in checker_result.get("issues", [])
                if isinstance(item, dict) and isinstance(item.get("reason"), str) and item.get("reason", "").strip()
            ]
            default_message = "Checker 未通过；失败稿已后台留档，未替换当前正文"
            if issue_reasons:
                default_message = f"Checker 未通过：{'；'.join(issue_reasons)}；失败稿已后台留档，未替换当前正文"
            error_message = checker_result.get("error_message") or default_message
            error_context = checker_result.get("error_context") or {"agent_role": "checker"}

            def persist_rejected() -> bool:
                result = db.execute(
                    update(Chapter)
                    .where(
                        Chapter.id == chapter.id,
                        Chapter.write_generation == job.chapter_write_generation,
                    )
                    .values(draft_text=job.baseline_text, status=job.baseline_status, updated_at=utc_now())
                )
                if result.rowcount != 1:
                    db.rollback()
                    return False
                last_candidate.checker_result = checker_result
                db.flush()
                if not _apply_job_phase(
                    db,
                    job.job_id,
                    "failed",
                    checker_result=checker_result,
                    bible_sha256=job.bible_sha256,
                    draft_fingerprint=fingerprint,
                    error_code=error_code,
                    error_message=error_message,
                    error_context=error_context,
                ):
                    raise RuntimeError("write job terminal row is no longer writable")
                db.commit()
                return True

            if not write_registry.finish_if_current(job, persist_rejected, phase="failed"):
                db.rollback()
                _mark_chapter_changed(sf, job)
                job.mark_terminal("cancelled")
                return
    except LLMError as exc:
        db.rollback()
        if not _restore_baseline(
            db, job, phase="failed", error_code=exc.code, error_message=str(exc), error_context=_error_context(exc)
        ):
            _mark_chapter_changed(sf, job)
            job.mark_terminal("cancelled")
            return
        job.mark_terminal("failed")
    except Exception as exc:
        db.rollback()
        if not _restore_baseline(
            db, job, phase="failed", error_code="write_failed", error_message="写作任务执行失败"
        ):
            _mark_chapter_changed(sf, job)
            job.mark_terminal("cancelled")
            return
        job.mark_terminal("failed")
    finally:
        db.close()


def _run_extract_job(job: WriteJob, sf: sessionmaker[Session]) -> None:
    """Run one v2 archive call; accepted prose is never rolled back."""
    db = sf()
    client: Any | None = None
    try:
        chapter = db.get(Chapter, job.chapter_id)
        revision = db.get(ChapterArchiveRevision, job.archive_revision_id) if job.archive_revision_id else None
        if chapter is None or revision is None:
            record_job_phase(
                sf,
                job.job_id,
                "failed",
                error_code="chapter_missing",
                error_message="章节或归档任务不存在",
            )
            job.mark_terminal("failed")
            return
        run = db.get(JobRun, job.job_id)
        # A different process may have reopened the chapter before this worker
        # acquired its session.  The durable run/revision lifecycle, not this
        # process's registry, decides whether an Extractor call is still valid.
        if (
            run is None
            or run.phase in TERMINAL_PHASES
            or chapter.status != "finalized"
            or revision.status not in {"pending", "extracting"}
        ):
            db.rollback()
            job.mark_terminal("cancelled")
            return
        mark_revision_extracting(revision, chapter)
        db.commit()

        client = getattr(job.extractor, "llm", None)
        started = time.monotonic()
        try:
            output = job.extractor.extract_v2(job.extractor_user_message, job.selected_characters)
        except LLMError as exc:
            _record_llm(sf, "extractor", client, started, exc.code, job, upstream_reason=exc.upstream_reason)
            exc.agent_role, exc.model_name = "extractor", getattr(client, "model_name", None)
            raise
        except ExtractorContractError:
            _record_llm(sf, "extractor", client, started, None, job)
            raise
        else:
            _record_llm(sf, "extractor", client, started, None, job)
        validated = validate_archive_output(chapter, output)
        if _should_stop(job):
            db.rollback()
            chapter = db.get(Chapter, job.chapter_id)
            revision = db.get(ChapterArchiveRevision, job.archive_revision_id)
            if chapter is not None and revision is not None and revision.status in {"pending", "extracting"}:
                mark_revision_failed(
                    revision,
                    chapter,
                    error_code="archive_cancelled",
                    error_message="归档任务已取消",
                )
                db.commit()
            return

        invalidated_writer_chapters: list[str] = []

        def persist_complete() -> None:
            nonlocal invalidated_writer_chapters
            updated_ids, event_ids = activate_archive_revision(
                db,
                chapter,
                revision,
                validated,
                model_name=getattr(client, "model_name", None),
                job_id=job.job_id,
            )
            invalidated_downstream = invalidate_downstream_archives(
                db, chapter.book_id, after_index=chapter.index
            )
            rebuild_book_projection(db, chapter.book_id)
            # Extractor-owned dynamic projections are Writer prompt input for
            # chapters selecting the changed characters. Persist the
            # generation bump in this same archive transaction; local thread
            # cancellation remains only a post-commit optimization.
            affected_writer_chapters = [
                affected
                for character_id in updated_ids
                for affected in chapters_for_character(db, character_id)
            ]
            invalidated_writer_chapters = invalidate_writer_inputs(db, affected_writer_chapters)
            if not _apply_job_phase(
                db,
                job.job_id,
                "done",
                attempt=1,
                updated_character_ids=updated_ids,
                added_event_ids=event_ids,
                error_context={
                    "archive_revision_id": revision.id,
                    "fact_count": len(validated.facts),
                    "state_delta_count": len(validated.deltas),
                    "invalidated_downstream_count": len(invalidated_downstream),
                },
            ):
                raise RuntimeError("archive job terminal row is no longer writable")
            db.commit()

        if not write_registry.finish_if_current(job, persist_complete, phase="done"):
            db.rollback()
        else:
            cancel_local_writer_jobs(invalidated_writer_chapters)
    except LLMError as exc:
        db.rollback()
        _log_archive_failure(
            job,
            stage="upstream",
            error_code=exc.code,
            client=client,
            error_context=_error_context(exc),
        )
        chapter = db.get(Chapter, job.chapter_id)
        revision = db.get(ChapterArchiveRevision, job.archive_revision_id)
        if chapter is not None and revision is not None:
            mark_revision_failed(revision, chapter, error_code=exc.code, error_message=str(exc))
            db.flush()
            _apply_job_phase(
                db,
                job.job_id,
                "failed",
                attempt=1,
                error_code=exc.code,
                error_message=str(exc),
                error_context=_error_context(exc),
            )
            db.commit()
        job.mark_terminal("failed")
    except ArchiveFingerprintMismatch as exc:
        db.rollback()
        _log_archive_failure(
            job,
            stage="activation",
            error_code="archive_input_changed",
            reason="archive input fingerprint changed",
            client=client,
        )
        chapter = db.get(Chapter, job.chapter_id)
        revision = db.get(ChapterArchiveRevision, job.archive_revision_id)
        if chapter is not None and revision is not None:
            revision.status = "stale"
            revision.error_code = "archive_input_changed"
            revision.error_message = str(exc)
            revision.finished_at = utc_now()
            chapter.archive_status = "stale"
            chapter.active_archive_revision_id = None
            chapter.legacy_archive_eligible = False
            db.flush()
            _apply_job_phase(
                db,
                job.job_id,
                "failed",
                attempt=1,
                error_code="archive_input_changed",
                error_message=str(exc),
            )
            rebuild_book_projection(db, chapter.book_id)
            db.commit()
        job.mark_terminal("failed")
    except (ArchiveV2ValidationError, ExtractorContractError) as exc:
        db.rollback()
        chapter = db.get(Chapter, job.chapter_id)
        revision = db.get(ChapterArchiveRevision, job.archive_revision_id)
        reason = str(exc)
        _log_archive_failure(
            job,
            stage="archive_validation",
            error_code="archive_validation_failed",
            reason=reason,
            client=client,
        )
        if chapter is not None and revision is not None:
            summary = output.get("summary", "") if "output" in locals() and isinstance(output, dict) else ""
            mark_revision_partial(revision, chapter, reason=reason, summary=summary)
            db.flush()
            _apply_job_phase(
                db,
                job.job_id,
                "failed",
                attempt=1,
                error_code="archive_validation_failed",
                error_message=f"归档未通过确定性校验：{reason}",
                error_context={"stage": "archive_validation", "attempts": 1, "reason": reason},
            )
            db.commit()
        job.mark_terminal("failed")
    except Exception as exc:
        db.rollback()
        _log_archive_failure(
            job,
            stage="persistence",
            error_code="extract_failed",
            client=client,
            exception_type=type(exc).__name__,
        )
        chapter = db.get(Chapter, job.chapter_id)
        revision = db.get(ChapterArchiveRevision, job.archive_revision_id)
        if chapter is not None and revision is not None:
            message = "归档任务执行失败"
            mark_revision_failed(revision, chapter, error_code="extract_failed", error_message=message)
            db.flush()
            _apply_job_phase(
                db,
                job.job_id,
                "failed",
                attempt=1,
                error_code="extract_failed",
                error_message=message,
            )
            db.commit()
        job.mark_terminal("failed")
    finally:
        db.close()


def _extractor_user_reason(reason: str) -> str:
    exact = {
        "event_type must use the canonical taxonomy": "人物事件类型不在固定分类中",
        "duplicate character event": "人物事件内容重复",
        "character event exceeds per-character limit": "单个人物的事件超过每章 3 条上限",
        "character events exceed chapter limit": "本章人物事件超过 8 条上限",
        "selected character event text must name its owner": "人物事件文本没有明确写出所属人物姓名",
        "character event evidence is required": "人物事件缺少正文原文证据",
        "character event evidence lacks a substantial literal draft excerpt": "人物事件证据没有包含足够的正文连续原文",
        "character event evidence context must identify its owner": "人物事件的原文证据及近邻语境无法确认所属人物",
        "dynamic fields patch evidence is required": "人物动态字段缺少正文原文证据",
        "dynamic fields patch evidence lacks a substantial literal draft excerpt": "人物动态字段证据没有包含足够的正文连续原文",
        "dynamic fields patch evidence context must identify its owner": "人物动态字段的原文证据及近邻语境无法确认所属人物",
        "snapshot must contain all three current-state slots": "即时快照必须完整包含位置、行动和情绪三项",
        "duplicate character snapshot": "同一人物重复输出即时快照",
        "duplicate persistent state slot": "同一人物重复输出持续状态字段",
        "duplicate relationship pair": "同一人物关系重复输出",
        "persistent operation has unsupported slot": "持续状态使用了未批准的字段名",
        "persistent_ops must be an array": "持续状态列表结构不正确",
        "relationship_ops must be an array": "人物关系列表结构不正确",
        "state_updates must be an array": "人物当前状态列表结构不正确",
        "state_updates item must be an object": "人物当前状态条目结构不正确",
        "snapshot value must describe chapter ending only": "即时快照必须只描述章节结束时状态",
        "relationship target must be another selected character": "人物关系对象必须是另一位本章已选人物",
        "state_updates references an unselected character": "人物状态引用了本章未获批准的人物",
        "character_events references an unselected character": "人物事件引用了本章未获批准的人物",
    }
    if reason in exact:
        return exact[reason]
    archive_names = {
        "state_changes": "状态变化",
        "unresolved_items": "未解决事项",
        "atomic_memories": "原子记忆",
    }
    for field, label in archive_names.items():
        if reason == f"{field} character attribution must name its owner":
            return f"{label}绑定了人物，但文本没有明确写出该人物姓名"
        if reason == f"{field} references an unselected character":
            return f"{label}引用了本章未获批准的人物"
    evidence_fields = {
        "snapshot presence": "人物即时快照的出场",
        "snapshot 当前位置": "即时快照“当前位置”的",
        "snapshot 当前行动": "即时快照“当前行动”的",
        "snapshot 情绪状态": "即时快照“情绪状态”的",
        "persistent 身体状态": "持续状态“身体状态”的",
        "persistent 当前目标": "持续状态“当前目标”的",
        "persistent 秘密状态": "持续状态“秘密状态”的",
        "relationship": "人物关系的",
    }
    evidence_suffixes = {
        "evidence is required": "原文证据缺失",
        "evidence lacks a substantial literal draft excerpt": "证据没有包含足够的正文连续原文",
        "evidence context must identify its owner": "原文证据及近邻语境无法确认所属人物",
    }
    for field, label in evidence_fields.items():
        for suffix, message in evidence_suffixes.items():
            if reason == f"{field} {suffix}":
                return label + message
    if reason.startswith("unsupported dynamic field key: "):
        return "人物动态字段使用了未批准的字段名：" + reason.removeprefix("unsupported dynamic field key: ")
    return reason


def _should_stop(job: WriteJob) -> bool:
    return job.cancel_event.is_set() or not write_registry.is_current(job)


def _generation_matches(db: Session, job: WriteJob) -> bool:
    if job.chapter_write_generation is None:
        return False
    return db.scalar(select(Chapter.write_generation).where(Chapter.id == job.chapter_id)) == job.chapter_write_generation


def _mark_chapter_changed(session_factory: sessionmaker[Session], job: WriteJob) -> None:
    record_job_phase(
        session_factory,
        job.job_id,
        "cancelled",
        error_code="chapter_changed",
        error_message="章节已编辑，旧写作任务已取消",
    )


def _restore_baseline(db: Session, job: WriteJob, *, phase: str | None = None, **fields: Any) -> bool:
    """Restore only if this job still owns the persisted chapter generation."""
    if job.chapter_write_generation is None:
        return False
    result = db.execute(
        update(Chapter)
        .where(
            Chapter.id == job.chapter_id,
            Chapter.write_generation == job.chapter_write_generation,
        )
        .values(draft_text=job.baseline_text, status=job.baseline_status, updated_at=utc_now())
    )
    if result.rowcount != 1:
        db.rollback()
        return False
    if phase is not None and not _apply_job_phase(db, job.job_id, phase, **fields):
        db.rollback()
        return False
    db.commit()
    return True


def _restore_draft_ready(db: Session, job: WriteJob) -> None:
    if not write_registry.is_current(job): return
    chapter = db.get(Chapter, job.chapter_id)
    if chapter is not None:
        chapter.status = "draft_ready"; db.commit()
