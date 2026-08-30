from __future__ import annotations

import hashlib
import time

from fastapi import APIRouter, Depends, Header, HTTPException, Response, status
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlalchemy.orm import Session, object_session

from app.agents.extractor import ExtractorAgent
from app.agents.checker import CheckerAgent
from app.agents.inspiration_creator import InspirationCreatorAgent
from app.agents.memory_selector import MemorySelectorAgent
from app.agents.writer import WriterAgent
from app.db import SessionLocal, get_db
from app.llm.base import LLMError
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
from app.services.character_state_projection import projected_fields_before_chapter, rebuild_book_projection
from app.services.inspiration_context import InspirationContextError, build_inspiration_context
from app.services.write_jobs import WriteJob, WriteJobConflict, record_job_phase, write_registry
from app.services.write_ownership import cancel_local_writer_jobs, invalidate_writer_inputs
from app.services.archive_v2 import (
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
    issues = result.get("issues")
    if not isinstance(issues, list):
        return result
    redacted = dict(result)
    redacted["issues"] = [
        {key: issue[key] for key in ("kind", "reason") if key in issue}
        if isinstance(issue, dict)
        else issue
        for issue in issues
    ]
    return redacted


def _job_status_from_run(
    chapter: Chapter,
    run: JobRun,
    visible_checker_result: dict | None = None,
) -> WriteJobStatus:
    outcome_current = None
    if run.phase in {"done", "failed", "cancelled"}:
        if run.kind == "write" and run.chapter_write_generation is not None:
            outcome_current = run.chapter_write_generation == chapter.write_generation
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
        error_message=run.error_message,
        error_context=run.error_context,
        violations=run.violations,
        memory_context=run.memory_context,
        checker_result=_redacted_checker_result(run.checker_result),
        visible_checker_result=visible_checker_result,
    )
    if run.phase == "done":
        status_out.chapter = _chapter_read(chapter)
        status_out.updated_character_ids = run.updated_character_ids
        status_out.added_event_ids = run.added_event_ids
    return status_out


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
    if payload.model_fields_set:
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
    if payload.model_fields_set:
        bump_content_revision(chapter)
    rebuild_book_search_index(db, chapter.book_id)
    db.commit()
    if payload.model_fields_set:
        cancel_local_writer_jobs(invalidated)
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
    memory_selector_client=Depends(get_memory_selector_client),
    writer_client=Depends(get_writer_client),
    checker_client=Depends(get_checker_client),
) -> WriteJobStatus:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if chapter.status == "finalized":
        raise HTTPException(status_code=409, detail={"code": "chapter_finalized", "message": "请先重新编辑本章"})
    try:
        validate_character_preflight(db, chapter)
    except CharacterPreflightError as exc:
        raise HTTPException(
            status_code=409,
            detail={"code": exc.code, "message": exc.message, "details": exc.details},
        ) from exc

    live_job = write_registry.get_live(chapter_id)
    if live_job is not None:
        if not payload.replace_draft:
            raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行"})
        write_registry.cancel(live_job, discard=True)
        if live_job.thread is not None:
            live_job.thread.join(timeout=8)
        record_job_phase(SessionLocal, live_job.job_id, "cancelled")
        invalidate_writer_inputs(db, [chapter])
    candidates = memory_candidates(db, chapter)
    selected_ids = {link.character_id for link in chapter.character_links}
    candidates = prefilter_memory_candidates(candidates, chapter=chapter, selected_character_ids=selected_ids)
    budget = memory_budget()
    bible_snapshot = chapter.user_prompt
    bible_sha256 = hashlib.sha256(bible_snapshot.encode()).hexdigest()
    selector_message = memory_selector_user_message(
        chapter, candidates, budget, bible=bible_snapshot,
        dynamic_fields_by_character=projected_fields_before_chapter(db, chapter),
    )
    baseline_text = chapter.draft_text
    baseline_status = "draft_ready" if baseline_text.strip() else "draft"
    job_id = uuid_str()
    run = JobRun(
        id=job_id,
        chapter_id=chapter.id,
        kind="write",
        phase="selecting_memory",
        bible_sha256=bible_sha256,
        chapter_write_generation=chapter.write_generation,
        model_binding_snapshot={
            "memory_selector": _model_snapshot(memory_selector_client),
            "writer": _model_snapshot(writer_client),
            "checker": _model_snapshot(checker_client),
        },
    )
    db.add(run)
    job = WriteJob(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="write",
        memory_selector=MemorySelectorAgent(
            memory_selector_client, get_persona(db, "memory_selector", book_id=chapter.book_id)
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
    )
    try:
        write_registry.reserve(job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行"})
    chapter.status = "writing"
    bump_content_revision(chapter)
    db.commit()
    write_registry.launch(job, SessionLocal)
    return WriteJobStatus(chapter_id=chapter.id, job_id=job_id, kind="write", phase="selecting_memory")


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
        return WriteJobStatus(
            chapter_id=chapter_id,
            job_id=live_job.job_id or None,
            kind=live_job.kind,
            phase=live_job.phase,
        )
    if run is None:
        return WriteJobStatus(chapter_id=chapter_id, kind="write", phase="idle")
    return _job_status_from_run(chapter, run, _visible_checker_result(db, chapter))


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
    if (
        candidate.bible_sha256 != hashlib.sha256(chapter.user_prompt.encode()).hexdigest()
        or candidate.draft_fingerprint != fingerprint
        or result.get("draft_fingerprint") != fingerprint
    ):
        return None
    return result


def _next_candidate_attempt(db: Session, chapter_id: str) -> int:
    current_max = db.scalar(
        select(func.max(ChapterDraftCandidate.attempt)).where(ChapterDraftCandidate.chapter_id == chapter_id)
    )
    return int(current_max or 0) + 1


def _has_current_checker_override(
    db: Session,
    chapter: Chapter,
    candidate: ChapterDraftCandidate | None,
    fingerprint: str,
) -> bool:
    """Return whether the user already approved this exact writing input.

    Extractor failures must not erase a deliberate Bible-check override.  The
    approval is kept in the existing immutable JobRun audit trail and scoped
    by the full draft fingerprint, so editing the body, Bible, title, world or
    selected-character input automatically invalidates it.
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
        if run.draft_fingerprint == fingerprint:
            return True
        # Build 26 and older did record the explicit override but not its
        # fingerprint.  Recover that approval only when the immutable current
        # candidate proves every fingerprinted input is still byte-identical
        # and predates the override job.  A later recheck/edit cannot inherit
        # this compatibility path.
        if (
            run.draft_fingerprint is None
            and candidate is not None
            and candidate.created_at <= run.created_at
            and candidate.draft_text == chapter.draft_text
            and candidate.bible_sha256 == hashlib.sha256(chapter.user_prompt.encode()).hexdigest()
            and candidate.draft_fingerprint == fingerprint
            and _candidate_fingerprint(chapter, candidate) == fingerprint
        ):
            return True
    return False


@router.post("/chapters/{chapter_id}/check", response_model=CheckerRunRead)
def rerun_checker(
    chapter_id: str,
    db: Session = Depends(get_db),
    _revision_checked: None = Depends(_require_task_revision),
    checker_client=Depends(get_checker_client),
) -> CheckerRunRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    candidate = _current_candidate(db, chapter)
    violations = draft_violations(db, chapter, chapter.draft_text, "manual_edit")
    if violations:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "checker_preflight_failed",
                "message": "当前正文未通过确定性校验，未调用 Bible 检查",
                "violations": violations,
            },
        )
    # A manually edited text must become a separate immutable candidate so the
    # generated version and its original Checker evidence remain reviewable.
    if candidate is None or candidate.draft_text != chapter.draft_text:
        db.execute(
            update(ChapterDraftCandidate)
            .where(ChapterDraftCandidate.chapter_id == chapter.id)
            .values(is_current=False)
        )
        candidate = ChapterDraftCandidate(
            chapter_id=chapter.id,
            attempt=_next_candidate_attempt(db, chapter.id),
            draft_text=chapter.draft_text,
            non_whitespace_count=nonspace_len(chapter.draft_text),
            finish_reason="manual_edit",
            deterministic_violations=[],
            bible_sha256=hashlib.sha256(chapter.user_prompt.encode()).hexdigest(),
            draft_fingerprint=draft_fingerprint(chapter, chapter.draft_text),
            is_current=True,
        )
        db.add(candidate)
        db.flush()
    fingerprint = _candidate_fingerprint(chapter, candidate)
    from app.services.context import checker_user_message
    try:
        raw = CheckerAgent(checker_client, get_persona(db, "checker", book_id=chapter.book_id)).check(
            checker_user_message(chapter, chapter.draft_text, chapter.user_prompt)
        )
        from app.services.write_jobs import _valid_checker_result
        candidate.checker_result = _valid_checker_result(raw, fingerprint)
    except Exception as exc:  # Checker never changes a candidate, including upstream failures.
        candidate.checker_result = {"status": "unavailable", "draft_fingerprint": fingerprint, "error_code": getattr(exc, "code", "checker_failed")}
    candidate.bible_sha256 = hashlib.sha256(chapter.user_prompt.encode()).hexdigest()
    candidate.draft_fingerprint = fingerprint
    db.commit(); db.refresh(candidate)
    return CheckerRunRead.model_validate(candidate).model_copy(update={"draft_text": ""})


def _start_archive_job(
    db: Session,
    chapter: Chapter,
    extractor_client,
    *,
    provenance: str,
    checker_result: dict | None = None,
    draft_check_fingerprint: str | None = None,
) -> WriteJobStatus:
    if write_registry.get_live(chapter.id) is not None:
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})
    if provenance == "live":
        chapter.legacy_archive_eligible = False
        chapter.archive_status = "stale"
    extractor = ExtractorAgent(extractor_client, get_persona(db, "extractor", book_id=chapter.book_id))
    selected_characters = [(link.character_id, link.character.name) for link in chapter.character_links]
    message = build_archive_user_message(chapter, projected_fields_before_chapter(db, chapter))
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
        phase="extracting",
        checker_result=checker_result,
        bible_sha256=hashlib.sha256(chapter.user_prompt.encode()).hexdigest(),
        draft_fingerprint=draft_check_fingerprint,
        archive_revision_id=revision.id,
        model_binding_snapshot={"extractor": _model_snapshot(extractor_client)},
    )
    db.add(run)
    job = WriteJob(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="extract",
        extractor=extractor,
        extractor_user_message=message,
        selected_characters=selected_characters,
        archive_revision_id=revision.id,
    )
    try:
        write_registry.reserve(job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "当前任务正在进行"})
    chapter.status = "finalized"
    bump_content_revision(chapter)
    db.commit()
    write_registry.launch(job, SessionLocal)
    return WriteJobStatus(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="extract",
        phase="extracting",
        checker_result=_redacted_checker_result(run.checker_result),
    )


@router.post("/chapters/{chapter_id}/accept", response_model=WriteJobStatus)
def accept_chapter(
    chapter_id: str, payload: CheckerAcceptRequest = CheckerAcceptRequest(),
    db: Session = Depends(get_db),
    _revision_checked: None = Depends(_require_task_revision),
    extractor_client=Depends(get_extractor_client),
) -> WriteJobStatus:
    if write_registry.get_live(chapter_id) is not None:
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行，不能接受旧草稿"})
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if not chapter.draft_text.strip():
        raise HTTPException(status_code=409, detail="chapter has no draft text")
    candidate = _current_candidate(db, chapter)
    fingerprint = draft_fingerprint(chapter, chapter.draft_text)
    checker_current = False
    if candidate is not None and candidate.draft_text == chapter.draft_text:
        result = candidate.checker_result or {}
        checker_current = (
            candidate.bible_sha256 == hashlib.sha256(chapter.user_prompt.encode()).hexdigest()
            and candidate.draft_fingerprint == _candidate_fingerprint(chapter, candidate)
            and result.get("draft_fingerprint") == candidate.draft_fingerprint
            and result.get("verdict") == "passed"
        )
    checker_override = payload.override_checker or _has_current_checker_override(db, chapter, candidate, fingerprint)
    # Pre-v1.6 imported drafts have no candidate. Keep old wire clients able to
    # accept those drafts, while all v1.6 candidates require a current pass or
    # an explicit user override.
    if candidate is not None and not checker_current and not checker_override:
        raise HTTPException(status_code=409, detail={"code": "checker_override_required", "message": "Bible 检查未通过、失效或不可用；请明确忽略后接受"})

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
        extractor_client,
        provenance="manual_retry" if was_finalized else "live",
        checker_result={"override": True, "draft_fingerprint": fingerprint} if override_applied else None,
        draft_check_fingerprint=fingerprint,
    )


@router.post("/chapters/{chapter_id}/archive/retry", response_model=WriteJobStatus)
def retry_chapter_archive(
    chapter_id: str,
    payload: ArchiveRetryRequest = ArchiveRetryRequest(),
    db: Session = Depends(get_db),
    _revision_checked: None = Depends(_require_task_revision),
    extractor_client=Depends(get_extractor_client),
) -> WriteJobStatus:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if chapter.status != "finalized":
        raise HTTPException(
            status_code=409,
            detail={"code": "chapter_not_finalized", "message": "正文尚未接受，不能单独重试归档"},
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
        extractor_client,
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
