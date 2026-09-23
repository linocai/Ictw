from __future__ import annotations

import hashlib
import json
import logging
import threading
import time
from collections.abc import Callable
from typing import Any

from sqlalchemy import select, text, update
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
    memory_selection_problem,
    nonspace_len,
    pack_selector_context,
    pack_writer_context,
    writer_user_message,
    writing_reference_context,
)
from app.services.archive_v2 import (
    archive_validation_message,
    ArchiveFingerprintMismatch,
    ArchiveV2ValidationError,
    activate_archive_revision,
    invalidate_downstream_archives,
    mark_revision_extracting,
    mark_revision_failed,
    mark_revision_partial,
    validate_archive_output,
)
from app.services.content_revisions import bump_content_revision
from app.services.checker_validation import CheckerValidationError, validate_checker_result
from app.services.production_context import (
    bind_selected_candidate_draft,
    is_frozen_input_current,
    prepare_selected_write_input,
)
from app.services.search_index import rebuild_book_search_index
from app.services.character_state_projection import rebuild_book_projection
from app.services.write_ownership import (
    cancel_local_writer_jobs,
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
        checker_snapshot: dict[str, Any] | None = None,
        checker_candidate_id: str | None = None,
        checker_draft_text: str = "",
        checker_draft_fingerprint: str = "",
        checker_user_message: str = "",
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
        self.checker_snapshot = checker_snapshot or {}
        self.checker_candidate_id = checker_candidate_id
        self.checker_draft_text = checker_draft_text
        self.checker_draft_fingerprint = checker_draft_fingerprint
        self.checker_user_message = checker_user_message
        self.cancel_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.discard_on_cancel = False
        self._lock = threading.Lock()
        self._terminal = False
        # Final persistence may run a short database transaction.  The flag
        # records that it has won the in-memory ownership race without holding
        # this per-job lock across that transaction.
        self._finalizing = False
        self.phase = (
            "extracting" if kind == "extract" else
            "checking" if kind == "check" else
            ("selecting_memory" if memory_selector else "writing")
        )

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
            if self._jobs.get(job.chapter_id) is not job:
                return False
            with job._lock:
                if job._terminal or job.phase in TERMINAL_PHASES or job._finalizing:
                    return False
                job.discard_on_cancel = discard
                job.cancel_event.set()
                job.phase = "cancelled"
                job._terminal = True
                return True

    def finish_if_current(self, job: WriteJob, persist: Callable[[], None], *, phase: str) -> bool:
        """Persist a terminal result only while this job exclusively owns the chapter.

        First prove that the registry still points to this live job, then mark
        the job as finalizing under its state lock.  The callback may acquire a
        short SQLite transaction, but no registry or job mutex remains held
        while it does so.  This avoids every DB -> in-memory lock inversion
        for conditional-write routes; cancellation that arrives after the
        finalization marker deliberately loses, matching the old behavior
        where final persistence held the registry mutex.
        """
        with self._lock:
            if (
                self._jobs.get(job.chapter_id) is not job
                or job.cancel_event.is_set()
                or job.is_terminal
            ):
                return False
        with job._lock:
            if (
                job.cancel_event.is_set()
                or job._terminal
                or job.phase in TERMINAL_PHASES
                or job._finalizing
            ):
                return False
            job._finalizing = True
        try:
            if persist() is False:
                return False
            with job._lock:
                job.phase = phase
                job._terminal = True
            return True
        finally:
            with job._lock:
                job._finalizing = False

    def launch(self, job: WriteJob, session_factory: sessionmaker[Session]) -> None:
        target = {
            "extract": _run_extract_job,
            "check": _run_checker_retry_job,
        }.get(job.kind, _run_job)
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
        "bible_sha256", "draft_fingerprint", "input_snapshot", "input_fingerprint",
        "context_limitations", "candidate_id", "parent_job_id",
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


def fail_unlaunched_job(
    session_factory: sessionmaker[Session],
    job: WriteJob,
    *,
    error_code: str,
    error_message: str,
    checker_result: dict[str, Any] | None = None,
) -> bool:
    """Durably end a reserved job whose route could not launch its thread.

    Reservation intentionally precedes the durable request commit so two
    requests cannot start work for one chapter.  If that commit or the thread
    launch fails, the in-memory reservation must be released and any already
    persisted row must converge to a terminal state.  A write job also owns a
    visible ``writing`` status, so restore its baseline when it still owns the
    recorded generation.  No model work has begun on this path.
    """
    db = session_factory()
    try:
        run = db.get(JobRun, job.job_id)
        if run is None or run.phase in TERMINAL_PHASES:
            return False
        chapter = db.get(Chapter, job.chapter_id)
        if job.kind == "write" and chapter is not None and job.chapter_write_generation is not None:
            db.execute(
                update(Chapter)
                .where(
                    Chapter.id == chapter.id,
                    Chapter.write_generation == job.chapter_write_generation,
                )
                .values(
                    draft_text=job.baseline_text,
                    status=job.baseline_status,
                    updated_at=utc_now(),
                    content_revision=Chapter.content_revision + 1,
                )
            )
        if checker_result is not None:
            run.checker_result = checker_result
            if run.candidate_id:
                candidate = db.get(ChapterDraftCandidate, run.candidate_id)
                if candidate is not None and candidate.latest_checker_attempt_id == run.id:
                    candidate.checker_result = checker_result
        if not _apply_job_phase(
            db,
            job.job_id,
            "failed",
            error_code=error_code,
            error_message=error_message,
            error_context={"agent_role": "write_pipeline" if job.kind == "write" else "checker"},
            checker_result=checker_result,
        ):
            db.rollback()
            return False
        db.commit()
        return True
    finally:
        db.close()


def _error_context(exc: LLMError) -> dict[str, Any]:
    return {key: value for key, value in {
        "agent_role": exc.agent_role, "model_name": exc.model_name, "http_status": exc.status_code,
        "upstream_reason": safe_upstream_reason(exc.upstream_reason),
        "finish_reason": safe_finish_reason(exc.finish_reason),
        "block_reason": safe_block_reason(exc.block_reason),
    }.items() if value is not None}


def _public_context_limitations(limitations: object) -> list[dict[str, Any]]:
    """Translate frozen readiness rows for the public checker result wire."""
    if not isinstance(limitations, list):
        return []
    result: list[dict[str, Any]] = []
    for item in limitations:
        if not isinstance(item, dict):
            continue
        chapter_id = item.get("chapter_id")
        index = item.get("chapter_index", item.get("index"))
        title = item.get("title")
        reason = item.get("reason")
        effective_status = item.get("kind", item.get("effective_status"))
        if (
            isinstance(chapter_id, str)
            and isinstance(index, int)
            and isinstance(title, str)
            and isinstance(reason, str)
            and isinstance(effective_status, str)
        ):
            result.append({
                "chapter_id": chapter_id,
                "index": index,
                "title": title,
                "reason": reason,
                "effective_status": effective_status,
            })
    return result


def _begin_final_checker_cas(db: Session) -> None:
    """Serialize SQLite's final proof reads with the promotion write.

    Python 3.12's sqlite driver can leave a SELECT-only Session outside a
    transaction.  Without this reservation another request can change a
    frozen dependency after validation but before the first UPDATE.  Model
    work is already complete; this short lock covers only proof and commit.
    """
    if db.bind is not None and db.bind.dialect.name == "sqlite":
        db.execute(text("BEGIN IMMEDIATE"))


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


def _call(
    job: WriteJob,
    session_factory: sessionmaker[Session],
    role: str,
    method: Any,
    *args: Any,
    **kwargs: Any,
) -> Any:
    start = time.monotonic()
    agent = {"memory_selector": job.memory_selector, "writer": job.writer, "checker": job.checker}[role]
    client = getattr(agent, "llm", None)
    try:
        result = method(*args, **kwargs)
    except LLMError as exc:
        _record_llm(session_factory, role, client, start, exc.code, job, upstream_reason=exc.upstream_reason)
        exc.agent_role, exc.model_name = role, getattr(client, "model_name", None)
        raise
    _record_llm(session_factory, role, client, start, None, job)
    return result


def _run_memory_selector(job: WriteJob, sf: sessionmaker[Session]) -> MemorySelection:
    assert job.memory_selector is not None
    return _call(
        job,
        sf,
        "memory_selector",
        job.memory_selector.select,
        job.selector_user_message,
        validator=lambda selection: memory_selection_problem(
            job.memory_candidates,
            selection.briefs,
            selection.conflicts,
            selection.previous_ending_start_id,
            budget=job.memory_budget,
        ),
    )


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


def _valid_checker_result(raw: Any, fingerprint: str, *, bible_required: bool = True) -> dict[str, Any]:
    if not isinstance(raw, dict) or raw.get("verdict") not in {"passed", "suspect", "violation"}:
        raise ValueError("Checker 返回结构无效")
    if not isinstance(raw.get("issues"), list):
        raise ValueError("Checker 缺少有效问题列表")
    issues: list[dict[str, str]] = []
    for item in raw["issues"]:
        if not isinstance(item, dict):
            continue
        required = [item.get(key) for key in ("kind", "draft_evidence", "reason")]
        bible_evidence = item.get("bible_evidence")
        # Imported prose may have no chapter requirements. Keep evidence for
        # other checks without demanding a fabricated quote from an empty Bible.
        valid_bible = isinstance(bible_evidence, str) and (bool(bible_evidence.strip()) if bible_required else True)
        if valid_bible and all(isinstance(value, str) and value.strip() for value in required):
            issues.append({key: item[key].strip() for key in ("kind", "draft_evidence", "bible_evidence", "reason")})
    if raw["verdict"] == "violation" and not issues:
        return {"verdict": "suspect", "issues": [], "draft_fingerprint": fingerprint, "invalid_evidence": True}
    return {"verdict": raw["verdict"], "issues": issues, "draft_fingerprint": fingerprint}


def _run_checker_retry_job(job: WriteJob, sf: sessionmaker[Session]) -> None:
    """Recheck one retained Writer candidate without repeating selection/write.

    The route has already persisted the immutable check attempt and constructed
    the prompt.  This worker therefore owns no ORM object while the Checker
    call is in flight; the final transaction proves that this exact private
    candidate and frozen source set are still current before promotion.
    """
    snapshot = job.checker_snapshot
    fingerprint = job.checker_draft_fingerprint
    try:
        assert job.checker is not None
        raw = _call(job, sf, "checker", job.checker.check, job.checker_user_message)
        result = validate_checker_result(raw, snapshot, check_attempt_id=job.job_id)
        result["draft_fingerprint"] = fingerprint
    except LLMError as exc:
        result = {
            "status": "unavailable", "draft_fingerprint": fingerprint,
            "input_fingerprint": snapshot.get("input_fingerprint", ""),
            "check_attempt_id": job.job_id, "error_code": exc.code,
            "error_context": _error_context(exc),
        }
    except (CheckerValidationError, ValueError, TypeError):
        result = {
            "status": "unavailable", "draft_fingerprint": fingerprint,
            "input_fingerprint": snapshot.get("input_fingerprint", ""),
            "check_attempt_id": job.job_id, "error_code": "checker_invalid_response",
            "error_message": "检查模型未返回有效检查结论",
        }

    # Result payloads are also consumed directly by the job read-model.  Use
    # the same public limitation wire shape as production-readiness instead of
    # leaking the frozen internal chapter_index/kind representation.
    result["context_limitations"] = _public_context_limitations(snapshot.get("context_limitations"))

    db = sf()
    try:
        # SQLite does not begin a transaction for SELECTs under the legacy
        # driver mode.  Reserve the short final window before *any* proof
        # read, otherwise a dependency PATCH can land between the proof and
        # the promotion UPDATE below.
        _begin_final_checker_cas(db)
        run = db.get(JobRun, job.job_id)
        candidate = db.get(ChapterDraftCandidate, job.checker_candidate_id)
        chapter = db.get(Chapter, job.chapter_id)
        if run is None or candidate is None or chapter is None:
            if run is not None:
                _apply_job_phase(db, job.job_id, "failed", error_code="checker_source_missing", error_message="原写作候选已不存在")
                db.commit()
            job.mark_terminal("failed")
            return

        current = (
            run.phase == "checking"
            and candidate.latest_checker_attempt_id == job.job_id
            and candidate.checker_input_fingerprint == snapshot.get("input_fingerprint")
            and candidate.checker_input_snapshot == snapshot
            and hashlib.sha256(candidate.draft_text.encode()).hexdigest() == snapshot.get("draft", {}).get("sha256")
            and is_frozen_input_current(db, chapter, snapshot)
        )
        if not current:
            _apply_job_phase(
                db, job.job_id, "cancelled", error_code="checker_input_changed",
                error_message="检查期间输入已变更，旧结论未应用",
            )
            db.commit()
            job.mark_terminal("cancelled")
            return

        candidate.checker_result = result
        if result.get("verdict") == "passed":
            promoted = db.execute(
                update(Chapter)
                .where(Chapter.id == chapter.id, Chapter.write_generation == run.chapter_write_generation)
                .values(
                    draft_text=candidate.draft_text, status="draft_ready", updated_at=utc_now(),
                    content_revision=Chapter.content_revision + 1,
                )
            )
            if promoted.rowcount != 1:
                db.rollback()
                _mark_chapter_changed(sf, job)
                job.mark_terminal("cancelled")
                return
            db.execute(
                update(ChapterDraftCandidate)
                .where(ChapterDraftCandidate.chapter_id == chapter.id)
                .values(is_current=False)
            )
            candidate.is_current = True
            rebuild_book_search_index(db, chapter.book_id)
            _apply_job_phase(
                db, job.job_id, "done", checker_result=result,
                draft_fingerprint=fingerprint, input_snapshot=snapshot,
                input_fingerprint=snapshot.get("input_fingerprint"),
                context_limitations=snapshot.get("context_limitations"),
            )
            db.commit()
            job.mark_terminal("done")
            return

        reasons = [
            item.get("reason", "").strip() for item in result.get("issues", [])
            if isinstance(item, dict) and isinstance(item.get("reason"), str) and item.get("reason", "").strip()
        ]
        message = result.get("error_message") or (
            f"Checker 未通过：{'；'.join(reasons)}；失败稿已后台留档，未替换当前正文"
            if reasons else "Checker 未通过；失败稿已后台留档，未替换当前正文"
        )
        _apply_job_phase(
            db, job.job_id, "failed", checker_result=result,
            draft_fingerprint=fingerprint, input_snapshot=snapshot,
            input_fingerprint=snapshot.get("input_fingerprint"),
            context_limitations=snapshot.get("context_limitations"),
            error_code=result.get("error_code") or "checker_rejected",
            error_message=message,
            error_context=result.get("error_context") or {"agent_role": "checker"},
        )
        db.commit()
        job.mark_terminal("failed")
    except Exception:
        db.rollback()
        record_job_phase(sf, job.job_id, "failed", error_code="checker_retry_failed", error_message="Checker 重试执行失败")
        job.mark_terminal("failed")
    finally:
        db.close()


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
        conflicts: list[MemoryBlock] = []
        deterministic_ending = pack_writer_context(job.memory_candidates, [], None, job.memory_budget)
        previous_ending = deterministic_ending.previous_ending
        ending_start_id = next(
            (block.id for block in job.memory_candidates if block.memory_type == "previous_ending"), None
        )
        manifest: dict[str, Any] = {
            "memory_brief": [],
            "conflicts": [],
            "previous_ending_start_id": ending_start_id,
            "previous_ending": previous_ending,
            "selection_mode": "deterministic_no_selector",
        }
        # No session/transaction is retained while either model is executing.
        # Selector receives the pure prompt frozen by the route; refresh all
        # database state after it returns before building Writer input.
        db.rollback()
        if job.memory_selector:
            record_job_phase(sf, job.job_id, "selecting_memory", bible_sha256=job.bible_sha256)
            selection = _run_memory_selector(job, sf)
            packed_context = pack_selector_context(
                job.memory_candidates,
                selection.briefs,
                selection.conflicts,
                selection.previous_ending_start_id,
                budget=job.memory_budget,
            )
            memories = packed_context.memories
            conflicts = list(packed_context.conflicts or [])
            previous_ending = packed_context.previous_ending
            source_by_id = {block.id: block for block in job.memory_candidates}
            used_source_ids = [source_id for item in memories + conflicts for source_id in item.id.split("|")]
            manifest = {
                "memory_brief": [
                {"text": item.text, "source_ids": item.id.split("|"), "chapter_index": item.chapter_index,
                 "memory_type": item.memory_type} for item in memories],
                "conflicts": [{"text": item.text, "source_ids": item.id.split("|")} for item in conflicts],
                "previous_ending_start_id": selection.previous_ending_start_id,
                "previous_ending": previous_ending,
                "selection_mode": "selector",
            }
            manifest["memory_non_whitespace_count"] = sum(nonspace_len(item.text) for item in memories)
            manifest["sources"] = [
                {"id": source_id, "chapter_index": source_by_id[source_id].chapter_index,
                 "memory_type": source_by_id[source_id].memory_type, "source_excerpt": source_by_id[source_id].text}
                for source_id in dict.fromkeys(used_source_ids) if source_id in source_by_id
            ]
            record_job_phase(sf, job.job_id, "writing", memory_context=manifest, bible_sha256=job.bible_sha256)
        chapter = db.get(Chapter, job.chapter_id)
        if chapter is None or not _generation_matches(db, job) or hashlib.sha256(chapter.user_prompt.encode()).hexdigest() != job.bible_sha256:
            _mark_chapter_changed(sf, job)
            job.mark_terminal("cancelled")
            return
        if _should_stop(job):
            if not _restore_baseline(
                db, job, phase="cancelled", error_code="write_cancelled", error_message="写作任务已取消"
            ):
                _mark_chapter_changed(sf, job)
            job.mark_terminal(); return
        # Freeze every source that will constrain Writer before it is called.
        # Binding the private candidate text later is a pure JSON operation;
        # it must never reread history/projection after the model has started.
        prepared_checker_snapshot = prepare_selected_write_input(
            db, chapter, memory_manifest=manifest
        )
        reference_context = prepared_checker_snapshot["reference_context"]
        message = writer_user_message(
            chapter.book, chapter, bible=job.bible_snapshot, reference_context=reference_context,
        )
        record_job_phase(
            sf, job.job_id, "writing", memory_context=manifest,
            input_snapshot=prepared_checker_snapshot,
            input_fingerprint=prepared_checker_snapshot["input_fingerprint"],
            context_limitations=prepared_checker_snapshot["context_limitations"],
        )
        # The prompt now contains only plain values. End the short source-read
        # transaction before streaming Writer output.
        db.commit()
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
        checker_snapshot = bind_selected_candidate_draft(
            prepared_checker_snapshot, last_candidate.draft_text
        )
        # The Writer and Checker must see the exact same frozen references.
        # This catches accidental drift in either context assembler before a
        # model conclusion is allowed to influence a visible chapter.
        if checker_snapshot["reference_context"] != reference_context:
            raise RuntimeError("writer and checker reference contexts diverged")
        last_candidate.checker_input_snapshot = checker_snapshot
        last_candidate.checker_input_fingerprint = checker_snapshot["input_fingerprint"]
        last_candidate.latest_checker_attempt_id = job.job_id
        candidate_attempt = last_candidate.attempt
        candidate_id = last_candidate.id
        candidate_text = last_candidate.draft_text
        checker_message = checker_user_message(
            chapter, candidate_text, job.bible_snapshot,
            reference_context=checker_snapshot["reference_context"],
            source_catalog=checker_snapshot["source_catalog"],
            name_hits=checker_snapshot["name_hits"],
            name_groups=checker_snapshot.get("name_groups"),
            name_candidate_groups=checker_snapshot.get("name_candidate_groups"),
        )
        db.commit()
        record_job_phase(
            sf,
            job.job_id,
            "checking",
            attempt=candidate_attempt,
            draft_fingerprint=fingerprint,
            candidate_id=candidate_id,
            input_snapshot=checker_snapshot,
            input_fingerprint=checker_snapshot["input_fingerprint"],
            context_limitations=checker_snapshot["context_limitations"],
        )
        try:
            assert job.checker is not None
            raw = _call(
                job,
                sf,
                "checker",
                job.checker.check,
                checker_message,
            )
            checker_result = validate_checker_result(raw, checker_snapshot, check_attempt_id=job.job_id)
            checker_result["draft_fingerprint"] = fingerprint
        except LLMError as exc:
            checker_result = {
                "status": "unavailable", "draft_fingerprint": fingerprint,
                "input_fingerprint": checker_snapshot["input_fingerprint"],
                "check_attempt_id": job.job_id,
                "error_code": exc.code, "error_context": _error_context(exc),
            }
        except (CheckerValidationError, ValueError, TypeError):
            checker_result = {
                "status": "unavailable",
                "draft_fingerprint": fingerprint,
                "input_fingerprint": checker_snapshot["input_fingerprint"],
                "check_attempt_id": job.job_id,
                "error_code": "checker_invalid_response",
                "error_message": "检查模型未返回有效检查结论",
            }
        checker_result["context_limitations"] = _public_context_limitations(
            checker_snapshot.get("context_limitations")
        )
        if checker_result.get("verdict") == "passed":
            def persist_passed() -> bool:
                # The candidate, visible chapter and terminal JobRun are one
                # transaction.  This must use a new Session: the worker's
                # pre-Writer reads remain in its identity map while models run
                # (SessionLocal intentionally has expire_on_commit=False).
                # Refreshing only Chapter/Candidate is insufficient because
                # frozen-input validation also reads book, character, archive
                # and history dependencies.
                final_db = sf()
                try:
                    _begin_final_checker_cas(final_db)
                    final_chapter = final_db.get(Chapter, job.chapter_id)
                    final_candidate = final_db.get(ChapterDraftCandidate, candidate_id)
                    final_run = final_db.get(JobRun, job.job_id)
                    snapshot = final_candidate.checker_input_snapshot if final_candidate is not None else None
                    if (
                        final_chapter is None
                        or final_candidate is None
                        or final_run is None
                        or final_run.phase != "checking"
                        or final_candidate.latest_checker_attempt_id != job.job_id
                        or final_candidate.checker_input_fingerprint != checker_snapshot["input_fingerprint"]
                        or not isinstance(snapshot, dict)
                        or snapshot != checker_snapshot
                        or hashlib.sha256(final_candidate.draft_text.encode()).hexdigest() != snapshot.get("draft", {}).get("sha256")
                        or not is_frozen_input_current(final_db, final_chapter, snapshot)
                    ):
                        return False
                    result = final_db.execute(
                        update(Chapter)
                        .where(
                            Chapter.id == final_chapter.id,
                            Chapter.write_generation == job.chapter_write_generation,
                        )
                        .values(
                            draft_text=final_candidate.draft_text,
                            status="draft_ready",
                            updated_at=utc_now(),
                            content_revision=Chapter.content_revision + 1,
                        )
                    )
                    if result.rowcount != 1:
                        final_db.rollback()
                        return False
                    final_candidate.checker_result = checker_result
                    final_db.execute(
                        update(ChapterDraftCandidate)
                        .where(ChapterDraftCandidate.chapter_id == final_chapter.id)
                        .values(is_current=False)
                    )
                    final_candidate.is_current = True
                    rebuild_book_search_index(final_db, final_chapter.book_id)
                    final_db.flush()
                    if not _apply_job_phase(
                        final_db,
                        job.job_id,
                        "done",
                        checker_result=checker_result,
                        bible_sha256=job.bible_sha256,
                        draft_fingerprint=fingerprint,
                    ):
                        raise RuntimeError("write job terminal row is no longer writable")
                    final_db.commit()
                    return True
                except Exception:
                    final_db.rollback()
                    raise
                finally:
                    final_db.close()

            if not write_registry.finish_if_current(job, persist_passed, phase="done"):
                db.rollback()
                if not _restore_stale_checker_baseline(sf, job):
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
                final_db = sf()
                try:
                    _begin_final_checker_cas(final_db)
                    final_chapter = final_db.get(Chapter, job.chapter_id)
                    final_candidate = final_db.get(ChapterDraftCandidate, candidate_id)
                    final_run = final_db.get(JobRun, job.job_id)
                    snapshot = final_candidate.checker_input_snapshot if final_candidate is not None else None
                    if (
                        final_chapter is None
                        or final_candidate is None
                        or final_run is None
                        or final_run.phase != "checking"
                        or final_candidate.latest_checker_attempt_id != job.job_id
                        or final_candidate.checker_input_fingerprint != checker_snapshot["input_fingerprint"]
                        or not isinstance(snapshot, dict)
                        or snapshot != checker_snapshot
                        or hashlib.sha256(final_candidate.draft_text.encode()).hexdigest() != snapshot.get("draft", {}).get("sha256")
                        or not is_frozen_input_current(final_db, final_chapter, snapshot)
                    ):
                        return False
                    result = final_db.execute(
                        update(Chapter)
                        .where(
                            Chapter.id == final_chapter.id,
                            Chapter.write_generation == job.chapter_write_generation,
                        )
                        .values(
                            draft_text=job.baseline_text,
                            status=job.baseline_status,
                            updated_at=utc_now(),
                            content_revision=Chapter.content_revision + 1,
                        )
                    )
                    if result.rowcount != 1:
                        final_db.rollback()
                        return False
                    final_candidate.checker_result = checker_result
                    final_db.flush()
                    if not _apply_job_phase(
                        final_db,
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
                    final_db.commit()
                    return True
                except Exception:
                    final_db.rollback()
                    raise
                finally:
                    final_db.close()

            if not write_registry.finish_if_current(job, persist_rejected, phase="failed"):
                db.rollback()
                if not _restore_stale_checker_baseline(sf, job):
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
            bump_content_revision(chapter)
            for invalidated_id in invalidated_downstream:
                invalidated_chapter = db.get(Chapter, invalidated_id)
                if invalidated_chapter is not None:
                    bump_content_revision(invalidated_chapter)
            rebuild_book_projection(db, chapter.book_id)
            # Do not cancel every later task merely because a revision ID was
            # replaced: the v2.2 snapshot compares source semantic identity
            # and content, so a byte-identical rearchive stays usable. A
            # changed brief/fact/candidate range is rejected by the final
            # frozen-input CAS below; local cancellation is only an optional
            # optimization and must not become a false invalidation gate.
            invalidated_writer_chapters = []
            rebuild_book_search_index(db, chapter.book_id)
            # The terminal JobRun timestamp is compared with the visible
            # chapter timestamp by /job. Flush all content revision/status
            # mutations first so a terminal run can never look older than its
            # own successfully activated archive state.
            db.flush()
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
            bump_content_revision(chapter)
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
            # Mirrors activate_archive_revision: a stale attempt must not strip
            # the chapter of its surviving memory source. Clearing
            # legacy_archive_eligible here erased legacy chapters outright
            # whenever a manual retry raced an edit to an earlier chapter.
            chapter.archive_status = "stale"
            bump_content_revision(chapter)
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
            rebuild_book_search_index(db, chapter.book_id)
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
            mark_revision_partial(
                revision,
                chapter,
                reason=reason,
                summary=summary,
                diagnostics=getattr(exc, "diagnostics", None),
            )
            bump_content_revision(chapter)
            db.flush()
            _apply_job_phase(
                db,
                job.job_id,
                "failed",
                attempt=1,
                error_code="archive_validation_failed",
                error_message=f"归档未通过确定性校验：{archive_validation_message(reason)}",
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
            bump_content_revision(chapter)
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


def _restore_stale_checker_baseline(session_factory: sessionmaker[Session], job: WriteJob) -> bool:
    """Restore the owned baseline when a fresh Checker CAS sees other drift.

    Some frozen dependencies (for example a newly relevant name hit or an
    earlier archive fact) do not necessarily advance this chapter's writer
    generation.  They still make a waiting Checker conclusion stale.  In that
    case the visible chapter may still say ``writing`` until this worker puts
    its own baseline back.  If another owner advanced the generation or
    cancelled the local job, that owner already controls visible restoration.
    """
    if _should_stop(job):
        return False
    db = session_factory()
    try:
        if not _generation_matches(db, job):
            return False
        return _restore_baseline(
            db,
            job,
            phase="cancelled",
            error_code="checker_input_changed",
            error_message="检查期间参考资料已变更，旧写作结果未应用",
        )
    finally:
        db.close()


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
        .values(
            draft_text=job.baseline_text,
            status=job.baseline_status,
            updated_at=utc_now(),
            content_revision=Chapter.content_revision + 1,
        )
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
        chapter.status = "draft_ready"
        bump_content_revision(chapter)
        db.commit()
