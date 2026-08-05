from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from dataclasses import dataclass
from typing import Any, Iterable

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Book, Chapter, Character, CharacterEvent


# --- Centralized tunable constants (see PROJECT_PLAN v1.1.0) ---
MIN_DRAFT_NONSPACE_CHARS = 4000
# The final, compressed memory brief is deliberately small; the programme may
# recall far more source material before asking Selector to compress it.
MEMORY_BUDGET_CHARS = 2400
PREVIOUS_ENDING_MAX_CHARS = 700
CHARACTER_EVENT_MAX_CHARS = 60
MAX_MEMORY_BRIEFS = 8
MAX_MEMORY_CONFLICTS = 4
MAX_MEMORY_SOURCES = 16
MAX_SOURCES_PER_BRIEF = 6


def nonspace_len(text: str) -> int:
    return sum(1 for ch in text if not ch.isspace())


def draft_fingerprint(chapter: Chapter, text: str, *, bible: str | None = None) -> str:
    """Return the stable identity of the exact constraints checked against a draft.

    This intentionally includes the writing context that can make a previous
    Bible check unsafe to reuse.  JSON's sorted keys and compact separators
    make equivalent JSON character state produce the same digest regardless of
    insertion order.
    """
    selected = sorted((link.character for link in chapter.character_links), key=lambda character: character.id)
    payload = {
        "bible": chapter.user_prompt if bible is None else bible,
        "chapter_title": chapter.title,
        "world_setting": chapter.book.world_setting,
        "selected_characters": [
            {
                "id": character.id,
                "name": character.name,
                "fixed_profile": character.fixed_profile,
                "dynamic_fields": character.dynamic_fields or {},
            }
            for character in selected
        ],
        "draft_text": text,
    }
    serialized = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


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

    def manifest(self) -> dict[str, Any]:
        return {
            "memory_brief": [
                {
                    "text": block.text,
                    "source_ids": block.id.split("|"),
                    "chapter_index": block.chapter_index,
                    "memory_type": block.memory_type,
                    "source_excerpt": block.text,
                }
                for block in self.memories
            ],
            "previous_ending": self.previous_ending,
            "memory_non_whitespace_count": sum(nonspace_len(block.text) for block in self.memories),
            "previous_ending_non_whitespace_count": nonspace_len(self.previous_ending),
        }


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
    legacy_prior_ids: list[str] = []
    from app.services.archive_v2 import active_archive_revision
    for item in prior:
        revision = active_archive_revision(db, item)
        if revision is not None:
            if revision.summary.strip():
                blocks.append(
                    MemoryBlock(
                        id=f"archive_v2:{revision.id}:summary",
                        text=f"第 {item.index} 章摘要：{revision.summary.strip()}",
                        chapter_index=item.index,
                        memory_type="summary",
                    )
                )
            for fact in revision.facts:
                participant_ids = [participant.character_id for participant in fact.participants]
                blocks.append(
                    MemoryBlock(
                        id=f"archive_v2_fact:{fact.id}",
                        text=f"第 {item.index} 章{fact.fact_type}事实：{fact.fact_text.strip()}",
                        chapter_index=item.index,
                        character_id=participant_ids[0] if len(participant_ids) == 1 else None,
                        memory_type="canonical_fact",
                    )
                )
            continue
        if not (item.legacy_archive_eligible or item.archive_input_fingerprint is None):
            continue
        legacy_prior_ids.append(item.id)
        canonical_summary = item.long_summary.strip()
        if canonical_summary:
            blocks.append(
                MemoryBlock(
                    # Preserve the stable legacy ID so saved audit/source
                    # references remain understandable after the merge.
                    id=f"chapter:{item.id}:summary",
                    text=f"第 {item.index} 章摘要：{canonical_summary}",
                    chapter_index=item.index,
                    memory_type="summary",
                )
            )
        elif item.headline.strip():
            # v1.6.3 made the chapter summary the canonical history source.
            # Keep the headline only as a compatibility fallback for an old or
            # hand-edited chapter whose canonical summary is still empty; never
            # send both representations of the same chapter to Selector.
            blocks.append(
                MemoryBlock(
                    id=f"chapter:{item.id}:headline",
                    text=f"第 {item.index} 章大事记：{item.headline.strip()}",
                    chapter_index=item.index,
                    memory_type="headline",
                )
            )
        blocks.extend(_archive_memory_blocks(item))
    if legacy_prior_ids:
        events = db.scalars(
            select(CharacterEvent)
            .where(CharacterEvent.book_id == chapter.book_id, CharacterEvent.chapter_id.in_(legacy_prior_ids))
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


def _archive_memory_blocks(chapter: Chapter) -> list[MemoryBlock]:
    """Expose v1.6 accepted archive facts as individually traceable sources.

    IDs are derived from the persisted chapter and slot, so source references
    stay stable between Selector runs and always identify a chapter/type.
    Malformed hand-edited values are ignored rather than turning a future write
    into an archive-read failure.
    """
    blocks: list[MemoryBlock] = []
    for memory_type, label, items in (
        ("state_change", "状态变化", chapter.state_changes or []),
        ("unresolved_item", "未决事项", chapter.unresolved_items or []),
        ("atomic_memory", "原子记忆", chapter.atomic_memories or []),
    ):
        if not isinstance(items, list):
            continue
        for position, item in enumerate(items, start=1):
            if not isinstance(item, dict):
                continue
            text = item.get("text")
            if not isinstance(text, str) or not text.strip():
                continue
            character_id = item.get("character_id")
            blocks.append(
                MemoryBlock(
                    id=f"chapter:{chapter.id}:{memory_type}:{position}",
                    text=f"第 {chapter.index} 章{label}：{text.strip()}",
                    chapter_index=chapter.index,
                    character_id=character_id if isinstance(character_id, str) else None,
                    memory_type=memory_type,
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
    query = normalize_text(f"{chapter.title}\n{chapter.user_prompt}")
    keywords = _keywords(query)

    def score(block: MemoryBlock) -> tuple[int, int, int, str]:
        text = normalize_text(block.text)
        selected = int(block.character_id in selected_character_ids)
        overlap = sum(1 for word in keywords if word and word in text)
        return (-selected, -overlap, -block.chapter_index, block.id)

    ranked = sorted(ordinary, key=score)
    # Even when the full candidate pool fits, put likely-relevant facts first.
    # This preserves broad recall while preventing chronological order from
    # nudging the model toward a chapter-by-chapter recap.
    if len(ranked) <= 300 and sum(nonspace_len(block.text) for block in ranked) <= 30_000:
        return ending + ranked
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


def memory_selector_user_message(
    chapter: Chapter, blocks: list[MemoryBlock], budget: int, *, bible: str | None = None,
    dynamic_fields_by_character: dict[str, dict[str, Any]] | None = None,
) -> str:
    selected = _selected_characters(chapter)
    cards = _character_cards(selected, include_ids=True, dynamic_fields_by_character=dynamic_fields_by_character)
    ending_blocks = [block for block in blocks if block.memory_type == "previous_ending"]
    ordinary_blocks = [block for block in blocks if block.memory_type != "previous_ending"]
    candidates = "\n\n".join(f"[{block.id}]\n{block.text}" for block in ordinary_blocks) or "（没有可用历史记忆）"
    ending = "\n\n".join(f"[{block.id}]\n{block.text}" for block in ending_blocks) or "（没有可用的紧邻上一章结尾）"
    return "\n\n".join(
        [
            "# 本章剧情 Bible（原文快照）\n" + (bible if bible is not None else chapter.user_prompt).strip(),
            "# 本章允许人物及当前状态\n" + (cards or "（无已选人物）"),
            f"# 历史记忆简报预算\n最终记忆简报最多 {budget} 个去空白字符；上一章结尾独立，最多 {PREVIOUS_ENDING_MAX_CHARS} 字。"
            "只压缩有来源且会直接约束本章写作的历史事实，不得改写 Bible 或补足历史。"
            f"最多 {MAX_MEMORY_BRIEFS} 条简报、{MAX_MEMORY_CONFLICTS} 条冲突、合计 {MAX_MEMORY_SOURCES} 个不同来源；"
            "候选已按相关性排列。禁止逐章回顾，禁止因为某章发生在前面就自动选入；"
            "同一事实的多个来源必须合并成一条简报。若没有会影响本章动作、认知、人物状态或连续性的历史事实，briefs 返回空数组。",
            (
                "# 紧邻上一章结尾候选（原文）\n" + ending + "\n\n"
                "如有候选，请选择满足开场衔接所需的最短片段起点；只考虑时间、地点、动作、人物状态和最后落点，"
                "不要为了背景完整而扩大范围。返回该段方括号中的 ID，后端会从该段原样截取至结尾。"
            ),
            "# 候选记忆块\n" + candidates,
            (
                '# 输出\n只返回 JSON object：{"briefs":[{"text":"精炼历史事实","source_ids":["候选ID"]}],'
                '"conflicts":[{"text":"冲突说明","source_ids":["候选ID"]}],'
                '"previous_ending_start_id":"上一章结尾起点ID或null"}。briefs/conflicts 允许空数组。'
                "每条事实和冲突均须包含非空 source_ids；ID 必须从候选块的方括号中原样完整复制，不得自造。"
                "briefs 按对本章的重要性从高到低排列；不要输出候选清单、章节流水账或一章一条的复述。"
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
        size = nonspace_len(block.text)
        if used + size > budget:
            continue
        result.append(block)
        used += size
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


def pack_memory_brief(
    blocks: list[MemoryBlock],
    briefs: Iterable[dict[str, Any]],
    budget: int,
    *,
    max_items: int = MAX_MEMORY_BRIEFS,
    max_sources: int = MAX_MEMORY_SOURCES,
) -> list[MemoryBlock]:
    """Validate Selector's compressed facts against recalled sources.

    A brief is usable only when every source is a real non-ending candidate. We
    retain the model's concise wording but keep all sources in the persisted
    manifest (the first source is represented by the block id for old helpers).
    """
    by_id = {block.id: block for block in blocks if block.memory_type != "previous_ending"}
    packed: list[MemoryBlock] = []
    used = 0
    used_source_ids: set[str] = set()
    seen: set[tuple[str, tuple[str, ...]]] = set()
    for item in briefs:
        if len(packed) >= max_items:
            break
        if not isinstance(item, dict):
            continue
        text = item.get("text")
        source_ids = item.get("source_ids")
        if not isinstance(text, str) or not text.strip() or not isinstance(source_ids, list):
            continue
        ids = tuple(dict.fromkeys(source_id.strip() for source_id in source_ids if isinstance(source_id, str) and source_id.strip()))
        if (
            not ids
            or len(ids) > MAX_SOURCES_PER_BRIEF
            or any(source_id not in by_id for source_id in ids)
            or len(used_source_ids.union(ids)) > max_sources
        ):
            continue
        key = (normalize_text(text).strip(), ids)
        if key in seen:
            continue
        size = nonspace_len(text)
        if used + size > budget:
            continue
        seen.add(key)
        primary = by_id[ids[0]]
        packed.append(MemoryBlock("|".join(ids), text.strip(), primary.chapter_index, primary.character_id, "memory_brief"))
        used += size
        used_source_ids.update(ids)
    return packed


def writer_user_message(
    book: Book,
    chapter: Chapter,
    memories: list[MemoryBlock] | None = None,
    previous_ending: str = "",
    *,
    bible: str | None = None,
    dynamic_fields_by_character: dict[str, dict[str, Any]] | None = None,
) -> str:
    characters = _selected_characters(chapter)
    allow = "、".join(character.name for character in characters) or "（没有已知人物卡；Bible 明写的临时角色仍可出现）"
    memory_text = "\n\n".join(block.text for block in (memories or [])) or "（本章不需要其他历史记忆）"
    ending_text = previous_ending.strip() or "（没有可用的紧邻上一章结尾）"
    return "\n\n".join(
        [
            "# 世界观（硬约束）\n" + (book.world_setting.strip() or "（无）"),
            (
                "# 本章允许人物白名单\n"
                f"{allow}\n"
                "白名单表示允许出现或被提及，不要求全部使用。历史记忆中出现的人物不会因此获得本章出场权限。"
            ),
            "# 人物卡（固定设定与本章开始前当前动态状态）\n" + (_character_cards(characters, dynamic_fields_by_character=dynamic_fields_by_character) or "（无）"),
            (
                "# 历史参考资料（只读，低于本章 Bible）\n"
                "## 紧邻上一章结尾原文（仅用于开场衔接）\n"
                "以下原文只用于承接时间、地点、动作、身体状态、情绪余韵和现场环境；"
                "不得决定本章主要剧情、授权白名单外人物，或要求延续与 Bible 无关的情节。\n\n"
                + ending_text
                + "\n\n## 其他工作记忆\n"
                + memory_text
            ),
            f"# 本章剧情 Bible（原文快照，情节最高权威）\n标题：{chapter.title}\n\n{(bible if bible is not None else chapter.user_prompt).strip()}",
            (
                "# 最终执行契约\n"
                "本章剧情 Bible 是本次写作的最高情节权威，决定本章发生什么、事件顺序和结尾落点。"
                "历史参考只能帮助处理衔接与已发生事实，不得据此增加 Bible 未要求的剧情、场景、冲突或人物。"
                "历史参考与 Bible 冲突时必须忽略冲突内容并服从 Bible。写作前在内部确认 Bible 的必要事件和结尾落点，不得输出分析过程。\n"
                "在内部为 Bible 的必要事件分配足够篇幅，完整写成一章。正文至少 4000 个去空白字符，"
                "但没有产品字数上限。只输出正文，不得解释、列提纲或擅自增加剧情、人物。"
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


def extractor_user_message(db: Session, book: Book, chapter: Chapter) -> str:
    characters = _selected_characters(chapter)
    from app.services.character_state_projection import projected_fields_before_chapter
    prior_fields = projected_fields_before_chapter(db, chapter)
    # Names are identity labels only.  The model never receives or chooses UUIDs;
    # ExtractorAgent maps an exact selected name back to its ID mechanically.
    character_names = "\n".join(f"- {character.name}" for character in characters) or "（无已选人物）"
    return "\n\n".join(
        [
            "# 事实来源（唯一）\n以下“最终接受正文”是唯一可以归档事实的材料。"
            "不得使用、复述或根据未提供的 Bible、世界观、人物卡或历史记忆补写事实。",
            "# 人物姓名白名单（仅用于身份归属，不是事实来源）\n" + character_names,
            "# 本章开始前有效状态（仅作更新基线，不是可归档事实）\n" + (
                "\n".join(f"- {character.name}：{_format_dynamic_fields(prior_fields.get(character.id, {}))}" for character in characters)
                if characters else "（无已选人物）"
            ),
            (
                "# 提取输出约束\nheadline/long_summary 必填；long_summary 是本章唯一摘要，不限制机械字数；"
                "state_changes、unresolved_items、atomic_memories "
                "逐项只记录正文中明确发生、明确改变或明确尚未解决的事实。人物归属只能使用上面列出的精确姓名；"
                "人物相关的 text 与 event_text 必须以该人物精确姓名开头。人物事件只使用约定的中文类型。"
                "character_events 必须按重要性从高到低排列，每个人物最多 3 条、本章最多 8 条；"
                "只记录会改变人物故事线、关系、认知、决定或持续状态的关键节点。普通动作、对白、过程流水账"
                "以及同一事实的拆分或换措辞重复都不建事件。"
                "state_updates 只写本章实际在场人物的当前状态：snapshot 一旦提供必须完整给出当前位置、当前行动、情绪状态三槽，"
                "每槽 set 或 clear；persistent_ops 只允许身体状态、当前目标、秘密状态；relationship_ops 是唯一人物对关系。"
                "同一无向人物对在整份 state_updates 中只输出一次：必须放在上方白名单顺序更靠前的人物下，"
                "另一人物不得重复该关系；value 只写双方共同关系状态，不写两份不同视角。"
                "snapshot 只描述章节结束时，禁止过程串。掌握信息只进 atomic_memories；不得输出其他状态、未知、未明确或占位值。"
                "所有 set/clear 的 evidence 必须是正文中的原文片段，"
                "且必须包含所属人物姓名；宁可不记，也不得猜测归属。未选择人物时人物更新数组必须为空。"
                f"每条 event_text 不超过 {CHARACTER_EVENT_MAX_CHARS} 个去空白字符。"
            ),
            f"# 最终接受正文（原样）\n{chapter.draft_text}",
        ]
    )


def checker_user_message(chapter: Chapter, draft_text: str, bible: str) -> str:
    characters = _selected_characters(chapter)
    allow = "、".join(character.name for character in characters) or "（无已选人物）"
    return "\n\n".join(
        [
            "# 本章剧情 Bible（原文快照）\n" + bible,
            "# 本章允许人物白名单\n" + allow,
            "# 待检查正文（原样）\n" + draft_text,
            (
                "# 检查任务\n只检查 Bible 必要事件遗漏、事件顺序或结果矛盾、以及会影响后续事实的新增人物、"
                "线索、秘密、冲突或关系变化。文学性的动作、心理、环境和自然衔接不是违规。"
                "每个 issue 必须同时引用正文和 Bible 证据；没有证据时不要报告 issue。"
            ),
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
    matched, ambiguous = scan_known_character_names(chapter.user_prompt, known)
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
            "本章剧情 Bible 出现了未选择人物",
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
    if not text.strip():
        violations.append({"code": "empty_body", "message": "正文为空"})
    # A local edit has no upstream completion record.  The check endpoint
    # marks it explicitly as manual_edit, which is a normal local completion
    # semantic rather than a truncated model response.
    normal_finish_reasons = {"stop", "end_turn", "completed", "complete", "manual_edit", None, ""}
    if finish_reason not in normal_finish_reasons:
        violations.append({"code": "length_truncated", "message": f"上游因长度截断（{finish_reason}）"})
    if chars < MIN_DRAFT_NONSPACE_CHARS:
        violations.append(
            {"code": "minimum_length", "message": f"正文 {chars} 字，少于最低要求 {MIN_DRAFT_NONSPACE_CHARS} 字", "current_chars": chars}
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


def _character_cards(
    characters: Iterable[Character], include_ids: bool = False,
    dynamic_fields_by_character: dict[str, dict[str, Any]] | None = None,
) -> str:
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
                _format_dynamic_fields((dynamic_fields_by_character or {}).get(character.id, character.dynamic_fields)),
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
