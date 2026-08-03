from __future__ import annotations

from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.models import Book, Chapter, Character, CharacterEvent, CharacterFieldPatch
from app.services.extraction import apply_extractor_output


class CharacterMemoryRebuildError(ValueError):
    pass


def rebuild_book_character_memory(
    db: Session, book: Book, outputs_by_chapter_id: dict[str, dict[str, Any]]
) -> dict[str, int]:
    """Atomically replace Extractor-owned character memory for one book.

    Accepted prose, Bible, headline and narrative summary are deliberately
    preserved.  The caller owns the transaction and must commit only after all
    chapters apply successfully.
    """
    chapters = list(
        db.scalars(
            select(Chapter)
            .where(Chapter.book_id == book.id, Chapter.status == "finalized")
            .order_by(Chapter.index)
        ).all()
    )
    expected_ids = {chapter.id for chapter in chapters}
    if set(outputs_by_chapter_id) != expected_ids:
        raise CharacterMemoryRebuildError("rebuild outputs do not cover every finalized chapter exactly once")

    db.execute(delete(CharacterEvent).where(CharacterEvent.book_id == book.id))
    db.execute(delete(CharacterFieldPatch).where(CharacterFieldPatch.book_id == book.id))
    characters = list(db.scalars(select(Character).where(Character.book_id == book.id)).all())
    for character in characters:
        character.dynamic_fields = {}
    db.flush()

    updated_characters: set[str] = set()
    event_count = 0
    for chapter in chapters:
        preserved = (chapter.headline, chapter.long_summary, chapter.status)
        updated_ids, event_ids = apply_extractor_output(db, chapter, outputs_by_chapter_id[chapter.id])
        chapter.headline, chapter.long_summary, chapter.status = preserved
        updated_characters.update(updated_ids)
        event_count += len(event_ids)
    db.flush()

    patch_count = db.scalar(
        select(func.count()).select_from(CharacterFieldPatch).where(CharacterFieldPatch.book_id == book.id)
    ) or 0
    return {
        "chapters": len(chapters),
        "characters": len(characters),
        "updated_characters": len(updated_characters),
        "events": event_count,
        "patches": int(patch_count),
    }
