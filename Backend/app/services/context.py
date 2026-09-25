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
    # Archive v2 facts may belong to several characters.  Keep the complete
    # immutable set while retaining character_id for old callers and old
    # single-person records.
    participant_ids: tuple[str, ...] = ()
    # Stable source identity is deliberately separate from a revision/fact
    # database ID so an equivalent re-archive can be rebound safely.
    source_chapter_id: str = ""
    source_position: int = 0


def memory_participant_ids(block: MemoryBlock) -> tuple[str, ...]:
    values = block.participant_ids or ((block.character_id,) if block.character_id else ())
    return tuple(sorted({value for value in values if isinstance(value, str) and value}))


@dataclass(frozen=True)
class PackedWriterContext:
    memories: list[MemoryBlock]
    previous_ending: str = ""
    conflicts: list[MemoryBlock] | None = None

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
            "conflicts": [
                {"text": block.text, "source_ids": block.id.split("|")}
                for block in (self.conflicts or [])
            ],
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
                        source_chapter_id=item.id,
                    )
                )
            for position, fact in enumerate(revision.facts, start=1):
                participant_ids = tuple(sorted({participant.character_id for participant in fact.participants}))
                blocks.append(
                    MemoryBlock(
                        id=f"archive_v2_fact:{fact.id}",
                        text=f"第 {item.index} 章{fact.fact_type}事实：{fact.fact_text.strip()}",
                        chapter_index=item.index,
                        character_id=participant_ids[0] if len(participant_ids) == 1 else None,
                        memory_type="canonical_fact",
                        participant_ids=participant_ids,
                        source_chapter_id=item.id,
                        source_position=position,
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
                    source_chapter_id=item.id,
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
                    source_chapter_id=item.id,
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
                    participant_ids=(event.character_id,) if event.character_id else (),
                    source_chapter_id=event.chapter_id,
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
                    participant_ids=(character_id,) if isinstance(character_id, str) else (),
                    source_chapter_id=chapter.id,
                    source_position=position,
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
        selected = int(bool(set(memory_participant_ids(block)).intersection(selected_character_ids)))
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


def prefilter_memory_candidates_v1(
    blocks: list[MemoryBlock],
    *,
    chapter: Chapter,
    selected_character_ids: set[str],
) -> list[MemoryBlock]:
    """Reproduce Build63 candidate ordering for retained v1 snapshots.

    v1 knew only ``character_id``.  A later archive-v2 multi-participant
    block must therefore remain unselected for a v1 currentness comparison;
    otherwise crossing the 300-block/30k-character gate would falsely stale
    an old retained candidate after this client upgrade.
    """
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


def selector_source_aliases(blocks: list[MemoryBlock]) -> dict[str, str]:
    """Request-local short handles; canonical IDs never depend on model copying UUIDs."""
    ordinary = [block for block in blocks if block.memory_type != "previous_ending"]
    ending = [block for block in blocks if block.memory_type == "previous_ending"]
    return {**{f"M{i}": block.id for i, block in enumerate(ordinary, 1)},
            **{f"E{i}": block.id for i, block in enumerate(ending, 1)}}


def memory_selector_user_message(
    chapter: Chapter, blocks: list[MemoryBlock], budget: int, *, bible: str | None = None,
    dynamic_fields_by_character: dict[str, dict[str, Any]] | None = None,
    unknown_state_slots: list[dict[str, Any]] | None = None,
) -> str:
    selected = _selected_characters(chapter)
    cards = _character_cards(selected, include_ids=True, dynamic_fields_by_character=dynamic_fields_by_character)
    unknown_state_text = _format_unknown_state_slots(unknown_state_slots or [])
    ending_blocks = [block for block in blocks if block.memory_type == "previous_ending"]
    ordinary_blocks = [block for block in blocks if block.memory_type != "previous_ending"]
    aliases = {value: key for key, value in selector_source_aliases(blocks).items()}
    candidates = "\n\n".join(f"[{aliases[block.id]}]\n{block.text}" for block in ordinary_blocks) or "（没有可用历史记忆）"
    ending = "\n\n".join(f"[{aliases[block.id]}]\n{block.text}" for block in ending_blocks) or "（没有可用的紧邻上一章结尾）"
    return "\n\n".join(
        [
            "# 本章剧情 Bible（原文快照）\n" + (bible if bible is not None else chapter.user_prompt).strip(),
            "# 本章允许人物及当前状态\n" + (cards or "（无已选人物）"),
            "# 本章开始前待定状态\n" + unknown_state_text,
            "待定只表示资料尚不足，不能推定相反状态、人物冲突或本章必须补写的事件。",
            f"# 历史记忆简报预算\n最终记忆简报最多 {budget} 个去空白字符；上一章结尾独立，最多 {PREVIOUS_ENDING_MAX_CHARS} 字。"
            "只压缩有来源且会直接约束本章写作的历史事实，不得改写 Bible 或补足历史。"
            f"最多 {MAX_MEMORY_BRIEFS} 条简报、{MAX_MEMORY_CONFLICTS} 条冲突、建议合计不超过 {MAX_MEMORY_SOURCES} 个不同来源；"
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
                "每条事实和冲突均须包含非空 source_ids；记忆来源只用 M 开头的短编号，结尾起点只用 E 开头的短编号；从方括号原样复制，不得使用人物 ID 或自造编号。"
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
        # The adjacent ending has a dedicated 700-character allowance.  It
        # must not consume the separate 2,400-character brief/conflict budget.
        previous_ending = truncate_to_nonspace(previous_ending, PREVIOUS_ENDING_MAX_CHARS)
    return PackedWriterContext(
        memories=pack_selected_memories(blocks, selected_ids, budget),
        previous_ending=previous_ending,
    )


class MemorySelectionValidationError(ValueError):
    """Selector output is structurally valid JSON but not a valid selection."""


def memory_selection_problem(
    blocks: list[MemoryBlock],
    briefs: Any,
    conflicts: Any,
    previous_ending_start_id: Any,
    *,
    budget: int = MEMORY_BUDGET_CHARS,
) -> str | None:
    """Return a human-actionable rejection reason for one Selector response.

    This is deliberately stricter than the old packers.  An unknown source or
    an over-budget item is a failed selection that gets exactly one model
    correction, never a silent downgrade to an empty history context.
    """
    if not isinstance(briefs, list) or not isinstance(conflicts, list):
        return "briefs 与 conflicts 必须都是数组"
    if len(briefs) > MAX_MEMORY_BRIEFS:
        return f"简报 {len(briefs)} 条，超过 {MAX_MEMORY_BRIEFS} 条"
    if len(conflicts) > MAX_MEMORY_CONFLICTS:
        return f"冲突 {len(conflicts)} 条，超过 {MAX_MEMORY_CONFLICTS} 条"
    if previous_ending_start_id is not None:
        ending_ids = {block.id for block in blocks if block.memory_type == "previous_ending"}
        if not isinstance(previous_ending_start_id, str) or previous_ending_start_id not in ending_ids:
            return "上一章结尾起点不是本次候选中的有效 ID"

    by_id = {block.id: block for block in blocks if block.memory_type != "previous_ending"}
    used = 0
    seen: set[tuple[str, tuple[str, ...], str]] = set()
    for category, items in (("简报", briefs), ("冲突", conflicts)):
        for position, item in enumerate(items, start=1):
            if not isinstance(item, dict):
                return f"{category}第 {position} 条不是对象"
            if set(item) != {"text", "source_ids"}:
                return f"{category}第 {position} 条字段不符合协议"
            text = item.get("text")
            raw_ids = item.get("source_ids")
            if not isinstance(text, str) or not text.strip():
                return f"{category}第 {position} 条缺少 text"
            if not isinstance(raw_ids, list) or not raw_ids:
                return f"{category}第 {position} 条缺少 source_ids"
            if len(raw_ids) > MAX_SOURCES_PER_BRIEF:
                return f"{category}第 {position} 条引用超过 {MAX_SOURCES_PER_BRIEF} 个来源"
            if any(not isinstance(value, str) or not value.strip() for value in raw_ids):
                return f"{category}第 {position} 条包含空来源 ID"
            # Source IDs are protocol tokens, not prose.  Do not validate a
            # trimmed value and then hand the original token to the packer:
            # that deferred a bad ID into a KeyError outside Selector's one
            # permitted correction attempt.
            if any(value != value.strip() for value in raw_ids):
                return f"{category}第 {position} 条来源 ID 含前后空白，必须原样复制"
            ids = tuple(dict.fromkeys(raw_ids))
            if len(ids) != len(raw_ids):
                return f"{category}第 {position} 条重复引用来源"
            unknown = [value for value in ids if value not in by_id]
            if unknown:
                return f"{category}第 {position} 条引用了本次候选外的来源"
            key = (normalize_text(text).strip(), ids, category)
            if key in seen:
                return f"{category}中有重复条目"
            seen.add(key)
            used += nonspace_len(text)
            if used > budget:
                return f"简报与冲突合计 {used} 字，超过 {budget} 字"
    return None


def pack_selector_context(
    blocks: list[MemoryBlock],
    briefs: list[dict[str, Any]],
    conflicts: list[dict[str, Any]],
    previous_ending_start_id: str | None,
    *,
    budget: int = MEMORY_BUDGET_CHARS,
) -> PackedWriterContext:
    """Turn a *validated* Selector selection into the exact Writer/Checker input."""
    problem = memory_selection_problem(
        blocks, briefs, conflicts, previous_ending_start_id, budget=budget,
    )
    if problem:
        raise MemorySelectionValidationError(problem)
    by_id = {block.id: block for block in blocks if block.memory_type != "previous_ending"}

    def packed(items: list[dict[str, Any]], memory_type: str) -> list[MemoryBlock]:
        result: list[MemoryBlock] = []
        for item in items:
            ids = tuple(item["source_ids"])
            primary = by_id[ids[0]]
            result.append(MemoryBlock(
                "|".join(ids), item["text"].strip(), primary.chapter_index,
                primary.character_id, memory_type,
                participant_ids=tuple(sorted({
                    participant
                    for source_id in ids
                    for participant in memory_participant_ids(by_id[source_id])
                })),
                source_chapter_id=primary.source_chapter_id,
            ))
        return result

    ending = pack_writer_context(blocks, [], previous_ending_start_id, budget).previous_ending
    return PackedWriterContext(
        memories=packed(briefs, "memory_brief"),
        conflicts=packed(conflicts, "memory_conflict"),
        previous_ending=ending,
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
        packed.append(MemoryBlock(
            "|".join(ids), text.strip(), primary.chapter_index, primary.character_id, "memory_brief",
            participant_ids=tuple(sorted({
                participant for source_id in ids for participant in memory_participant_ids(by_id[source_id])
            })),
            source_chapter_id=primary.source_chapter_id,
        ))
        used += size
        used_source_ids.update(ids)
    return packed


def writing_reference_context(
    book: Book,
    chapter: Chapter,
    memories: list[MemoryBlock] | None = None,
    previous_ending: str = "",
    *,
    dynamic_fields_by_character: dict[str, dict[str, Any]] | None = None,
    conflicts: list[MemoryBlock] | None = None,
    unknown_state_slots: list[dict[str, Any]] | None = None,
) -> str:
    characters = _selected_characters(chapter)
    allow = "、".join(character.name for character in characters) or "（没有已选人物）"
    exemptions = sorted({normalize_text(name).strip() for name in (chapter.exempted_character_names or []) if isinstance(name, str) and normalize_text(name).strip()})
    exemption_text = "、".join(exemptions) or "（无）"
    memory_text = "\n\n".join(block.text for block in (memories or [])) or "（本章不需要其他历史记忆）"
    conflict_text = "\n\n".join(block.text for block in (conflicts or [])) or "（无）"
    ending_text = previous_ending.strip() or "（没有可用的紧邻上一章结尾）"
    return "\n\n".join(
        [
            "# 世界观（硬约束）\n" + (book.world_setting.strip() or "（无）"),
            (
                "# 本章人物授权\n"
                f"已选人物：{allow}\n"
                f"仅可提及的姓名豁免：{exemption_text}\n"
                "已选人物可出现或被提及，不要求全部使用。姓名豁免仅许可提及该姓名，不代表人物卡身份、人物关系或状态归属。"
                "历史记忆中出现的人物不会因此获得本章出场权限。"
            ),
            "# 人物卡（固定设定与本章开始前当前动态状态）\n" + (_character_cards(characters, dynamic_fields_by_character=dynamic_fields_by_character) or "（无）"),
            (
                "# 本章开始前待定状态\n"
                + _format_unknown_state_slots(unknown_state_slots or [])
                + "\n待定槽不能从旧人物卡、历史事实或常识补回为确定状态；它也不是已证实的相反事实，"
                "不得仅因待定而把正文判为矛盾或要求补写。只有本章正文明确写出后才能形成新事实。"
            ),
            (
                "# 历史参考资料（只读，低于本章 Bible）\n"
                "## 紧邻上一章结尾原文（仅用于开场衔接）\n"
                "以下原文只用于承接时间、地点、动作、身体状态、情绪余韵和现场环境；"
                "不得决定本章主要剧情、授权白名单外人物，或要求延续与 Bible 无关的情节。\n\n"
                + ending_text
                + "\n\n## 其他工作记忆\n"
                + memory_text
                + "\n\n## 待核对的历史冲突（不覆盖本章 Bible）\n"
                + conflict_text
            ),
        ]
    )


def writer_user_message(
    book: Book,
    chapter: Chapter,
    memories: list[MemoryBlock] | None = None,
    previous_ending: str = "",
    *,
    bible: str | None = None,
    dynamic_fields_by_character: dict[str, dict[str, Any]] | None = None,
    reference_context: str | None = None,
) -> str:
    # Freeze this same block for Writer and Checker during a generation.
    if reference_context is None:
        reference_context = writing_reference_context(
            book, chapter, memories, previous_ending,
            dynamic_fields_by_character=dynamic_fields_by_character,
        )
    return "\n\n".join(
        [
            reference_context,
            f"# 本章剧情 Bible（原文快照，情节最高权威）\n标题：{chapter.title}\n\n{(bible if bible is not None else chapter.user_prompt).strip()}",
            (
                "# 最终执行契约\n"
                "本章剧情 Bible 决定核心事件、明确禁止事项及明确指定的顺序和结尾；未指定的过程允许合理发挥。"
                "为完成本章意图，可自然补充互动、场景衔接、局部波折、情绪与态度变化，以及已有关系中的渐进发展。"
                "历史参考用于衔接与核对既有事实，历史不授权白名单外人物。不得输出分析过程。\n"
                "为核心事件和自然展开分配足够篇幅，完整写成一章。正文至少 4000 个去空白字符，"
                "但没有产品字数上限。只输出正文，不得解释或列提纲。"
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
            source_chapter_id=chapter.id,
            source_position=index,
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


def manual_checker_reference_context(db: Session, chapter: Chapter) -> str:
    """Bounded current facts for manual checks; no extra Selector/model call."""
    from app.services import character_state_projection as projection

    blocks = prefilter_memory_candidates(
        memory_candidates(db, chapter), chapter=chapter,
        selected_character_ids={character.id for character in _selected_characters(chapter)},
    )
    packed = pack_writer_context(
        blocks, [block.id for block in blocks if block.memory_type != "previous_ending"],
        None, MEMORY_BUDGET_CHARS,
    )
    state_reader = getattr(projection, "projected_state_before_chapter", None)
    if callable(state_reader):
        prior_state, unknown_slots = state_reader(db, chapter, stable_relationship_keys=True)
    else:
        prior_state = projection.projected_fields_before_chapter(db, chapter, stable_relationship_keys=True)
        unknown_slots = []
    return writing_reference_context(
        chapter.book, chapter, packed.memories, packed.previous_ending,
        dynamic_fields_by_character=prior_state,
        unknown_state_slots=unknown_slots,
    )


def checker_user_message(
    chapter: Chapter,
    draft_text: str,
    bible: str,
    *,
    reference_context: str,
    source_catalog: list[dict[str, Any]] | None = None,
    name_hits: list[dict[str, Any]] | None = None,
    name_groups: list[dict[str, Any]] | None = None,
    name_candidate_groups: list[dict[str, Any]] | None = None,
    retry_reason_code: str | None = None,
) -> str:
    catalog_lines = []
    for source in source_catalog or []:
        if not isinstance(source, dict):
            continue
        kind, source_id, text = source.get("kind"), source.get("id"), source.get("text")
        if isinstance(kind, str) and isinstance(source_id, str) and isinstance(text, str):
            if (kind, source_id) == ("draft", "draft"):
                catalog_lines.append("[draft:draft]\n见下方“待检查正文（原样）”。")
            elif (kind, source_id) == ("bible", "bible"):
                catalog_lines.append("[bible:bible]\n见上方“本章剧情 Bible（原文快照）”。")
            else:
                catalog_lines.append(f"[{kind}:{source_id}]\n{text}")
    source_directory = "\n\n".join(catalog_lines) or "（来源目录由程序冻结；没有额外条目）"
    fallback_groups: list[dict[str, Any]] = []
    fallback_candidates: dict[tuple[tuple[str, ...], tuple[str, ...]], str] = {}
    if name_groups is None:
        for hit in name_hits or []:
            if not isinstance(hit, dict):
                continue
            hit_id, source_id, text = hit.get("hit_id"), hit.get("source_id"), hit.get("text")
            candidates = hit.get("candidate_character_ids")
            selected = hit.get("selected_character_ids")
            excerpt = hit.get("local_excerpt")
            if not (
                isinstance(hit_id, str) and isinstance(source_id, str) and isinstance(text, str)
                and isinstance(candidates, list) and isinstance(selected, list) and isinstance(excerpt, str)
                and all(isinstance(value, str) for value in candidates + selected)
            ):
                continue
            candidate_key = fallback_candidates.setdefault(
                (tuple(candidates), tuple(selected)), f"c{len(fallback_candidates) + 1}",
            )
            fallback_groups.append({
                "hit_ids": [hit_id], "source_id": source_id, "name": text,
                "candidate_key": candidate_key, "local_context": excerpt,
            })
        name_groups = fallback_groups
        name_candidate_groups = [
            {"candidate_key": key, "character_ids": list(ids), "selected_character_ids": list(selected_ids)}
            for (ids, selected_ids), key in fallback_candidates.items()
        ]
    candidate_lines = []
    for group in name_candidate_groups or []:
        if not isinstance(group, dict):
            continue
        key, ids, selected_ids = group.get("candidate_key"), group.get("character_ids"), group.get("selected_character_ids")
        if isinstance(key, str) and isinstance(ids, list) and isinstance(selected_ids, list) and all(isinstance(value, str) for value in ids + selected_ids):
            candidate_lines.append(f"{key}：候选ID={','.join(ids)}；已选ID={','.join(selected_ids) or '（无）'}")
    # Request-local group IDs replace copied hit ID lists.  The exact same
    # deterministic helper is used by checker_validation when it expands the
    # semantic answer back into program-owned hit evidence.
    from app.services.checker_validation import numbered_name_groups
    group_lines = []
    for group_id, group in numbered_name_groups(name_groups or []):
        if not isinstance(group, dict):
            continue
        hit_ids = group.get("hit_ids")
        source_id, name, candidate_key, context = (
            group.get("source_id"), group.get("name"), group.get("candidate_key"), group.get("local_context"),
        )
        if (
            isinstance(hit_ids, list) and hit_ids and all(isinstance(value, str) for value in hit_ids)
            and all(isinstance(value, str) for value in (source_id, name, candidate_key, context))
        ):
            group_lines.append(
                f"[{group_id}] 来源={source_id}，词={name}，候选组={candidate_key}，局部原文={context}"
            )
    name_directory = "\n".join(group_lines) or "（没有待辨别姓名命中；name_uses 返回空数组）"
    candidate_directory = "\n".join(candidate_lines) or "（无待辨别姓名候选组）"
    evidence_contract = (
        "# 程序提供的检查来源目录\n" + source_directory + "\n\n"
        "# 待辨别姓名候选组\n" + candidate_directory + "\n\n"
        "# 待辨别姓名局部片段\n" + name_directory + "\n\n"
        "# 证据与姓名输出协议\n"
        "每个 issue 返回 kind、reason、draft_evidence、bible_evidence、source_kind、source_id、source_evidence。"
        "source_kind/source_id 必须原样指向上方目录，source_evidence 必须是该来源中的连续原文；"
        "不得用省略号拼接不连续片段。只有 source_kind=bible 时 bible_evidence 才可非空，且必须是同一 Bible 原文。"
        "kind=missing_requirement 表示核心要求遗漏：draft_evidence 留空、必须引用非空 Bible；其余问题通常必须引用正文。"
        "但未选择人物、重名或身份未明且该姓名只出现在 Bible 时，身份问题可把 source_kind/source_id 指向 Bible，"
        "draft_evidence 留空并用 Bible 原文举证，绝不可伪造正文引文。"
        "来源 prior_state:unknown 只表示资料范围，绝不可单独作为正文矛盾、必需事件或 issue 的依据；"
        "只有其他冻结来源存在确切证据时才可报告问题。"
        "逐组返回 name_uses：每项含 group_id、classification、reason 和可选 character_id。"
        "group_id 必须原样等于下方一个程序分组，每个分组恰好返回一次；不得返回 hit_ids、偏移或自行拆分、合并分组；"
        "classification 只能为 character、ordinary_word、uncertain。程序会按 group_id 重建每次命中的精确引文与位置。"
        "ordinary_word 不是人物；character/uncertain 的人物授权问题由程序根据冻结目录生成，不必重复写身份 issue。"
    )
    if retry_reason_code in {"checker_invalid_response", "invalid_protocol", "invalid_name_uses"}:
        evidence_contract += (
            "\n上次检查未形成可用结论。请逐一覆盖所有给定 group_id，每组仅出现一次；"
            "只返回 group_id，不返回 hit_ids。"
        )
    if not bible.strip():
        return "\n\n".join([
            reference_context,
            f"# 本章剧情 Bible\n标题：{chapter.title}\n未提供本章写作要求。",
            "# 待检查正文（原样）\n" + draft_text,
            (
                "# 检查任务\n本章 Bible 为空，跳过“是否符合本章写作要求”这一项："
                "不检查相对于 Bible 的必要事件遗漏、顺序、结尾或剧情越界。"
                "不得因 Bible 为空、未提供写作要求或无法对照 Bible 而报告 issue 或给出 suspect、violation。"
                "不得将标题、历史参考或从正文推断出的意图当作补造的 Bible。"
                "其余检查照常：只基于已提供的世界观、人物卡、章前状态、有效历史及正文，"
                "核对确有证据的事实矛盾、正文内部矛盾和人物授权问题；没有资料时不得猜测。"
                "历史人物不会自动获得本章出场权限；文学性细节不是违规。"
                "每个 issue 的 draft_evidence 引用正文原文，reason 说明具体矛盾及对应资料证据，"
                "bible_evidence 留为空字符串，不得编造 Bible 引文。"
                "没有其他有证据的问题时返回 passed，issues 为空数组。"
            ),
            evidence_contract,
        ])
    return "\n\n".join(
        [
            reference_context,
            f"# 本章剧情 Bible（原文快照，情节最高权威）\n标题：{chapter.title}\n\n{bible}",
            "# 待检查正文（原样）\n" + draft_text,
            (
                "# 检查任务\n先核对世界观、人物卡、本章开始前动态状态及有效历史，区分既有事实与本章新增变化。"
                "已有身份或关系在正文中的自然呈现，不因 Bible 未重复列出就构成新增关系。"
                "历史人物不自动获得白名单权限。Bible 决定核心事件、明确禁止事项及明确指定的顺序和结尾，未指定的过程允许合理发挥。"
                "为完成本章意图，可自然补充互动、场景衔接、局部波折、情绪与态度变化，以及已有关系中的渐进发展。"
                "只报告有证据的实质矛盾、核心要求遗漏、违背明确禁止事项或指定顺序与结局，以及未经授权的重大转折。"
                "没有上述具体证据时，不得仅因发挥较多而判为 suspect 或 violation；没有其他问题应返回 passed。"
                "每个 issue 必须引用正文和对应冻结来源；只有 Bible 问题才引用 Bible 证据，不得将参考资料冒充 Bible 引文。"
            ),
            evidence_contract,
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
    """Compatibility hook for callers that used to preflight raw name substrings.

    Names such as ``夏天`` and ``白雪`` need the Checker call's semantic
    ``name_uses`` classification.  Treating a substring as a definitive
    character here was both a false-positive source and an unreviewable hard
    gate, so the function deliberately performs no character decision.
    """
    del db, chapter


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
    # Character mention decisions move to Checker ``name_uses``.  A raw name
    # substring only creates a candidate for word-sense classification; it is
    # not enough evidence to reject a draft or make a generic override unsafe.
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
                _format_dynamic_fields(
                    character.dynamic_fields
                    if dynamic_fields_by_character is None
                    else dynamic_fields_by_character.get(character.id, {})
                ),
            ]
        )
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def _format_dynamic_fields(fields: dict[str, Any]) -> str:
    if not fields:
        return "（暂无）"
    return "\n".join(f"- {key}：{value}" for key, value in sorted(fields.items()))


def _format_unknown_state_slots(unknown_slots: list[dict[str, Any]]) -> str:
    if not unknown_slots:
        return "（无）"
    lines: list[str] = []
    for item in unknown_slots:
        if not isinstance(item, dict):
            continue
        name = item.get("character_name") or item.get("character_id") or "人物"
        slot = item.get("slot") or "状态"
        reason = item.get("message") or "该状态尚无法确定"
        if item.get("scope") == "relationship":
            other = item.get("other_character_name") or item.get("other_character_id") or "关系对象已不可用"
            lines.append(f"- {name} 与 {other} 的关系：待定（{reason}）")
        else:
            lines.append(f"- {name} 的 {slot}：待定（{reason}）")
    return "\n".join(lines) or "（无）"


def _keywords(text: str) -> set[str]:
    tokens = set(re.findall(r"[A-Za-z0-9_]{2,}|[\u4e00-\u9fff]{2,8}", text))
    # Long Chinese runs are supplemented with bigrams so overlap remains useful.
    for token in tuple(tokens):
        if re.fullmatch(r"[\u4e00-\u9fff]+", token):
            tokens.update(token[i : i + 2] for i in range(max(0, len(token) - 1)))
    return tokens
