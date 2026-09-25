from __future__ import annotations

from typing import Any

from app.llm.base import LLMClient
from app.services.personas import compose_system_prompt


CHECKER_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["passed", "suspect", "violation"]},
        "issues": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "kind": {"type": "string"},
                    "draft_evidence": {"type": "string"},
                    "bible_evidence": {"type": "string"},
                    "reason": {"type": "string"},
                    "source_kind": {"type": "string", "enum": ["bible", "world", "character", "prior_state", "history", "draft", "authorization"]},
                    "source_id": {"type": "string"},
                    "source_evidence": {"type": "string"},
                },
                "required": ["kind", "draft_evidence", "bible_evidence", "reason", "source_kind", "source_id", "source_evidence"],
                "additionalProperties": False,
            },
        },
        "name_uses": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "group_id": {"type": "string"},
                    "classification": {"type": "string", "enum": ["character", "ordinary_word", "uncertain"]},
                    "reason": {"type": "string"},
                    "character_id": {"type": "string"},
                },
                "required": [
                    "group_id", "classification", "reason",
                ],
                "additionalProperties": False,
            },
        },
    },
    "required": ["verdict", "issues", "name_uses"],
    "additionalProperties": False,
}


class CheckerAgent:
    """v1.6 Checker foundation; workflow orchestration is introduced in phase 2."""

    def __init__(self, llm: LLMClient, editable_persona: str) -> None:
        self.llm = llm
        self.system_prompt = compose_system_prompt("checker", editable_persona)

    def check(self, user_message: str) -> dict[str, Any]:
        return self.llm.complete_json(
            system=self.system_prompt,
            user=user_message,
            schema=CHECKER_SCHEMA,
            temperature=0.1,
            timeout=180,
        )
