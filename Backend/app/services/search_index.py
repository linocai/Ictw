"""Safe, rebuildable search projection.

Only values that are already public through the author-facing API enter this
table.  In particular, Writer candidates, JobRun checker records and rejected
evidence never pass through this module.
"""

from __future__ import annotations

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import (
    Book, Chapter, ChapterArchiveFact, ChapterArchiveRevision,
    Character, CharacterEvent, SearchDocument,
)


def rebuild_book_search_index(db: Session, book_id: str) -> None:
    """Replace one book's projection inside the caller's transaction."""
    book = db.get(Book, book_id)
    db.execute(delete(SearchDocument).where(SearchDocument.book_id == book_id))
    if book is None:
        return

    db.add(SearchDocument(
        id=f"book:{book.id}", book_id=book.id, result_type="book",
        title=book.title, body=book.world_setting,
    ))
    chapters = db.scalars(select(Chapter).where(Chapter.book_id == book_id)).all()
    for chapter in chapters:
        db.add(SearchDocument(
            id=f"chapter:{chapter.id}", book_id=book_id, chapter_id=chapter.id,
            result_type="chapter", title=chapter.title,
            body="\n".join((chapter.user_prompt, chapter.author_note, chapter.draft_text)),
        ))
    characters = db.scalars(select(Character).where(Character.book_id == book_id)).all()
    for character in characters:
        db.add(SearchDocument(
            id=f"character:{character.id}", book_id=book_id, character_id=character.id,
            result_type="character", title=character.name,
            body="\n".join((character.role, character.fixed_profile)),
        ))
    active_chapter_ids = set(db.scalars(
        select(ChapterArchiveRevision.chapter_id)
        .join(Chapter, ChapterArchiveRevision.chapter_id == Chapter.id)
        .where(
            Chapter.book_id == book_id,
            ChapterArchiveRevision.is_active.is_(True),
            ChapterArchiveRevision.status == "complete",
            Chapter.active_archive_revision_id == ChapterArchiveRevision.id,
        )
    ).all())
    legacy_events = db.execute(
        select(CharacterEvent, Character.name)
        .join(Character, CharacterEvent.character_id == Character.id)
        .where(CharacterEvent.book_id == book_id)
    ).all()
    for event, character_name in legacy_events:
        if event.chapter_id in active_chapter_ids:
            continue
        db.add(SearchDocument(
            id=f"character-event:{event.id}", book_id=book_id,
            chapter_id=event.chapter_id, character_id=event.character_id,
            result_type="character", title=character_name or "人物记录",
            body=event.event_text,
        ))
    active_revisions = db.scalars(
        select(ChapterArchiveRevision)
        .join(Chapter, ChapterArchiveRevision.chapter_id == Chapter.id)
        .where(
            Chapter.book_id == book_id,
            ChapterArchiveRevision.is_active.is_(True),
            ChapterArchiveRevision.status == "complete",
            Chapter.active_archive_revision_id == ChapterArchiveRevision.id,
        )
    ).all()
    for archive in active_revisions:
        db.add(SearchDocument(
            id=f"archive-summary:{archive.id}", book_id=book_id, chapter_id=archive.chapter_id,
            result_type="archive", title="归档摘要", body=archive.summary,
        ))
        for fact in archive.facts:
            db.add(SearchDocument(
                id=f"archive-fact:{fact.id}", book_id=book_id, chapter_id=archive.chapter_id,
                result_type="archive", title=fact.fact_type, body=fact.fact_text,
            ))


def rebuild_all_search_indexes(db: Session) -> None:
    for book_id in db.scalars(select(Book.id)).all():
        rebuild_book_search_index(db, book_id)


def snippet_for_query(value: str, query: str, *, limit: int = 220) -> str:
    """Return a bounded, stable context without leaking the full source."""
    text = (value or "").strip()
    if len(text) <= limit:
        return text
    index = text.casefold().find(query.casefold())
    if index < 0:
        return text[:limit].rstrip() + "…"
    start = max(0, index - limit // 3)
    end = min(len(text), start + limit)
    prefix = "…" if start else ""
    suffix = "…" if end < len(text) else ""
    return prefix + text[start:end].strip() + suffix
