from __future__ import annotations

from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.models import Book, Chapter, Character, CharacterEvent, CharacterFieldPatch, CharacterStateChange
from app.services.character_state_projection import rebuild_book_projection
from app.services.extraction import persist_validated_state_changes, validate_state_rebuild_output


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

    # Existing Extractor events and chapter archive are user-visible history;
    # v1.7.2 rebuilds only the new current-state source and materialization.
    db.execute(delete(CharacterFieldPatch).where(CharacterFieldPatch.book_id == book.id))
    db.execute(delete(CharacterStateChange).where(CharacterStateChange.book_id == book.id))
    characters = list(db.scalars(select(Character).where(Character.book_id == book.id)).all())
    for character in characters:
        character.dynamic_fields = {}
    db.flush()

    updated_characters: set[str] = set()
    change_count = 0
    for chapter in chapters:
        validated = validate_state_rebuild_output(chapter, outputs_by_chapter_id[chapter.id])
        persist_validated_state_changes(db, chapter, validated)
        updated_characters.update({item.character_id for item in validated.state_changes})
        change_count += len(validated.state_changes)
    db.flush()
    projection = rebuild_book_projection(db, book.id)

    patch_count = db.scalar(
        select(func.count()).select_from(CharacterFieldPatch).where(CharacterFieldPatch.book_id == book.id)
    ) or 0
    return {
        "chapters": len(chapters),
        "characters": len(characters),
        "updated_characters": len(updated_characters),
        "events": int(db.scalar(select(func.count()).select_from(CharacterEvent).where(CharacterEvent.book_id == book.id)) or 0),
        "patches": int(patch_count),
        "state_changes": change_count,
        "effective_states": projection["effective"],
    }
