from __future__ import annotations

from typing import Any

from app.llm.base import LLMClient
from app.services.personas import compose_system_prompt


def extractor_schema(selected_character_ids: list[str]) -> dict[str, Any]:
    character_id_schema: dict[str, Any] = {"type": "string", "enum": selected_character_ids}
    arrays_extra = {"maxItems": 0} if not selected_character_ids else {}
    archive_item = {
        "type": "object",
        "properties": {
            "text": {"type": "string"},
            "kind": {"type": "string"},
            "character_id": {"anyOf": [character_id_schema, {"type": "null"}]},
        },
        "required": ["text"],
        "additionalProperties": False,
    }
    return {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "headline": {"type": "string"},
        # ``summary`` remains the compact legacy field.  ``long_summary`` is
        # the v1.6 archive used by later memory recall.
        "long_summary": {"type": "string"},
        "state_changes": {"type": "array", "items": archive_item},
        "unresolved_items": {"type": "array", "items": archive_item},
        "atomic_memories": {"type": "array", "items": archive_item},
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
    "required": [
        "summary", "headline", "long_summary", "state_changes", "unresolved_items", "atomic_memories",
        "character_events", "dynamic_fields_patch",
    ],
    "additionalProperties": False,
    }


class ExtractorAgent:
    def __init__(self, llm: LLMClient, editable_persona: str) -> None:
        self.llm = llm
        self.system_prompt = compose_system_prompt("extractor", editable_persona)

    def extract(self, user_message: str, selected_character_ids: list[str] | None = None) -> dict[str, Any]:
        return self.llm.complete_json(
            system=self.system_prompt,
            user=user_message,
            schema=extractor_schema(selected_character_ids or []),
            temperature=0.2,
            timeout=300,
        )
