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
PREVIOUS_ENDING_MAX_CHARS = 700
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


@dataclass(frozen=True)
class PackedWriterContext:
    memories: list[MemoryBlock]
    previous_ending: str = ""


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
    previous = next((item for item in prior if item.index == chapter.index - 1), None)
    if previous is not None and previous.draft_text.strip():
        blocks.extend(_previous_ending_blocks(previous))
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
    ending = [block for block in blocks if block.memory_type == "previous_ending"]
    ordinary = [block for block in blocks if block.memory_type != "previous_ending"]
    if len(ordinary) <= 300 and sum(nonspace_len(block.text) for block in ordinary) <= 30_000:
        return blocks
    query = normalize_text(f"{chapter.title}\n{chapter.user_prompt}\n{chapter_author_note(chapter)}")
    keywords = _keywords(query)

    def score(block: MemoryBlock) -> tuple[int, int, int, str]:
        text = normalize_text(block.text)
        selected = int(block.character_id in selected_character_ids)
        overlap = sum(1 for word in keywords if word and word in text)
        return (-selected, -overlap, -block.chapter_index, block.id)

    ranked = sorted(ordinary, key=score)
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
    return ending + chosen


def memory_selector_user_message(chapter: Chapter, blocks: list[MemoryBlock], budget: int) -> str:
    selected = _selected_characters(chapter)
    cards = _character_cards(selected, include_ids=True)
    ending_blocks = [block for block in blocks if block.memory_type == "previous_ending"]
    ordinary_blocks = [block for block in blocks if block.memory_type != "previous_ending"]
    candidates = "\n\n".join(f"[{block.id}]\n{block.text}" for block in ordinary_blocks) or "（没有可用历史记忆）"
    ending = "\n\n".join(f"[{block.id}]\n{block.text}" for block in ending_blocks) or "（没有可用的紧邻上一章结尾）"
    return "\n\n".join(
        [
            "# 本章剧情 Bible\n" + chapter.user_prompt.strip(),
            "# 作者对本章的备注\n" + (chapter_author_note(chapter).strip() or "（无）"),
            "# 本章允许人物及当前状态\n" + (cards or "（无已选人物）"),
            f"# 历史上下文总预算\n上一章结尾和其他历史记忆合计最多 {budget} 个中文去空白字符。"
            f"上一章结尾最多 {PREVIOUS_ENDING_MAX_CHARS} 字，章节梗概最多选 {MEMORY_SUMMARY_MAX_ITEMS} 条。你只负责选择，不得改写历史。",
            (
                "# 紧邻上一章结尾候选（原文）\n" + ending + "\n\n"
                "如有候选，请选择满足开场衔接所需的最短片段起点；只考虑时间、地点、动作、人物状态和最后落点，"
                "不要为了背景完整而扩大范围。返回该段方括号中的 ID，后端会从该段原样截取至结尾。"
            ),
            "# 候选记忆块\n" + candidates,
            (
                '# 输出\n只返回 JSON object：{"memory_ids":["按重要性排序的候选ID"],'
                '"previous_ending_start_id":"上一章结尾起点ID或null"}。memory_ids 允许空数组。'
                "ID 必须从候选块的方括号中原样完整复制（chapter 类 ID 含 :headline 或 :summary 后缀），不得截断、改写或自造。"
            ),
        ]
    )


def _resolve_selected_block(by_id: dict[str, MemoryBlock], memory_id: str) -> MemoryBlock | None:
    """Resolve a selector-returned id, salvaging suffix-truncated near-misses.

    Models occasionally return `chapter:{uuid}` without the `:headline`/`:summary`
    suffix. A truncated id is recovered only when exactly one candidate matches the
    prefix; an ambiguous or unknown id is dropped rather than guessed.
    """
    block = by_id.get(memory_id)
    if block is not None:
        return block
    prefix_matches = [item for key, item in by_id.items() if key.startswith(f"{memory_id}:")]
    if len(prefix_matches) == 1:
        return prefix_matches[0]
    return None


def pack_selected_memories(blocks: list[MemoryBlock], selected_ids: Iterable[str], budget: int) -> list[MemoryBlock]:
    by_id = {block.id: block for block in blocks if block.memory_type != "previous_ending"}
    result: list[MemoryBlock] = []
    used = 0
    summary_count = 0
    seen: set[str] = set()
    for memory_id in selected_ids:
        if not isinstance(memory_id, str):
            continue
        block = _resolve_selected_block(by_id, memory_id.strip())
        # Invalid, ambiguous, or empty selections are skipped, not fatal: fewer
        # memories is a legal outcome, while failing here kills the whole write.
        if block is None or not block.text.strip():
            continue
        if block.id in seen:
            continue
        seen.add(block.id)
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


def pack_writer_context(
    blocks: list[MemoryBlock],
    selected_ids: Iterable[str],
    previous_ending_start_id: str | None,
    budget: int,
) -> PackedWriterContext:
    ending_blocks = [block for block in blocks if block.memory_type == "previous_ending"]
    previous_ending = ""
    if ending_blocks:
        start = next(
            (index for index, block in enumerate(ending_blocks) if block.id == previous_ending_start_id),
            0,
        )
        previous_ending = "\n\n".join(block.text for block in ending_blocks[start:])
        previous_ending = truncate_to_nonspace(previous_ending, min(budget, PREVIOUS_ENDING_MAX_CHARS))
    remaining = max(0, budget - nonspace_len(previous_ending))
    return PackedWriterContext(
        memories=pack_selected_memories(blocks, selected_ids, remaining),
        previous_ending=previous_ending,
    )


def writer_user_message(
    book: Book,
    chapter: Chapter,
    memories: list[MemoryBlock] | None = None,
    previous_ending: str = "",
) -> str:
    characters = _selected_characters(chapter)
    allow = "、".join(character.name for character in characters) or "（没有已知人物卡；Bible 明写的临时角色仍可出现）"
    memory_text = "\n\n".join(block.text for block in (memories or [])) or "（本章不需要其他历史记忆）"
    ending_text = previous_ending.strip() or "（没有可用的紧邻上一章结尾）"
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
            (
                "# 历史参考资料（只读，低于本章 Bible）\n"
                "## 紧邻上一章结尾原文（仅用于开场衔接）\n"
                "以下原文只用于承接时间、地点、动作、身体状态、情绪余韵和现场环境；"
                "不得决定本章主要剧情、授权白名单外人物，或要求延续与 Bible 无关的情节。\n\n"
                + ending_text
                + "\n\n## 其他工作记忆\n"
                + memory_text
            ),
            "# 作者对本章的备注\n" + (chapter_author_note(chapter).strip() or "（无）"),
            f"# 本章剧情 Bible（情节最高权威）\n标题：{chapter.title}\n\n{chapter.user_prompt.strip()}",
            (
                "# 最终执行契约\n"
                "本章剧情 Bible 是本次写作的最高情节权威，决定本章发生什么、事件顺序和结尾落点。"
                "历史参考只能帮助处理衔接与已发生事实，不得据此增加 Bible 未要求的剧情、场景、冲突或人物。"
                "历史参考与 Bible 冲突时必须忽略冲突内容并服从 Bible。写作前在内部确认 Bible 的必要事件和结尾落点，不得输出分析过程。\n"
                "在内部为 Bible 的必要事件分配足够篇幅；完成全部必要事件且达到最低字数前，不得提前进入本章结尾落点。\n"
                f"目标 {chapter.target_word_count} 字，最终正文必须在 "
                f"{low_bound}～{high_bound} 个去空白字符内。"
                "只输出正文，不得解释、列提纲或擅自增加剧情、人物。"
            ),
        ]
    )


def writer_expansion_user_message(
    original_message: str,
    current_text: str,
    violations: list[dict[str, Any]],
) -> str:
    return "\n\n".join(
        [
            original_message,
            "# 当前正文\n" + current_text,
            "# 本次篇幅校验\n" + "\n".join(f"- {item['message']}" for item in violations),
            (
                "# Writer 扩写任务\n"
                "保持当前正文已经完成的情节、顺序和结尾落点，在这些内容内部有机补足动作过程、"
                "环境反馈、人物反应与心理变化。保留可用原文并返回完整正文，不得只输出新增段落；"
                "达到前述最低字数前不得收束结尾。"
            ),
        ]
    )


def _previous_ending_blocks(chapter: Chapter) -> list[MemoryBlock]:
    text = chapter.draft_text.strip()
    paragraphs = [part.strip() for part in re.split(r"\n\s*", text) if part.strip()]
    if not paragraphs:
        return []
    selected: list[str] = []
    used = 0
    for paragraph in reversed(paragraphs):
        size = nonspace_len(paragraph)
        remaining = PREVIOUS_ENDING_MAX_CHARS - used
        if remaining <= 0:
            break
        if size > remaining:
            paragraph = _truncate_from_end(paragraph, remaining)
            size = nonspace_len(paragraph)
        selected.append(paragraph)
        used += size
        if used >= PREVIOUS_ENDING_MAX_CHARS:
            break
    selected.reverse()
    return [
        MemoryBlock(
            id=f"previous_ending:{chapter.id}:p{index}",
            text=paragraph,
            chapter_index=chapter.index,
            memory_type="previous_ending",
        )
        for index, paragraph in enumerate(selected, start=1)
    ]


def _truncate_from_end(text: str, n: int) -> str:
    count = 0
    start = len(text)
    for index in range(len(text) - 1, -1, -1):
        if not text[index].isspace():
            count += 1
            if count > n:
                break
        start = index
    return text[start:]


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
