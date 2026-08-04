"""Atomically apply previously validated v2 state bundles for multiple books.

The manifest and bundles contain accepted prose-derived LLM output, so they
must stay outside Git and be mode 0600.  This command never calls an LLM and
prints metadata/counts only.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from sqlalchemy import func, select

from app.db import SessionLocal
from app.models import Book, CharacterEvent, JobRun
from app.services.character_memory_rebuild import rebuild_book_character_memory
from rebuild_book_character_memory import ACTIVE_PHASES, load_validated_bundle


def _secure_json(path: str) -> dict:
    source = Path(path).expanduser().resolve()
    if source.stat().st_mode & 0o077:
        raise RuntimeError("manifest permissions must not allow group or other access")
    value = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("manifest must be a JSON object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description="Atomically apply verified v2 character-state rebuild bundles")
    parser.add_argument("--manifest", required=True, help="0600 JSON: {books:[{book_id, expected_title, bundle_file}]}")
    args = parser.parse_args()
    manifest = _secure_json(args.manifest)
    entries = manifest.get("books")
    if not isinstance(entries, list) or not entries:
        raise RuntimeError("manifest books must be a non-empty list")
    db = SessionLocal()
    try:
        if db.scalars(select(JobRun).where(JobRun.phase.in_(ACTIVE_PHASES))).first() is not None:
            raise RuntimeError("active write jobs exist; stop before rebuilding")
        prepared: list[tuple[Book, dict]] = []
        for entry in entries:
            if not isinstance(entry, dict):
                raise RuntimeError("manifest book entry is invalid")
            book_id, title, bundle = entry.get("book_id"), entry.get("expected_title"), entry.get("bundle_file")
            if not all(isinstance(value, str) and value for value in (book_id, title, bundle)):
                raise RuntimeError("manifest book entry requires book_id, expected_title and bundle_file")
            book = db.get(Book, book_id)
            if book is None or book.title != title:
                raise RuntimeError("book identity check failed")
            chapters = list(book.chapters)
            finalized = sorted((chapter for chapter in chapters if chapter.status == "finalized"), key=lambda chapter: chapter.index)
            if not finalized:
                raise RuntimeError("book has no finalized chapters")
            prepared.append((book, load_validated_bundle(bundle, book, finalized)))
        # No mutation happens before every book/bundle has passed identity,
        # fingerprint and deterministic state validation.
        summaries: list[dict[str, int | str]] = []
        for book, outputs in prepared:
            before_events = int(db.scalar(select(func.count()).select_from(CharacterEvent).where(CharacterEvent.book_id == book.id)) or 0)
            stats = rebuild_book_character_memory(db, book, outputs)
            after_events = int(db.scalar(select(func.count()).select_from(CharacterEvent).where(CharacterEvent.book_id == book.id)) or 0)
            if before_events != after_events:
                raise RuntimeError("character event count changed during state-only rebuild")
            summaries.append({"book_id": book.id, "chapters": stats["chapters"], "state_changes": stats["state_changes"], "effective_states": stats["effective_states"], "events": after_events})
        db.commit()
        for summary in summaries:
            print("applied " + " ".join(f"{key}={value}" for key, value in summary.items()))
        return 0
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())
