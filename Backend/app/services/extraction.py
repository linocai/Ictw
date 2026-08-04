from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
from typing import Any

from sqlalchemy import delete
from sqlalchemy.orm import Session

from app.agents.extractor import CANONICAL_EVENT_TYPES
from app.models import Chapter, Character, CharacterEvent, CharacterStateChange
from app.models.entities import uuid_str
from app.services.character_state_projection import PERSISTENT_SLOTS, SNAPSHOT_SLOTS, rebuild_book_projection
from app.services.context import CHARACTER_EVENT_MAX_CHARS, normalize_text, truncate_to_nonspace


class ExtractorValidationError(ValueError):
    pass


class UnselectedCharacterReference(ExtractorValidationError):
    """Compatibility import for callers that used the v1 exception type."""


ARCHIVE_LIST_FIELDS = ("state_changes", "unresolved_items", "atomic_memories")
_FORBIDDEN_VALUE_PARTS = ("未知", "未明确", "不明确", "暂无", "无从得知", "待定")


@dataclass(frozen=True)
class ValidatedStateChange:
    character_id: str
    other_character_id: str | None
    scope: str
    slot: str
    operation: str
    value: str | None
    evidence: str
    batch_id: str


@dataclass(frozen=True)
class ValidatedExtractorOutput:
    headline: str
    long_summary: str
    archive_values: dict[str, list[dict[str, str]]]
    events: list[tuple[str, str, str]]
    state_changes: list[ValidatedStateChange]

    @property
    def patches_by_character(self) -> dict[str, dict[str, str | None]]:
        """Read-only transition helper; no caller may use it to merge state."""
        return {}


def _validated_archive_items(raw: Any, *, field: str, character_map: dict[str, Character]) -> list[dict[str, str]]:
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ExtractorValidationError(f"{field} must be an array")
    result: list[dict[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            raise ExtractorValidationError(f"{field} item must be an object")
        character_id = item.get("character_id")
        if character_id is not None and (not isinstance(character_id, str) or character_id not in character_map):
            raise UnselectedCharacterReference(f"{field} references an unselected character")
        text = item.get("text")
        if not isinstance(text, str) or not text.strip():
            raise ExtractorValidationError(f"{field} item text is required")
        if isinstance(character_id, str) and normalize_text(character_map[character_id].name) not in normalize_text(text):
            raise ExtractorValidationError(f"{field} character attribution must name its owner")
        kind = item.get("kind")
        if kind is not None and not isinstance(kind, str):
            raise ExtractorValidationError(f"{field} item kind must be a string")
        normalized: dict[str, str] = {"text": text.strip()}
        if isinstance(kind, str) and kind.strip():
            normalized["kind"] = kind.strip()
        if isinstance(character_id, str):
            normalized["character_id"] = character_id
        result.append(normalized)
    return result


def _validated_evidence(chapter: Chapter, character: Character, raw: Any, *, field: str) -> str:
    if not isinstance(raw, str) or not raw.strip():
        raise ExtractorValidationError(f"{field} evidence is required")
    evidence = raw.strip()
    normalized_evidence = "".join(normalize_text(evidence).split())
    normalized_draft = "".join(normalize_text(chapter.draft_text).split())
    match_start = normalized_draft.find(normalized_evidence)
    match_size = len(normalized_evidence)
    if match_start < 0:
        longest = SequenceMatcher(None, normalized_evidence, normalized_draft, autojunk=False).find_longest_match()
        minimum = max(8, min(16, len(normalized_evidence) // 3))
        if longest.size < minimum:
            raise ExtractorValidationError(f"{field} evidence lacks a substantial literal draft excerpt")
        match_start, match_size = longest.b, longest.size
    owner = "".join(normalize_text(character.name).split())
    if owner not in normalized_evidence and owner not in normalized_draft[max(0, match_start - 96):match_start]:
        raise ExtractorValidationError(f"{field} evidence context must identify its owner")
    return evidence


def _validated_operation(
    chapter: Chapter, owner: Character, raw: Any, *, field: str
) -> tuple[str, str | None, str]:
    if not isinstance(raw, dict):
        raise ExtractorValidationError(f"{field} must be an object")
    operation = raw.get("operation")
    value = raw.get("value")
    if operation not in {"set", "clear"}:
        raise ExtractorValidationError(f"{field} operation must be set or clear")
    if operation == "set":
        if not isinstance(value, str) or not value.strip():
            raise ExtractorValidationError(f"{field} set value is required")
        value = value.strip()
        if any(part in value for part in _FORBIDDEN_VALUE_PARTS):
            raise ExtractorValidationError(f"{field} value cannot be unknown or unspecified")
        if field.startswith("snapshot") and ("先" in value and "后" in value):
            raise ExtractorValidationError("snapshot value must describe chapter ending only")
    elif value is not None:
        raise ExtractorValidationError(f"{field} clear value must be null")
    return operation, value, _validated_evidence(chapter, owner, raw.get("evidence"), field=field)


def _validated_state_updates(chapter: Chapter, raw: Any, character_map: dict[str, Character]) -> list[ValidatedStateChange]:
    if not isinstance(raw, list):
        raise ExtractorValidationError("state_updates must be an array")
    result: list[ValidatedStateChange] = []
    snapshots: set[str] = set()
    persistent: set[tuple[str, str]] = set()
    relationships: set[tuple[str, str]] = set()
    for item in raw:
        if not isinstance(item, dict):
            raise ExtractorValidationError("state_updates item must be an object")
        character_id = item.get("character_id")
        if not isinstance(character_id, str) or character_id not in character_map:
            raise UnselectedCharacterReference("state_updates references an unselected character")
        owner = character_map[character_id]
        snapshot = item.get("snapshot")
        if snapshot is not None:
            if character_id in snapshots:
                raise ExtractorValidationError("duplicate character snapshot")
            if not isinstance(snapshot, dict) or set(snapshot) != {"presence_evidence", *SNAPSHOT_SLOTS}:
                raise ExtractorValidationError("snapshot must contain all three current-state slots")
            _validated_evidence(chapter, owner, snapshot.get("presence_evidence"), field="snapshot presence")
            snapshots.add(character_id)
            batch_id = uuid_str()
            for slot in SNAPSHOT_SLOTS:
                operation, value, evidence = _validated_operation(chapter, owner, snapshot[slot], field=f"snapshot {slot}")
                result.append(ValidatedStateChange(character_id, None, "snapshot", slot, operation, value, evidence, batch_id))
        raw_persistent = item.get("persistent_ops")
        if not isinstance(raw_persistent, list):
            raise ExtractorValidationError("persistent_ops must be an array")
        for op in raw_persistent:
            if not isinstance(op, dict) or op.get("slot") not in PERSISTENT_SLOTS:
                raise ExtractorValidationError("persistent operation has unsupported slot")
            key = (character_id, op["slot"])
            if key in persistent:
                raise ExtractorValidationError("duplicate persistent state slot")
            persistent.add(key)
            operation, value, evidence = _validated_operation(chapter, owner, op, field=f"persistent {op['slot']}")
            result.append(ValidatedStateChange(character_id, None, "persistent", op["slot"], operation, value, evidence, ""))
        raw_relationships = item.get("relationship_ops")
        if not isinstance(raw_relationships, list):
            raise ExtractorValidationError("relationship_ops must be an array")
        for op in raw_relationships:
            if not isinstance(op, dict):
                raise ExtractorValidationError("relationship operation must be an object")
            other_id = op.get("other_character_id")
            if not isinstance(other_id, str) or other_id not in character_map or other_id == character_id:
                raise ExtractorValidationError("relationship target must be another selected character")
            left, right = sorted((character_id, other_id))
            if (left, right) in relationships:
                raise ExtractorValidationError("duplicate relationship pair")
            relationships.add((left, right))
            operation, value, evidence = _validated_operation(chapter, owner, op, field="relationship")
            result.append(ValidatedStateChange(left, right, "relationship", "relationship", operation, value, evidence, ""))
    return result


def validate_extractor_output(chapter: Chapter, output: dict[str, Any]) -> ValidatedExtractorOutput:
    if not isinstance(output, dict):
        raise ExtractorValidationError("Extractor output must be an object")
    headline, long_summary = output.get("headline"), output.get("long_summary", output.get("summary"))
    if not isinstance(headline, str) or not headline.strip():
        raise ExtractorValidationError("Extractor output missing headline")
    if not isinstance(long_summary, str) or not long_summary.strip():
        raise ExtractorValidationError("Extractor output missing long_summary")
    if not isinstance(output.get("character_events"), list):
        raise ExtractorValidationError("character_events must be an array")
    character_map = {link.character_id: link.character for link in chapter.character_links}
    archive_values = {field: _validated_archive_items(output.get(field), field=field, character_map=character_map) for field in ARCHIVE_LIST_FIELDS}
    events: list[tuple[str, str, str]] = []
    for item in output["character_events"]:
        if not isinstance(item, dict):
            raise ExtractorValidationError("character_events item must be an object")
        character_id = item.get("character_id")
        if not isinstance(character_id, str) or character_id not in character_map:
            raise UnselectedCharacterReference("character_events references an unselected character")
        event_text, event_type = item.get("event_text"), item.get("event_type")
        if not isinstance(event_text, str) or not event_text.strip():
            raise ExtractorValidationError("selected character event text is required")
        if normalize_text(character_map[character_id].name) not in normalize_text(event_text):
            raise ExtractorValidationError("selected character event text must name its owner")
        if event_type not in CANONICAL_EVENT_TYPES:
            raise ExtractorValidationError("event_type must use the canonical taxonomy")
        _validated_evidence(chapter, character_map[character_id], item.get("evidence"), field="character event")
        events.append((character_id, event_type, event_text.strip()))
    return ValidatedExtractorOutput(headline.strip(), long_summary.strip(), archive_values, events, _validated_state_updates(chapter, output.get("state_updates"), character_map))


def validate_state_rebuild_output(chapter: Chapter, output: dict[str, Any]) -> ValidatedExtractorOutput:
    """Validate only state rows for the offline rebuild.

    Existing events and archive fields are intentionally outside this contract
    because the apply path never changes them.
    """
    if not isinstance(output, dict) or set(output) != {"state_updates"}:
        raise ExtractorValidationError("state rebuild output must contain only state_updates")
    character_map = {link.character_id: link.character for link in chapter.character_links}
    return ValidatedExtractorOutput(
        chapter.headline or "state-rebuild",
        chapter.long_summary or "state-rebuild",
        {},
        [],
        _validated_state_updates(chapter, output.get("state_updates"), character_map),
    )


def apply_extractor_output(db: Session, chapter: Chapter, output: dict[str, Any]) -> tuple[list[str], list[str]]:
    validated = validate_extractor_output(chapter, output)
    db.execute(delete(CharacterEvent).where(CharacterEvent.chapter_id == chapter.id))
    db.execute(delete(CharacterStateChange).where(CharacterStateChange.chapter_id == chapter.id))
    event_ids: list[str] = []
    for character_id, event_type, event_text in validated.events:
        event = CharacterEvent(book_id=chapter.book_id, chapter_id=chapter.id, character_id=character_id, event_type=event_type, event_text=truncate_to_nonspace(event_text, CHARACTER_EVENT_MAX_CHARS))
        db.add(event); db.flush(); event_ids.append(event.id)
    persist_validated_state_changes(db, chapter, validated)
    chapter.headline, chapter.long_summary = validated.headline, validated.long_summary
    chapter.state_changes = validated.archive_values["state_changes"]
    chapter.unresolved_items = validated.archive_values["unresolved_items"]
    chapter.atomic_memories = validated.archive_values["atomic_memories"]
    chapter.status = "finalized"
    db.flush()
    rebuild_book_projection(db, chapter.book_id)
    updated = sorted({change.character_id for change in validated.state_changes} | {change.other_character_id for change in validated.state_changes if change.other_character_id})
    return updated, event_ids


def persist_validated_state_changes(db: Session, chapter: Chapter, validated: ValidatedExtractorOutput) -> None:
    """Persist only replayable state facts; used by offline rebuild after validation."""
    db.execute(delete(CharacterStateChange).where(CharacterStateChange.chapter_id == chapter.id))
    for change in validated.state_changes:
        db.add(CharacterStateChange(book_id=chapter.book_id, chapter_id=chapter.id, character_id=change.character_id, other_character_id=change.other_character_id, scope=change.scope, slot=change.slot, operation=change.operation, value=change.value, evidence=change.evidence, batch_id=change.batch_id))
