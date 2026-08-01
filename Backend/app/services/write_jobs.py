from __future__ import annotations

import hashlib
import threading
import time
from collections.abc import Callable
from typing import Any

from sqlalchemy import update
from sqlalchemy.orm import Session, sessionmaker

from app.agents.checker import CheckerAgent
from app.agents.memory_selector import MemorySelection, MemorySelectorAgent
from app.agents.writer import WriterAgent
from app.llm.base import LLMError
from app.models import Chapter, ChapterDraftCandidate, JobRun
from app.models.entities import utc_now
from app.services.audit import record_llm_call
from app.services.context import (
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
from app.services.extraction import apply_extractor_output


TERMINAL_PHASES = {"done", "failed", "cancelled"}


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
        selected_character_ids: list[str] | None = None,
        bible_snapshot: str = "",
        bible_sha256: str = "",
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
        self.selected_character_ids = selected_character_ids or []
        self.bible_snapshot = bible_snapshot
        self.bible_sha256 = bible_sha256 or hashlib.sha256(bible_snapshot.encode()).hexdigest()
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
            persist()
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
        "upstream_reason": exc.upstream_reason, "finish_reason": exc.finish_reason, "block_reason": exc.block_reason,
    }.items() if value is not None}


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
        # The snapshot must still match before any model output can affect storage.
        if hashlib.sha256(chapter.user_prompt.encode()).hexdigest() != job.bible_sha256:
            record_job_phase(sf, job.job_id, "cancelled", error_code="bible_changed", error_message="Bible 已变更，已取消旧写作任务")
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
            valid_conflicts = pack_memory_brief(job.memory_candidates, selection.conflicts, remaining)
            conflicts = [{"text": item.text, "source_ids": item.id.split("|")} for item in valid_conflicts]
            source_by_id = {block.id: block for block in job.memory_candidates}
            used_source_ids = [source_id for item in memories + valid_conflicts for source_id in item.id.split("|")]
            manifest = {**packed_ending.manifest(), "memory_brief": [
                {"text": item.text, "source_ids": item.id.split("|"), "chapter_index": item.chapter_index,
                 "memory_type": item.memory_type} for item in memories], "conflicts": conflicts}
            manifest["sources"] = [
                {"id": source_id, "chapter_index": source_by_id[source_id].chapter_index,
                 "memory_type": source_by_id[source_id].memory_type, "source_excerpt": source_by_id[source_id].text}
                for source_id in dict.fromkeys(used_source_ids) if source_id in source_by_id
            ]
            record_job_phase(sf, job.job_id, "writing", memory_context=manifest, bible_sha256=job.bible_sha256)
        if _should_stop(job):
            _restore_baseline(db, job); job.mark_terminal(); return
        message = writer_user_message(chapter.book, chapter, memories, previous_ending, bible=job.bible_snapshot)
        last_candidate: ChapterDraftCandidate | None = None
        for attempt in (1, 2):
            record_job_phase(sf, job.job_id, "writing", attempt=attempt)
            text = _run_writer(job, sf, message)
            if _should_stop(job):
                _restore_baseline(db, job); job.mark_terminal(); return
            _normal_finish_or_raise(job, "writer", job.writer)
            violations = draft_violations(db, chapter, text, job.writer.finish_reason if job.writer else None)
            last_candidate = _persist_candidate(db, job, chapter, text, attempt, violations)
            length_only = all(item["code"] in {"empty_body", "minimum_length", "length_truncated"} for item in violations)
            if not violations:
                break
            if attempt == 1 and length_only:
                continue  # exact same original input; never expand the first text.
            _restore_baseline(db, job)
            code = "writer_minimum_failed" if length_only else "writer_validation_failed"
            record_job_phase(sf, job.job_id, "failed", attempt=attempt, violations=violations, error_code=code,
                             error_message="整章生成未通过确定性校验；失败稿已后台留档，未替换当前正文",
                             error_context={"agent_role": "writer"})
            job.mark_terminal("failed")
            return
        assert last_candidate is not None
        if hashlib.sha256(chapter.user_prompt.encode()).hexdigest() != job.bible_sha256 or not write_registry.is_current(job):
            _restore_baseline(db, job); job.mark_terminal(); return
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
            checker_result = {"status": "unavailable", "draft_fingerprint": fingerprint, "error_code": "checker_invalid", "error_message": str(exc)}
        if checker_result.get("verdict") == "passed":
            def persist_passed() -> None:
                last_candidate.checker_result = checker_result
                db.execute(
                    update(ChapterDraftCandidate)
                    .where(ChapterDraftCandidate.chapter_id == chapter.id)
                    .values(is_current=False)
                )
                last_candidate.is_current = True
                chapter.draft_text, chapter.status = last_candidate.draft_text, "draft_ready"
                # Flush the authoritative chapter timestamp before stamping the
                # terminal run, so outcome_current remains deterministic.
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

            if not write_registry.finish_if_current(job, persist_passed, phase="done"):
                db.rollback()
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

            def persist_rejected() -> None:
                last_candidate.checker_result = checker_result
                chapter.draft_text, chapter.status = job.baseline_text, job.baseline_status
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

            if not write_registry.finish_if_current(job, persist_rejected, phase="failed"):
                db.rollback()
                return
    except LLMError as exc:
        db.rollback(); _restore_baseline(db, job)
        record_job_phase(sf, job.job_id, "failed", error_code=exc.code, error_message=str(exc), error_context=_error_context(exc))
        job.mark_terminal("failed")
    except Exception as exc:
        db.rollback(); _restore_baseline(db, job)
        record_job_phase(sf, job.job_id, "failed", error_code="write_failed", error_message=str(exc))
        job.mark_terminal("failed")
    finally:
        db.close()


def _run_extract_job(job: WriteJob, sf: sessionmaker[Session]) -> None:
    db = sf()
    try:
        chapter = db.get(Chapter, job.chapter_id)
        if chapter is None:
            record_job_phase(sf, job.job_id, "failed", error_code="chapter_missing", error_message="章节不存在"); job.mark_terminal("failed"); return
        start, client = time.monotonic(), getattr(job.extractor, "llm", None)
        try:
            output = job.extractor.extract(job.extractor_user_message, job.selected_character_ids)
        except LLMError as exc:
            _record_llm(sf, "extractor", client, start, exc.code, job, upstream_reason=exc.upstream_reason)
            exc.agent_role, exc.model_name = "extractor", getattr(client, "model_name", None); raise
        _record_llm(sf, "extractor", client, start, None, job)
        if _should_stop(job): db.rollback(); job.mark_terminal(); return
        updated_ids, event_ids = apply_extractor_output(db, chapter, output); db.commit()
        record_job_phase(sf, job.job_id, "done", updated_character_ids=updated_ids, added_event_ids=event_ids); job.mark_terminal("done")
    except LLMError as exc:
        db.rollback(); _restore_draft_ready(db, job)
        record_job_phase(sf, job.job_id, "failed", error_code=exc.code, error_message=str(exc), error_context=_error_context(exc)); job.mark_terminal("failed")
    except Exception as exc:
        db.rollback(); _restore_draft_ready(db, job)
        record_job_phase(sf, job.job_id, "failed", error_code="extract_failed", error_message=f"提取失败：{exc}"); job.mark_terminal("failed")
    finally:
        db.close()


def _should_stop(job: WriteJob) -> bool:
    return job.cancel_event.is_set() or not write_registry.is_current(job)


def _restore_baseline(db: Session, job: WriteJob) -> None:
    if not write_registry.is_current(job): return
    chapter = db.get(Chapter, job.chapter_id)
    if chapter is not None:
        chapter.draft_text, chapter.status = job.baseline_text, job.baseline_status; db.commit()


def _restore_draft_ready(db: Session, job: WriteJob) -> None:
    if not write_registry.is_current(job): return
    chapter = db.get(Chapter, job.chapter_id)
    if chapter is not None:
        chapter.status = "draft_ready"; db.commit()
