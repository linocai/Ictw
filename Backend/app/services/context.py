from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Iterable

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Book, Chapter, Character, CharacterEvent


# --- Centralized tunable constants (see PROJECT_PLAN v1.1.0) ---
WORD_COUNT_MIN_RATIO = 0.80
WORD_COUNT_MAX_RATIO = 1.20
MEMORY_BUDGET_CHARS = 1800
MEMORY_SUMMARY_MAX_ITEMS = 2
CHARACTER_EVENT_MAX_CHARS = 60


def word_count_bounds(target: int) -> tuple[int, int]:
    return int(target * WORD_COUNT_MIN_RATIO), int(target * WORD_COUNT_MAX_RATIO)


def nonspace_len(text: str) -> int:
    return sum(1 for ch in text if not ch.isspace())


def truncate_to_nonspace(text: str, n: int) -> str:
    """Hard-truncate so the result contains at most ``n`` non-space characters."""
    if n <= 0:
        return ""
    count = 0
    end = 0
    for index, ch in enumerate(text):
        if not ch.isspace():
            count += 1
            if count > n:
                break
            end = index + 1
    else:
        return text
    return text[:end]


def chapter_author_note(chapter: Chapter) -> str:
    return str(getattr(chapter, "author_note", getattr(chapter, "chapter_style", "")) or "")


@dataclass(frozen=True)
class MemoryBlock:
    id: str
    text: str
    chapter_index: int
    character_id: str | None = None
    memory_type: str = ""


def memory_budget(bible: str = "") -> int:
    # Fixed budget, decoupled from Bible length. Argument is ignored but the
    # signature is kept for callers that still pass a Bible string.
    return MEMORY_BUDGET_CHARS


def memory_candidates(db: Session, chapter: Chapter) -> list[MemoryBlock]:
    prior = list(
        db.scalars(
            select(Chapter)
            .where(
                Chapter.book_id == chapter.book_id,
                Chapter.index < chapter.index,
                Chapter.status == "finalized",
            )
            .order_by(Chapter.index, Chapter.id)
        ).all()
    )
    blocks: list[MemoryBlock] = []
    for item in prior:
        if item.headline.strip():
            blocks.append(
                MemoryBlock(
                    id=f"chapter:{item.id}:headline",
                    text=f"第 {item.index} 章大事记：{item.headline.strip()}",
                    chapter_index=item.index,
                    memory_type="headline",
                )
            )
        if item.summary.strip():
            blocks.append(
                MemoryBlock(
                    id=f"chapter:{item.id}:summary",
                    text=f"第 {item.index} 章梗概：{item.summary.strip()}",
                    chapter_index=item.index,
                    memory_type="summary",
                )
            )
    if prior:
        prior_ids = [item.id for item in prior]
        events = db.scalars(
            select(CharacterEvent)
            .where(CharacterEvent.book_id == chapter.book_id, CharacterEvent.chapter_id.in_(prior_ids))
            .join(Chapter, CharacterEvent.chapter_id == Chapter.id)
            .order_by(Chapter.index, CharacterEvent.id)
        ).all()
        index_by_id = {item.id: item.index for item in prior}
        for event in events:
            if not event.event_text.strip():
                continue
            character_name = event.character.name if event.character is not None else event.character_id
            blocks.append(
                MemoryBlock(
                    id=f"character_event:{event.id}",
                    text=(
                        f"第 {index_by_id[event.chapter_id]} 章人物故事线（{character_name}）："
                        f"{event.event_text.strip()}"
                    ),
                    chapter_index=index_by_id[event.chapter_id],
                    character_id=event.character_id,
                    memory_type="character_event",
                )
            )
    return blocks


def prefilter_memory_candidates(
    blocks: list[MemoryBlock],
    *,
    chapter: Chapter,
    selected_character_ids: set[str],
) -> list[MemoryBlock]:
    if len(blocks) <= 300 and sum(nonspace_len(block.text) for block in blocks) <= 30_000:
        return blocks
    query = normalize_text(f"{chapter.title}\n{chapter.user_prompt}\n{chapter_author_note(chapter)}")
    keywords = _keywords(query)

    def score(block: MemoryBlock) -> tuple[int, int, int, str]:
        text = normalize_text(block.text)
        selected = int(block.character_id in selected_character_ids)
        overlap = sum(1 for word in keywords if word and word in text)
        return (-selected, -overlap, -block.chapter_index, block.id)

    ranked = sorted(blocks, key=score)
    chosen: list[MemoryBlock] = []
    chars = 0
    for block in ranked:
        size = nonspace_len(block.text)
        if len(chosen) >= 300:
            break
        if chars + size > 30_000:
            continue
        chosen.append(block)
        chars += size
    return chosen


def memory_selector_user_message(chapter: Chapter, blocks: list[MemoryBlock], budget: int) -> str:
    selected = _selected_characters(chapter)
    cards = _character_cards(selected, include_ids=True)
    candidates = "\n\n".join(f"[{block.id}]\n{block.text}" for block in blocks) or "（没有可用历史记忆）"
    return "\n\n".join(
        [
            "# 本章剧情 Bible\n" + chapter.user_prompt.strip(),
            "# 作者对本章的备注\n" + (chapter_author_note(chapter).strip() or "（无）"),
            "# 本章允许人物及当前状态\n" + (cards or "（无已选人物）"),
            f"# 记忆预算\n最多 {budget} 个中文去空白字符。章节梗概最多选 {MEMORY_SUMMARY_MAX_ITEMS} 条。"
            "你只负责选择，不得改写历史。",
            "# 候选记忆块\n" + candidates,
            '# 输出\n只返回 JSON object：{"memory_ids":["按重要性排序的候选ID"]}。允许空数组。',
        ]
    )


def pack_selected_memories(blocks: list[MemoryBlock], selected_ids: Iterable[str], budget: int) -> list[MemoryBlock]:
    by_id = {block.id: block for block in blocks}
    result: list[MemoryBlock] = []
    used = 0
    summary_count = 0
    seen: set[str] = set()
    for memory_id in selected_ids:
        if not isinstance(memory_id, str) or memory_id not in by_id:
            raise ValueError(f"memory selector returned invalid id: {memory_id}")
        if memory_id in seen:
            continue
        seen.add(memory_id)
        block = by_id[memory_id]
        if not block.text.strip():
            raise ValueError(f"memory selector selected an empty block: {memory_id}")
        # Hard cap on chapter-summary blocks; headline/character_event unbounded.
        if block.memory_type == "summary" and summary_count >= MEMORY_SUMMARY_MAX_ITEMS:
            continue
        size = nonspace_len(block.text)
        if used + size > budget:
            continue
        result.append(block)
        used += size
        if block.memory_type == "summary":
            summary_count += 1
    return result


def writer_user_message(book: Book, chapter: Chapter, memories: list[MemoryBlock] | None = None) -> str:
    characters = _selected_characters(chapter)
    allow = "、".join(character.name for character in characters) or "（没有已知人物卡；Bible 明写的临时角色仍可出现）"
    memory_text = "\n\n".join(block.text for block in (memories or [])) or "（本章不需要历史记忆）"
    low_bound, high_bound = word_count_bounds(chapter.target_word_count)
    return "\n\n".join(
        [
            "# 世界观（硬约束）\n" + (book.world_setting.strip() or "（无）"),
            (
                "# 本章允许人物白名单\n"
                f"{allow}\n"
                "白名单表示允许出现或被提及，不要求全部使用。历史记忆中出现的人物不会因此获得本章出场权限。"
            ),
            "# 人物卡（固定设定与当前动态状态）\n" + (_character_cards(characters) or "（无）"),
            "# 只读工作记忆\n" + memory_text,
            "# 作者对本章的备注\n" + (chapter_author_note(chapter).strip() or "（无）"),
            f"# 本章剧情 Bible（情节最高权威）\n标题：{chapter.title}\n\n{chapter.user_prompt.strip()}",
            (
                "# 字数和交稿契约\n"
                f"目标 {chapter.target_word_count} 字，最终正文必须在 "
                f"{low_bound}～{high_bound} 个去空白字符内。"
                "只输出正文，不得解释、列提纲或擅自增加剧情、人物。"
            ),
        ]
    )


def reviser_user_message(
    chapter: Chapter,
    current_text: str,
    violations: list[dict[str, Any]],
) -> str:
    characters = _selected_characters(chapter)
    low_bound, high_bound = word_count_bounds(chapter.target_word_count)
    return "\n\n".join(
        [
            "# 本章剧情 Bible\n" + chapter.user_prompt.strip(),
            "# 作者对本章的备注\n" + (chapter_author_note(chapter).strip() or "（无）"),
            "# 允许人物\n" + ("、".join(c.name for c in characters) or "（无已知人物）"),
            (
                "# 目标区间\n"
                f"{low_bound}～{high_bound} 个去空白字符"
            ),
            "# 程序校验违规报告\n" + "\n".join(f"- {item['message']}" for item in violations),
            "# 当前正文\n" + current_text,
            "# 修订契约\n只修复报告中的问题；保持 Bible 的情节、顺序和结尾落点。只输出完整修订正文。",
        ]
    )


def extractor_user_message(db: Session, book: Book, chapter: Chapter) -> str:
    characters = _selected_characters(chapter)
    return "\n\n".join(
        [
            f"# 世界观\n{book.world_setting}",
            f"# 本章剧情 Bible\n{chapter.user_prompt}",
            "# 本章已选人物必要信息\n" + (_character_cards(characters, include_ids=True) or "（无已选人物）"),
            (
                "# 提取输出约束\nsummary/headline 必填。人物更新只能使用上面列出的角色ID；"
                "未选择人物时两个人物更新数组必须为空。"
                f"每条 event_text 不超过 {CHARACTER_EVENT_MAX_CHARS} 个去空白字符。"
            ),
            f"# 最终正文\n{chapter.draft_text}",
        ]
    )


def normalize_text(value: str) -> str:
    return unicodedata.normalize("NFKC", value or "")


def scan_known_character_names(
    text: str,
    characters: Iterable[Character],
) -> tuple[list[Character], list[str]]:
    """Return longest matches and ambiguous normalized names in text."""
    normalized = normalize_text(text)
    by_name: dict[str, list[Character]] = {}
    for character in characters:
        name = normalize_text(character.name).strip()
        if name:
            by_name.setdefault(name, []).append(character)
    names = sorted(by_name, key=lambda item: (-len(item), item))
    matches: list[Character] = []
    ambiguous: list[str] = []
    pos = 0
    while pos < len(normalized):
        candidates = [name for name in names if normalized.startswith(name, pos)]
        if not candidates:
            pos += 1
            continue
        longest = candidates[0]
        # Single-character names use a left-boundary heuristic: they only count
        # when the preceding character starts the string or is not a CJK
        # ideograph (whitespace/punctuation/latin/quotes). This stops "森林"
        # matching "林". Names of length >= 2 keep substring matching.
        if len(longest) == 1:
            prev = normalized[pos - 1] if pos > 0 else ""
            if prev and ("一" <= prev <= "鿿"):
                pos += 1
                continue
        owners = by_name[longest]
        if len(owners) > 1:
            if longest not in ambiguous:
                ambiguous.append(longest)
        else:
            matches.append(owners[0])
        pos += len(longest)
    return matches, ambiguous


def validate_character_preflight(db: Session, chapter: Chapter) -> None:
    if not chapter.user_prompt.strip():
        raise CharacterPreflightError("bible_empty", "本章剧情 Bible 不能为空")
    known = list(db.scalars(select(Character).where(Character.book_id == chapter.book_id).order_by(Character.id)).all())
    matched, ambiguous = scan_known_character_names(
        f"{chapter.user_prompt}\n{chapter_author_note(chapter)}", known
    )
    if ambiguous:
        raise CharacterPreflightError(
            "ambiguous_character_name",
            "同书存在无法区分的重名人物",
            {"names": ambiguous},
        )
    selected = {link.character_id for link in chapter.character_links}
    exempted = set(chapter.exempted_character_names or [])
    unselected = sorted({item.name for item in matched if item.id not in selected} - exempted)
    if unselected:
        raise CharacterPreflightError(
            "unselected_characters_in_bible",
            "本章剧情 Bible 或作者备注出现了未选择人物",
            {"names": unselected},
        )


class CharacterPreflightError(ValueError):
    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None) -> None:
        self.code = code
        self.message = message
        self.details = details or {}
        super().__init__(message)


def draft_violations(db: Session, chapter: Chapter, text: str, finish_reason: str | None) -> list[dict[str, Any]]:
    violations: list[dict[str, Any]] = []
    chars = nonspace_len(text)
    low, high = word_count_bounds(chapter.target_word_count)
    if not text.strip():
        violations.append({"code": "empty_body", "message": "正文为空"})
    if finish_reason in {"length", "max_tokens", "MAX_TOKENS"}:
        violations.append({"code": "length_truncated", "message": f"上游因长度截断（{finish_reason}）"})
    if chars < low or chars > high:
        violations.append(
            {"code": "word_count", "message": f"正文 {chars} 字，不在目标区间 {low}～{high} 字", "current_chars": chars}
        )
    known = list(db.scalars(select(Character).where(Character.book_id == chapter.book_id).order_by(Character.id)).all())
    matched, ambiguous = scan_known_character_names(text, known)
    selected = {link.character_id for link in chapter.character_links}
    exempted = set(chapter.exempted_character_names or [])
    unselected = sorted({item.name for item in matched if item.id not in selected} - exempted)
    if ambiguous:
        violations.append({"code": "ambiguous_character", "message": f"正文含重名人物：{'、'.join(ambiguous)}"})
    if unselected:
        violations.append(
            {"code": "unselected_character", "message": f"正文含未获准人物：{'、'.join(unselected)}", "names": unselected}
        )
    return violations


def _selected_characters(chapter: Chapter) -> list[Character]:
    return [link.character for link in chapter.character_links]


def _character_cards(characters: Iterable[Character], include_ids: bool = False) -> str:
    blocks: list[str] = []
    for character in characters:
        lines = [f"## {character.name}（{character.role}）"]
        if include_ids:
            lines.append(f"角色ID：{character.id}")
        lines.extend(
            [
                "固定设定：",
                character.fixed_profile or "（暂无）",
                "动态状态：",
                _format_dynamic_fields(character.dynamic_fields),
            ]
        )
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def _format_dynamic_fields(fields: dict[str, Any]) -> str:
    if not fields:
        return "（暂无）"
    return "\n".join(f"- {key}：{value}" for key, value in sorted(fields.items()))


def _keywords(text: str) -> set[str]:
    tokens = set(re.findall(r"[A-Za-z0-9_]{2,}|[\u4e00-\u9fff]{2,8}", text))
    # Long Chinese runs are supplemented with bigrams so overlap remains useful.
    for token in tuple(tokens):
        if re.fullmatch(r"[\u4e00-\u9fff]+", token):
            tokens.update(token[i : i + 2] for i in range(max(0, len(token) - 1)))
    return tokens
