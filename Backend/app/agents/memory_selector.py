from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from app.llm.base import LLMClient, LLMError
from app.services.personas import compose_system_prompt


MEMORY_SELECTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "briefs": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "source_ids": {"type": "array", "items": {"type": "string"}}},
                "required": ["text", "source_ids"],
                "additionalProperties": False,
            },
        },
        "conflicts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"text": {"type": "string"}, "source_ids": {"type": "array", "items": {"type": "string"}}},
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

    def select(self, user_message: str) -> MemorySelection:
        for attempt in range(2):
            try:
                output = self.llm.complete_json(
                    # This contract is deliberately appended in code rather than
                    # living only in DEFAULT_PERSONAS: production personas are
                    # user-editable and existing rows are never overwritten by
                    # seed_defaults during an upgrade.
                    system=f"{self.system_prompt}\n\n{MEMORY_SELECTION_FIXED_CONTRACT}",
                    user=user_message,
                    schema=MEMORY_SELECTION_SCHEMA,
                    temperature=0.1,
                    timeout=180,
                )
                briefs = output.get("briefs") if isinstance(output.get("briefs"), list) else []
                conflicts = output.get("conflicts") if isinstance(output.get("conflicts"), list) else []
                start_id = output.get("previous_ending_start_id")
                return MemorySelection(
                    briefs=[item for item in briefs if isinstance(item, dict)],
                    conflicts=[item for item in conflicts if isinstance(item, dict)],
                    previous_ending_start_id=start_id.strip() if isinstance(start_id, str) and start_id.strip() else None,
                )
            except LLMError as exc:
                if attempt == 0 and exc.retryable:
                    continue
                raise
        raise RuntimeError("memory selector failed")
