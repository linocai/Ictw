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
MAX_EXTRACTION_ATTEMPTS = 4


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
            for attempt in range(MAX_EXTRACTION_ATTEMPTS):
                output = extractor.extract(message, selected)
                try:
                    validated = validate_extractor_output(chapter, output)
                    break
                except ExtractorValidationError as exc:
                    if attempt == MAX_EXTRACTION_ATTEMPTS - 1:
                        raise
                    message += (
                        f"\n\n# 第 {attempt + 1} 次格式纠偏\n上一次输出未通过确定性校验：{exc}。"
                        "只保留能在正文中找到逐字证据的 event 和动态字段；找不到就删除该条，宁缺毋滥。"
                        "每条 evidence 只能直接复制正文中包含所属人物姓名的完整原句或连续原文段落，"
                        "不得添加‘原文’标签、引号、解释，不得转述、概括或改写。"
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
