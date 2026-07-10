from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Book, Character, CharacterEvent, Chapter
from app.schemas.character import CharacterCreate, CharacterEventRead, CharacterImportRequest, CharacterRead, CharacterPatch

router = APIRouter(tags=["characters"])


def _character_read(db: Session, character: Character) -> CharacterRead:
    events = db.scalars(
        select(CharacterEvent)
        .join(Chapter, CharacterEvent.chapter_id == Chapter.id)
        .where(CharacterEvent.character_id == character.id)
        .order_by(Chapter.index)
    ).all()
    data = CharacterRead.model_validate(character)
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
            )
        )
    return data


@router.get("/books/{book_id}/characters", response_model=list[CharacterRead])
def list_characters(book_id: str, db: Session = Depends(get_db)) -> list[CharacterRead]:
    rows = db.scalars(select(Character).where(Character.book_id == book_id).order_by(Character.created_at)).all()
    return [_character_read(db, row) for row in rows]


@router.post("/books/{book_id}/characters", response_model=CharacterRead, status_code=status.HTTP_201_CREATED)
def create_character(book_id: str, payload: CharacterCreate, db: Session = Depends(get_db)) -> CharacterRead:
    if db.get(Book, book_id) is None:
        raise HTTPException(status_code=404, detail="book not found")
    character = Character(book_id=book_id, **payload.model_dump())
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
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(character, key, value)
    db.commit()
    db.refresh(character)
    return _character_read(db, character)


@router.delete("/characters/{character_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_character(character_id: str, db: Session = Depends(get_db)) -> Response:
    character = db.get(Character, character_id)
    if character is not None:
        db.delete(character)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
