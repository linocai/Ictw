from __future__ import annotations

from copy import deepcopy
from typing import Any

from app.llm.base import LLMClient
from app.services.personas import compose_system_prompt


CANONICAL_DYNAMIC_FIELD_KEYS = (
    "当前位置",
    "当前行动",
    "身体状态",
    "情绪状态",
    "当前目标",
    "掌握信息",
    "秘密状态",
    "其他状态",
)

CANONICAL_EVENT_TYPES = ("经历", "行动", "决定", "关系", "情绪", "认知", "状态")

SelectedCharacter = tuple[str, str]


class ExtractorContractError(ValueError):
    pass


def extractor_schema(selected_character_names: list[str]) -> dict[str, Any]:
    character_name_schema: dict[str, Any] = {"type": "string", "enum": selected_character_names}
    nullable_character_name = {"anyOf": [character_name_schema, {"type": "null"}]}
    arrays_extra = {"maxItems": 0} if not selected_character_names else {}
    archive_item = {
        "type": "object",
        "properties": {
            "text": {"type": "string"},
            "kind": {"type": "string"},
            "character_name": nullable_character_name,
        },
        "required": ["text", "character_name"],
        "additionalProperties": False,
    }
    dynamic_fields = {
        "type": "object",
        "properties": {
            key: {"anyOf": [{"type": "string"}, {"type": "null"}]}
            for key in CANONICAL_DYNAMIC_FIELD_KEYS
        },
        "additionalProperties": False,
    }
    relationship_item = {
        "type": "object",
        "properties": {
            "other_character_name": character_name_schema,
            "status": {"type": "string"},
        },
        "required": ["other_character_name", "status"],
        "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {
            "headline": {"type": "string"},
            # ``long_summary`` is the sole narrative chapter summary.  The legacy
            # ``summary``/synopsis wire field is mirrored by the API, not generated
            # as a second Extractor artifact.
            "long_summary": {"type": "string"},
            "state_changes": {"type": "array", "items": archive_item},
            "unresolved_items": {"type": "array", "items": archive_item},
            "atomic_memories": {"type": "array", "items": archive_item},
            "character_events": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "character_name": character_name_schema,
                        "event_type": {"type": "string", "enum": list(CANONICAL_EVENT_TYPES)},
                        "event_text": {"type": "string"},
                        "evidence": {"type": "string"},
                    },
                    "required": ["character_name", "event_type", "event_text", "evidence"],
                    "additionalProperties": False,
                },
                **arrays_extra,
            },
            "dynamic_fields_patch": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "character_name": character_name_schema,
                        "evidence": {"type": "string"},
                        "fields": dynamic_fields,
                        "relationships": {"type": "array", "items": relationship_item},
                    },
                    "required": ["character_name", "evidence", "fields", "relationships"],
                    "additionalProperties": False,
                },
                **arrays_extra,
            },
        },
        "required": [
            "headline", "long_summary", "state_changes", "unresolved_items", "atomic_memories",
            "character_events", "dynamic_fields_patch",
        ],
        "additionalProperties": False,
    }


def bind_extractor_character_names(
    output: dict[str, Any], selected_characters: list[SelectedCharacter]
) -> dict[str, Any]:
    """Map model-facing names to persisted IDs without letting the model choose UUIDs."""
    if not isinstance(output, dict):
        raise ExtractorContractError("Extractor output must be an object")
    name_to_id: dict[str, str] = {}
    id_to_name: dict[str, str] = {}
    for character_id, name in selected_characters:
        normalized = name.strip()
        if not normalized:
            raise ExtractorContractError("selected character name is empty")
        if normalized in name_to_id and name_to_id[normalized] != character_id:
            raise ExtractorContractError(f"selected character name is ambiguous: {normalized}")
        name_to_id[normalized] = character_id
        id_to_name[character_id] = normalized

    result = deepcopy(output)
    missing = object()

    def bind(item: Any, *, allow_null: bool) -> dict[str, Any]:
        if not isinstance(item, dict):
            raise ExtractorContractError("Extractor character item must be an object")
        name = item.pop("character_name", missing)
        if name is missing:
            raise ExtractorContractError("Extractor character_name is required")
        if name is None and allow_null:
            item["character_id"] = None
            return item
        if not isinstance(name, str) or name not in name_to_id:
            raise ExtractorContractError("Extractor character_name is not in the selected whitelist")
        item["character_id"] = name_to_id[name]
        return item

    for field in ("state_changes", "unresolved_items", "atomic_memories"):
        raw = result.get(field)
        if not isinstance(raw, list):
            raise ExtractorContractError(f"{field} must be an array")
        result[field] = [bind(item, allow_null=True) for item in raw]

    raw_events = result.get("character_events")
    if not isinstance(raw_events, list):
        raise ExtractorContractError("character_events must be an array")
    result["character_events"] = [bind(item, allow_null=False) for item in raw_events]

    raw_patches = result.get("dynamic_fields_patch")
    if not isinstance(raw_patches, list):
        raise ExtractorContractError("dynamic_fields_patch must be an array")
    bound_patches: list[dict[str, Any]] = []
    for raw_item in raw_patches:
        item = bind(raw_item, allow_null=False)
        owner_id = item["character_id"]
        owner_name = id_to_name[owner_id]
        fields = item.get("fields")
        relationships = item.pop("relationships", None)
        if not isinstance(fields, dict) or not isinstance(relationships, list):
            raise ExtractorContractError("dynamic fields and relationships must use the fixed structure")
        for relationship in relationships:
            if not isinstance(relationship, dict):
                raise ExtractorContractError("relationship update must be an object")
            other_name = relationship.get("other_character_name")
            status = relationship.get("status")
            if not isinstance(other_name, str) or other_name not in name_to_id or other_name == owner_name:
                raise ExtractorContractError("relationship target must be another selected character")
            if not isinstance(status, str) or not status.strip():
                raise ExtractorContractError("relationship status is required")
            fields[f"与{other_name}关系"] = status.strip()
        item["fields"] = fields
        bound_patches.append(item)
    result["dynamic_fields_patch"] = bound_patches
    return result


class ExtractorAgent:
    def __init__(self, llm: LLMClient, editable_persona: str) -> None:
        self.llm = llm
        self.system_prompt = compose_system_prompt("extractor", editable_persona)

    def extract(
        self, user_message: str, selected_characters: list[SelectedCharacter] | None = None
    ) -> dict[str, Any]:
        selected = selected_characters or []
        names = [name.strip() for _, name in selected]
        if any(not name for name in names) or len(set(names)) != len(names):
            raise ExtractorContractError("selected character names must be non-empty and unique")
        output = self.llm.complete_json(
            system=self.system_prompt,
            user=user_message,
            schema=extractor_schema(names),
            temperature=0.2,
            timeout=300,
        )
        return bind_extractor_character_names(output, selected)
