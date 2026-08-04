from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

from sqlalchemy import delete, select

from app.agents.extractor import ExtractorAgent
from app.db import SessionLocal
from app.llm.factory import build_llm_client
from app.models import Book, Chapter, Character, CharacterStateChange, JobRun
from app.services.character_memory_rebuild import rebuild_book_character_memory
from app.services.character_state_projection import rebuild_book_projection
from app.services.context import draft_fingerprint, extractor_user_message
from app.services.extraction import (
    ExtractorValidationError,
    persist_validated_state_changes,
    salvage_state_rebuild_output,
    validate_state_rebuild_output,
)
from app.services.personas import get_persona


ACTIVE_PHASES = {"selecting_memory", "writing", "checking", "extracting"}
MAX_EXTRACTION_ATTEMPTS = 3
BUNDLE_VERSION = 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Rebuild one book's Extractor-owned character memory")
    parser.add_argument("--book-id", required=True)
    parser.add_argument("--expected-title", required=True)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--apply", action="store_true", help="extract and commit after every output validates")
    action.add_argument("--output-file", help="save a validated dry-run bundle with mode 0600")
    action.add_argument("--apply-file", help="commit an earlier validated bundle without calling the LLM again")
    return parser.parse_args()


def write_validated_bundle(
    path: str, book: Book, chapters: list[Chapter], outputs: dict[str, dict[str, Any]]
) -> None:
    target = Path(path).expanduser().resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": BUNDLE_VERSION,
        "book_id": book.id,
        "book_title": book.title,
        "chapters": [
            {
                "id": chapter.id,
                "index": chapter.index,
                "fingerprint": draft_fingerprint(chapter, chapter.draft_text),
                "output": outputs[chapter.id],
            }
            for chapter in chapters
        ],
    }
    temporary = target.with_name(f".{target.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
        os.chmod(target, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def load_validated_bundle(
    path: str, book: Book, chapters: list[Chapter]
) -> dict[str, dict[str, Any]]:
    source = Path(path).expanduser().resolve()
    if source.stat().st_mode & 0o077:
        raise RuntimeError("validated bundle permissions must not allow group or other access")
    payload = json.loads(source.read_text(encoding="utf-8"))
    if (
        not isinstance(payload, dict)
        or payload.get("version") != BUNDLE_VERSION
        or payload.get("book_id") != book.id
        or payload.get("book_title") != book.title
    ):
        raise RuntimeError("validated bundle identity check failed")
    raw_entries = payload.get("chapters")
    if not isinstance(raw_entries, list):
        raise RuntimeError("validated bundle chapters are invalid")
    entries = {
        entry.get("id"): entry
        for entry in raw_entries
        if isinstance(entry, dict) and isinstance(entry.get("id"), str)
    }
    if len(entries) != len(raw_entries) or set(entries) != {chapter.id for chapter in chapters}:
        raise RuntimeError("validated bundle does not cover finalized chapters exactly once")

    outputs: dict[str, dict[str, Any]] = {}
    for chapter in chapters:
        entry = entries[chapter.id]
        if entry.get("index") != chapter.index:
            raise RuntimeError("validated bundle chapter order changed")
        if entry.get("fingerprint") != draft_fingerprint(chapter, chapter.draft_text):
            raise RuntimeError(f"chapter {chapter.index} changed after bundle validation")
        output = entry.get("output")
        if not isinstance(output, dict):
            raise RuntimeError("validated bundle output is invalid")
        validated = validate_state_rebuild_output(chapter, output)
        outputs[chapter.id] = output
        print(
            f"loaded chapter={chapter.index} events={len(validated.events)} "
            f"state_changes={len(validated.state_changes)}"
        )
    return outputs


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

        if args.apply_file:
            outputs = load_validated_bundle(args.apply_file, book, chapters)
        else:
            # Build every chapter against the validated projection produced by
            # earlier chapters in this same dry-run.  These staging writes stay
            # inside the caller transaction and are always rolled back before a
            # bundle is returned or an apply begins.
            db.execute(delete(CharacterStateChange).where(CharacterStateChange.book_id == book.id))
            for character in db.scalars(select(Character).where(Character.book_id == book.id)).all():
                character.dynamic_fields = {}
            db.flush()
            extractor = ExtractorAgent(build_llm_client(db, "extractor"), get_persona(db, "extractor"))
            outputs = {}
            for chapter in chapters:
                selected = [(link.character_id, link.character.name) for link in chapter.character_links]
                message = extractor_user_message(db, book, chapter)
                for attempt in range(MAX_EXTRACTION_ATTEMPTS):
                    output = extractor.extract_state_updates(message, selected)
                    try:
                        validated = validate_state_rebuild_output(chapter, output)
                        break
                    except ExtractorValidationError as exc:
                        if attempt == MAX_EXTRACTION_ATTEMPTS - 1:
                            output, dropped = salvage_state_rebuild_output(chapter, output)
                            validated = validate_state_rebuild_output(chapter, output)
                            print(
                                f"salvaged chapter={chapter.index} dropped_components={dropped} "
                                f"state_changes={len(validated.state_changes)}"
                            )
                            break
                        message += (
                            f"\n\n# 第 {attempt + 1} 次格式纠偏\n上一次输出未通过确定性校验：{exc}。"
                            "只输出 state_updates，只保留能在正文中找到逐字证据的状态；找不到就删除该条，宁缺毋滥。"
                            "即时快照必须完整包含位置、行动、情绪三槽；持续状态与人物关系只能 set/clear。"
                            "同一无向人物对整份输出只能写一次，放在人物白名单顺序更靠前的一方，"
                            "另一侧不得重复，value 写双方共同关系状态。"
                            "每条 evidence 只能直接复制正文中包含所属人物姓名的完整原句或连续原文段落，"
                            "不得添加‘原文’标签、引号、解释，不得转述、概括或改写。"
                        )
                outputs[chapter.id] = output
                persist_validated_state_changes(db, chapter, validated)
                db.flush()
                rebuild_book_projection(db, book.id)
                print(
                    f"validated chapter={chapter.index} events={len(validated.events)} "
                    f"state_changes={len(validated.state_changes)}"
                )

        if args.output_file:
            write_validated_bundle(args.output_file, book, chapters, outputs)
            print(f"validated bundle saved chapters={len(chapters)}; database unchanged")
            db.rollback()
            return 0
        if not args.apply and not args.apply_file:
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
