"""Persistent Writer-input invalidation shared by chapter, book and character edits."""

from __future__ import annotations

from collections.abc import Iterable

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import Chapter, ChapterCharacter, JobRun
from app.models.entities import utc_now


def invalidate_writer_inputs(db: Session, chapters: Iterable[Chapter]) -> list[str]:
    """Advance only supplied chapters inside the caller's transaction.

    Database generation is authoritative across processes.  Local registry
    cancellation is deliberately split into a post-commit best-effort helper.
    """
    ids: list[str] = []
    for chapter in {chapter.id: chapter for chapter in chapters}.values():
        chapter.write_generation += 1
        if chapter.status == "writing":
            chapter.status = "draft_ready" if chapter.draft_text.strip() else "draft"
        db.execute(
            update(JobRun)
            .where(
                JobRun.chapter_id == chapter.id,
                JobRun.kind == "write",
                JobRun.phase.notin_(("done", "failed", "cancelled")),
            )
            .values(
                phase="cancelled",
                error_code="chapter_changed",
                error_message="写作输入已编辑，旧写作任务已取消",
                finished_at=utc_now(),
            )
        )
        ids.append(chapter.id)
    return ids


def chapters_for_book(db: Session, book_id: str) -> list[Chapter]:
    return list(db.scalars(select(Chapter).where(Chapter.book_id == book_id)).all())


def chapters_for_character(db: Session, character_id: str) -> list[Chapter]:
    return list(
        db.scalars(
            select(Chapter).join(ChapterCharacter).where(ChapterCharacter.character_id == character_id)
        ).all()
    )


def cancel_local_writer_jobs(chapter_ids: Iterable[str]) -> None:
    """Prompt local cancellation only after commit; never a correctness gate."""
    from app.services.write_jobs import write_registry

    for chapter_id in chapter_ids:
        job = write_registry.get_live(chapter_id)
        if job is not None and job.kind == "write":
            write_registry.cancel(job, discard=True)
