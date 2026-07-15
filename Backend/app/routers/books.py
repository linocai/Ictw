from __future__ import annotations

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

import json

from app.db import get_db
from app.models import Book, Chapter, Character, CharacterEvent
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


def _dynamic_value_text(value: object) -> str:
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False)


@router.get("/books/{book_id}/memories/export.txt")
def export_memories(book_id: str, db: Session = Depends(get_db)) -> Response:
    """导出 Extractor 生成的全部记忆：大事记、章节梗概、人物动态字段与故事线。

    与 `export.txt`（正文导出）互补；这里不含任何章节正文，只含记忆产物，
    章节不限 finalized（summary/headline 可被用户手动编辑，编辑结果一并导出）。
    """
    book = db.get(Book, book_id)
    if book is None:
        from fastapi import HTTPException

        raise HTTPException(status_code=404, detail="book not found")
    chapters = db.scalars(select(Chapter).where(Chapter.book_id == book_id).order_by(Chapter.index)).all()
    characters = db.scalars(
        select(Character).where(Character.book_id == book_id).order_by(Character.created_at)
    ).all()
    chapter_order = {chapter.id: chapter.index for chapter in chapters}
    events = db.scalars(select(CharacterEvent).where(CharacterEvent.book_id == book_id)).all()
    events_by_character: dict[str, list[CharacterEvent]] = {}
    for event in events:
        events_by_character.setdefault(event.character_id, []).append(event)

    parts = [f"{book.title}——记忆导出", ""]

    parts.append("【大事记】")
    headline_lines = [
        f"第 {chapter.index} 章 {chapter.title}：{chapter.headline}".strip()
        for chapter in chapters
        if chapter.headline.strip()
    ]
    parts.extend(headline_lines or ["（暂无）"])
    parts.append("")

    parts.append("【章节梗概】")
    summary_blocks: list[str] = []
    for chapter in chapters:
        if chapter.summary.strip():
            summary_blocks.extend([f"第 {chapter.index} 章 {chapter.title}".strip(), chapter.summary, ""])
    if summary_blocks:
        parts.extend(summary_blocks)
    else:
        parts.extend(["（暂无）", ""])

    parts.append("【人物记忆】")
    if characters:
        for character in characters:
            header = f"{character.name}（{character.role}）" if character.role.strip() else character.name
            parts.append(header)
            if character.dynamic_fields:
                parts.append("动态字段：")
                for key in sorted(character.dynamic_fields):
                    parts.append(f"  {key}：{_dynamic_value_text(character.dynamic_fields[key])}")
            character_events = sorted(
                events_by_character.get(character.id, []),
                key=lambda event: (chapter_order.get(event.chapter_id, 0), event.created_at),
            )
            if character_events:
                parts.append("故事线：")
                for event in character_events:
                    index = chapter_order.get(event.chapter_id)
                    prefix = f"第 {index} 章" if index is not None else "（章节已删除）"
                    parts.append(f"  {prefix} [{event.event_type}] {event.event_text}")
            if not character.dynamic_fields and not character_events:
                parts.append("（暂无记忆）")
            parts.append("")
    else:
        parts.extend(["（暂无人物）", ""])

    return Response("\n".join(parts), media_type="text/plain; charset=utf-8")
