from __future__ import annotations

from copy import deepcopy
from typing import Any

from app.llm.base import LLMClient
from app.services.character_state_projection import PERSISTENT_SLOTS, SNAPSHOT_SLOTS
from app.services.archive_v2 import (
    FACT_TYPES,
    MAX_FACTS,
    MAX_FACT_REF_CHARS,
    MAX_FACT_TEXT_CHARS,
    MAX_STATE_DELTAS,
    MAX_STATE_VALUE_CHARS,
    MAX_SUMMARY_CHARS,
    RECOMMENDED_FACT_SPAN_SENTENCES,
)
from app.services.personas import compose_system_prompt


CANONICAL_EVENT_TYPES = ("经历", "行动", "决定", "关系", "情绪", "认知", "状态")
CHARACTER_EVENT_MAX_PER_CHARACTER = 3
CHARACTER_EVENT_MAX_TOTAL = 8
EXTRACTOR_TIMEOUT_SECONDS = 120
EXTRACTOR_MAX_OUTPUT_TOKENS = 8192
SelectedCharacter = tuple[str, str]


class ExtractorContractError(ValueError):
    pass


def extractor_v2_schema(selected_character_names: list[str]) -> dict[str, Any]:
    """Single-call v2 ledger contract; evidence is represented by source IDs."""
    name = {"type": "string", "enum": selected_character_names}
    participant_array: dict[str, Any] = {
        "type": "array",
        "items": name,
        "uniqueItems": True,
        "maxItems": min(4, len(selected_character_names)),
    }
    fact = {
        "type": "object",
        "description": (
            f"一个事实及其最小充分证据区间；start_id 到 end_id 必须是正文中已有的连续句子编号，"
            f"首尾均计入，优先不超过 {RECOMMENDED_FACT_SPAN_SENTENCES} 句；确需更多时仍必须使用最小充分连续区间。"
        ),
        "properties": {
            "fact_ref": {
                "type": "string",
                "minLength": 1,
                "maxLength": MAX_FACT_REF_CHARS,
                "description": "本次输出内唯一的临时事实引用；建议依次使用 F1、F2……，后端会机械归一化。",
            },
            "type": {"type": "string", "enum": list(FACT_TYPES)},
            "importance": {"type": "integer", "minimum": 1, "maximum": 3},
            "text": {"type": "string", "minLength": 1, "maxLength": MAX_FACT_TEXT_CHARS},
            "participant_names": participant_array,
            "start_id": {
                "type": "string",
                "description": (
                    f"正文中已有的起始句子编号；与 end_id 组成最小充分连续区间，"
                    f"优先不超过 {RECOMMENDED_FACT_SPAN_SENTENCES} 句。"
                ),
            },
            "end_id": {
                "type": "string",
                "description": (
                    f"正文中已有的结束句子编号；与 start_id 组成最小充分连续区间，"
                    f"优先不超过 {RECOMMENDED_FACT_SPAN_SENTENCES} 句。"
                ),
            },
        },
        "required": [
            "fact_ref", "type", "importance", "text", "participant_names", "start_id", "end_id"
        ],
        "additionalProperties": False,
    }
    common_delta_properties = {
        "fact_ref": {
            "type": "string",
            "minLength": 1,
            "maxLength": MAX_FACT_REF_CHARS,
            "description": "必须精确引用 facts 中某条事实的临时 fact_ref。",
        },
        "operation": {"type": "string", "enum": ["set", "clear"]},
        "value": {
            "anyOf": [
                {"type": "string", "minLength": 1, "maxLength": MAX_STATE_VALUE_CHARS},
                {"type": "null"},
            ]
        },
    }
    character_delta = {
        "type": "object",
        "description": "单个人物的章末净状态变化；character_name 必须参与所引用的 fact。",
        "properties": {
            **common_delta_properties,
            "character_name": name,
            "slot": {
                "type": "string",
                "enum": [*SNAPSHOT_SLOTS, *PERSISTENT_SLOTS],
                "description": (
                    "后端由 slot 机械确定状态类别；当前位置、当前行动、情绪状态可只输出实际变化项，"
                    "身体状态、当前目标、秘密状态为持续状态。"
                ),
            },
        },
        "required": ["fact_ref", "character_name", "slot", "operation", "value"],
        "additionalProperties": False,
    }
    relationship_delta = {
        "type": "object",
        "description": (
            "两个人物的关系净变化。所引用 fact 的 participant_names 必须恰好两人；"
            "不要重复输出 character_name 或 other_character_name，后端会从 fact 机械推导双方。"
        ),
        "properties": {
            **common_delta_properties,
            "slot": {"type": "string", "enum": ["relationship"]},
        },
        "required": ["fact_ref", "slot", "operation", "value"],
        "additionalProperties": False,
    }
    delta = {"oneOf": [character_delta, relationship_delta]}
    empty_when_no_characters = {"maxItems": 0} if not selected_character_names else {}
    return {
        "type": "object",
        "properties": {
            "summary": {"type": "string", "minLength": 1, "maxLength": MAX_SUMMARY_CHARS},
            "facts": {"type": "array", "items": fact, "maxItems": MAX_FACTS},
            "end_state_delta": {
                "type": "array",
                "items": delta,
                "maxItems": min(MAX_STATE_DELTAS, MAX_STATE_DELTAS if selected_character_names else 0),
                **empty_when_no_characters,
            },
        },
        "required": ["summary", "facts", "end_state_delta"],
        "additionalProperties": False,
    }


def _operation_schema() -> dict[str, Any]:
    return {
        "type": "object",
        "properties": {
            "operation": {"type": "string", "enum": ["set", "clear"]},
            "value": {"anyOf": [{"type": "string"}, {"type": "null"}]},
            "evidence": {"type": "string"},
        },
        "required": ["operation", "value", "evidence"],
        "additionalProperties": False,
    }


def _character_events_schema(selected_character_names: list[str]) -> dict[str, Any]:
    name = {"type": "string", "enum": selected_character_names}
    maximum = min(
        CHARACTER_EVENT_MAX_TOTAL,
        len(selected_character_names) * CHARACTER_EVENT_MAX_PER_CHARACTER,
    )
    return {
        "type": "array",
        "description": (
            "按重要性从高到低排列，只记录改变人物故事线、关系、认知、决定或持续状态的关键节点；"
            "普通动作、对白和同一事实的重复表述不得建事件。"
        ),
        "items": {
            "type": "object",
            "properties": {
                "character_name": name,
                "event_type": {"type": "string", "enum": list(CANONICAL_EVENT_TYPES)},
                "event_text": {"type": "string"},
                "evidence": {"type": "string"},
            },
            "required": ["character_name", "event_type", "event_text", "evidence"],
            "additionalProperties": False,
        },
        "maxItems": maximum,
    }


def extractor_schema(selected_character_names: list[str]) -> dict[str, Any]:
    name = {"type": "string", "enum": selected_character_names}
    nullable_name = {"anyOf": [name, {"type": "null"}]}
    arrays_extra = {"maxItems": 0} if not selected_character_names else {}
    archive_item = {
        "type": "object",
        "properties": {"text": {"type": "string"}, "kind": {"type": "string"}, "character_name": nullable_name},
        "required": ["text", "character_name"], "additionalProperties": False,
    }
    snapshot = {
        "type": "object",
        "properties": {
            "presence_evidence": {"type": "string"},
            "当前位置": _operation_schema(), "当前行动": _operation_schema(), "情绪状态": _operation_schema(),
        },
        "required": ["presence_evidence", *SNAPSHOT_SLOTS], "additionalProperties": False,
    }
    persistent_op = {
        "type": "object",
        "properties": {"slot": {"type": "string", "enum": list(PERSISTENT_SLOTS)}, **_operation_schema()["properties"]},
        "required": ["slot", "operation", "value", "evidence"], "additionalProperties": False,
    }
    relationship_op = {
        "type": "object",
        "description": (
            "无向人物关系。同一人物对在整份 state_updates 中只能出现一次，"
            "并归到人物白名单顺序更靠前的一方；value 描述双方共同关系，不写各自视角。"
        ),
        "properties": {"other_character_name": name, **_operation_schema()["properties"]},
        "required": ["other_character_name", "operation", "value", "evidence"], "additionalProperties": False,
    }
    state_update = {
        "type": "object",
        "properties": {
            "character_name": name,
            "snapshot": {"anyOf": [snapshot, {"type": "null"}]},
            "persistent_ops": {"type": "array", "items": persistent_op},
            "relationship_ops": {"type": "array", "items": relationship_op},
        },
        "required": ["character_name", "snapshot", "persistent_ops", "relationship_ops"], "additionalProperties": False,
    }
    return {
        "type": "object",
        "properties": {
            "headline": {"type": "string"}, "long_summary": {"type": "string"},
            "state_changes": {"type": "array", "items": archive_item},
            "unresolved_items": {"type": "array", "items": archive_item},
            "atomic_memories": {"type": "array", "items": archive_item},
            "character_events": _character_events_schema(selected_character_names),
            "state_updates": {"type": "array", "items": state_update, **arrays_extra},
        },
        "required": ["headline", "long_summary", "state_changes", "unresolved_items", "atomic_memories", "character_events", "state_updates"],
        "additionalProperties": False,
    }


def extractor_state_rebuild_schema(selected_character_names: list[str]) -> dict[str, Any]:
    """Narrow offline-rebuild contract: existing archives/events stay untouched."""
    state_updates = extractor_schema(selected_character_names)["properties"]["state_updates"]
    return {
        "type": "object",
        "properties": {"state_updates": state_updates},
        "required": ["state_updates"],
        "additionalProperties": False,
    }


def _legacy_updates(result: dict[str, Any]) -> list[dict[str, Any]]:
    """Read old in-flight payloads without preserving their merge semantics.

    This is deliberately an input adapter only: v1.7.2 schemas/prompts never
    request ``dynamic_fields_patch`` and the persistence layer never writes it.
    """
    updates: list[dict[str, Any]] = []
    for patch in result.pop("dynamic_fields_patch", []) or []:
        if not isinstance(patch, dict):
            continue
        fields = patch.pop("fields", {})
        evidence = patch.pop("evidence", "")
        relationships = patch.pop("relationships", [])
        snapshot = None
        if any(slot in fields for slot in SNAPSHOT_SLOTS):
            snapshot = {"presence_evidence": evidence}
            for slot in SNAPSHOT_SLOTS:
                value = fields.get(slot)
                snapshot[slot] = {"operation": "set" if value else "clear", "value": value, "evidence": evidence}
        persistent_ops = [
            {"slot": slot, "operation": "set" if value else "clear", "value": value, "evidence": evidence}
            for slot, value in fields.items() if slot in PERSISTENT_SLOTS
        ]
        relationship_ops = [
            {"other_character_name": item.get("other_character_name"), "operation": "set", "value": item.get("status"), "evidence": evidence}
            for item in relationships if isinstance(item, dict)
        ]
        updates.append({"character_name": patch.get("character_name"), "snapshot": snapshot, "persistent_ops": persistent_ops, "relationship_ops": relationship_ops})
    return updates


def bind_extractor_character_names(
    output: dict[str, Any],
    selected_characters: list[SelectedCharacter],
    *,
    drop_conflicting_relationships: bool = False,
) -> dict[str, Any]:
    """Map model-facing names to persisted IDs without exposing UUIDs to it."""
    if not isinstance(output, dict):
        raise ExtractorContractError("Extractor output must be an object")
    name_to_id: dict[str, str] = {}
    id_to_name: dict[str, str] = {}
    for character_id, raw_name in selected_characters:
        name = raw_name.strip()
        if not name:
            raise ExtractorContractError("selected character name is empty")
        if name in name_to_id and name_to_id[name] != character_id:
            raise ExtractorContractError(f"selected character name is ambiguous: {name}")
        name_to_id[name], id_to_name[character_id] = character_id, name
    result = deepcopy(output)
    if "state_updates" not in result and "dynamic_fields_patch" in result:
        result["state_updates"] = _legacy_updates(result)
        result["_legacy_state_adapter"] = True
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
    raw_updates = result.get("state_updates")
    if not isinstance(raw_updates, list):
        raise ExtractorContractError("state_updates must be an array")
    bound: list[dict[str, Any]] = []
    seen_relationships: dict[
        tuple[str, str], tuple[tuple[Any, Any], list[dict[str, Any]], dict[str, Any]]
    ] = {}
    conflicted_relationships: set[tuple[str, str]] = set()
    for raw in raw_updates:
        item = bind(raw, allow_null=False)
        relationship_ops = item.get("relationship_ops")
        if not isinstance(relationship_ops, list):
            relationship_ops = []
        filtered_relationship_ops: list[dict[str, Any]] = []
        for operation in relationship_ops:
            if not isinstance(operation, dict):
                raise ExtractorContractError("relationship operation must be an object")
            other = operation.pop("other_character_name", None)
            if not isinstance(other, str) or other not in name_to_id or other == id_to_name[item["character_id"]]:
                raise ExtractorContractError("relationship target must be another selected character")
            operation["other_character_id"] = name_to_id[other]
            pair = tuple(sorted((item["character_id"], operation["other_character_id"])))
            if pair in conflicted_relationships:
                continue
            signature = (operation.get("operation"), operation.get("value"))
            previous = seen_relationships.get(pair)
            if previous is not None:
                # Old clients emitted mirrored relationship fields.  New model
                # output may still repeat the exact same undirected fact; that
                # is safe to canonicalize once.  Different values remain a hard
                # conflict and must be corrected by Extractor.
                previous_signature, previous_container, previous_operation = previous
                if result.get("_legacy_state_adapter") or previous_signature == signature:
                    continue
                if drop_conflicting_relationships:
                    previous_container.remove(previous_operation)
                    conflicted_relationships.add(pair)
                    seen_relationships.pop(pair, None)
                    continue
                raise ExtractorContractError("relationship pair has conflicting duplicate updates")
            filtered_relationship_ops.append(operation)
            seen_relationships[pair] = (signature, filtered_relationship_ops, operation)
        item["relationship_ops"] = filtered_relationship_ops
        bound.append(item)
    result["state_updates"] = bound
    result.pop("_legacy_state_adapter", None)
    return result


class ExtractorAgent:
    def __init__(self, llm: LLMClient, editable_persona: str) -> None:
        self.llm = llm
        self.system_prompt = compose_system_prompt("extractor", editable_persona)

    def extract_v2(
        self, user_message: str, selected_characters: list[SelectedCharacter] | None = None
    ) -> dict[str, Any]:
        selected = selected_characters or []
        names = [name.strip() for _, name in selected]
        if any(not name for name in names) or len(set(names)) != len(names):
            raise ExtractorContractError("selected character names must be non-empty and unique")
        return self.llm.complete_json(
            system=self.system_prompt,
            user=user_message,
            schema=extractor_v2_schema(names),
            temperature=0.1,
            timeout=EXTRACTOR_TIMEOUT_SECONDS,
            hard_timeout=True,
            max_tokens=EXTRACTOR_MAX_OUTPUT_TOKENS,
        )

    def extract_state_updates(
        self, user_message: str, selected_characters: list[SelectedCharacter] | None = None
    ) -> dict[str, Any]:
        """Extract only replayable state for the offline v1.7.2 rebuild."""
        selected = selected_characters or []
        names = [name.strip() for _, name in selected]
        if any(not name for name in names) or len(set(names)) != len(names):
            raise ExtractorContractError("selected character names must be non-empty and unique")
        output = self.llm.complete_json(
            system=(
                self.system_prompt
                + "\n\n本次是离线当前状态重建：只输出 state_updates。"
                "既有人物事件、摘要和章节归档全部保留，不得重新生成。"
            ),
            user=(
                "# 本次唯一输出\n只从最终接受正文提取 state_updates；不得输出 headline、摘要、"
                "人物事件或其他归档字段。\n\n" + user_message
            ),
            schema=extractor_state_rebuild_schema(names),
            temperature=0.2,
            timeout=EXTRACTOR_TIMEOUT_SECONDS,
            hard_timeout=True,
            max_tokens=EXTRACTOR_MAX_OUTPUT_TOKENS,
        )
        wrapped = {
            "headline": "state-rebuild",
            "long_summary": "state-rebuild",
            "state_changes": [],
            "unresolved_items": [],
            "atomic_memories": [],
            "character_events": [],
            "state_updates": output.get("state_updates"),
        }
        bound = bind_extractor_character_names(
            wrapped, selected, drop_conflicting_relationships=True
        )
        return {"state_updates": bound["state_updates"]}
