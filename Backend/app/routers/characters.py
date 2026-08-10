from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import (
    Book,
    Chapter,
    ChapterArchiveFact,
    ChapterArchiveFactParticipant,
    ChapterArchiveRevision,
    ChapterArchiveStateDelta,
    Character,
    CharacterEvent,
    CharacterStateChange,
)
from app.schemas.character import (
    CharacterCreate,
    CharacterEventPatch,
    CharacterEventRead,
    CharacterImportRequest,
    CharacterPatch,
    CharacterRead,
)
from app.services.context import CHARACTER_EVENT_MAX_CHARS, truncate_to_nonspace
from app.services.character_state_projection import rebuild_book_projection
from app.services.write_ownership import cancel_local_writer_jobs, chapters_for_character, invalidate_writer_inputs
from app.services.archive_v2 import invalidate_archive_if_input_changed, invalidate_downstream_archives

router = APIRouter(tags=["characters"])


def _character_event_read(event: CharacterEvent) -> CharacterEventRead:
    return CharacterEventRead(
        id=event.id,
        book_id=event.book_id,
        character_id=event.character_id,
        chapter_id=event.chapter_id,
        event_type=event.event_type,
        event_text=event.event_text,
        created_at=event.created_at,
        updated_at=event.updated_at,
        chapter_index=event.chapter.index if event.chapter is not None else None,
    )


def _character_read(db: Session, character: Character) -> CharacterRead:
    events = db.scalars(
        select(CharacterEvent)
        .join(Chapter, CharacterEvent.chapter_id == Chapter.id)
        .where(CharacterEvent.character_id == character.id)
        .order_by(Chapter.index)
    ).all()
    data = CharacterRead.model_validate(character)
    data.dynamic_fields_updated_chapter_index = db.scalar(
        select(func.max(Chapter.index))
        .join(CharacterStateChange, CharacterStateChange.chapter_id == Chapter.id)
        .where(
            CharacterStateChange.book_id == character.book_id,
            CharacterStateChange.is_effective.is_(True),
            or_(CharacterStateChange.character_id == character.id, CharacterStateChange.other_character_id == character.id),
        )
    )
    v2_updated_index = db.scalar(
        select(func.max(Chapter.index))
        .join(ChapterArchiveRevision, ChapterArchiveRevision.chapter_id == Chapter.id)
        .join(ChapterArchiveStateDelta, ChapterArchiveStateDelta.revision_id == ChapterArchiveRevision.id)
        .where(
            ChapterArchiveRevision.is_active.is_(True),
            ChapterArchiveRevision.status == "complete",
            ChapterArchiveStateDelta.is_effective.is_(True),
            or_(
                ChapterArchiveStateDelta.character_id == character.id,
                ChapterArchiveStateDelta.other_character_id == character.id,
            ),
        )
    )
    if v2_updated_index is not None:
        data.dynamic_fields_updated_chapter_index = max(
            data.dynamic_fields_updated_chapter_index or 0, v2_updated_index
        )
    data.events = []
    for event in events:
        data.events.append(
            CharacterEventRead(
                id=event.id,
                book_id=event.book_id,
                character_id=event.character_id,
                chapter_id=event.chapter_id,
                event_type=event.event_type,
                event_text=event.event_text,
                created_at=event.created_at,
                updated_at=event.updated_at,
                chapter_index=event.chapter.index,
                source="legacy",
                editable=True,
            )
        )
    v2_facts = db.execute(
        select(ChapterArchiveFact, Chapter)
        .join(ChapterArchiveRevision, ChapterArchiveFact.revision_id == ChapterArchiveRevision.id)
        .join(Chapter, ChapterArchiveRevision.chapter_id == Chapter.id)
        .join(
            ChapterArchiveFactParticipant,
            ChapterArchiveFactParticipant.fact_id == ChapterArchiveFact.id,
        )
        .where(
            ChapterArchiveFactParticipant.character_id == character.id,
            ChapterArchiveRevision.is_active.is_(True),
            ChapterArchiveRevision.status == "complete",
            Chapter.active_archive_revision_id == ChapterArchiveRevision.id,
        )
        .order_by(Chapter.index, ChapterArchiveFact.position)
    ).all()
    for fact, chapter in v2_facts:
        data.events.append(
            CharacterEventRead(
                id=fact.id,
                book_id=chapter.book_id,
                character_id=character.id,
                chapter_id=chapter.id,
                event_type=fact.fact_type,
                event_text=truncate_to_nonspace(fact.fact_text, CHARACTER_EVENT_MAX_CHARS),
                created_at=fact.created_at,
                updated_at=fact.created_at,
                chapter_index=chapter.index,
                source="archive_v2",
                editable=False,
            )
        )
    data.events.sort(key=lambda item: (item.chapter_index or 0, item.created_at, item.id))
    return data


@router.get("/books/{book_id}/characters", response_model=list[CharacterRead])
def list_characters(book_id: str, db: Session = Depends(get_db)) -> list[CharacterRead]:
    rows = db.scalars(select(Character).where(Character.book_id == book_id).order_by(Character.created_at)).all()
    return [_character_read(db, row) for row in rows]


@router.post("/books/{book_id}/characters", response_model=CharacterRead, status_code=status.HTTP_201_CREATED)
def create_character(book_id: str, payload: CharacterCreate, db: Session = Depends(get_db)) -> CharacterRead:
    if db.get(Book, book_id) is None:
        raise HTTPException(status_code=404, detail="book not found")
    # Old installations still send this field when saving a fixed character
    # card.  It is a materialized Extractor projection and never client-owned.
    values = payload.model_dump(exclude={"dynamic_fields"})
    character = Character(book_id=book_id, **values)
    db.add(character)
    db.commit()
    db.refresh(character)
    return _character_read(db, character)


@router.post("/books/{book_id}/characters/import", response_model=list[CharacterRead])
def import_characters(book_id: str, payload: CharacterImportRequest, db: Session = Depends(get_db)) -> list[CharacterRead]:
    if db.get(Book, book_id) is None:
        raise HTTPException(status_code=404, detail="book not found")
    created: list[Character] = []
    for item in payload.items:
        character = Character(book_id=book_id, name=item.name, role=item.role, fixed_profile=item.fixed_profile)
        db.add(character)
        created.append(character)
    db.commit()
    for character in created:
        db.refresh(character)
    return [_character_read(db, character) for character in created]


@router.get("/characters/{character_id}", response_model=CharacterRead)
def get_character(character_id: str, db: Session = Depends(get_db)) -> CharacterRead:
    character = db.get(Character, character_id)
    if character is None:
        raise HTTPException(status_code=404, detail="character not found")
    return _character_read(db, character)


@router.patch("/characters/{character_id}", response_model=CharacterRead)
def patch_character(character_id: str, payload: CharacterPatch, db: Session = Depends(get_db)) -> CharacterRead:
    character = db.get(Character, character_id)
    if character is None:
        raise HTTPException(status_code=404, detail="character not found")
    old_name = character.name
    writer_input_changed = bool({"name", "role", "fixed_profile", "dynamic_fields"} & payload.model_fields_set)
    updates = payload.model_dump(exclude_unset=True, exclude={"dynamic_fields"})
    for key, value in updates.items():
        setattr(character, key, value)
    if character.name != old_name:
        db.flush()
        rebuild_book_projection(db, character.book_id)
    invalidated = invalidate_writer_inputs(db, chapters_for_character(db, character.id)) if writer_input_changed else []
    db.commit()
    cancel_local_writer_jobs(invalidated)
    db.refresh(character)
    return _character_read(db, character)


@router.delete("/characters/{character_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_character(character_id: str, db: Session = Depends(get_db)) -> Response:
    character = db.get(Character, character_id)
    if character is not None:
        book_id = character.book_id
        affected_chapters = sorted(
            (link.chapter for link in character.chapter_links), key=lambda chapter: chapter.index
        )
        invalidated = invalidate_writer_inputs(db, affected_chapters)
        for chapter in affected_chapters:
            invalidate_archive_if_input_changed(db, chapter, force=True)
        db.delete(character)
        db.flush()
        if affected_chapters:
            invalidate_downstream_archives(
                db, book_id, after_index=max(0, affected_chapters[0].index - 1)
            )
        rebuild_book_projection(db, book_id)
        db.commit()
        cancel_local_writer_jobs(invalidated)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.patch("/character-events/{event_id}", response_model=CharacterEventRead)
def patch_character_event(
    event_id: str, payload: CharacterEventPatch, db: Session = Depends(get_db)
) -> CharacterEventRead:
    event = db.get(CharacterEvent, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="character event not found")
    event.event_text = truncate_to_nonspace(payload.event_text, CHARACTER_EVENT_MAX_CHARS)
    db.commit()
    db.refresh(event)
    return _character_event_read(event)


@router.delete("/character-events/{event_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_character_event(event_id: str, db: Session = Depends(get_db)) -> Response:
    event = db.get(CharacterEvent, event_id)
    if event is not None:
        db.delete(event)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
