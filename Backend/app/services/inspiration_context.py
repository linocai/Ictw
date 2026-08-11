from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Chapter, Character, CharacterEvent
from app.services.archive_v2 import active_archive_revision
from app.services.character_state_projection import projected_fields_before_chapter
from app.services.context import nonspace_len, normalize_text, truncate_to_nonspace


INSPIRATION_HISTORY_BUDGET_CHARS = 6000
INSPIRATION_HISTORY_MAX_SOURCES = 48
INSPIRATION_CONTINUATION_MIN_CHAPTERS = 2


@dataclass(frozen=True)
class InspirationHistorySource:
    id: str
    text: str
    chapter_index: int
    character_ids: frozenset[str] = frozenset()


@dataclass(frozen=True)
class InspirationContext:
    user_message: str
    source_chapter_indexes: dict[str, int]
    known_characters: tuple[Character, ...]
    selected_character_ids: frozenset[str]
    mode: str


class InspirationContextError(ValueError):
    pass


def build_inspiration_context(
    db: Session,
    chapter: Chapter,
    *,
    title: str,
    bible: str,
    pacing_boundary: str,
    selected_character_ids: list[str],
) -> InspirationContext:
    if len(set(selected_character_ids)) != len(selected_character_ids):
        raise InspirationContextError("duplicate character ids")
    known_characters = tuple(
        db.scalars(
            select(Character)
            .where(Character.book_id == chapter.book_id)
            .order_by(Character.id)
        ).all()
    )
    by_id = {character.id: character for character in known_characters}
    if any(character_id not in by_id for character_id in selected_character_ids):
        raise InspirationContextError("character does not belong to chapter book")
    selected_ids = frozenset(selected_character_ids)
    selected_characters = [by_id[character_id] for character_id in sorted(selected_ids)]
    projected = projected_fields_before_chapter(db, chapter)
    sources = _rank_and_pack_sources(
        _history_sources(db, chapter),
        title=title,
        bible=bible,
        selected_character_ids=selected_ids,
    )
    history_chapter_count = len({source.chapter_index for source in sources})
    mode = (
        "continuation"
        if history_chapter_count >= INSPIRATION_CONTINUATION_MIN_CHAPTERS
        else "free_ideation"
    )
    source_manifest = (
        {source.id: source.chapter_index for source in sources}
        if mode == "continuation"
        else {}
    )
    character_blocks = []
    for character in selected_characters:
        character_blocks.append(
            "\n".join(
                [
                    f"## {character.name}（{character.role or '未标注角色'}）",
                    "固定设定：" + (character.fixed_profile.strip() or "（暂无）"),
                    "本章开始前状态：" + _format_fields(projected.get(character.id, {})),
                ]
            )
        )
    if mode == "continuation":
        history = "\n\n".join(f"[{source.id}]\n{source.text}" for source in sources)
        mode_instruction = (
            "承接模式：已有至少两个历史章节的有效记忆。只有确实承接这些记忆时才填写 history_basis，"
            "并在 source_ids 中复制对应方括号 ID；不承接历史的卡片仍使用 null 与空数组。"
        )
    else:
        history = "\n\n".join(source.text for source in sources)
        mode_instruction = (
            "自由发想模式：当前有效历史不足。可以把上方少量背景用于避免明显冲突，但不得声称承接历史；"
            "每张卡的 history_basis 必须为 null，source_ids 必须为空数组。没有历史、空 Bible 或无人选择都不是失败条件。"
        )
    if title.strip():
        title_context = (
            "# 本章标题（作者已确定，不可改拟）\n"
            + title.strip()
            + "\n所有方向必须围绕该标题呈现的章节可能性；不得另拟、替换或建议新标题。"
        )
    else:
        title_context = "# 本章标题\n（空白；不得替作者拟标题）"
    if pacing_boundary.strip():
        pacing_context = (
            "# 本章推进边界（用户明确，必须遵守）\n"
            + pacing_boundary.strip()
            + "\n这段话限定本章最多推进到哪里。不得把其中的否定、禁止或尚未发生事项误写成实际事件；"
            "每个方向都必须在边界以内收束。"
        )
    else:
        pacing_context = (
            "# 本章推进边界\n（未填写；除非标题或 Bible 明确要求重大跃迁，否则只推进到最小但有意义的新变化，"
            "不得跳过人物关系、认知、冲突或长期主线的中间阶段。）"
        )
    user_message = "\n\n".join(
        [
            title_context,
            "# 当前 Bible 临时快照\n" + (bible.strip() or "（空白）"),
            pacing_context,
            "# 世界观（只读）\n" + (chapter.book.world_setting.strip() or "（暂无）"),
            "# 本章允许人物及章前状态（只读白名单）\n"
            + ("\n\n".join(character_blocks) or "（未选择人物；不得擅自使用本书已有角色）"),
            "# 此前章节有效历史（只读，不授权人物）\n"
            + (history or "（没有可用历史记忆）"),
            "# 内部模式（程序决定）\n" + mode_instruction,
            (
                "# 创作任务\n给出 3 个实质不同的 Bible 灵感方向。当前 Bible 可以为空。"
                "每个 body 必须为 200–300 个去空白字符，目标约 220–280 字；它就是可采用进 Bible 的剧情正文，"
                "不要只给一句抽象梗概，也不要直接代写小说正文。不得靠同义复述、空泛气氛或解释创作意图凑字。"
                "正文要让作者自然看清本章从什么状态开始、事情怎样演变，以及最后停在什么有限的新状态，但不得输出这些栏目。"
                "构思时可以让若干场景自然衔接；场景可以是人物互动、个人动作、内心思考、回忆、梦境、环境或意象的流动。"
                "场景化只是构思方法，不是输出模板：场景数量与形式不固定，允许一个持续的文学性场景，不得输出“场景一／二／三”或套用起因、冲突、转折、结果等固定栏目。"
                "可以给出少量具体动作、感受、画面或关系变化，但不展开完整对白或逐场调度，给作者保留继续创作空间。"
                "人物关系、认知、秘密、冲突和长期主线都不得为了戏剧性跳过中间阶段；除非标题、Bible 或推进边界明确授权重大跃迁，"
                "只选择最小但有意义的变化。body 最后用自然语句写清本章收束到哪里、仍有什么没有说破或解决，为后续保留距离；不得另设“本章终点”等标签。"
                "模型不负责命名方向，JSON 中不要返回 title；服务器会映射固定标签。"
                "200–300 字只计算 body；history_basis 与 note 是不写入 Bible 的可选辅助信息，必须简短。body 只写新的创作建议；"
                "历史中出现但未在白名单中的人物不能因此出现在建议中；若确实需要全新人物，只能在 note 明示“可能需要新增人物”。"
            ),
        ]
    )
    return InspirationContext(
        user_message=user_message,
        source_chapter_indexes=source_manifest,
        known_characters=known_characters,
        selected_character_ids=selected_ids,
        mode=mode,
    )


def _history_sources(db: Session, chapter: Chapter) -> list[InspirationHistorySource]:
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
    sources: list[InspirationHistorySource] = []
    legacy_chapters: list[Chapter] = []
    for item in prior:
        revision = active_archive_revision(db, item)
        if revision is not None:
            if revision.summary.strip():
                sources.append(
                    InspirationHistorySource(
                        id=f"archive_v2:{revision.id}:summary",
                        text=f"第 {item.index} 章摘要：{revision.summary.strip()}",
                        chapter_index=item.index,
                    )
                )
            for fact in revision.facts:
                sources.append(
                    InspirationHistorySource(
                        id=f"archive_v2_fact:{fact.id}",
                        text=f"第 {item.index} 章{fact.fact_type}事实：{fact.fact_text.strip()}",
                        chapter_index=item.index,
                        character_ids=frozenset(participant.character_id for participant in fact.participants),
                    )
                )
            continue
        if not item.legacy_archive_eligible:
            continue
        legacy_chapters.append(item)
        summary = item.long_summary.strip() or item.headline.strip()
        if summary:
            sources.append(
                InspirationHistorySource(
                    id=f"chapter:{item.id}:summary",
                    text=f"第 {item.index} 章摘要：{summary}",
                    chapter_index=item.index,
                )
            )
        for memory_type, label, values in (
            ("state_change", "状态变化", item.state_changes or []),
            ("unresolved_item", "未决事项", item.unresolved_items or []),
            ("atomic_memory", "原子记忆", item.atomic_memories or []),
        ):
            if not isinstance(values, list):
                continue
            for position, value in enumerate(values, start=1):
                if not isinstance(value, dict) or not isinstance(value.get("text"), str):
                    continue
                text = value["text"].strip()
                if not text:
                    continue
                character_id = value.get("character_id")
                sources.append(
                    InspirationHistorySource(
                        id=f"chapter:{item.id}:{memory_type}:{position}",
                        text=f"第 {item.index} 章{label}：{text}",
                        chapter_index=item.index,
                        character_ids=frozenset([character_id]) if isinstance(character_id, str) else frozenset(),
                    )
                )
    if legacy_chapters:
        index_by_id = {item.id: item.index for item in legacy_chapters}
        events = db.scalars(
            select(CharacterEvent)
            .where(CharacterEvent.chapter_id.in_(index_by_id))
            .order_by(CharacterEvent.chapter_id, CharacterEvent.id)
        ).all()
        for event in events:
            if event.event_text.strip():
                sources.append(
                    InspirationHistorySource(
                        id=f"character_event:{event.id}",
                        text=f"第 {index_by_id[event.chapter_id]} 章人物故事线：{event.event_text.strip()}",
                        chapter_index=index_by_id[event.chapter_id],
                        character_ids=frozenset([event.character_id]),
                    )
                )
    return sources


def _rank_and_pack_sources(
    sources: list[InspirationHistorySource],
    *,
    title: str,
    bible: str,
    selected_character_ids: frozenset[str],
) -> list[InspirationHistorySource]:
    keywords = _keywords(normalize_text(f"{title}\n{bible}"))

    def score(source: InspirationHistorySource) -> tuple[int, int, int, str]:
        normalized = normalize_text(source.text)
        character_hit = int(bool(source.character_ids.intersection(selected_character_ids)))
        overlap = sum(1 for keyword in keywords if keyword in normalized)
        return (-character_hit, -overlap, -source.chapter_index, source.id)

    packed: list[InspirationHistorySource] = []
    used = 0
    for source in sorted(sources, key=score):
        if len(packed) >= INSPIRATION_HISTORY_MAX_SOURCES:
            break
        remaining = INSPIRATION_HISTORY_BUDGET_CHARS - used
        if remaining <= 0:
            break
        text = truncate_to_nonspace(source.text, remaining)
        size = nonspace_len(text)
        if not text.strip() or size == 0:
            continue
        packed.append(
            InspirationHistorySource(
                id=source.id,
                text=text,
                chapter_index=source.chapter_index,
                character_ids=source.character_ids,
            )
        )
        used += size
    return packed


def _keywords(text: str) -> set[str]:
    tokens = set(re.findall(r"[A-Za-z0-9_]{2,}|[\u4e00-\u9fff]{2,8}", text))
    for token in tuple(tokens):
        if re.fullmatch(r"[\u4e00-\u9fff]+", token):
            tokens.update(token[index : index + 2] for index in range(max(0, len(token) - 1)))
    return tokens


def _format_fields(fields: dict[str, Any]) -> str:
    if not fields:
        return "（暂无）"
    return json.dumps(fields, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
