from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from app.llm.base import LLMClient, LLMError
from app.services.context import (
    MAX_MEMORY_BRIEFS,
    MAX_MEMORY_CONFLICTS,
    MAX_MEMORY_SOURCES,
    MAX_SOURCES_PER_BRIEF,
)
from app.services.personas import compose_system_prompt


MEMORY_SELECTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "briefs": {
            "type": "array",
            "maxItems": MAX_MEMORY_BRIEFS,
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "source_ids": {"type": "array", "maxItems": MAX_SOURCES_PER_BRIEF, "items": {"type": "string"}}},
                "required": ["text", "source_ids"],
                "additionalProperties": False,
            },
        },
        "conflicts": {
            "type": "array",
            "maxItems": MAX_MEMORY_CONFLICTS,
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "source_ids": {"type": "array", "maxItems": MAX_SOURCES_PER_BRIEF, "items": {"type": "string"}}},
                "required": ["text", "source_ids"],
                "additionalProperties": False,
            },
        },
        "previous_ending_start_id": {"type": ["string", "null"]},
    },
    "required": ["briefs", "conflicts", "previous_ending_start_id"],
    "additionalProperties": False,
}

MEMORY_SELECTION_FIXED_CONTRACT = (
    "固定输出协议：每条 briefs/conflicts 必须含 text 与非空 source_ids，还必须根据用户消息中的紧邻上一章结尾候选，"
    "返回 previous_ending_start_id（满足开场衔接所需的最短原文片段起点 ID；无候选时为 null）。"
    "只能复制候选 ID；允许压缩和合并候选历史的既有事实，但不得改写 Bible、补造历史、推断动机或添加因果。"
    f"briefs 最多 {MAX_MEMORY_BRIEFS} 条，conflicts 最多 {MAX_MEMORY_CONFLICTS} 条，合计最多引用 {MAX_MEMORY_SOURCES} 个不同来源，"
    f"每条最多 {MAX_SOURCES_PER_BRIEF} 个来源。只选择缺失后可能导致本章违背 Bible、人物状态或连续性的事实；"
    "禁止逐章回顾、禁止一章一条，相关来源必须合并。输出按本章重要性排序；没有直接相关历史时允许空数组。"
)


@dataclass(frozen=True)
class MemorySelection:
    briefs: list[dict[str, Any]]
    conflicts: list[dict[str, Any]]
    previous_ending_start_id: str | None = None


class MemorySelectorAgent:
    def __init__(self, llm: LLMClient, editable_persona: str) -> None:
        self.llm = llm
        self.system_prompt = compose_system_prompt("memory_selector", editable_persona)

    def select(
        self,
        user_message: str,
        *,
        validator: Callable[[MemorySelection], str | None] | None = None,
    ) -> MemorySelection:
        correction = ""
        for attempt in range(2):
            try:
                output = self.llm.complete_json(
                    # This contract is deliberately appended in code rather than
                    # living only in DEFAULT_PERSONAS: production personas are
                    # user-editable and existing rows are never overwritten by
                    # seed_defaults during an upgrade.
                    system=f"{self.system_prompt}\n\n{MEMORY_SELECTION_FIXED_CONTRACT}",
                    user=user_message + correction,
                    schema=MEMORY_SELECTION_SCHEMA,
                    temperature=0.1,
                    timeout=180,
                )
                briefs = output.get("briefs")
                conflicts = output.get("conflicts")
                start_id = output.get("previous_ending_start_id")
                selection = MemorySelection(
                    briefs=briefs if isinstance(briefs, list) else [],
                    conflicts=conflicts if isinstance(conflicts, list) else [],
                    # Keep ID tokens verbatim for the shared strict validator.
                    # Whitespace is a malformed source ID, not harmless prose
                    # normalization; it gets the same one correction chance as
                    # every other bad ID.
                    previous_ending_start_id=start_id if isinstance(start_id, str) and start_id else None,
                )
                problem = _selection_limit_problem(briefs, conflicts)
                if problem is None and isinstance(start_id, str) and start_id != start_id.strip():
                    problem = "上一章结尾起点 ID 含前后空白，必须原样复制"
                if problem is None and validator is not None:
                    problem = validator(selection)
                if problem:
                    if attempt == 0:
                        correction = (
                            "\n\n# 程序退回\n上一次输出未通过选择规模校验："
                            + problem
                            + "。请重新选择真正约束本章的少量历史，并合并同类来源；不要逐章复述。"
                        )
                        continue
                    raise LLMError(
                        f"Memory Selector 两次输出均未通过规模校验：{problem}",
                        code="memory_selection_invalid",
                        retryable=False,
                    )
                return selection
            except LLMError as exc:
                if attempt == 0 and exc.retryable:
                    continue
                raise
        raise RuntimeError("memory selector failed")


def _selection_limit_problem(briefs: Any, conflicts: Any) -> str | None:
    if not isinstance(briefs, list) or not isinstance(conflicts, list):
        return "briefs 与 conflicts 必须都是数组"
    if len(briefs) > MAX_MEMORY_BRIEFS:
        return f"简报 {len(briefs)} 条，超过 {MAX_MEMORY_BRIEFS} 条"
    if len(conflicts) > MAX_MEMORY_CONFLICTS:
        return f"冲突 {len(conflicts)} 条，超过 {MAX_MEMORY_CONFLICTS} 条"
    unique_sources: set[str] = set()
    for item in briefs + conflicts:
        if not isinstance(item, dict):
            return "每条简报或冲突必须是对象"
        source_ids = item.get("source_ids")
        text = item.get("text")
        if not isinstance(text, str) or not text.strip() or not isinstance(source_ids, list) or not source_ids:
            return "每条简报或冲突必须含非空 text 与 source_ids"
        ids = {value.strip() for value in source_ids if isinstance(value, str) and value.strip()}
        if len(ids) != len(source_ids):
            return "来源 ID 必须为非空且不得重复"
        if len(ids) > MAX_SOURCES_PER_BRIEF:
            return f"单条引用 {len(ids)} 个来源，超过 {MAX_SOURCES_PER_BRIEF} 个"
        unique_sources.update(ids)
    if len(unique_sources) > MAX_MEMORY_SOURCES:
        return f"合计引用 {len(unique_sources)} 个来源，超过 {MAX_MEMORY_SOURCES} 个"
    return None
