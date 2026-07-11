from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from app.llm.base import LLMClient, LLMError


MEMORY_SELECTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "memory_ids": {"type": "array", "items": {"type": "string"}},
        "previous_ending_start_id": {"type": ["string", "null"]},
    },
    "required": ["memory_ids"],
    "additionalProperties": False,
}

MEMORY_SELECTION_FIXED_CONTRACT = (
    "固定输出协议：除有序 memory_ids 外，还必须根据用户消息中的紧邻上一章结尾候选，"
    "返回 previous_ending_start_id（满足开场衔接所需的最短原文片段起点 ID；无候选时为 null）。"
    "只能复制候选 ID，不得改写、概括或补造历史。"
)


@dataclass(frozen=True)
class MemorySelection:
    memory_ids: list[str]
    previous_ending_start_id: str | None = None


class MemorySelectorAgent:
    def __init__(self, llm: LLMClient, system_prompt: str) -> None:
        self.llm = llm
        self.system_prompt = system_prompt

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
                ids = output.get("memory_ids")
                # Malformed shapes degrade to "fewer/no memories" instead of
                # failing the whole write: an empty selection is a legal outcome,
                # and pack_selected_memories re-validates every id anyway.
                if isinstance(ids, str):
                    ids = [ids]
                if not isinstance(ids, list):
                    ids = []
                start_id = output.get("previous_ending_start_id")
                return MemorySelection(
                    memory_ids=[item for item in ids if isinstance(item, str)],
                    previous_ending_start_id=start_id.strip() if isinstance(start_id, str) and start_id.strip() else None,
                )
            except LLMError as exc:
                if attempt == 0 and exc.retryable:
                    continue
                raise
        raise RuntimeError("memory selector failed")
