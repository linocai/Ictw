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
                # Malformed shapes degrade to "fewer/no memories" instead of
                # failing the whole write: an empty selection is a legal outcome,
                # and pack_selected_memories re-validates every id anyway.
                if isinstance(ids, str):
                    ids = [ids]
                if not isinstance(ids, list):
                    return []
                return [item for item in ids if isinstance(item, str)]
            except LLMError as exc:
                if attempt == 0 and exc.retryable:
                    continue
                raise
        raise RuntimeError("memory selector failed")
