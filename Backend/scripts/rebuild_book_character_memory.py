from __future__ import annotations

import argparse

from sqlalchemy import select

from app.agents.extractor import ExtractorAgent
from app.db import SessionLocal
from app.llm.factory import build_llm_client
from app.models import Book, Chapter, JobRun
from app.services.character_memory_rebuild import rebuild_book_character_memory
from app.services.context import extractor_user_message
from app.services.personas import get_persona


ACTIVE_PHASES = {"selecting_memory", "writing", "checking", "extracting"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Rebuild one book's Extractor-owned character memory")
    parser.add_argument("--book-id", required=True)
    parser.add_argument("--expected-title", required=True)
    parser.add_argument("--apply", action="store_true", help="commit the rebuild after every output validates")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    db = SessionLocal()
    try:
        book = db.get(Book, args.book_id)
        if book is None or book.title != args.expected_title:
            raise RuntimeError("book identity check failed")
        active = list(db.scalars(select(JobRun).where(JobRun.phase.in_(ACTIVE_PHASES))).all())
        if active:
            raise RuntimeError("active write jobs exist; stop before rebuilding")
        chapters = list(
            db.scalars(
                select(Chapter)
                .where(Chapter.book_id == book.id, Chapter.status == "finalized")
                .order_by(Chapter.index)
            ).all()
        )
        if not chapters:
            raise RuntimeError("book has no finalized chapters")

        extractor = ExtractorAgent(build_llm_client(db, "extractor"), get_persona(db, "extractor"))
        outputs: dict[str, dict] = {}
        for chapter in chapters:
            selected = [(link.character_id, link.character.name) for link in chapter.character_links]
            output = extractor.extract(extractor_user_message(db, book, chapter), selected)
            outputs[chapter.id] = output
            print(
                f"validated chapter={chapter.index} events={len(output['character_events'])} "
                f"patches={len(output['dynamic_fields_patch'])}"
            )

        if not args.apply:
            print(f"dry-run complete chapters={len(chapters)}; database unchanged")
            db.rollback()
            return 0

        db.rollback()
        book = db.get(Book, args.book_id)
        if book is None or book.title != args.expected_title:
            raise RuntimeError("book identity changed before apply")
        stats = rebuild_book_character_memory(db, book, outputs)
        db.commit()
        print("rebuild committed " + " ".join(f"{key}={value}" for key, value in stats.items()))
        return 0
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


if __name__ == "__main__":
    raise SystemExit(main())
