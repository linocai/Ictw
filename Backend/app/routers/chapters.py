from __future__ import annotations

import hashlib

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, object_session

from app.agents.extractor import ExtractorAgent
from app.agents.checker import CheckerAgent
from app.agents.memory_selector import MemorySelectorAgent
from app.agents.writer import WriterAgent
from app.db import SessionLocal, get_db
from app.llm.factory import (
    get_extractor_client,
    get_checker_client,
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
from app.services.character_state_projection import projected_fields_before_chapter, rebuild_book_projection
from app.services.write_jobs import WriteJob, WriteJobConflict, record_job_phase, write_registry
from app.services.archive_v2 import (
    archive_input_fingerprint,
    archive_read_model,
    build_archive_user_message,
    create_archive_revision,
    invalidate_downstream_archives,
    invalidate_archive_if_input_changed,
)

router = APIRouter(tags=["chapters"])


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
        character_links=[{"character_id": link.character_id, "chapter_note": ""} for link in chapter.character_links],
        archive=archive_read_model(session, chapter) if session is not None else None,
    )


def _job_status_from_run(
    chapter: Chapter,
    run: JobRun,
    visible_checker_result: dict | None = None,
) -> WriteJobStatus:
    outcome_current = None
    if run.phase in {"done", "failed", "cancelled"}:
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
        checker_result=run.checker_result,
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
        chapter.character_links.append(ChapterCharacter(character_id=item.character_id))
        seen.add(item.character_id)
    # Relationship-only edits do not otherwise issue an UPDATE for chapters,
    # so explicitly advance the authoritative version used by /job
    # outcome_current reconciliation.
    chapter.updated_at = utc_now()


def _apply_author_note(chapter: Chapter, author_note: str | None) -> None:
    if author_note is not None:
        chapter.author_note = author_note


@router.get("/books/{book_id}/chapters", response_model=list[ChapterSummary])
def list_chapters(book_id: str, db: Session = Depends(get_db)) -> list[Chapter]:
    return list(db.scalars(select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index)).all())


@router.post("/books/{book_id}/chapters", response_model=ChapterRead, status_code=status.HTTP_201_CREATED)
def create_chapter(book_id: str, payload: ChapterCreate, db: Session = Depends(get_db)) -> ChapterRead:
    if db.get(Book, book_id) is None:
        raise HTTPException(status_code=404, detail="book not found")
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
    db.add(chapter)
    db.flush()
    _replace_links(db, chapter, payload.character_links)
    db.commit()
    db.refresh(chapter)
    return _chapter_read(chapter)


@router.get("/chapters/{chapter_id}", response_model=ChapterRead)
def get_chapter(chapter_id: str, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    return _chapter_read(chapter)


@router.patch("/chapters/{chapter_id}", response_model=ChapterRead)
def patch_chapter(chapter_id: str, payload: ChapterPatch, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
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
    archive_invalidated = invalidate_archive_if_input_changed(
        db, chapter, previous_fingerprint=previous_archive_fingerprint
    )
    if archive_invalidated:
        invalidate_downstream_archives(db, chapter.book_id, after_index=chapter.index)
        rebuild_book_projection(db, chapter.book_id)
    db.commit()
    db.refresh(chapter)
    return _chapter_read(chapter)



@router.delete("/chapters/{chapter_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_chapter(chapter_id: str, db: Session = Depends(get_db)) -> Response:
    job = write_registry.get_live(chapter_id)
    if job is not None:
        write_registry.cancel(job, discard=True)
        if job.thread is not None:
            job.thread.join(timeout=8)
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        return Response(status_code=status.HTTP_204_NO_CONTENT)
    book_id = chapter.book_id
    old_index = chapter.index
    db.delete(chapter)
    db.flush()
    following = db.scalars(
        select(Chapter)
        .where(Chapter.book_id == book_id, Chapter.index > old_index)
        .order_by(Chapter.index)
    ).all()
    for item in following:
        item.index -= 1
        db.flush()
    invalidate_downstream_archives(db, book_id, after_index=old_index - 1)
    rebuild_book_projection(db, book_id)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/chapters/{chapter_id}/import", response_model=ChapterRead)
def import_chapter(chapter_id: str, payload: ChapterImportRequest, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
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
    archive_invalidated = invalidate_archive_if_input_changed(
        db, chapter, previous_fingerprint=previous_archive_fingerprint
    )
    if archive_invalidated:
        invalidate_downstream_archives(db, chapter.book_id, after_index=chapter.index)
        rebuild_book_projection(db, chapter.book_id)
    db.commit()
    db.refresh(chapter)
    return _chapter_read(chapter)


@router.post("/chapters/{chapter_id}/write", response_model=WriteJobStatus)
def write_chapter(
    chapter_id: str,
    payload: WriteRequest = WriteRequest(),
    db: Session = Depends(get_db),
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
    run = JobRun(id=job_id, chapter_id=chapter.id, kind="write", phase="selecting_memory", bible_sha256=bible_sha256)
    db.add(run)
    job = WriteJob(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="write",
        memory_selector=MemorySelectorAgent(memory_selector_client, get_persona(db, "memory_selector")),
        writer=WriterAgent(writer_client, get_persona(db, "writer")),
        checker=CheckerAgent(checker_client, get_persona(db, "checker")),
        selector_user_message=selector_message,
        memory_candidates=candidates,
        memory_budget=budget,
        baseline_text=baseline_text,
        baseline_status=baseline_status,
        bible_snapshot=bible_snapshot,
        bible_sha256=bible_sha256,
    )
    try:
        write_registry.reserve(job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行"})
    chapter.status = "writing"
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
    if job is not None and job.kind == "extract" and job.archive_revision_id:
        revision = db.get(ChapterArchiveRevision, job.archive_revision_id)
        if revision is not None and revision.status in {"pending", "extracting"}:
            revision.status = "failed"
            revision.error_code = "archive_cancelled"
            revision.error_message = "归档任务已取消"
            revision.finished_at = utc_now()
            chapter.archive_status = "complete" if chapter.active_archive_revision_id else "failed"
            db.commit()
            db.refresh(chapter)
    if chapter.status in ("writing", "extracting"):
        chapter.status = "draft_ready" if chapter.draft_text.strip() else "draft"
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
def rerun_checker(chapter_id: str, db: Session = Depends(get_db), checker_client=Depends(get_checker_client)) -> CheckerRunRead:
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
        raw = CheckerAgent(checker_client, get_persona(db, "checker")).check(
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
    extractor = ExtractorAgent(extractor_client, get_persona(db, "extractor"))
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
    db.commit()
    write_registry.launch(job, SessionLocal)
    return WriteJobStatus(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="extract",
        phase="extracting",
        checker_result=run.checker_result,
    )


@router.post("/chapters/{chapter_id}/accept", response_model=WriteJobStatus)
def accept_chapter(
    chapter_id: str, payload: CheckerAcceptRequest = CheckerAcceptRequest(), db: Session = Depends(get_db), extractor_client=Depends(get_extractor_client)
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


@router.post("/chapters/{chapter_id}/reopen", response_model=ChapterRead)
def reopen_chapter(chapter_id: str, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    previous_archive_fingerprint = archive_input_fingerprint(chapter)
    chapter.status = "draft_ready"
    # Reopening invalidates v2 selection, but legacy rows remain auditable.
    invalidate_archive_if_input_changed(
        db, chapter, previous_fingerprint=previous_archive_fingerprint, force=True
    )
    invalidate_downstream_archives(db, chapter.book_id, after_index=chapter.index)
    rebuild_book_projection(db, chapter.book_id)
    db.commit()
    db.refresh(chapter)
    return _chapter_read(chapter)
