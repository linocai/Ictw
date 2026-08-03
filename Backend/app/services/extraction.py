from __future__ import annotations

from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.agents.extractor import CANONICAL_DYNAMIC_FIELD_KEYS, CANONICAL_EVENT_TYPES
from app.models import Chapter, Character, CharacterEvent, CharacterFieldPatch
from app.services.context import CHARACTER_EVENT_MAX_CHARS, normalize_text, truncate_to_nonspace


class ExtractorValidationError(ValueError):
    pass


# Kept as a compatibility import for older callers. v1 silently discards
# unknown/unselected/name-form references instead of asking the user to select.
class UnselectedCharacterReference(ExtractorValidationError):
    pass


ARCHIVE_LIST_FIELDS = ("state_changes", "unresolved_items", "atomic_memories")


def _validated_archive_items(
    raw: Any,
    *,
    field: str,
    character_map: dict[str, Character],
) -> list[dict[str, str]]:
    """Normalize Extractor archive lists without inventing missing facts.

    ``character_id`` is optional (a plot state or unresolved item can be
    chapter-level), but any supplied ID must be from this chapter's whitelist.
    Unknown IDs are discarded just like legacy character events.  A malformed
    selected/global record is a real extraction failure, preserving the old
    transaction rollback guarantee.
    """
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
            continue
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
    if evidence not in chapter.draft_text:
        raise ExtractorValidationError(f"{field} evidence is not an exact draft excerpt")
    if normalize_text(character.name) not in normalize_text(evidence):
        raise ExtractorValidationError(f"{field} evidence must name its owner")
    return evidence


def _validated_dynamic_fields(
    raw: Any, *, owner: Character, character_map: dict[str, Character]
) -> dict[str, str | None]:
    if not isinstance(raw, dict):
        raise ExtractorValidationError("selected character dynamic fields patch must be an object")
    selected_names = {character.name for character in character_map.values()}
    allowed = set(CANONICAL_DYNAMIC_FIELD_KEYS)
    result: dict[str, str | None] = {}
    for key, value in raw.items():
        if not isinstance(key, str):
            raise ExtractorValidationError("dynamic field key must be a string")
        if key not in allowed:
            relation_name = key.removeprefix("与").removesuffix("关系") if key.startswith("与") and key.endswith("关系") else ""
            if relation_name not in selected_names or relation_name == owner.name:
                raise ExtractorValidationError(f"unsupported dynamic field key: {key}")
        if value is not None and (not isinstance(value, str) or not value.strip()):
            raise ExtractorValidationError(f"dynamic field value is invalid: {key}")
        result[key] = value.strip() if isinstance(value, str) else None
    return result


def apply_extractor_output(db: Session, chapter: Chapter, output: dict[str, Any]) -> tuple[list[str], list[str]]:
    if not isinstance(output, dict):
        raise ExtractorValidationError("Extractor output must be an object")
    headline = output.get("headline")
    if not isinstance(headline, str) or not headline.strip():
        raise ExtractorValidationError("Extractor output missing headline")
    # New Extractors emit only long_summary.  Accepting the old key here keeps
    # in-flight/legacy callers recoverable without asking the model for two
    # semantically duplicate artifacts.
    long_summary = output.get("long_summary", output.get("summary"))
    if not isinstance(long_summary, str) or not long_summary.strip():
        raise ExtractorValidationError("Extractor output missing long_summary")
    raw_events = output.get("character_events")
    raw_patches = output.get("dynamic_fields_patch")
    if not isinstance(raw_events, list):
        raise ExtractorValidationError("character_events must be an array")
    if not isinstance(raw_patches, list):
        raise ExtractorValidationError("dynamic_fields_patch must be an array")

    character_map = {link.character_id: link.character for link in chapter.character_links}
    selected_ids = set(character_map)
    archive_values = {
        field: _validated_archive_items(output.get(field), field=field, character_map=character_map)
        for field in ARCHIVE_LIST_FIELDS
    }

    valid_events: list[tuple[str, str, str]] = []
    for item in raw_events:
        if not isinstance(item, dict):
            raise ExtractorValidationError("character_events item must be an object")
        character_id = item.get("character_id")
        if not isinstance(character_id, str) or character_id not in selected_ids:
            continue
        event_text = item.get("event_text")
        if not isinstance(event_text, str) or not event_text.strip():
            raise ExtractorValidationError("selected character event text is required")
        character = character_map[character_id]
        if normalize_text(character.name) not in normalize_text(event_text):
            raise ExtractorValidationError("selected character event text must name its owner")
        _validated_evidence(chapter, character, item.get("evidence"), field="character event")
        event_type = item.get("event_type")
        if not isinstance(event_type, str) or event_type not in CANONICAL_EVENT_TYPES:
            raise ExtractorValidationError("event_type must use the canonical taxonomy")
        valid_events.append((character_id, event_type, event_text.strip()))

    valid_patches_by_character: dict[str, dict[str, str | None]] = {}
    for item in raw_patches:
        if not isinstance(item, dict):
            raise ExtractorValidationError("dynamic_fields_patch item must be an object")
        character_id = item.get("character_id")
        if not isinstance(character_id, str) or character_id not in selected_ids:
            continue
        character = character_map[character_id]
        _validated_evidence(chapter, character, item.get("evidence"), field="dynamic fields patch")
        fields = _validated_dynamic_fields(item.get("fields"), owner=character, character_map=character_map)
        valid_patches_by_character.setdefault(character_id, {}).update(fields)

    # Replacement and all extracted chapter metadata are committed by the caller
    # in one transaction. A validation error above leaves existing events intact.
    db.execute(delete(CharacterEvent).where(CharacterEvent.chapter_id == chapter.id))
    added_event_ids: list[str] = []
    for character_id, event_type, event_text in valid_events:
        event = CharacterEvent(
            book_id=chapter.book_id,
            chapter_id=chapter.id,
            character_id=character_id,
            event_type=event_type,
            event_text=truncate_to_nonspace(event_text, CHARACTER_EVENT_MAX_CHARS),
        )
        db.add(event)
        db.flush()
        added_event_ids.append(event.id)

    # Re-accepting a chapter must keep the ORIGINAL pre-chapter baseline: the
    # previous patch row's priors win over the character's current (already
    # merged) values, otherwise deleting the chapter would revert to the
    # chapter's own earlier output instead of the state before it.
    existing_patches = {
        row.character_id: row
        for row in db.scalars(
            select(CharacterFieldPatch).where(CharacterFieldPatch.chapter_id == chapter.id)
        ).all()
    }
    db.execute(delete(CharacterFieldPatch).where(CharacterFieldPatch.chapter_id == chapter.id))

    updated_ids: list[str] = []
    patched_character_ids: set[str] = set()
    for character_id, fields in valid_patches_by_character.items():
        character: Character = character_map[character_id]
        current = dict(character.dynamic_fields or {})
        old_row = existing_patches.get(character_id)
        prior_values: dict[str, Any] = dict(old_row.prior_values or {}) if old_row else {}
        prior_missing: set[str] = set(old_row.prior_missing or []) if old_row else set()
        for key in fields:
            if key in prior_values or key in prior_missing:
                continue
            if key in current:
                prior_values[key] = current[key]
            else:
                prior_missing.add(key)
        db.add(
            CharacterFieldPatch(
                book_id=chapter.book_id,
                chapter_id=chapter.id,
                character_id=character_id,
                prior_values=prior_values,
                prior_missing=sorted(prior_missing),
            )
        )
        patched_character_ids.add(character_id)
        merged = current
        for key, value in fields.items():
            if value is None:
                merged.pop(key, None)
            else:
                merged[key] = value
        character.dynamic_fields = merged
        updated_ids.append(character.id)

    # Characters this chapter patched earlier but not in this re-accept keep
    # their record: the old merge is still in effect and must stay revertible.
    for character_id, old_row in existing_patches.items():
        if character_id in patched_character_ids:
            continue
        db.add(
            CharacterFieldPatch(
                book_id=chapter.book_id,
                chapter_id=chapter.id,
                character_id=character_id,
                prior_values=dict(old_row.prior_values or {}),
                prior_missing=list(old_row.prior_missing or []),
            )
        )

    canonical_summary = long_summary.strip()
    chapter.headline = headline.strip()
    chapter.long_summary = canonical_summary
    chapter.state_changes = archive_values["state_changes"]
    chapter.unresolved_items = archive_values["unresolved_items"]
    chapter.atomic_memories = archive_values["atomic_memories"]
    chapter.status = "finalized"
    return sorted(set(updated_ids)), added_event_ids
