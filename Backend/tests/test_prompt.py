from __future__ import annotations

from app.models import Book, Chapter, ChapterCharacter, Character, CharacterEvent
from app.services.context import (
    MEMORY_BUDGET_CHARS,
    PREVIOUS_ENDING_MAX_CHARS,
    MemoryBlock,
    memory_budget,
    memory_candidates,
    memory_selector_user_message,
    pack_selected_memories,
    pack_writer_context,
    writer_expansion_user_message,
    writer_user_message,
)
from app.services.personas import DEFAULT_PERSONAS


def test_default_memory_selector_persona_covers_ending_start_without_rewriting():
    prompt = DEFAULT_PERSONAS["memory_selector"]
    assert "结尾起点 ID" in prompt
    assert "最短原文片段" in prompt
    assert "不得重写" in prompt


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
        "# 历史参考资料",
        "# 作者对本章的备注",
        "# 本章剧情 Bible",
        "# 最终执行契约",
    ]
    positions = [text.index(header) for header in headers]
    assert positions == sorted(positions)
    assert "固定" in text and "清醒" in text
    assert "旧故事线" not in text
    assert text.count("# 世界观") == 1
    assert "Bible 是本次写作的最高情节权威" in text
    assert "不得据此增加 Bible 未要求的剧情" in text
    assert "达到最低字数前，不得提前进入本章结尾落点" in text


def test_writer_expansion_prompt_preserves_original_contract_without_duplicate_plot_rule():
    original = "# 本章剧情 Bible\n行动\n\n# 最终执行契约\n不得擅自增加剧情。"
    expanded = writer_expansion_user_message(
        original,
        "当前短稿",
        [{"code": "word_count", "message": "正文 4 字，不在目标区间 80～120 字"}],
    )
    assert expanded.count("不得擅自增加剧情") == 1
    assert "当前短稿" in expanded
    assert "不得只输出新增段落" in expanded
    assert "达到前述最低字数前不得收束结尾" in expanded


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


def test_previous_ending_uses_only_adjacent_finalized_chapter_and_preserves_source(client, auth_headers):
    from app.db import SessionLocal

    db = SessionLocal()
    try:
        book = Book(title="书")
        db.add(book)
        db.flush()
        old = Chapter(book_id=book.id, index=1, status="finalized", draft_text="更早章节结尾")
        adjacent = Chapter(
            book_id=book.id,
            index=2,
            status="finalized",
            draft_text="第一段原文\n第二段原文\n最后一段原文",
        )
        current = Chapter(book_id=book.id, index=3, user_prompt="承接开场")
        db.add_all([old, adjacent, current])
        db.commit()
        db.refresh(current)
        blocks = memory_candidates(db, current)
        selector_prompt = memory_selector_user_message(current, blocks, MEMORY_BUDGET_CHARS)
    finally:
        db.close()

    ending = [block for block in blocks if block.memory_type == "previous_ending"]
    assert [block.text for block in ending] == ["第一段原文", "第二段原文", "最后一段原文"]
    assert all(str(adjacent.id) in block.id for block in ending)
    assert all("更早章节结尾" not in block.text for block in ending)

    packed = pack_writer_context(blocks, [], ending[1].id, MEMORY_BUDGET_CHARS)
    assert packed.previous_ending == "第二段原文\n\n最后一段原文"
    assert "previous_ending_start_id" in selector_prompt
    assert "满足开场衔接所需的最短片段起点" in selector_prompt
    assert "[" + ending[0].id + "]\n第一段原文" in selector_prompt


def test_previous_ending_is_capped_and_invalid_start_falls_back_deterministically(client, auth_headers):
    from app.db import SessionLocal

    db = SessionLocal()
    try:
        book = Book(title="书")
        db.add(book)
        db.flush()
        previous = Chapter(
            book_id=book.id,
            index=1,
            status="finalized",
            draft_text="甲" * 500 + "\n" + "乙" * 500,
        )
        current = Chapter(book_id=book.id, index=2, user_prompt="继续")
        db.add_all([previous, current])
        db.commit()
        db.refresh(current)
        blocks = memory_candidates(db, current)
    finally:
        db.close()

    ending = [block for block in blocks if block.memory_type == "previous_ending"]
    assert sum(len(block.text) for block in ending) == PREVIOUS_ENDING_MAX_CHARS
    assert ending[0].text == "甲" * 200
    assert ending[1].text == "乙" * 500
    fallback = pack_writer_context(blocks, [], "invented-id", MEMORY_BUDGET_CHARS)
    assert fallback.previous_ending == "甲" * 200 + "\n\n" + "乙" * 500


def test_previous_ending_and_memories_share_single_budget():
    blocks = [
        MemoryBlock("previous_ending:x:p1", "甲" * 700, 1, memory_type="previous_ending"),
        MemoryBlock("fits", "乙" * 1100, 1),
        MemoryBlock("over", "丙", 1),
    ]
    packed = pack_writer_context(blocks, ["fits", "over"], None, MEMORY_BUDGET_CHARS)
    assert len(packed.previous_ending) == 700
    assert [block.id for block in packed.memories] == ["fits"]
