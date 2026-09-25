from __future__ import annotations

import hashlib
import time
from collections.abc import Callable

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response, status
from sqlalchemy import func, select, text, update
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlalchemy.orm import Session, object_session

from app.agents.extractor import ExtractorAgent
from app.agents.checker import CheckerAgent
from app.agents.inspiration_creator import InspirationCreatorAgent
from app.agents.memory_selector import MemorySelectorAgent
from app.agents.writer import WriterAgent
from app.db import SessionLocal, get_db
from app.llm.base import LLMError
from app.llm.factory import LLMConfigurationError
from app.llm.factory import (
    get_extractor_client,
    get_checker_client,
    get_inspiration_creator_client,
    get_memory_selector_client,
    get_writer_client,
)
from app.models import Book, Chapter, ChapterArchiveRevision, ChapterCharacter, ChapterDraftCandidate, Character, JobRun
from app.models.entities import utc_now, uuid_str
from app.schemas.chapter import (
    ChapterCreate,
    ChapterImportRequest,
    ChapterPatch,
    ChapterRead,
    ChapterSummary,
    ArchiveRetryRequest,
    CheckerRunRequest,
    CheckerRetryRequest,
    ProductionReadinessRead,
    CheckerAcceptRequest,
    CheckerRunRead,
    InspirationRequest,
    InspirationResponse,
    RewriteImpactChapter,
    RewriteImpactPreview,
    WriteJobStatus,
    WriteRequest,
)
from app.services.context import (
    CharacterPreflightError,
    draft_fingerprint,
    draft_violations,
    memory_budget,
    memory_candidates,
    memory_selector_user_message,
    nonspace_len,
    prefilter_memory_candidates,
    validate_character_preflight,
)
from app.services.personas import get_persona
from app.services.audit import record_llm_call
from app.services.character_state_projection import (
    projected_fields_before_chapter,
    projected_state_before_chapter,
    rebuild_book_projection,
)
from app.services.inspiration_context import InspirationContextError, build_inspiration_context
from app.services.write_jobs import (
    WriteJob, WriteJobConflict, _apply_job_phase, _error_context, _valid_checker_result, fail_unlaunched_job,
    record_job_phase, write_registry,
)
from app.services.write_ownership import cancel_local_writer_jobs, invalidate_writer_inputs
from app.services.archive_v2 import (
    archive_validation_message,
    archive_input_fingerprint,
    archive_health_summaries,
    archive_read_model,
    build_archive_user_message,
    create_archive_revision,
    invalidate_downstream_archives,
    invalidate_archive_if_input_changed,
    stale_archives_for_reopen,
)
from app.services.content_revisions import bump_content_revision, require_matching_revision
from app.services.search_index import rebuild_book_search_index

router = APIRouter(tags=["chapters"])

# Deterministic violations that no override may wave through on accept: an
# unattributable character name corrupts the archive rather than expressing an
# authorial choice. Length-class codes stay overridable on purpose.
_ACCEPT_BLOCKING_VIOLATIONS = {"empty_body", "unselected_character", "ambiguous_character"}


def _begin_short_write_cas(db: Session) -> None:
    """Make SQLite proof reads and their durable decision indivisible.

    SQLite's legacy Python driver does not start a transaction for a SELECT.
    The routes below therefore reserve a write transaction before their first
    proof read, while all model work remains outside this short window.
    """
    if db.bind is None or db.bind.dialect.name != "sqlite":
        return
    # `require_matching_revision()` may already have acquired this exact
    # SQLite reservation for a request carrying If-Match.  SQLAlchemy's
    # `Session.in_transaction()` is not useful here: a read-only SELECT
    # autobegins its bookkeeping transaction while the sqlite DB-API driver
    # still reports no actual transaction.  Query the driver state so an
    # If-Match accept keeps its existing lock, while a legacy read-only route
    # upgrades to the required immediate transaction exactly once.
    connection = db.connection()
    raw = connection.connection
    driver = getattr(raw, "driver_connection", raw)
    if getattr(driver, "in_transaction", False):
        return
    db.execute(text("BEGIN IMMEDIATE"))


def get_lazy_extractor_resolver(request: Request) -> Callable[[Session, str], object]:
    """Resolve Extractor only after an accepted chapter is committed.

    FastAPI resolves ordinary dependencies before entering a route, which made
    an Extractor configuration error reject an otherwise valid acceptance.
    Keep the established ``get_extractor_client`` override usable by tests and
    supervised fixtures while making the actual client resolution lazy.
    """
    override = request.app.dependency_overrides.get(get_extractor_client)
    if override is not None:
        return lambda _db, _chapter_id: override()
    return lambda session, chapter_id: get_extractor_client(chapter_id=chapter_id, db=session)


def get_lazy_memory_selector_resolver(request: Request) -> Callable[[Session, str], object]:
    """Avoid requiring any Selector configuration when history is empty."""
    override = request.app.dependency_overrides.get(get_memory_selector_client)
    if override is not None:
        return lambda _db, _chapter_id: override()
    return lambda session, chapter_id: get_memory_selector_client(chapter_id=chapter_id, db=session)


def _memory_context_incomplete(readiness: dict) -> HTTPException:
    return HTTPException(
        status_code=409,
        detail={
            "code": "memory_context_incomplete",
            "message": "本次写作或检查将缺少前章记忆；请先恢复或明确知情继续",
            "details": {
                "context_token": readiness["context_token"],
                "limitations": readiness["context_limitations"],
                "recommended_recovery": readiness["recommended_recovery"],
            },
        },
    )


def _violation_summary(violations: list[dict]) -> str:
    """Fold the deterministic messages into the top-level 409 message.

    Clients that predate the `violations` key still render `message`, so the
    offending character name has to travel in the sentence itself rather than
    only in the structured payload.
    """
    return "；".join(
        item["message"] for item in violations if isinstance(item.get("message"), str)
    )


def _require_task_revision(
    chapter_id: str,
    if_match: str | None = Header(default=None, alias="If-Match"),
    db: Session = Depends(get_db),
) -> None:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    require_matching_revision(
        chapter, if_match, resource_type="chapter", resource_id=chapter.id, db=db
    )


def _model_snapshot(client) -> dict[str, object]:
    """Persist only effective, non-secret runtime configuration."""
    return {
        "model_name": str(getattr(client, "model_name", "") or ""),
        "thinking_enabled": getattr(client, "thinking_enabled", None),
        "reasoning_effort": getattr(client, "reasoning_effort", None),
        "temperature": getattr(client, "temperature_override", None),
        "capability_family": getattr(client, "capability_family", None),
    }

_CHAPTER_CREATE_RETRIES = 3


def _chapter_read(chapter: Chapter) -> ChapterRead:
    note = chapter.author_note
    canonical_summary = chapter.long_summary.strip()
    session = object_session(chapter)
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
        # summary is a deprecated response mirror for old App builds.
        summary=canonical_summary,
        headline=chapter.headline,
        long_summary=canonical_summary,
        state_changes=list(chapter.state_changes or []),
        unresolved_items=list(chapter.unresolved_items or []),
        atomic_memories=list(chapter.atomic_memories or []),
        exempted_character_names=list(chapter.exempted_character_names or []),
        status=chapter.status,
        source=chapter.source,
        created_at=chapter.created_at,
        updated_at=chapter.updated_at,
        content_revision=chapter.content_revision,
        character_links=[{"character_id": link.character_id, "chapter_note": ""} for link in chapter.character_links],
        archive=archive_read_model(session, chapter) if session is not None else None,
    )


def _redacted_checker_result(result: dict | None) -> dict | None:
    """Strip verbatim excerpts from the JobRun's Checker record before it ships.

    On rejection the visible chapter is rolled back to its baseline, so this
    record describes a candidate the author never saw. `kind` and `reason`
    explain the verdict; `draft_evidence` quotes the rejected candidate and
    `bible_evidence` quotes the Bible passage it was matched against. The full
    record stays on the server (`chapter_draft_candidates`, `job_runs`) as the
    audit trail the contract asks for. `visible_checker_result` is not routed
    through here: it is only produced when the candidate text equals the text
    currently in the editor, so its evidence is the author's own.
    """
    if not isinstance(result, dict):
        return result
    redacted = dict(result)
    issues = result.get("issues")
    if isinstance(issues, list):
        redacted["issues"] = [
            {key: issue[key] for key in ("kind", "reason") if key in issue}
            if isinstance(issue, dict)
            else issue
            for issue in issues
        ]
    # ``name_uses`` necessarily contains candidate evidence.  A rejected
    # candidate is private, so no classification row may leave the backend.
    redacted.pop("name_uses", None)
    redacted.pop("identity_issues", None)
    redacted.pop("_validation_diagnostics", None)
    return redacted


def _public_visible_checker_result(result: dict | None) -> dict | None:
    """Keep private protocol diagnostics out of a visible-draft response."""
    if not isinstance(result, dict):
        return result
    public = dict(result)
    public.pop("_validation_diagnostics", None)
    return public


def _public_context_limitations(limitations: object) -> list[dict]:
    """Keep job/checker payloads decodable by the readiness wire model."""
    if not isinstance(limitations, list):
        return []
    result: list[dict] = []
    for item in limitations:
        if not isinstance(item, dict):
            continue
        chapter_id = item.get("chapter_id")
        index = item.get("chapter_index", item.get("index"))
        title = item.get("title")
        reason = item.get("reason")
        effective_status = item.get("kind", item.get("effective_status"))
        if all(isinstance(value, str) for value in (chapter_id, title, reason, effective_status)) and isinstance(index, int):
            result.append({
                "chapter_id": chapter_id,
                "index": index,
                "title": title,
                "reason": reason,
                "effective_status": effective_status,
            })
    return result


_CHECKER_RETRYABLE_CODES = frozenset({
    "checker_invalid_response", "llm_timeout", "llm_transport", "llm_rate_limited",
    "llm_upstream_unavailable", "llm_upstream_rejected", "llm_upstream_error",
    "llm_content_blocked", "llm_output_truncated", "llm_empty_candidate", "llm_invalid_response",
    "checker_retry_start_failed", "checker_retry_failed",
})


def _is_retryable_checker_attempt(run: JobRun) -> bool:
    """Whether this *latest* Checker attempt may be retried on its candidate.

    A retained Writer candidate may have several Checker attempts.  The old
    Writer fault is only historical after a later check concludes.  Startup
    recovery deliberately leaves an interrupted checking attempt retryable so
    that it does not strand a private candidate after process restart.
    """
    if run.phase != "failed":
        return False
    if run.error_code == "interrupted":
        context = run.error_context if isinstance(run.error_context, dict) else {}
        return run.kind == "check" or context.get("interrupted_phase") == "checking"
    result = run.checker_result if isinstance(run.checker_result, dict) else {}
    return run.error_code in _CHECKER_RETRYABLE_CODES and result.get("status") == "unavailable"


def _retry_source_and_latest_attempt(
    db: Session, run: JobRun,
) -> tuple[JobRun | None, ChapterDraftCandidate | None, JobRun | None]:
    """Resolve an immutable Writer source and its candidate's latest attempt."""
    source = run
    if run.kind == "check" and run.parent_job_id:
        source = db.get(JobRun, run.parent_job_id)
    if source is None or source.kind != "write" or not source.candidate_id:
        return None, None, None
    candidate = db.get(ChapterDraftCandidate, source.candidate_id)
    if candidate is None or candidate.job_id != source.id or not candidate.latest_checker_attempt_id:
        return source, candidate, None
    latest = db.get(JobRun, candidate.latest_checker_attempt_id)
    if (
        latest is None
        or latest.chapter_id != source.chapter_id
        or latest.candidate_id != candidate.id
        or (latest.id != source.id and latest.parent_job_id != source.id)
    ):
        return source, candidate, None
    return source, candidate, latest


def _candidate_checker_input_current(
    db: Session, chapter: Chapter, candidate: ChapterDraftCandidate, latest: JobRun,
) -> bool:
    """One eligibility proof for both the retry button and the retry endpoint."""
    from app.services.production_context import is_frozen_input_current
    snapshot = latest.input_snapshot
    if (chapter.status == "finalized"
            or candidate.chapter_id != chapter.id or latest.chapter_id != chapter.id
            or latest.chapter_write_generation != chapter.write_generation
            or candidate.deterministic_violations or not isinstance(snapshot, dict)):
        return False
    draft = snapshot.get("draft")
    return bool(
        isinstance(draft, dict)
        and candidate.checker_input_snapshot == snapshot
        and candidate.checker_input_fingerprint == snapshot.get("input_fingerprint")
        and hashlib.sha256(candidate.draft_text.encode()).hexdigest() == draft.get("sha256")
        and is_frozen_input_current(db, chapter, snapshot)
    )


def _claim_chapter_operation(db: Session, chapter: Chapter) -> None:
    """Give a new Writer or Checker operation the durable ownership token.

    Every new write or check makes a later decision about this chapter.
    Advancing the existing ownership generation makes it invalidate an older
    hidden candidate without adding a second, migration-only marker. It does
    not change prose or its public content revision.
    """
    previous_generation = chapter.write_generation
    claimed = db.execute(
        update(Chapter)
        .where(
            Chapter.id == chapter.id,
            Chapter.write_generation == previous_generation,
        )
        .values(write_generation=previous_generation + 1, updated_at=utc_now())
    )
    if claimed.rowcount != 1:
        db.rollback()
        raise HTTPException(
            status_code=409,
            detail={"code": "checker_input_changed", "message": "检查开始前章节输入已变化，请重新检查"},
        )
    db.refresh(chapter)


def _check_outcome_is_current(db: Session, chapter: Chapter, run: JobRun) -> bool:
    """Prove a terminal manual/retry Checker result still belongs to this draft."""
    if run.phase == "cancelled" or run.error_code == "checker_input_changed" or not run.candidate_id:
        return False
    candidate = db.get(ChapterDraftCandidate, run.candidate_id)
    snapshot = run.input_snapshot
    if (
        candidate is None
        or not isinstance(snapshot, dict)
        or candidate.latest_checker_attempt_id != run.id
        or candidate.checker_input_snapshot != snapshot
        or candidate.checker_input_fingerprint != snapshot.get("input_fingerprint")
        or run.input_fingerprint != snapshot.get("input_fingerprint")
        or hashlib.sha256(candidate.draft_text.encode()).hexdigest() != snapshot.get("draft", {}).get("sha256")
    ):
        return False
    if run.chapter_write_generation is not None and run.chapter_write_generation != chapter.write_generation:
        return False
    from app.services.production_context import is_frozen_input_current

    return is_frozen_input_current(db, chapter, snapshot)


def _write_outcome_is_current(db: Session, chapter: Chapter, run: JobRun) -> bool:
    """Use the frozen Writer/Checker proof when a terminal run has one."""
    if run.error_code in {"chapter_changed", "checker_input_changed"}:
        return False
    if run.chapter_write_generation != chapter.write_generation:
        return False
    snapshot = run.input_snapshot
    if not isinstance(snapshot, dict) or snapshot.get("draft", {}).get("source") != "candidate" or not run.candidate_id:
        # Early Writer failures have no bound candidate snapshot. Generation
        # remains their only authoritative currentness proof.
        return True
    candidate = db.get(ChapterDraftCandidate, run.candidate_id)
    if (
        candidate is None
        or candidate.checker_input_snapshot != snapshot
        or candidate.checker_input_fingerprint != snapshot.get("input_fingerprint")
        or hashlib.sha256(candidate.draft_text.encode()).hexdigest() != snapshot.get("draft", {}).get("sha256")
    ):
        return False
    from app.services.production_context import is_frozen_input_current

    return is_frozen_input_current(db, chapter, snapshot)


def _extract_outcome_is_current(db: Session, chapter: Chapter, run: JobRun) -> bool:
    """Prove an archive outcome belongs to the still-accepted chapter input.

    A terminal Extractor run and its chapter update flush in the same commit,
    but SQLAlchemy's ``onupdate`` timestamp can be a few microseconds later
    than the explicit ``finished_at`` assignment.  Timestamp ordering thus
    incorrectly hid a current failed archive (and the retained Checker pass)
    immediately after acceptance.  The immutable revision input fingerprint
    is the actual proof used by archive retry and is not susceptible to that
    flush ordering.
    """
    if not run.archive_revision_id or chapter.status != "finalized":
        return False
    revision = db.get(ChapterArchiveRevision, run.archive_revision_id)
    return bool(
        revision is not None
        and revision.chapter_id == chapter.id
        and revision.input_fingerprint
        == archive_input_fingerprint(chapter, contract_version=revision.contract_version)
    )


def _job_status_from_run(
    chapter: Chapter,
    run: JobRun,
    visible_checker_result: dict | None = None,
    db: Session | None = None,
) -> WriteJobStatus:
    outcome_current = None
    if run.phase in {"done", "failed", "cancelled"}:
        if run.kind == "write" and run.chapter_write_generation is not None:
            outcome_current = _write_outcome_is_current(db, chapter, run) if db is not None else False
        elif run.kind == "check":
            outcome_current = _check_outcome_is_current(db, chapter, run) if db is not None else False
        elif run.kind == "extract" and db is not None:
            outcome_current = _extract_outcome_is_current(db, chapter, run)
        else:
            outcome_current = run.finished_at is not None and run.finished_at >= chapter.updated_at
    status_out = WriteJobStatus(
        chapter_id=chapter.id,
        job_id=run.id,
        outcome_current=outcome_current,
        kind=run.kind,
        phase=run.phase,
        attempt=run.attempt,
        error_code=run.error_code,
        error_message=archive_validation_message(run.error_message) if run.error_code == "archive_validation_failed" else run.error_message,
        error_context=run.error_context,
        violations=run.violations,
        memory_context=run.memory_context,
        checker_result=_redacted_checker_result(run.checker_result),
        visible_checker_result=visible_checker_result,
        checker_target=_checker_target(run),
    )
    if isinstance(status_out.checker_result, dict):
        checker = dict(status_out.checker_result)
        checker["context_limitations"] = _public_context_limitations(run.context_limitations)
        status_out.checker_result = checker
    if isinstance(status_out.memory_context, dict):
        memory_context = dict(status_out.memory_context)
        if "context_limitations" in memory_context:
            memory_context["context_limitations"] = _public_context_limitations(memory_context["context_limitations"])
        status_out.memory_context = memory_context
    if db is not None:
        source, candidate, latest = _retry_source_and_latest_attempt(db, run)
        status_out.can_retry_checker = bool(
            source is not None
            and candidate is not None
            and not candidate.deterministic_violations
            and latest is not None
            and _is_retryable_checker_attempt(latest)
            and _candidate_checker_input_current(db, chapter, candidate, latest)
        )
        status_out.checker_source_job_id = source.id if source is not None and status_out.can_retry_checker else None
    if run.phase == "done":
        status_out.chapter = _chapter_read(chapter)
        status_out.updated_character_ids = run.updated_character_ids
        status_out.added_event_ids = run.added_event_ids
    return status_out


def _checker_target(run: JobRun) -> str | None:
    if run.kind != "check":
        return None
    snapshot = run.input_snapshot if isinstance(run.input_snapshot, dict) else {}
    draft = snapshot.get("draft") if isinstance(snapshot.get("draft"), dict) else {}
    if draft.get("source") == "chapter":
        return "visible_draft"
    if draft.get("source") == "candidate":
        return "generated_candidate"
    return None


def _replace_links(db: Session, chapter: Chapter, links: list) -> None:
    chapter.character_links.clear()
    db.flush()
    seen: set[str] = set()
    for item in links:
        if item.character_id in seen:
            continue
        character = db.get(Character, item.character_id)
        if character is None or character.book_id != chapter.book_id:
            raise HTTPException(status_code=400, detail=f"invalid character_id {item.character_id}")
        # The archive fingerprint is recalculated before this transaction is
        # committed. Bind the already-loaded Character as well as its ID so
        # the in-memory relationship is immediately usable by that calculation.
        chapter.character_links.append(
            ChapterCharacter(character_id=item.character_id, character=character)
        )
        seen.add(item.character_id)
    # Relationship-only edits do not otherwise issue an UPDATE for chapters,
    # so explicitly advance the authoritative version used by /job
    # outcome_current reconciliation.
    chapter.updated_at = utc_now()


def _is_chapter_index_conflict(exc: IntegrityError) -> bool:
    detail = str(getattr(exc, "orig", exc)).lower()
    return "chapters.book_id, chapters.index" in detail or "uq_chapters_book_index" in detail


def _is_sqlite_busy(exc: OperationalError) -> bool:
    detail = str(getattr(exc, "orig", exc)).lower()
    return "database is locked" in detail or "database is busy" in detail


def _apply_author_note(chapter: Chapter, author_note: str | None) -> None:
    if author_note is not None:
        chapter.author_note = author_note


@router.get("/books/{book_id}/chapters", response_model=list[ChapterSummary])
def list_chapters(book_id: str, db: Session = Depends(get_db)) -> list[ChapterSummary]:
    chapters = list(db.scalars(select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index)).all())
    health = archive_health_summaries(db, chapters)
    return [
        ChapterSummary.model_validate(chapter).model_copy(update=health.get(chapter.id, {}))
        for chapter in chapters
    ]


@router.post("/books/{book_id}/chapters", response_model=ChapterRead, status_code=status.HTTP_201_CREATED)
def create_chapter(book_id: str, payload: ChapterCreate, db: Session = Depends(get_db)) -> ChapterRead:
    if db.get(Book, book_id) is None:
        raise HTTPException(status_code=404, detail="book not found")
    for attempt in range(_CHAPTER_CREATE_RETRIES):
        next_index = (db.scalar(select(func.max(Chapter.index)).where(Chapter.book_id == book_id)) or 0) + 1
        chapter = Chapter(
            book_id=book_id,
            index=next_index,
            title=payload.title,
            user_prompt=payload.user_prompt,
            target_word_count=payload.target_word_count,
            author_note=payload.author_note or "",
            archive_status="stale",
            legacy_archive_eligible=False,
        )
        try:
            db.add(chapter)
            db.flush()
            _replace_links(db, chapter, payload.character_links)
            rebuild_book_search_index(db, book_id)
            db.commit()
            db.refresh(chapter)
            return _chapter_read(chapter)
        except IntegrityError as exc:
            db.rollback()
            if not _is_chapter_index_conflict(exc) or attempt + 1 == _CHAPTER_CREATE_RETRIES:
                if _is_chapter_index_conflict(exc):
                    raise HTTPException(
                        status_code=409,
                        detail={"code": "chapter_index_busy", "message": "章节编号正在被其他编辑占用，请重试"},
                    ) from exc
                raise
        except OperationalError as exc:
            db.rollback()
            if not _is_sqlite_busy(exc) or attempt + 1 == _CHAPTER_CREATE_RETRIES:
                if _is_sqlite_busy(exc):
                    raise HTTPException(
                        status_code=409,
                        detail={"code": "chapter_index_busy", "message": "章节编号正在被其他编辑占用，请重试"},
                    ) from exc
                raise
        time.sleep(0.01 * (attempt + 1))
    raise AssertionError("unreachable chapter creation retry")


@router.get("/chapters/{chapter_id}", response_model=ChapterRead)
def get_chapter(chapter_id: str, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    return _chapter_read(chapter)


@router.get("/chapters/{chapter_id}/production-readiness", response_model=ProductionReadinessRead)
def chapter_production_readiness(chapter_id: str, db: Session = Depends(get_db)) -> ProductionReadinessRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    from app.services.production_context import production_readiness

    readiness = production_readiness(db, chapter)

    def limitation(item: dict) -> dict:
        return {
            "chapter_id": item["chapter_id"],
            "index": item["chapter_index"],
            "title": item["title"],
            "reason": item["reason"],
            "effective_status": item["kind"],
        }

    recommendation = readiness["recommended_recovery"]
    return ProductionReadinessRead(
        context_token=readiness["context_token"],
        limitations=[limitation(item) for item in readiness["context_limitations"]],
        recommended_recovery=(
            {
                "chapter_id": recommendation["chapter_id"],
                "index": recommendation["chapter_index"],
                "title": recommendation["title"],
                "reason": recommendation["reason"],
            }
            if recommendation is not None else None
        ),
    )


@router.post("/chapters/{chapter_id}/inspirations", response_model=InspirationResponse)
def create_inspirations(
    chapter_id: str,
    payload: InspirationRequest,
    db: Session = Depends(get_db),
    inspiration_client=Depends(get_inspiration_creator_client),
) -> InspirationResponse:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    try:
        context = build_inspiration_context(
            db,
            chapter,
            title=payload.title,
            bible=payload.bible,
            pacing_boundary=payload.pacing_boundary,
            selected_character_ids=payload.selected_character_ids,
        )
    except InspirationContextError as exc:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "inspiration_character_invalid",
                "message": "灵感请求包含无效人物选择",
                "details": {},
            },
        ) from exc

    def audit_attempt(duration_ms: int, error_code: str | None, upstream_reason: str | None) -> None:
        record_llm_call(
            SessionLocal,
            agent_role="inspiration_creator",
            client=inspiration_client,
            duration_ms=duration_ms,
            error_code=error_code,
            chapter_id=chapter.id,
            upstream_reason=upstream_reason,
        )

    agent = InspirationCreatorAgent(
        inspiration_client,
        get_persona(db, "inspiration_creator", book_id=chapter.book_id),
    )
    try:
        cards = agent.generate(
            context.user_message,
            source_chapter_indexes=context.source_chapter_indexes,
            known_characters=context.known_characters,
            selected_character_ids=set(context.selected_character_ids),
            audit_attempt=audit_attempt,
        )
    except LLMError as exc:
        messages = {
            "inspiration_invalid_response": "这批结果没有整理出至少 3 条可用灵感，请再试一次",
            "inspiration_unselected_character": "这批灵感提到了本章未选择的已有角色，已按人物白名单拒绝",
            "llm_timeout": "灵感生成超时，请稍后重试",
            "llm_content_blocked": "上游模型拒绝了本次灵感请求",
        }
        raise HTTPException(
            status_code=502,
            detail={
                "code": exc.code,
                "message": messages.get(exc.code, "灵感生成暂时失败，请稍后重试"),
                "details": exc.safe_details(),
            },
        ) from exc
    return InspirationResponse(
        cards=[
            {
                "title": card.title,
                "body": card.body,
                "history_basis": card.history_basis,
                "note": card.note,
                "history_chapter_indexes": list(card.history_chapter_indexes),
            }
            for card in cards
        ]
    )


@router.patch("/chapters/{chapter_id}", response_model=ChapterRead)
def patch_chapter(
    chapter_id: str,
    payload: ChapterPatch,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    require_matching_revision(chapter, if_match, resource_type="chapter", resource_id=chapter.id, db=db)
    previous_archive_fingerprint = archive_input_fingerprint(chapter)
    was_finalized = chapter.status == "finalized"
    prior_check_inputs = {
        key: getattr(chapter, key)
        for key in ("title", "user_prompt", "draft_text", "exempted_character_names")
    }
    prior_link_ids = sorted(link.character_id for link in chapter.character_links)
    updates = payload.model_dump(
        exclude_unset=True,
        exclude={"character_links", "author_note", "chapter_style", "summary", "long_summary"},
    )
    for key, value in updates.items():
        setattr(chapter, key, value)
    summary_is_set = "summary" in payload.model_fields_set
    long_summary_is_set = "long_summary" in payload.model_fields_set
    if summary_is_set or long_summary_is_set:
        current = chapter.long_summary
        legacy_value = payload.summary or ""
        canonical_value = payload.long_summary or ""
        if summary_is_set and long_summary_is_set:
            if legacy_value == canonical_value:
                chosen = canonical_value
            elif canonical_value == current:
                # A v1.6.2 client edited its visible legacy synopsis field.
                chosen = legacy_value
            else:
                # New canonical field wins when both values were edited.
                chosen = canonical_value
        elif long_summary_is_set:
            chosen = canonical_value
        else:
            chosen = legacy_value
        chapter.long_summary = chosen
    if "author_note" in payload.model_fields_set or "chapter_style" in payload.model_fields_set:
        _apply_author_note(chapter, payload.author_note)
    if payload.character_links is not None:
        _replace_links(db, chapter, payload.character_links)
    check_inputs_changed = any(
        key in payload.model_fields_set and getattr(chapter, key) != prior_check_inputs[key]
        for key in prior_check_inputs
    ) or (
        payload.character_links is not None
        and sorted(link.character_id for link in chapter.character_links) != prior_link_ids
    )
    # A PATCH is allowed for compatibility with existing clients, but a new
    # accepted chapter must never remain `finalized` merely because that
    # client did not make a separate /reopen call first.  These are exactly
    # the fields in the frozen Checker input (or its name authorization), so
    # treat a finalized edit as a reopen and require a current check again.
    reopened_by_input_edit = was_finalized and check_inputs_changed
    if reopened_by_input_edit:
        chapter.status = "draft_ready"
        stale_archives_for_reopen(db, chapter)
    if payload.model_fields_set:
        invalidated = invalidate_writer_inputs(db, [chapter])
    archive_invalidated = invalidate_archive_if_input_changed(
        db, chapter, previous_fingerprint=previous_archive_fingerprint,
        force=reopened_by_input_edit,
    )
    if archive_invalidated or reopened_by_input_edit:
        invalidated_downstream = invalidate_downstream_archives(db, chapter.book_id, after_index=chapter.index)
        for downstream_id in invalidated_downstream:
            downstream = db.get(Chapter, downstream_id)
            if downstream is not None:
                bump_content_revision(downstream)
        rebuild_book_projection(db, chapter.book_id)
    if payload.model_fields_set:
        bump_content_revision(chapter)
    rebuild_book_search_index(db, chapter.book_id)
    db.commit()
    if payload.model_fields_set:
        cancel_local_writer_jobs(invalidated)
    if reopened_by_input_edit:
        live_job = write_registry.get_live(chapter.id)
        if live_job is not None and live_job.kind == "extract":
            write_registry.cancel(live_job, discard=True)
    db.refresh(chapter)
    return _chapter_read(chapter)



@router.delete("/chapters/{chapter_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_chapter(
    chapter_id: str,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Response:
    # Order matters. Lookup first, then the gate, and only then any side
    # effect: an earlier build cancelled the live write job before checking
    # anything, so a request that was about to be refused still killed the
    # author's running generation.
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        # Deleting an already-deleted chapter stays idempotent, so this has to
        # precede the gate: a client retrying a successful delete must not be
        # told the (now absent) chapter is not the last one.
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    require_matching_revision(chapter, if_match, resource_type="chapter", resource_id=chapter.id, db=db)
    book_id = chapter.book_id
    old_index = chapter.index
    # Only the final chapter of a book may be deleted. This is a product guard
    # against destroying the wrong chapter; nothing below is allowed to lean on
    # it for correctness. Asking whether a later chapter exists is equivalent to
    # comparing against max(index) -- uq_chapters_book_index rules out
    # duplicates within a book -- but it stops at the first hit on the index and
    # skips the aggregate on the way through.
    has_following = db.scalar(
        select(Chapter.id)
        .where(Chapter.book_id == book_id, Chapter.index > old_index)
        .limit(1)
    )
    if has_following is not None:
        last_index = db.scalar(
            select(func.max(Chapter.index)).where(Chapter.book_id == book_id)
        )
        raise HTTPException(
            status_code=409,
            detail={
                "code": "chapter_not_last",
                "message": "只能删除全书最后一章",
                "details": {"index": old_index, "last_index": last_index},
            },
        )
    # Past the gate the request is committed, so cancelling the live write job
    # is now a consequence of an accepted delete rather than of a rejected one.
    job = write_registry.get_live(chapter_id)
    if job is not None:
        write_registry.cancel(job, discard=True)
        if job.thread is not None:
            job.thread.join(timeout=8)
    db.delete(chapter)
    db.flush()
    # On the normal path the gate above leaves this empty, but "normally" is not
    # "never": the gate's SELECT runs outside any transaction, because pysqlite
    # opens one only at the first DML statement. A chapter created by another
    # session in the window between the gate and the `db.delete` above is
    # therefore real, and this loop really renumbers it.
    following = db.scalars(
        select(Chapter)
        .where(Chapter.book_id == book_id, Chapter.index > old_index)
        .order_by(Chapter.index)
    ).all()
    for item in following:
        item.index -= 1
        db.flush()
    # M6 (audit), fixed here rather than argued away: a renumbered chapter can
    # still hold an in-flight write job keyed to its pre-reindex position. The
    # gate makes that rare, not impossible -- see the race described above -- so
    # this follows the same shape as `import_chapter`: advance the persistent
    # generation inside this transaction, prompt the local registry only after
    # it commits.
    invalidated = invalidate_writer_inputs(db, following)
    invalidate_downstream_archives(db, book_id, after_index=old_index - 1)
    rebuild_book_projection(db, book_id)
    rebuild_book_search_index(db, book_id)
    db.commit()
    cancel_local_writer_jobs(invalidated)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/chapters/{chapter_id}/import", response_model=ChapterRead)
def import_chapter(
    chapter_id: str,
    payload: ChapterImportRequest,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    require_matching_revision(chapter, if_match, resource_type="chapter", resource_id=chapter.id, db=db)
    previous_archive_fingerprint = archive_input_fingerprint(chapter)
    chapter.draft_text = payload.draft_text
    chapter.source = "imported"
    chapter.status = "draft_ready"
    for key in ("title", "user_prompt", "target_word_count"):
        value = getattr(payload, key)
        if value is not None:
            setattr(chapter, key, value)
    if "author_note" in payload.model_fields_set or "chapter_style" in payload.model_fields_set:
        _apply_author_note(chapter, payload.author_note)
    if payload.character_links is not None:
        _replace_links(db, chapter, payload.character_links)
    invalidated = invalidate_writer_inputs(db, [chapter])
    archive_invalidated = invalidate_archive_if_input_changed(
        db, chapter, previous_fingerprint=previous_archive_fingerprint
    )
    if archive_invalidated:
        invalidated_downstream = invalidate_downstream_archives(db, chapter.book_id, after_index=chapter.index)
        for downstream_id in invalidated_downstream:
            downstream = db.get(Chapter, downstream_id)
            if downstream is not None:
                bump_content_revision(downstream)
        rebuild_book_projection(db, chapter.book_id)
    bump_content_revision(chapter)
    rebuild_book_search_index(db, chapter.book_id)
    db.commit()
    cancel_local_writer_jobs(invalidated)
    db.refresh(chapter)
    return _chapter_read(chapter)


@router.post("/chapters/{chapter_id}/write", response_model=WriteJobStatus)
def write_chapter(
    chapter_id: str,
    payload: WriteRequest = WriteRequest(),
    db: Session = Depends(get_db),
    _revision_checked: None = Depends(_require_task_revision),
    memory_selector_resolver: Callable[[Session, str], object] = Depends(get_lazy_memory_selector_resolver),
    writer_client=Depends(get_writer_client),
    checker_client=Depends(get_checker_client),
) -> WriteJobStatus:
    # Legacy clients omit If-Match. They still must serialize the finalized
    # check with Writer admission; version compatibility cannot reopen prose.
    _begin_short_write_cas(db)
    chapter = db.get(Chapter, chapter_id)
    if chapter is not None:
        db.refresh(chapter)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if chapter.status == "finalized":
        raise HTTPException(status_code=409, detail={"code": "chapter_finalized", "message": "请先重新编辑本章"})
    from app.services.production_context import production_readiness

    readiness = production_readiness(db, chapter)
    if not readiness["is_complete"] and payload.acknowledged_context_token != readiness["context_token"]:
        raise _memory_context_incomplete(readiness)
    try:
        validate_character_preflight(db, chapter)
    except CharacterPreflightError as exc:
        raise HTTPException(
            status_code=409,
            detail={"code": exc.code, "message": exc.message, "details": exc.details},
        ) from exc

    live_job = write_registry.get_live(chapter_id)
    if live_job is not None:
        if not payload.replace_draft or live_job.kind not in {"write", "check"}:
            raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行"})
    candidates = memory_candidates(db, chapter)
    selected_ids = {link.character_id for link in chapter.character_links}
    candidates = prefilter_memory_candidates(candidates, chapter=chapter, selected_character_ids=selected_ids)
    budget = memory_budget()
    bible_snapshot = chapter.user_prompt
    bible_sha256 = hashlib.sha256(bible_snapshot.encode()).hexdigest()
    # A previous-ending excerpt is deterministic context, not a historical
    # choice. Do not parse/call an otherwise unused Selector binding for it.
    needs_selector = any(block.memory_type != "previous_ending" for block in candidates)
    memory_selector_client = memory_selector_resolver(db, chapter.id) if needs_selector else None
    selector_message = ""
    selector_input_snapshot: dict[str, object] | None = None
    if memory_selector_client is not None:
        from app.services.production_context import freeze_selector_input

        selector_input_snapshot = freeze_selector_input(db, chapter, candidates)
        selector_message = memory_selector_user_message(
            chapter, candidates, budget, bible=bible_snapshot,
            dynamic_fields_by_character=selector_input_snapshot["prior_state"],
            unknown_state_slots=selector_input_snapshot["unknown_state_slots"],
        )
    baseline_text = chapter.draft_text
    baseline_status = "draft_ready" if baseline_text.strip() else "draft"
    job_id = uuid_str()
    run = JobRun(
        id=job_id,
        chapter_id=chapter.id,
        kind="write",
        phase="selecting_memory" if memory_selector_client is not None else "writing",
        bible_sha256=bible_sha256,
        chapter_write_generation=chapter.write_generation,
        model_binding_snapshot={
            "memory_selector": _model_snapshot(memory_selector_client) if memory_selector_client is not None else {"skipped": "no_memory_candidates"},
            "writer": _model_snapshot(writer_client),
            "checker": _model_snapshot(checker_client),
        },
    )
    job = WriteJob(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="write",
        memory_selector=(
            MemorySelectorAgent(memory_selector_client, get_persona(db, "memory_selector", book_id=chapter.book_id))
            if memory_selector_client is not None else None
        ),
        writer=WriterAgent(writer_client, get_persona(db, "writer", book_id=chapter.book_id)),
        checker=CheckerAgent(checker_client, get_persona(db, "checker", book_id=chapter.book_id)),
        selector_user_message=selector_message,
        memory_candidates=candidates,
        memory_budget=budget,
        baseline_text=baseline_text,
        baseline_status=baseline_status,
        bible_snapshot=bible_snapshot,
        bible_sha256=bible_sha256,
        chapter_write_generation=chapter.write_generation,
        selector_input_snapshot=selector_input_snapshot,
    )
    try:
        # Complete fallible input/configuration preparation before replacing
        # a live owner. Transfer the slot atomically, never through an empty
        # interval in which an accept could acquire it.
        if live_job is not None:
            write_registry.reserve(job, replace=live_job)
        else:
            write_registry.reserve(job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行"})
    try:
        if live_job is not None and live_job.cancel_event.is_set():
            # No worker join or second writer Session while this request owns
            # SQLite's lock. Both jobs' durable states change together.
            _apply_job_phase(db, live_job.job_id, "cancelled")
            invalidate_writer_inputs(db, [chapter])
            run.chapter_write_generation = chapter.write_generation
            job.chapter_write_generation = chapter.write_generation
        elif live_job is None:
            # A fresh Writer job is also a newer chapter decision. Without
            # this claim, an older failed hidden candidate can remain eligible
            # and later replace the prose this Writer just produced.
            _claim_chapter_operation(db, chapter)
            run.chapter_write_generation = chapter.write_generation
            job.chapter_write_generation = chapter.write_generation
        db.add(run)
        chapter.status = "writing"
        bump_content_revision(chapter)
        db.commit()
        write_registry.launch(job, SessionLocal)
    except Exception:
        # Reservation is deliberately published before this transaction
        # commits.  A failed commit or thread launch has no worker to release
        # it, so repair any durable row and end this exact in-memory owner.
        db.rollback()
        try:
            if live_job is not None and live_job.cancel_event.is_set():
                # A rolled-back replacement left the cancelled worker's old
                # durable row alive. Repair its exact generation as well.
                fail_unlaunched_job(
                    SessionLocal, live_job, error_code="write_start_failed",
                    error_message="替换写作任务未能启动，原正文已保留，请重试",
                )
            if write_registry.is_current(job):
                fail_unlaunched_job(
                    SessionLocal,
                    job,
                    error_code="write_start_failed",
                    error_message="写作任务未能启动，请重试",
                )
        finally:
            if write_registry.is_current(job):
                # A persistent disk/SQLite failure can also make the recovery
                # Session fail.  Its durable row is then handled at startup,
                # but this exact in-memory reservation must never strand the
                # chapter behind write_running.
                job.mark_terminal("failed")
        raise
    return WriteJobStatus(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="write",
        phase="selecting_memory" if memory_selector_client is not None else "writing",
        memory_context={"context_limitations": readiness["context_limitations"]},
    )


@router.get("/chapters/{chapter_id}/job", response_model=WriteJobStatus)
def chapter_job(chapter_id: str, db: Session = Depends(get_db)) -> WriteJobStatus:
    # Read the run before the chapter so a terminal row and its chapter snapshot
    # are observed in the same order used by the worker's atomic terminal commit.
    run = db.scalars(
        select(JobRun)
        .where(JobRun.chapter_id == chapter_id)
        .order_by(JobRun.created_at.desc(), JobRun.id.desc())
    ).first()
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    live_job = write_registry.get_live(chapter_id)
    if live_job is not None and (not live_job.job_id or run is None or run.id != live_job.job_id):
        # reserve() necessarily happens before the request transaction commits.
        # A second client can therefore receive write_running and query /job in
        # the tiny window where the registry knows the new job but SQLite still
        # exposes the previous terminal row. Return a stable non-terminal
        # snapshot so that client can adopt and poll the real job instead of
        # treating the stale row as its outcome.
        draft = live_job.checker_snapshot.get("draft", {}) if isinstance(live_job.checker_snapshot, dict) else {}
        checker_target = (
            "visible_draft" if live_job.kind == "check" and draft.get("source") == "chapter"
            else "generated_candidate" if live_job.kind == "check" and draft.get("source") == "candidate"
            else None
        )
        return WriteJobStatus(
            chapter_id=chapter_id,
            job_id=live_job.job_id or None,
            kind=live_job.kind,
            phase=live_job.phase,
            checker_target=checker_target,
        )
    if run is None:
        return WriteJobStatus(chapter_id=chapter_id, kind="write", phase="idle")
    return _job_status_from_run(chapter, run, _visible_checker_result(db, chapter), db)


@router.post("/chapters/{chapter_id}/write/cancel", response_model=ChapterRead)
def cancel_write(chapter_id: str, db: Session = Depends(get_db)) -> ChapterRead:
    job = write_registry.get_live(chapter_id)
    if job is not None:
        write_registry.cancel(job, discard=True)
        if job.thread is not None:
            job.thread.join(timeout=8)
    db.expire_all()
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if job is not None and job.kind == "write":
        invalidated = invalidate_writer_inputs(db, [chapter])
        bump_content_revision(chapter)
        db.commit()
        db.refresh(chapter)
        cancel_local_writer_jobs(invalidated)
    if job is not None and job.kind == "extract" and job.archive_revision_id:
        revision = db.get(ChapterArchiveRevision, job.archive_revision_id)
        if revision is not None and revision.status in {"pending", "extracting"}:
            revision.status = "failed"
            revision.error_code = "archive_cancelled"
            revision.error_message = "归档任务已取消"
            revision.finished_at = utc_now()
            chapter.archive_status = "complete" if chapter.active_archive_revision_id else "failed"
            bump_content_revision(chapter)
            db.commit()
            db.refresh(chapter)
    # A `check` job observes visible prose only.  In particular, cancelling a
    # check on finalized prose must not reopen it or disturb its archive.
    if chapter.status in ("writing", "extracting"):
        chapter.status = "draft_ready" if chapter.draft_text.strip() else "draft"
        bump_content_revision(chapter)
        db.commit()
        db.refresh(chapter)
    # Record the terminal row only after the chapter has reached its restored
    # baseline. This ordering makes outcome_current deterministic even when the
    # worker did not finish within the bounded join above.
    if job is not None:
        record_job_phase(SessionLocal, job.job_id, "cancelled")
    return _chapter_read(chapter)


def _candidate_fingerprint(chapter: Chapter, candidate: ChapterDraftCandidate) -> str:
    return draft_fingerprint(chapter, candidate.draft_text)


def _candidate_matches_visible_draft(
    chapter: Chapter,
    candidate: ChapterDraftCandidate | None,
    draft_text: str,
) -> bool:
    """Whether this holder still represents the exact visible-check input."""
    return bool(
        candidate is not None
        and candidate.draft_text == draft_text
        and candidate.bible_sha256 == hashlib.sha256(chapter.user_prompt.encode()).hexdigest()
        and candidate.draft_fingerprint == draft_fingerprint(chapter, draft_text)
    )


def _current_candidate(db: Session, chapter: Chapter) -> ChapterDraftCandidate | None:
    return db.scalars(
        select(ChapterDraftCandidate)
        .where(ChapterDraftCandidate.chapter_id == chapter.id, ChapterDraftCandidate.is_current.is_(True))
        .order_by(ChapterDraftCandidate.created_at.desc(), ChapterDraftCandidate.id.desc())
    ).first()


def _visible_checker_result(db: Session, chapter: Chapter) -> dict | None:
    candidate = _current_candidate(db, chapter)
    if candidate is None or candidate.draft_text != chapter.draft_text:
        return None
    fingerprint = _candidate_fingerprint(chapter, candidate)
    result = candidate.checker_result or {}
    snapshot = candidate.checker_input_snapshot
    if (
        not isinstance(snapshot, dict)
        or
        candidate.bible_sha256 != hashlib.sha256(chapter.user_prompt.encode()).hexdigest()
        or candidate.draft_fingerprint != fingerprint
        or result.get("draft_fingerprint") != fingerprint
        or candidate.checker_input_fingerprint != snapshot.get("input_fingerprint")
        or result.get("input_fingerprint") != snapshot.get("input_fingerprint")
        or result.get("check_attempt_id") != candidate.latest_checker_attempt_id
        or hashlib.sha256(candidate.draft_text.encode()).hexdigest() != snapshot.get("draft", {}).get("sha256")
    ):
        return None
    from app.services.production_context import is_frozen_input_current

    if not is_frozen_input_current(db, chapter, snapshot):
        return None
    return _public_visible_checker_result(result)


def _next_candidate_attempt(db: Session, chapter_id: str) -> int:
    current_max = db.scalar(
        select(func.max(ChapterDraftCandidate.attempt)).where(ChapterDraftCandidate.chapter_id == chapter_id)
    )
    return int(current_max or 0) + 1


def _has_current_checker_override(
    db: Session,
    chapter: Chapter,
    snapshot: dict,
) -> bool:
    """Return whether the user already approved this exact writing input.

    Extractor failures must not erase a deliberate Bible-check override.  The
    approval is kept in the existing immutable JobRun audit trail and scoped
    by the frozen production-input fingerprint.  This includes history,
    projection and selected-character dependencies that a draft fingerprint
    alone cannot see.
    """
    runs = db.scalars(
        select(JobRun)
        .where(
            JobRun.chapter_id == chapter.id,
            JobRun.kind == "extract",
        )
        .order_by(JobRun.created_at.desc(), JobRun.id.desc())
    ).all()
    for run in runs:
        if (run.checker_result or {}).get("override") is not True:
            continue
        if (run.checker_result or {}).get("input_fingerprint") == snapshot.get("input_fingerprint"):
            return True
    return False


def _next_checker_attempt(db: Session, candidate_id: str) -> int:
    current_max = db.scalar(
        select(func.max(JobRun.attempt)).where(
            JobRun.kind == "check", JobRun.candidate_id == candidate_id,
        )
    )
    return int(current_max or 0) + 1


@router.post("/chapters/{chapter_id}/check", response_model=CheckerRunRead)
def rerun_checker(
    chapter_id: str,
    payload: CheckerRunRequest = CheckerRunRequest(),
    db: Session = Depends(get_db),
    _revision_checked: None = Depends(_require_task_revision),
    checker_client=Depends(get_checker_client),
) -> CheckerRunRead:
    """Run Checker without retaining a SQLite write transaction across I/O."""
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if not chapter.draft_text.strip():
        raise HTTPException(
            status_code=409,
            detail={"code": "checker_preflight_failed", "message": "正文为空，不能进行内容检查"},
        )
    if write_registry.get_live(chapter.id) is not None:
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})
    from app.services.checker_validation import CheckerValidationError, validate_checker_result
    from app.services.production_context import freeze_manual_checker_input, is_frozen_input_current, production_readiness
    from app.services.context import checker_user_message

    readiness = production_readiness(db, chapter)
    if not readiness["is_complete"] and payload.acknowledged_context_token != readiness["context_token"]:
        raise _memory_context_incomplete(readiness)
    _claim_chapter_operation(db, chapter)
    draft_text = chapter.draft_text
    snapshot = freeze_manual_checker_input(db, chapter, draft_text)
    candidate = _current_candidate(db, chapter)
    if not _candidate_matches_visible_draft(chapter, candidate, draft_text):
        db.execute(
            update(ChapterDraftCandidate)
            .where(ChapterDraftCandidate.chapter_id == chapter.id)
            .values(is_current=False)
        )
        candidate = ChapterDraftCandidate(
            chapter_id=chapter.id,
            attempt=_next_candidate_attempt(db, chapter.id),
            draft_text=draft_text,
            non_whitespace_count=nonspace_len(draft_text),
            finish_reason="manual_edit",
            deterministic_violations=[],
            bible_sha256=hashlib.sha256(chapter.user_prompt.encode()).hexdigest(),
            draft_fingerprint=draft_fingerprint(chapter, draft_text),
            is_current=True,
        )
        db.add(candidate)
        db.flush()
    check_job_id = uuid_str()
    run = JobRun(
        id=check_job_id,
        chapter_id=chapter.id,
        kind="check",
        phase="checking",
        attempt=_next_checker_attempt(db, candidate.id),
        candidate_id=candidate.id,
        parent_job_id=candidate.job_id,
        input_snapshot=snapshot,
        input_fingerprint=snapshot["input_fingerprint"],
        context_limitations=snapshot["context_limitations"],
        bible_sha256=hashlib.sha256(chapter.user_prompt.encode()).hexdigest(),
        draft_fingerprint=candidate.draft_fingerprint,
        chapter_write_generation=chapter.write_generation,
        model_binding_snapshot={"checker": _model_snapshot(checker_client)},
    )
    candidate.checker_input_snapshot = snapshot
    candidate.checker_input_fingerprint = snapshot["input_fingerprint"]
    candidate.latest_checker_attempt_id = check_job_id
    candidate.checker_result = None
    db.add(run)
    # All ORM-backed data must become a pure prompt/persona before releasing
    # the transaction.  The model invocation below must not lazily reopen a
    # SQLite read transaction through expired ORM attributes.
    candidate_id = candidate.id
    candidate_fingerprint = candidate.draft_fingerprint or ""
    checker_persona = get_persona(db, "checker", book_id=chapter.book_id)
    checker_message = checker_user_message(
        chapter,
        draft_text,
        snapshot["bible"],
        reference_context=snapshot["reference_context"],
        source_catalog=snapshot["source_catalog"],
        name_hits=snapshot["name_hits"],
        name_groups=snapshot.get("name_groups"),
        name_candidate_groups=snapshot.get("name_candidate_groups"),
    )
    # Build62 still calls this synchronous endpoint.  It must nevertheless
    # reserve the same chapter ownership slot as `/check/start`; otherwise a
    # second synchronous request could overlap its model call.
    legacy_job = WriteJob(
        chapter_id=chapter.id,
        job_id=check_job_id,
        kind="check",
        checker=CheckerAgent(checker_client, checker_persona),
        checker_snapshot=snapshot,
        checker_candidate_id=candidate_id,
        checker_draft_text=draft_text,
        checker_draft_fingerprint=candidate_fingerprint,
        checker_user_message=checker_message,
        chapter_write_generation=chapter.write_generation,
    )
    try:
        write_registry.reserve(legacy_job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})
    try:
        db.commit()  # release the candidate write before waiting for the model
    except Exception:
        legacy_job.mark_terminal("failed")
        raise

    started_at = time.monotonic()
    error_code: str | None = None
    upstream_reason: str | None = None
    try:
        agent = legacy_job.checker
        assert agent is not None
        raw = agent.check(checker_message)
        checker_result = validate_checker_result(raw, snapshot, check_attempt_id=check_job_id)
        checker_result["draft_fingerprint"] = candidate_fingerprint
    except Exception as exc:
        checker_result = _manual_checker_failure(
            exc,
            checker_client,
            candidate_fingerprint,
            snapshot,
            check_job_id,
        )
        error_code = checker_result["error_code"]
        upstream_reason = checker_result["error_context"].get("upstream_reason")
    # This result is returned directly by /check (rather than through the job
    # read-model), so translate the frozen internal limitation rows here too.
    # Swift intentionally decodes this field with the readiness limitation
    # shape shared by job status.
    checker_result["context_limitations"] = _public_context_limitations(
        snapshot["context_limitations"]
    )
    duration_ms = int((time.monotonic() - started_at) * 1000)

    # Reopen a short independent transaction.  An old response is retained as
    # an expired attempt but cannot replace a newer candidate/result.
    expired = False
    response: CheckerRunRead | None = None
    def persist_sync_result() -> bool:
        nonlocal expired, response
        result_session = SessionLocal()
        try:
            _begin_short_write_cas(result_session)
            stored_run = result_session.get(JobRun, check_job_id)
            stored_candidate = result_session.get(ChapterDraftCandidate, candidate_id)
            current_chapter = result_session.get(Chapter, chapter_id)
            is_current = bool(
                stored_run is not None
                and stored_candidate is not None
                and current_chapter is not None
                and stored_run.phase == "checking"
                and current_chapter.write_generation == legacy_job.chapter_write_generation
                and stored_candidate.latest_checker_attempt_id == check_job_id
                and stored_candidate.draft_text == draft_text
                and stored_candidate.checker_input_fingerprint == snapshot["input_fingerprint"]
                and stored_candidate.checker_input_snapshot == snapshot
                and is_frozen_input_current(result_session, current_chapter, snapshot)
            )
            if stored_run is None or stored_candidate is None or current_chapter is None:
                raise RuntimeError("checker attempt data disappeared")
            if is_current:
                stored_candidate.checker_result = checker_result
                stored_run.checker_result = checker_result
                stored_run.phase = "done" if checker_result.get("verdict") else "failed"
                stored_run.error_code = checker_result.get("error_code")
                stored_run.error_message = checker_result.get("error_message")
                stored_run.error_context = checker_result.get("error_context")
            else:
                stored_run.phase = "cancelled"
                stored_run.error_code = "checker_input_changed"
                stored_run.error_message = "检查期间输入已变更，旧结论未应用"
                expired = True
            stored_run.finished_at = utc_now()
            result_session.commit()
            if not expired:
                response = CheckerRunRead.model_validate(stored_candidate).model_copy(
                    update={
                        "draft_text": "",
                        "checker_result": _public_visible_checker_result(stored_candidate.checker_result),
                        "check_attempt_id": check_job_id,
                        "input_fingerprint": snapshot["input_fingerprint"],
                        "is_current": True,
                    }
                )
            return True
        finally:
            result_session.close()

    if not write_registry.finish_if_current(
        legacy_job, persist_sync_result,
        phase="done" if checker_result.get("verdict") else "failed",
    ):
        # A replacement/cancel won the registry ownership race. Its durable
        # terminal state is authoritative; this old response must not revive it.
        expired = True
    record_llm_call(
        SessionLocal,
        agent_role="checker",
        client=checker_client,
        duration_ms=duration_ms,
        error_code=error_code,
        chapter_id=chapter_id,
        job_id=check_job_id,
        upstream_reason=upstream_reason,
    )
    if expired:
        raise HTTPException(
            status_code=409,
            detail={"code": "checker_input_changed", "message": "检查期间正文或参考资料已变更，请重新检查"},
        )
    assert response is not None
    return response


def _manual_checker_failure(
    exc: Exception,
    client,
    fingerprint: str,
    snapshot: dict,
    check_attempt_id: str,
) -> dict:
    messages = {
        "llm_content_blocked": "上游模型拦截了本次检查请求",
        "llm_timeout": "检查模型请求超时",
        "llm_transport": "无法连接检查模型服务",
        "llm_rate_limited": "检查模型触发限流",
        "llm_upstream_unavailable": "检查模型服务暂时不可用",
        "llm_upstream_rejected": "检查模型服务拒绝了请求",
        "llm_output_truncated": "检查模型输出被截断",
        "llm_empty_candidate": "检查模型没有返回有效内容",
        "llm_invalid_response": "检查模型返回的数据格式无效",
        "checker_invalid_response": "检查模型未返回有效检查结论",
        "llm_upstream_error": "检查模型调用失败",
    }
    context = {"agent_role": "checker", "model_name": str(getattr(client, "model_name", "") or "")}
    code, message = "checker_failed", "本次检查未能完成，请重试"
    if isinstance(exc, LLMError):
        # Never return str(exc): SDK/JSON errors may embed credentials or prose.
        exc.agent_role, exc.model_name = "checker", context["model_name"]
        context.update(_error_context(exc))
        code = exc.code if exc.code in messages else "llm_upstream_error"
        message = messages[code]
    else:
        from app.services.checker_validation import checker_failure_diagnostics, checker_failure_message
        code, message = "checker_invalid_response", checker_failure_message(exc)
        checker_diagnostics = checker_failure_diagnostics(exc)
    if not isinstance(exc, LLMError):
        # Stored only in the internal Checker record; every public projection
        # removes it before leaving the backend.
        diagnostics = checker_diagnostics
    else:
        diagnostics = None
    return {
        "status": "unavailable", "draft_fingerprint": fingerprint,
        "input_fingerprint": snapshot.get("input_fingerprint", ""),
        "check_attempt_id": check_attempt_id,
        "error_code": code, "error_message": message, "error_context": context,
        **({"_validation_diagnostics": diagnostics} if diagnostics else {}),
    }


@router.post("/chapters/{chapter_id}/check/start", response_model=WriteJobStatus)
def start_checker(
    chapter_id: str,
    payload: CheckerRunRequest = CheckerRunRequest(),
    db: Session = Depends(get_db),
    _revision_checked: None = Depends(_require_task_revision),
    checker_client=Depends(get_checker_client),
) -> WriteJobStatus:
    """Start an informational current-prose check and return immediately.

    The worker uses the existing JobRun / registry lifecycle.  Its frozen
    ``draft.source=chapter`` is the durable discriminator from an opaque
    Writer-candidate retry, even when the visible prose originally came from
    a prior generated candidate.
    """
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if not chapter.draft_text.strip():
        raise HTTPException(
            status_code=409,
            detail={"code": "checker_preflight_failed", "message": "正文为空，不能进行内容检查"},
        )
    if write_registry.get_live(chapter.id) is not None:
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})

    from app.services.context import checker_user_message
    from app.services.production_context import freeze_manual_checker_input, production_readiness

    readiness = production_readiness(db, chapter)
    if not readiness["is_complete"] and payload.acknowledged_context_token != readiness["context_token"]:
        raise _memory_context_incomplete(readiness)
    _claim_chapter_operation(db, chapter)
    draft_text = chapter.draft_text
    snapshot = freeze_manual_checker_input(db, chapter, draft_text)
    candidate = _current_candidate(db, chapter)
    if not _candidate_matches_visible_draft(chapter, candidate, draft_text):
        db.execute(
            update(ChapterDraftCandidate)
            .where(ChapterDraftCandidate.chapter_id == chapter.id)
            .values(is_current=False)
        )
        candidate = ChapterDraftCandidate(
            chapter_id=chapter.id,
            attempt=_next_candidate_attempt(db, chapter.id),
            draft_text=draft_text,
            non_whitespace_count=nonspace_len(draft_text),
            finish_reason="manual_edit",
            deterministic_violations=[],
            bible_sha256=hashlib.sha256(chapter.user_prompt.encode()).hexdigest(),
            draft_fingerprint=draft_fingerprint(chapter, draft_text),
            is_current=True,
        )
        db.add(candidate)
        db.flush()
    check_job_id = uuid_str()
    persona = get_persona(db, "checker", book_id=chapter.book_id)
    checker_message = checker_user_message(
        chapter, draft_text, snapshot["bible"],
        reference_context=snapshot["reference_context"],
        source_catalog=snapshot["source_catalog"],
        name_hits=snapshot["name_hits"],
        name_groups=snapshot.get("name_groups"),
        name_candidate_groups=snapshot.get("name_candidate_groups"),
    )
    run = JobRun(
        id=check_job_id,
        chapter_id=chapter.id,
        kind="check",
        phase="checking",
        attempt=_next_checker_attempt(db, candidate.id),
        candidate_id=candidate.id,
        parent_job_id=None,
        input_snapshot=snapshot,
        input_fingerprint=snapshot["input_fingerprint"],
        context_limitations=snapshot["context_limitations"],
        bible_sha256=hashlib.sha256(chapter.user_prompt.encode()).hexdigest(),
        draft_fingerprint=candidate.draft_fingerprint,
        chapter_write_generation=chapter.write_generation,
        model_binding_snapshot={"checker": _model_snapshot(checker_client)},
    )
    candidate.checker_input_snapshot = snapshot
    candidate.checker_input_fingerprint = snapshot["input_fingerprint"]
    candidate.latest_checker_attempt_id = check_job_id
    candidate.checker_result = None
    db.add(run)
    job = WriteJob(
        chapter_id=chapter.id,
        job_id=check_job_id,
        kind="check",
        checker=CheckerAgent(checker_client, persona),
        checker_snapshot=snapshot,
        checker_candidate_id=candidate.id,
        checker_draft_text=draft_text,
        checker_draft_fingerprint=candidate.draft_fingerprint or "",
        checker_user_message=checker_message,
        chapter_write_generation=chapter.write_generation,
    )
    try:
        write_registry.reserve(job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})
    try:
        db.commit()
        write_registry.launch(job, SessionLocal)
    except Exception:
        db.rollback()
        if write_registry.is_current(job):
            unavailable = {
                "status": "unavailable", "input_fingerprint": snapshot.get("input_fingerprint", ""),
                "check_attempt_id": check_job_id, "draft_fingerprint": candidate.draft_fingerprint or "",
                "error_code": "checker_start_failed", "error_message": "复查未能启动；正文已保留，可重新复查",
            }
            try:
                fail_unlaunched_job(
                    SessionLocal, job, error_code="checker_start_failed",
                    error_message="复查未能启动；正文已保留，可重新复查", checker_result=unavailable,
                )
            finally:
                job.mark_terminal("failed")
        raise
    return WriteJobStatus(
        chapter_id=chapter.id,
        job_id=check_job_id,
        kind="check",
        phase="checking",
        checker_target="visible_draft",
    )


@router.post("/chapters/{chapter_id}/checker/retry", response_model=WriteJobStatus)
def retry_failed_writer_checker(
    chapter_id: str,
    payload: CheckerRetryRequest,
    db: Session = Depends(get_db),
    _revision_checked: None = Depends(_require_task_revision),
    checker_client=Depends(get_checker_client),
) -> WriteJobStatus:
    """Retry only a failed Checker against the retained Writer candidate."""
    from app.services.context import checker_user_message

    chapter = db.get(Chapter, chapter_id)
    source = db.get(JobRun, payload.source_job_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if source is None or source.chapter_id != chapter.id or source.kind != "write":
        raise HTTPException(status_code=404, detail={"code": "checker_source_not_found", "message": "未找到可重试的写作检查任务"})
    resolved_source, candidate, latest = _retry_source_and_latest_attempt(db, source)
    if resolved_source is None or candidate is None or latest is None or not _is_retryable_checker_attempt(latest):
        raise HTTPException(status_code=409, detail={"code": "checker_retry_not_available", "message": "当前候选的最新 Checker 结论不可单独重试"})
    if chapter.status == "finalized":
        raise HTTPException(status_code=409, detail={"code": "checker_retry_not_available", "message": "当前正文已经接受，旧生成稿不能再替换正文"})
    snapshot = latest.input_snapshot
    if not _candidate_checker_input_current(db, chapter, candidate, latest):
        raise HTTPException(status_code=409, detail={"code": "checker_retry_input_changed", "message": "原写作候选或其冻结输入已变化，不能只重试检查"})
    if write_registry.get_live(chapter.id) is not None:
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})
    _claim_chapter_operation(db, chapter)

    retry_id = uuid_str()
    persona = get_persona(db, "checker", book_id=chapter.book_id)
    checker_message = checker_user_message(
        chapter, candidate.draft_text, snapshot["bible"],
        reference_context=snapshot["reference_context"],
        source_catalog=snapshot["source_catalog"],
        name_hits=snapshot["name_hits"],
        name_groups=snapshot.get("name_groups"),
        name_candidate_groups=snapshot.get("name_candidate_groups"),
        retry_reason_code=(
            latest.checker_result.get("error_code")
            if isinstance(latest.checker_result, dict) else None
        ),
    )
    retry = JobRun(
        id=retry_id,
        chapter_id=chapter.id,
        kind="check",
        phase="checking",
        attempt=_next_checker_attempt(db, candidate.id),
        candidate_id=candidate.id,
        parent_job_id=source.id,
        input_snapshot=snapshot,
        input_fingerprint=snapshot["input_fingerprint"],
        context_limitations=snapshot.get("context_limitations"),
        bible_sha256=latest.bible_sha256,
        draft_fingerprint=candidate.draft_fingerprint,
        chapter_write_generation=chapter.write_generation,
        model_binding_snapshot={"checker": _model_snapshot(checker_client)},
    )
    candidate.latest_checker_attempt_id = retry_id
    candidate.checker_result = None
    db.add(retry)
    job = WriteJob(
        chapter_id=chapter.id,
        job_id=retry_id,
        kind="check",
        checker=CheckerAgent(checker_client, persona),
        checker_snapshot=snapshot,
        checker_candidate_id=candidate.id,
        checker_draft_text=candidate.draft_text,
        checker_draft_fingerprint=candidate.draft_fingerprint or "",
        checker_user_message=checker_message,
        chapter_write_generation=chapter.write_generation,
    )
    try:
        write_registry.reserve(job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})
    try:
        db.commit()
        write_registry.launch(job, SessionLocal)
    except Exception:
        db.rollback()
        if write_registry.is_current(job):
            unavailable = {
                "status": "unavailable",
                "input_fingerprint": snapshot.get("input_fingerprint", ""),
                "check_attempt_id": retry_id,
                "draft_fingerprint": candidate.draft_fingerprint or "",
                "error_code": "checker_retry_start_failed",
                "error_message": "Checker 重试未能启动，请重试",
            }
            try:
                fail_unlaunched_job(
                    SessionLocal,
                    job,
                    error_code="checker_retry_start_failed",
                    error_message="Checker 重试未能启动，请重试",
                    checker_result=unavailable,
                )
            finally:
                job.mark_terminal("failed")
        raise
    return WriteJobStatus(
        chapter_id=chapter.id,
        job_id=retry_id,
        kind="check",
        phase="checking",
        checker_source_job_id=resolved_source.id,
        checker_target="generated_candidate",
    )


def _archive_start_error(exc: Exception) -> tuple[str, str, dict]:
    if isinstance(exc, LLMConfigurationError):
        return exc.code, exc.message, {"agent_role": "extractor"}
    if isinstance(exc, HTTPException):
        detail = exc.detail if isinstance(exc.detail, dict) else {}
        return str(detail.get("code") or "archive_start_failed"), str(
            detail.get("message") or "归档配置暂时不可用，请修复后重试整理"
        ), {"agent_role": "extractor"}
    return "archive_start_failed", "归档暂时无法启动，请修复配置后重试整理", {"agent_role": "extractor"}


def _mark_archive_start_failed(job_id: str, code: str, message: str, context: dict) -> tuple[Chapter, JobRun]:
    """Finish a committed pending archive attempt without touching prose."""
    session = SessionLocal()
    try:
        run = session.get(JobRun, job_id)
        if run is None:
            raise RuntimeError("registered archive job disappeared")
        chapter = session.get(Chapter, run.chapter_id)
        revision = session.get(ChapterArchiveRevision, run.archive_revision_id)
        if chapter is None or revision is None:
            raise RuntimeError("registered archive data disappeared")
        if run.phase not in {"pending", "extracting"}:
            return chapter, run
        from app.services.archive_v2 import mark_revision_failed

        mark_revision_failed(revision, chapter, error_code=code, error_message=message)
        bump_content_revision(chapter)
        run.phase = "failed"
        run.error_code = code
        run.error_message = message
        run.error_context = context
        run.finished_at = utc_now()
        session.commit()
        session.refresh(chapter)
        session.refresh(run)
        return chapter, run
    finally:
        session.close()


def _start_archive_job(
    db: Session,
    chapter: Chapter,
    extractor_resolver: Callable[[Session, str], object],
    *,
    provenance: str,
    checker_result: dict | None = None,
    draft_check_fingerprint: str | None = None,
    accept_reservation: WriteJob | None = None,
) -> WriteJobStatus:
    """Accept/register first, then resolve and launch the Extractor.

    A rejected model configuration is an archive lifecycle failure, never a
    reason to undo an already authorized chapter acceptance.
    """
    # `/accept` reserves an in-memory admission slot *before* it takes its
    # SQLite final-proof lock.  Do not reacquire the registry while that DB
    # transaction is open; the slot already excludes a concurrent Writer.
    if accept_reservation is None and write_registry.get_live(chapter.id) is not None:
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})
    existing = db.scalars(
        select(JobRun)
        .where(
            JobRun.chapter_id == chapter.id,
            JobRun.kind == "extract",
            JobRun.phase.notin_(("done", "failed", "cancelled")),
        )
        .order_by(JobRun.created_at.desc(), JobRun.id.desc())
    ).first()
    if existing is not None:
        raise HTTPException(status_code=409, detail={"code": "archive_running", "message": "归档正在进行"})
    if provenance == "live":
        chapter.legacy_archive_eligible = False
        chapter.archive_status = "stale"
    selected_characters = [(link.character_id, link.character.name) for link in chapter.character_links]
    latest = db.scalars(
        select(ChapterArchiveRevision)
        .where(ChapterArchiveRevision.chapter_id == chapter.id)
        .order_by(ChapterArchiveRevision.revision.desc())
    ).first()
    previous_diagnostics: list[dict] | None = None
    if (
        latest is not None
        and latest.contract_version == "archive-v2.1"
        and latest.input_fingerprint == archive_input_fingerprint(chapter, contract_version=latest.contract_version)
        and latest.diagnostics
    ):
        # The archive validator stores whitelist-shaped diagnostics only.  A
        # retry may use those as correction guidance for this unchanged prose,
        # but never an old raw model response or a different chapter input.
        previous_diagnostics = [dict(item) for item in latest.diagnostics if isinstance(item, dict)]
    prior_state, prior_state_uncertainties = projected_state_before_chapter(db, chapter)
    message = build_archive_user_message(
        chapter,
        prior_state,
        previous_diagnostics=previous_diagnostics,
        prior_state_uncertainties=prior_state_uncertainties,
    )
    revision = create_archive_revision(
        db,
        chapter,
        provenance=provenance,
        input_fingerprint=archive_input_fingerprint(chapter),
    )
    job_id = uuid_str()
    run = JobRun(
        id=job_id,
        chapter_id=chapter.id,
        kind="extract",
        phase="pending",
        checker_result=checker_result,
        bible_sha256=hashlib.sha256(chapter.user_prompt.encode()).hexdigest(),
        draft_fingerprint=draft_check_fingerprint,
        archive_revision_id=revision.id,
    )
    db.add(run)
    # This is the durable acceptance transaction.  No model configuration or
    # model call belongs before it.
    chapter.status = "finalized"
    bump_content_revision(chapter)
    db.commit()

    # The durable finalized chapter plus pending extract row now excludes a
    # second accept/write.  Release the admission slot only after that commit,
    # before registering the actual Extractor owner.
    if accept_reservation is not None:
        accept_reservation.mark_terminal("done")

    reserved_job: WriteJob | None = None
    try:
        extractor_client = extractor_resolver(db, chapter.id)
        extractor = ExtractorAgent(extractor_client, get_persona(db, "extractor", book_id=chapter.book_id))
        job = WriteJob(
            chapter_id=chapter.id,
            job_id=job_id,
            kind="extract",
            extractor=extractor,
            extractor_user_message=message,
            selected_characters=selected_characters,
            archive_revision_id=revision.id,
        )
        reserved_job = job
        write_registry.reserve(job)
        persisted = db.get(JobRun, job_id)
        if persisted is None or persisted.phase != "pending":
            raise RuntimeError("archive registration is no longer current")
        persisted.phase = "extracting"
        persisted.model_binding_snapshot = {"extractor": _model_snapshot(extractor_client)}
        db.commit()
        write_registry.launch(job, SessionLocal)
    except Exception as exc:
        db.rollback()
        # `reserve()` publishes an in-memory exclusive owner before the
        # second durable registration commit.  A failure in that narrow gap
        # must release this exact owner or every archive retry remains stuck
        # behind write_running until process restart.
        if reserved_job is not None and write_registry.is_current(reserved_job):
            reserved_job.mark_terminal("failed")
        code, failure_message, context = _archive_start_error(exc)
        _mark_archive_start_failed(job_id, code, failure_message, context)
        # `_mark_archive_start_failed` owns and closes its recovery Session.
        # Reopen solely to render the accepted chapter while its relationships
        # are still attached; a detached Chapter must never lazy-load links.
        failure_session = SessionLocal()
        try:
            failed_run = failure_session.get(JobRun, job_id)
            failed_chapter = failure_session.get(Chapter, chapter.id)
            if failed_run is None or failed_chapter is None:
                raise RuntimeError("archive failure record disappeared")
            result = _job_status_from_run(failed_chapter, failed_run, db=failure_session)
            # HTTP success means prose is accepted even though the archive
            # start itself failed.
            result.chapter = _chapter_read(failed_chapter)
            return result
        finally:
            failure_session.close()

    return WriteJobStatus(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="extract",
        phase="extracting",
        checker_result=_redacted_checker_result(run.checker_result),
    )


def _accept_chapter_after_reservation(
    chapter_id: str,
    payload: CheckerAcceptRequest,
    db: Session,
    extractor_resolver: Callable[[Session, str], object],
    *,
    if_match: str | None,
    accept_reservation: WriteJob,
) -> WriteJobStatus:
    # Keep every deterministic acceptance proof and the durable finalized /
    # pending-archive transition in one short transaction.  In SQLite a
    # SELECT-only Session is not a transaction, so this must precede the
    # first Chapter/Candidate read rather than merely the final UPDATE.
    _begin_short_write_cas(db)
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    require_matching_revision(
        chapter, if_match, resource_type="chapter", resource_id=chapter.id, db=db
    )
    if not chapter.draft_text.strip():
        raise HTTPException(status_code=409, detail="chapter has no draft text")
    from app.services.production_context import freeze_manual_checker_input, is_frozen_input_current

    candidate = _current_candidate(db, chapter)
    fingerprint = draft_fingerprint(chapter, chapter.draft_text)
    current_snapshot: dict | None = None
    current_check_evidence = False
    identity_resolved = False
    checker_current = False
    if candidate is not None and candidate.draft_text == chapter.draft_text:
        result = candidate.checker_result or {}
        snapshot = candidate.checker_input_snapshot
        snapshot_current = (
            isinstance(snapshot, dict)
            and candidate.checker_input_fingerprint == snapshot.get("input_fingerprint")
            and hashlib.sha256(candidate.draft_text.encode()).hexdigest() == snapshot.get("draft", {}).get("sha256")
            and is_frozen_input_current(db, chapter, snapshot)
        )
        if snapshot_current:
            current_snapshot = snapshot
        current_check_evidence = bool(
            snapshot_current
            and result.get("input_fingerprint") == snapshot.get("input_fingerprint")
            and result.get("check_attempt_id") == candidate.latest_checker_attempt_id
            and result.get("draft_fingerprint") == candidate.draft_fingerprint
        )
        checker_current = (
            current_check_evidence
            and result.get("verdict") == "passed"
        )
    # An override remains an authorial choice only for checker availability or
    # prose-length.  It cannot make an unresolved known name safe: that must
    # be classified by Checker or explicitly exempted/selected first.
    if current_snapshot is None:
        current_snapshot = freeze_manual_checker_input(db, chapter, chapter.draft_text)
    if current_check_evidence:
        name_uses = result.get("name_uses", [])
        hit_ids = {item.get("hit_id") for item in current_snapshot.get("name_hits", []) if isinstance(item, dict)}
        resolved_ids = {
            item.get("hit_id") for item in name_uses
            if isinstance(item, dict) and item.get("classification") == "ordinary_word"
        }
        identity_resolved = resolved_ids == hit_ids and len(name_uses) == len(hit_ids)
    if current_check_evidence and not identity_resolved:
        raise HTTPException(
            status_code=409,
            detail={"code": "accept_identity_unresolved", "message": "正文含未解决的人物身份或白名单问题；请调整人物选择、豁免或正文后重新检查"},
        )
    checker_override = payload.override_checker or _has_current_checker_override(db, chapter, current_snapshot)
    # Candidate absence is no historical-compatibility marker: a newly pasted
    # draft has no candidate until its first check.  Already-finalized prose is
    # only re-entering the archive lifecycle, so it does not need a new check.
    if chapter.status != "finalized" and not checker_current and not checker_override:
        raise HTTPException(status_code=409, detail={"code": "checker_override_required", "message": "Bible 检查未通过、失效或不可用；请明确忽略后接受"})
    if chapter.status != "finalized" and not checker_current and checker_override and current_snapshot.get("name_hits") and not identity_resolved:
        raise HTTPException(
            status_code=409,
            detail={"code": "checker_identity_check_required", "message": "正文或 Bible 含需要辨别的人名；请先完成有效检查，忽略参数不能绕过人物白名单"},
        )

    # A chapter only grows a candidate row once a write job runs or /check gets
    # past its preflight, so pasting a short draft and accepting it used to skip
    # every deterministic check on the server. The client hides the accept
    # action in that state, but that is a client-side rule, and this text
    # becomes a memory source for every later chapter.
    #
    # The two violation classes are not equivalent. Character-whitelist
    # failures are a correctness matter — unselected names cannot be attributed
    # by Extractor and silently degrade to chapter-level facts — so they are
    # refused outright; the recorded way through is to exempt the name. Length
    # is a product judgement about the author's own manuscript, so a deliberate
    # short chapter stays possible behind an explicit override.
    violations = draft_violations(db, chapter, chapter.draft_text, "manual_edit")
    blocking = [item for item in violations if item["code"] in _ACCEPT_BLOCKING_VIOLATIONS]
    if blocking:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "accept_preflight_failed",
                "message": f"正文未通过确定性校验，未接受：{_violation_summary(blocking)}",
                "violations": blocking,
            },
        )
    short_draft = any(item["code"] in {"minimum_length", "length_truncated"} for item in violations)
    if short_draft and not (payload.allow_short_draft or payload.override_checker):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "short_draft_confirmation_required",
                "message": "正文不足 4000 字；请先明确确认这是作者自带短稿后接受",
                "violations": [item for item in violations if item["code"] in {"minimum_length", "length_truncated"}],
            },
        )
    if violations and candidate is None and not checker_override:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "accept_override_required",
                "message": f"正文未通过确定性校验：{_violation_summary(violations)}；请明确忽略后接受",
                "violations": violations,
            },
        )
    was_finalized = chapter.status == "finalized"
    override_applied = not checker_current and checker_override
    return _start_archive_job(
        db,
        chapter,
        extractor_resolver,
        provenance="manual_retry" if was_finalized else "live",
        checker_result=(
            {
                "override": True,
                "draft_fingerprint": fingerprint,
                "input_fingerprint": current_snapshot.get("input_fingerprint"),
                "context_limitations": _public_context_limitations(current_snapshot.get("context_limitations")),
            }
            if override_applied else None
        ),
        draft_check_fingerprint=fingerprint,
        accept_reservation=accept_reservation,
    )


@router.post("/chapters/{chapter_id}/accept", response_model=WriteJobStatus)
def accept_chapter(
    chapter_id: str,
    payload: CheckerAcceptRequest = CheckerAcceptRequest(),
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
    extractor_resolver: Callable[[Session, str], object] = Depends(get_lazy_extractor_resolver),
) -> WriteJobStatus:
    """Reserve admission before the final SQLite acceptance proof.

    Writer completion takes its per-job state lock and then a short DB CAS.
    Acceptance must therefore admit itself through the registry first, before
    it obtains the matching DB transaction; no code in the proof-to-finalize
    interval re-enters the registry.  The durable pending Extractor row
    replaces this temporary owner immediately after the acceptance commit.
    """
    reservation = WriteJob(chapter_id=chapter_id, job_id=uuid_str(), kind="accept")
    try:
        write_registry.reserve(reservation)
    except WriteJobConflict:
        raise HTTPException(
            status_code=409,
            detail={"code": "write_running", "message": "写作正在进行，不能接受旧草稿"},
        )
    try:
        return _accept_chapter_after_reservation(
            chapter_id,
            payload,
            db,
            extractor_resolver,
            if_match=if_match,
            accept_reservation=reservation,
        )
    except Exception:
        # Do not retain the DB lock while touching the registry.  If the
        # durable acceptance commit succeeded, `_start_archive_job` already
        # marked this slot terminal before any Extractor registration.
        db.rollback()
        if write_registry.is_current(reservation):
            reservation.mark_terminal("failed")
        raise


@router.post("/chapters/{chapter_id}/archive/retry", response_model=WriteJobStatus)
def retry_chapter_archive(
    chapter_id: str,
    payload: ArchiveRetryRequest = ArchiveRetryRequest(),
    db: Session = Depends(get_db),
    _revision_checked: None = Depends(_require_task_revision),
    extractor_resolver: Callable[[Session, str], object] = Depends(get_lazy_extractor_resolver),
) -> WriteJobStatus:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if chapter.status != "finalized":
        raise HTTPException(
            status_code=409,
            detail={"code": "chapter_not_finalized", "message": "正文尚未接受，不能单独重试归档"},
        )
    from app.services.production_context import production_readiness
    readiness = production_readiness(db, chapter)
    recovery = readiness["recommended_recovery"]
    if (
        recovery is not None
        and recovery.get("chapter_index", chapter.index) < chapter.index
        and payload.acknowledged_context_token != readiness["context_token"]
    ):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "archive_prior_recovery_recommended",
                "message": "前章记忆仍不完整；请先恢复，或明确知情后重试本章归档",
                "details": {
                    "context_token": readiness["context_token"],
                    "limitations": _public_context_limitations(readiness["context_limitations"]),
                    "recommended_recovery": {
                        "chapter_id": recovery["chapter_id"], "index": recovery["chapter_index"],
                        "title": recovery["title"], "reason": recovery["reason"],
                    },
                },
            },
        )
    if payload.provenance == "selective_reextract":
        actual_draft_sha256 = hashlib.sha256(chapter.draft_text.encode()).hexdigest()
        if payload.expected_draft_sha256 != actual_draft_sha256:
            raise HTTPException(
                status_code=409,
                detail={
                    "code": "archive_report_mismatch",
                    "message": "章节正文已不同于用户确认的候选报告，已拒绝历史重提",
                },
            )
    return _start_archive_job(
        db,
        chapter,
        extractor_resolver,
        provenance=payload.provenance,
        draft_check_fingerprint=draft_fingerprint(chapter, chapter.draft_text),
    )


@router.get("/chapters/{chapter_id}/rewrite-preview", response_model=RewriteImpactPreview)
def rewrite_preview(chapter_id: str, db: Session = Depends(get_db)) -> RewriteImpactPreview:
    """Dry-run the archive cascade a rewrite of this chapter would cause.

    This deliberately runs the real `invalidate_archive_if_input_changed` +
    `invalidate_downstream_archives` and throws the transaction away, rather
    than reimplementing the staleness rule. A second copy of that rule is the
    exact failure this endpoint exists to prevent: the answer depends on each
    later chapter's `prior_state` fingerprint, so an independent story line
    that shares no characters with this chapter must not be reported.

    The price of reusing them is that a read-only request briefly takes SQLite's
    write lock, because `invalidate_downstream_archives` flushes. If that
    contention ever becomes a real problem, the fix is to split that function
    into a "decide" half and a "persist" half and let both callers share the
    decide half -- never to grow a second copy of the decision in here.

    Read-only is enforced by construction: the function never commits, and the
    `finally` rolls back whatever the two real functions wrote.
    """
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    chapter_index = chapter.index
    book_id = chapter.book_id
    try:
        previous_archive_fingerprint = archive_input_fingerprint(chapter)
        # `force=True` mirrors reopen: a rewrite discards this chapter's own
        # archive whether or not its inputs happen to have changed already.
        invalidate_archive_if_input_changed(
            db, chapter, previous_fingerprint=previous_archive_fingerprint, force=True
        )
        invalidated_ids = invalidate_downstream_archives(
            db, book_id, after_index=chapter_index
        )
        # Read the answer out as plain values *before* the rollback; rolling
        # back expires every ORM object these functions touched.
        affected: list[RewriteImpactChapter] = []
        if invalidated_ids:
            rows = db.scalars(
                select(Chapter)
                .where(Chapter.id.in_(invalidated_ids))
                .order_by(Chapter.index, Chapter.id)
            ).all()
            affected = [
                RewriteImpactChapter(id=row.id, index=row.index, title=row.title) for row in rows
            ]
    except OperationalError as exc:
        if not _is_sqlite_busy(exc):
            raise
        # The flush inside the cascade wants SQLite's write lock, which a live
        # Writer or Extractor commit can be holding. Report that in the same
        # structured shape `create_chapter` uses for the same collision instead
        # of a bare 500: the clients fall back to the conservative confirmation
        # wording, and a preview failure must stay diagnosable.
        raise HTTPException(
            status_code=409,
            detail={
                "code": "rewrite_preview_busy",
                "message": "数据库正忙，暂时取不到影响范围，请稍后重试",
                "details": {},
            },
        ) from exc
    finally:
        # No commit anywhere above, and `get_db` only closes, so this undoes
        # the whole dry run; the rollback also expires every ORM object the two
        # functions touched. `stale_archives_for_reopen` (JobRun bookkeeping)
        # and `rebuild_book_projection` (pure write) are intentionally skipped:
        # neither changes which chapters come back as affected.
        db.rollback()
    return RewriteImpactPreview(
        chapter_id=chapter_id, index=chapter_index, affected_chapters=affected
    )


@router.post("/chapters/{chapter_id}/reopen", response_model=ChapterRead)
def reopen_chapter(
    chapter_id: str,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    require_matching_revision(chapter, if_match, resource_type="chapter", resource_id=chapter.id, db=db)
    previous_archive_fingerprint = archive_input_fingerprint(chapter)
    stale_archives_for_reopen(db, chapter)
    chapter.status = "draft_ready"
    # Reopening invalidates v2 selection, but legacy rows remain auditable.
    invalidate_archive_if_input_changed(
        db, chapter, previous_fingerprint=previous_archive_fingerprint, force=True
    )
    invalidated_downstream = invalidate_downstream_archives(db, chapter.book_id, after_index=chapter.index)
    for downstream_id in invalidated_downstream:
        downstream = db.get(Chapter, downstream_id)
        if downstream is not None:
            bump_content_revision(downstream)
    rebuild_book_projection(db, chapter.book_id)
    bump_content_revision(chapter)
    rebuild_book_search_index(db, chapter.book_id)
    db.commit()
    live_job = write_registry.get_live(chapter.id)
    if live_job is not None and live_job.kind == "extract":
        write_registry.cancel(live_job, discard=True)
    db.refresh(chapter)
    return _chapter_read(chapter)
