from __future__ import annotations

import argparse

from sqlalchemy import select

from app.agents.extractor import ExtractorAgent
from app.db import SessionLocal
from app.llm.factory import build_llm_client
from app.models import Book, Chapter, JobRun
from app.services.character_memory_rebuild import rebuild_book_character_memory
from app.services.context import extractor_user_message
from app.services.extraction import ExtractorValidationError, validate_extractor_output
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
            message = extractor_user_message(db, book, chapter)
            for attempt in range(2):
                output = extractor.extract(message, selected)
                try:
                    validated = validate_extractor_output(chapter, output)
                    break
                except ExtractorValidationError:
                    if attempt:
                        raise
                    message += (
                        "\n\n# 格式纠偏\n上一次输出未通过确定性归属或证据校验。"
                        "本次每条 evidence 必须包含所属人物精确姓名，并复制正文中至少 16 个连续原文字符；"
                        "不得转述、概括或改写 evidence。"
                    )
            outputs[chapter.id] = output
            print(
                f"validated chapter={chapter.index} events={len(validated.events)} "
                f"patches={len(validated.patches_by_character)}"
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
