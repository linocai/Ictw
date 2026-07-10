from __future__ import annotations

from typing import Any

from app.llm.base import LLMClient


def extractor_schema(selected_character_ids: list[str]) -> dict[str, Any]:
    character_id_schema: dict[str, Any] = {"type": "string", "enum": selected_character_ids}
    arrays_extra = {"maxItems": 0} if not selected_character_ids else {}
    return {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "headline": {"type": "string"},
        "character_events": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "character_id": character_id_schema,
                    "event_type": {"type": "string"},
                    "event_text": {"type": "string"},
                },
                "required": ["character_id", "event_text"],
            },
            **arrays_extra,
        },
        "dynamic_fields_patch": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "character_id": character_id_schema,
                    "fields": {"type": "object"},
                },
                "required": ["character_id", "fields"],
            },
            **arrays_extra,
        },
    },
    "required": ["summary", "headline", "character_events", "dynamic_fields_patch"],
    }


class ExtractorAgent:
    def __init__(self, llm: LLMClient, system_prompt: str) -> None:
        self.llm = llm
        self.system_prompt = system_prompt

    def extract(self, user_message: str, selected_character_ids: list[str] | None = None) -> dict[str, Any]:
        return self.llm.complete_json(
            system=self.system_prompt,
            user=user_message,
            schema=extractor_schema(selected_character_ids or []),
            temperature=0.2,
            timeout=300,
        )
