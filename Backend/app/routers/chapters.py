from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.agents.extractor import ExtractorAgent
from app.agents.memory_selector import MemorySelectorAgent
from app.agents.reviser import ReviserAgent
from app.agents.writer import WriterAgent
from app.db import SessionLocal, get_db
from app.llm.factory import (
    get_extractor_client,
    get_memory_selector_client,
    get_reviser_client,
    get_writer_client,
)
from app.models import Book, Chapter, ChapterCharacter, Character, CharacterFieldPatch, JobRun
from app.models.entities import uuid_str
from app.schemas.chapter import (
    ChapterCreate,
    ChapterImportRequest,
    ChapterPatch,
    ChapterRead,
    ChapterSummary,
    WriteJobStatus,
    WriteRequest,
)
from app.services.context import (
    CharacterPreflightError,
    chapter_author_note,
    extractor_user_message,
    memory_budget,
    memory_candidates,
    memory_selector_user_message,
    prefilter_memory_candidates,
    validate_character_preflight,
)
from app.services.personas import get_persona
from app.services.write_jobs import WriteJob, WriteJobConflict, record_job_phase, write_registry

router = APIRouter(tags=["chapters"])


def _chapter_read(chapter: Chapter) -> ChapterRead:
    note = chapter_author_note(chapter)
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
        exempted_character_names=list(chapter.exempted_character_names or []),
        status=chapter.status,
        source=chapter.source,
        created_at=chapter.created_at,
        updated_at=chapter.updated_at,
        character_links=[{"character_id": link.character_id, "chapter_note": ""} for link in chapter.character_links],
    )


def _job_status_from_run(chapter: Chapter, run: JobRun) -> WriteJobStatus:
    status_out = WriteJobStatus(
        chapter_id=chapter.id,
        kind=run.kind,
        phase=run.phase,
        attempt=run.attempt,
        error_code=run.error_code,
        error_message=run.error_message,
        violations=run.violations,
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
    updates = payload.model_dump(exclude_unset=True, exclude={"character_links", "author_note", "chapter_style"})
    for key, value in updates.items():
        setattr(chapter, key, value)
    if "author_note" in payload.model_fields_set or "chapter_style" in payload.model_fields_set:
        _apply_author_note(chapter, payload.author_note)
    if payload.character_links is not None:
        _replace_links(db, chapter, payload.character_links)
    db.commit()
    db.refresh(chapter)
    return _chapter_read(chapter)



def _revert_dynamic_fields(db: Session, chapter: Chapter) -> None:
    """Roll back this chapter's dynamic-field merges, key by key.

    A key is restored to its pre-chapter value (or removed if the chapter
    introduced it) unless a LATER chapter also patched the same key — the later
    chapter's state must win and stays untouched.
    """
    patches = db.scalars(
        select(CharacterFieldPatch).where(CharacterFieldPatch.chapter_id == chapter.id)
    ).all()
    if not patches:
        return
    later_rows = db.scalars(
        select(CharacterFieldPatch)
        .join(Chapter, CharacterFieldPatch.chapter_id == Chapter.id)
        .where(
            CharacterFieldPatch.character_id.in_([row.character_id for row in patches]),
            Chapter.book_id == chapter.book_id,
            Chapter.index > chapter.index,
        )
    ).all()
    later_keys: dict[str, set[str]] = {}
    for row in later_rows:
        keys = set(row.prior_values or {}) | set(row.prior_missing or [])
        later_keys.setdefault(row.character_id, set()).update(keys)
    for row in patches:
        character = db.get(Character, row.character_id)
        if character is None:
            continue
        blocked = later_keys.get(row.character_id, set())
        fields = dict(character.dynamic_fields or {})
        changed = False
        for key, value in (row.prior_values or {}).items():
            if key not in blocked and fields.get(key) != value:
                fields[key] = value
                changed = True
        for key in row.prior_missing or []:
            if key not in blocked and key in fields:
                fields.pop(key)
                changed = True
        if changed:
            character.dynamic_fields = fields


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
    _revert_dynamic_fields(db, chapter)
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
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/chapters/{chapter_id}/import", response_model=ChapterRead)
def import_chapter(chapter_id: str, payload: ChapterImportRequest, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
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
    reviser_client=Depends(get_reviser_client),
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
    selector_message = memory_selector_user_message(chapter, candidates, budget)
    baseline_text = chapter.draft_text
    baseline_status = "draft_ready" if baseline_text.strip() else "draft"
    job_id = uuid_str()
    run = JobRun(id=job_id, chapter_id=chapter.id, kind="write", phase="selecting_memory")
    db.add(run)
    job = WriteJob(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="write",
        memory_selector=MemorySelectorAgent(memory_selector_client, get_persona(db, "memory_selector")),
        writer=WriterAgent(writer_client, get_persona(db, "writer")),
        reviser=ReviserAgent(reviser_client, get_persona(db, "reviser")),
        selector_user_message=selector_message,
        memory_candidates=candidates,
        memory_budget=budget,
        baseline_text=baseline_text,
        baseline_status=baseline_status,
    )
    try:
        write_registry.reserve(job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行"})
    chapter.status = "writing"
    db.commit()
    write_registry.launch(job, SessionLocal)
    return WriteJobStatus(chapter_id=chapter.id, kind="write", phase="selecting_memory")


@router.get("/chapters/{chapter_id}/job", response_model=WriteJobStatus)
def chapter_job(chapter_id: str, db: Session = Depends(get_db)) -> WriteJobStatus:
    # Read the run BEFORE the chapter. pysqlite does not hold a snapshot across
    # SELECTs, and the worker commits the finalized/draft_ready chapter before it
    # commits the terminal job phase. Observing a terminal run therefore
    # guarantees the subsequent chapter read sees the already-committed result.
    run = db.scalars(
        select(JobRun)
        .where(JobRun.chapter_id == chapter_id)
        .order_by(JobRun.created_at.desc(), JobRun.id.desc())
    ).first()
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if run is None:
        return WriteJobStatus(chapter_id=chapter_id, kind="write", phase="idle")
    return _job_status_from_run(chapter, run)


@router.post("/chapters/{chapter_id}/write/cancel", response_model=ChapterRead)
def cancel_write(chapter_id: str, db: Session = Depends(get_db)) -> ChapterRead:
    job = write_registry.get_live(chapter_id)
    if job is not None:
        write_registry.cancel(job, discard=True)
        if job.thread is not None:
            job.thread.join(timeout=8)
        record_job_phase(SessionLocal, job.job_id, "cancelled")
    db.expire_all()
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if chapter.status in ("writing", "extracting"):
        chapter.status = "draft_ready" if chapter.draft_text.strip() else "draft"
        db.commit()
        db.refresh(chapter)
    return _chapter_read(chapter)


@router.post("/chapters/{chapter_id}/accept", response_model=WriteJobStatus)
def accept_chapter(
    chapter_id: str, db: Session = Depends(get_db), extractor_client=Depends(get_extractor_client)
) -> WriteJobStatus:
    if write_registry.get_live(chapter_id) is not None:
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行，不能接受旧草稿"})
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    if not chapter.draft_text.strip():
        raise HTTPException(status_code=409, detail="chapter has no draft text")
    book = db.get(Book, chapter.book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="book not found")
    extractor = ExtractorAgent(extractor_client, get_persona(db, "extractor"))
    selected_ids = [link.character_id for link in chapter.character_links]
    message = extractor_user_message(db, book, chapter)
    job_id = uuid_str()
    run = JobRun(id=job_id, chapter_id=chapter.id, kind="extract", phase="extracting")
    db.add(run)
    job = WriteJob(
        chapter_id=chapter.id,
        job_id=job_id,
        kind="extract",
        extractor=extractor,
        extractor_user_message=message,
        selected_character_ids=selected_ids,
    )
    try:
        write_registry.reserve(job)
    except WriteJobConflict:
        db.rollback()
        raise HTTPException(status_code=409, detail={"code": "write_running", "message": "写作正在进行，不能接受旧草稿"})
    chapter.status = "extracting"
    db.commit()
    write_registry.launch(job, SessionLocal)
    return WriteJobStatus(chapter_id=chapter.id, kind="extract", phase="extracting")


@router.post("/chapters/{chapter_id}/reopen", response_model=ChapterRead)
def reopen_chapter(chapter_id: str, db: Session = Depends(get_db)) -> ChapterRead:
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    chapter.status = "draft_ready"
    db.commit()
    db.refresh(chapter)
    return _chapter_read(chapter)
