from __future__ import annotations

from typing import Any

from app.llm.base import LLMClient, LLMError


MEMORY_SELECTION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {"memory_ids": {"type": "array", "items": {"type": "string"}}},
    "required": ["memory_ids"],
    "additionalProperties": False,
}


class MemorySelectorAgent:
    def __init__(self, llm: LLMClient, system_prompt: str) -> None:
        self.llm = llm
        self.system_prompt = system_prompt

    def select(self, user_message: str) -> list[str]:
        for attempt in range(2):
            try:
                output = self.llm.complete_json(
                    system=self.system_prompt,
                    user=user_message,
                    schema=MEMORY_SELECTION_SCHEMA,
                    temperature=0.1,
                    timeout=180,
                )
                ids = output.get("memory_ids")
                if not isinstance(ids, list) or any(not isinstance(item, str) for item in ids):
                    raise ValueError("memory selector returned invalid JSON payload")
                return ids
            except LLMError as exc:
                if attempt == 0 and exc.retryable:
                    continue
                raise
        raise RuntimeError("memory selector failed")
