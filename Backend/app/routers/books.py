from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.models import Book, Chapter, Character
from app.models.entities import utc_now
from app.schemas.book import BookCreate, BookPatch, BookRead

router = APIRouter(tags=["books"])


def book_read(db: Session, book: Book) -> BookRead:
    chapter_count = db.scalar(select(func.count()).select_from(Chapter).where(Chapter.book_id == book.id)) or 0
    character_count = db.scalar(select(func.count()).select_from(Character).where(Character.book_id == book.id)) or 0
    data = BookRead.model_validate(book)
    data.chapter_count = chapter_count
    data.character_count = character_count
    return data


@router.get("/books", response_model=list[BookRead])
def list_books(db: Session = Depends(get_db)) -> list[BookRead]:
    books = db.scalars(select(Book).order_by(Book.last_opened_at.desc().nullslast(), Book.updated_at.desc())).all()
    return [book_read(db, book) for book in books]


@router.post("/books", response_model=BookRead, status_code=status.HTTP_201_CREATED)
def create_book(payload: BookCreate, db: Session = Depends(get_db)) -> BookRead:
    book = Book(title=payload.title, world_setting=payload.world_setting, last_opened_at=utc_now())
    db.add(book)
    db.commit()
    db.refresh(book)
    return book_read(db, book)


@router.get("/books/{book_id}", response_model=BookRead)
def get_book(book_id: str, db: Session = Depends(get_db)) -> BookRead:
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    book.last_opened_at = utc_now()
    db.commit()
    db.refresh(book)
    return book_read(db, book)


@router.patch("/books/{book_id}", response_model=BookRead)
def patch_book(book_id: str, payload: BookPatch, db: Session = Depends(get_db)) -> BookRead:
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(book, key, value)
    db.commit()
    db.refresh(book)
    return book_read(db, book)


@router.delete("/books/{book_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_book(book_id: str, db: Session = Depends(get_db)) -> Response:
    book = db.get(Book, book_id)
    if book is not None:
        db.delete(book)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/books/{book_id}/export.txt")
def export_book(book_id: str, db: Session = Depends(get_db)) -> Response:
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    chapters = db.scalars(
        select(Chapter).where(Chapter.book_id == book_id, Chapter.status == "finalized").order_by(Chapter.index)
    ).all()
    parts = [book.title, ""]
    for chapter in chapters:
        parts.extend([f"第 {chapter.index} 章 {chapter.title}".strip(), "", chapter.draft_text, ""])
    return Response("\n".join(parts), media_type="text/plain; charset=utf-8")
