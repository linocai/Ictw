from __future__ import annotations

from app.models import Book, Chapter, ChapterCharacter, Character, CharacterEvent
from app.services.context import (
    MEMORY_BUDGET_CHARS,
    MemoryBlock,
    memory_budget,
    memory_candidates,
    pack_selected_memories,
    writer_user_message,
)


def test_writer_prompt_order_and_character_card_excludes_storyline(client, auth_headers):
    from app.db import SessionLocal

    db = SessionLocal()
    try:
        book = Book(title="书", world_setting="世界观")
        db.add(book)
        db.flush()
        character = Character(
            book_id=book.id,
            name="林夕",
            role="主角",
            fixed_profile="固定",
            dynamic_fields={"状态": "清醒"},
        )
        db.add(character)
        db.flush()
        previous = Chapter(
            book_id=book.id,
            index=1,
            title="前章",
            summary="上一章梗概",
            headline="上一章大事",
            status="finalized",
        )
        chapter = Chapter(
            book_id=book.id,
            index=2,
            title="本章",
            user_prompt="本章剧情",
            target_word_count=3000,
            author_note="冷静",
        )
        db.add_all([previous, chapter])
        db.flush()
        chapter.character_links.append(ChapterCharacter(character_id=character.id))
        db.add(
            CharacterEvent(
                book_id=book.id,
                chapter_id=previous.id,
                character_id=character.id,
                event_text="旧故事线",
            )
        )
        db.commit()
        db.refresh(chapter)
        text = writer_user_message(db.get(Book, book.id), chapter, [MemoryBlock("x", "只读记忆", 1)])
    finally:
        db.close()

    headers = [
        "# 世界观",
        "# 本章允许人物白名单",
        "# 人物卡",
        "# 只读工作记忆",
        "# 作者对本章的备注",
        "# 本章剧情 Bible",
        "# 字数和交稿契约",
    ]
    positions = [text.index(header) for header in headers]
    assert positions == sorted(positions)
    assert "固定" in text and "清醒" in text
    assert "旧故事线" not in text


def test_memory_candidates_scope_and_budget_packing(client, auth_headers):
    from app.db import SessionLocal

    db = SessionLocal()
    try:
        first_book = Book(title="甲")
        second_book = Book(title="乙")
        db.add_all([first_book, second_book])
        db.flush()
        finalized = Chapter(
            book_id=first_book.id,
            index=1,
            headline="可用大事",
            summary="可用梗概",
            status="finalized",
        )
        unfinished = Chapter(book_id=first_book.id, index=2, headline="未完成", status="draft")
        current = Chapter(book_id=first_book.id, index=3, user_prompt="行动")
        foreign = Chapter(book_id=second_book.id, index=1, headline="跨书", status="finalized")
        db.add_all([finalized, unfinished, current, foreign])
        db.commit()
        db.refresh(current)
        candidates = memory_candidates(db, current)
    finally:
        db.close()
    assert len(candidates) == 2
    assert all("可用" in block.text for block in candidates)
    assert memory_budget("短") == MEMORY_BUDGET_CHARS
    blocks = [MemoryBlock("too-big", "甲" * 700, 1), MemoryBlock("fits", "乙" * 500, 1)]
    packed = pack_selected_memories(blocks, ["too-big", "fits"], 600)
    assert [item.id for item in packed] == ["fits"]
