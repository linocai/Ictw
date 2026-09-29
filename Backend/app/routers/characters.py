from __future__ import annotations

from dataclasses import dataclass

from fastapi import APIRouter, Depends, Header, HTTPException, Response, status
from sqlalchemy import select
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
from app.services.character_state_projection import projected_book_state, rebuild_book_projection
from app.services.write_ownership import cancel_local_writer_jobs, chapters_for_character, invalidate_writer_inputs
from app.services.archive_v2 import (
    archive_health_summaries,
    invalidate_archive_if_input_changed,
    invalidate_downstream_archives,
)
from app.services.content_revisions import bump_content_revision, require_matching_revision
from app.services.search_index import rebuild_book_search_index

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
        content_revision=event.content_revision,
        chapter_index=event.chapter.index if event.chapter is not None else None,
    )


@dataclass(frozen=True)
class _CharacterMemoryRead:
    legacy_chapter_ids: set[str]
    active_revision_ids: set[str]
    fields: dict[str, dict[str, str]]
    updated_indexes: dict[str, int]


def _character_memory_read(db: Session, book_id: str) -> _CharacterMemoryRead:
    chapters = db.scalars(
        select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index, Chapter.id)
    ).all()
    health = archive_health_summaries(db, list(chapters))
    legacy_chapter_ids = {
        chapter.id for chapter in chapters if health[chapter.id]["archive_schema"] == "legacy"
    }
    active_revision_ids = {
        chapter.active_archive_revision_id
        for chapter in chapters if health[chapter.id]["archive_schema"] == "v2"
        and chapter.active_archive_revision_id is not None
    }
    fields, effective_rows = projected_book_state(db, book_id)
    chapter_indexes = {chapter.id: chapter.index for chapter in chapters}
    updated_indexes: dict[str, int] = {}
    for row in effective_rows:
        chapter_id = row.revision.chapter_id if isinstance(row, ChapterArchiveStateDelta) else row.chapter_id
        index = chapter_indexes[chapter_id]
        for character_id in (row.character_id, row.other_character_id):
            if character_id is not None:
                updated_indexes[character_id] = max(updated_indexes.get(character_id, 0), index)
    return _CharacterMemoryRead(legacy_chapter_ids, active_revision_ids, fields, updated_indexes)


def _character_read(
    db: Session, character: Character, *, memory: _CharacterMemoryRead | None = None,
) -> CharacterRead:
    if memory is None:
        memory = _character_memory_read(db, character.book_id)
    events = db.scalars(
        select(CharacterEvent)
        .join(Chapter, CharacterEvent.chapter_id == Chapter.id)
        .where(CharacterEvent.character_id == character.id)
        .order_by(Chapter.index)
    ).all()
    data = CharacterRead.model_validate(character)
    # Materialized flags can outlive a source whose fingerprint has changed.
    # Replay valid sources for reads as well as writes, without altering audit.
    data.dynamic_fields = memory.fields.get(character.id, {})
    data.dynamic_fields_updated_chapter_index = memory.updated_indexes.get(character.id)
    data.events = []
    # Live storylines use the same verified source per chapter as Selector.
    # Ineligible legacy rows remain available through the direct audit API.
    for event in events:
        if event.chapter_id not in memory.legacy_chapter_ids:
            continue
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
                content_revision=event.content_revision,
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
            ChapterArchiveRevision.id.in_(memory.active_revision_ids),
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
    memory = _character_memory_read(db, book_id) if rows else None
    return [_character_read(db, row, memory=memory) for row in rows]


@router.post("/books/{book_id}/characters", response_model=CharacterRead, status_code=status.HTTP_201_CREATED)
def create_character(book_id: str, payload: CharacterCreate, db: Session = Depends(get_db)) -> CharacterRead:
    if db.get(Book, book_id) is None:
        raise HTTPException(status_code=404, detail="book not found")
    # Old installations still send this field when saving a fixed character
    # card.  It is a materialized Extractor projection and never client-owned.
    values = payload.model_dump(exclude={"dynamic_fields"})
    character = Character(book_id=book_id, **values)
    db.add(character)
    db.flush()
    rebuild_book_search_index(db, book_id)
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
    db.flush()
    rebuild_book_search_index(db, book_id)
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
def patch_character(
    character_id: str,
    payload: CharacterPatch,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> CharacterRead:
    character = db.get(Character, character_id)
    if character is None:
        raise HTTPException(status_code=404, detail="character not found")
    require_matching_revision(character, if_match, resource_type="character", resource_id=character.id, db=db)
    old_name = character.name
    writer_input_changed = bool({"name", "role", "fixed_profile", "dynamic_fields"} & payload.model_fields_set)
    updates = payload.model_dump(exclude_unset=True, exclude={"dynamic_fields"})
    for key, value in updates.items():
        setattr(character, key, value)
    if character.name != old_name:
        db.flush()
        rebuild_book_projection(db, character.book_id)
    invalidated_writer_jobs = invalidate_writer_inputs(db, chapters_for_character(db, character.id)) if writer_input_changed else []
    if payload.model_fields_set:
        bump_content_revision(character)
        rebuild_book_search_index(db, character.book_id)
    db.commit()
    cancel_local_writer_jobs(invalidated_writer_jobs)
    db.refresh(character)
    return _character_read(db, character)


@router.delete("/characters/{character_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_character(
    character_id: str,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Response:
    character = db.get(Character, character_id)
    if character is not None:
        require_matching_revision(character, if_match, resource_type="character", resource_id=character.id, db=db)
        book_id = character.book_id
        affected_chapters = sorted(
            (link.chapter for link in character.chapter_links), key=lambda chapter: chapter.index
        )
        invalidated_writer_jobs = invalidate_writer_inputs(db, affected_chapters)
        for chapter in affected_chapters:
            invalidate_archive_if_input_changed(db, chapter, force=True)
            bump_content_revision(chapter)
        db.delete(character)
        db.flush()
        if affected_chapters:
            downstream_ids = invalidate_downstream_archives(
                db, book_id, after_index=max(0, affected_chapters[0].index - 1)
            )
            for downstream_id in downstream_ids:
                downstream = db.get(Chapter, downstream_id)
                if downstream is not None:
                    bump_content_revision(downstream)
        rebuild_book_projection(db, book_id)
        rebuild_book_search_index(db, book_id)
        db.commit()
        cancel_local_writer_jobs(invalidated_writer_jobs)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.patch("/character-events/{event_id}", response_model=CharacterEventRead)
def patch_character_event(
    event_id: str, payload: CharacterEventPatch, db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> CharacterEventRead:
    event = db.get(CharacterEvent, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="character event not found")
    require_matching_revision(event, if_match, resource_type="character_event", resource_id=event.id, db=db)
    event.event_text = truncate_to_nonspace(payload.event_text, CHARACTER_EVENT_MAX_CHARS)
    bump_content_revision(event)
    db.flush()
    rebuild_book_search_index(db, event.book_id)
    db.commit()
    db.refresh(event)
    return _character_event_read(event)


@router.get("/character-events/{event_id}", response_model=CharacterEventRead)
def get_character_event(event_id: str, db: Session = Depends(get_db)) -> CharacterEventRead:
    event = db.get(CharacterEvent, event_id)
    if event is None:
        raise HTTPException(status_code=404, detail="character event not found")
    return _character_event_read(event)


@router.delete("/character-events/{event_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_character_event(
    event_id: str,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Response:
    event = db.get(CharacterEvent, event_id)
    if event is not None:
        require_matching_revision(event, if_match, resource_type="character_event", resource_id=event.id, db=db)
        book_id = event.book_id
        db.delete(event)
        db.flush()
        rebuild_book_search_index(db, book_id)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
