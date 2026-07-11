from __future__ import annotations

from typing import Any

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from app.models import Chapter, Character, CharacterEvent, CharacterFieldPatch
from app.services.context import CHARACTER_EVENT_MAX_CHARS, truncate_to_nonspace


class ExtractorValidationError(ValueError):
    pass


# Kept as a compatibility import for older callers. v1 silently discards
# unknown/unselected/name-form references instead of asking the user to select.
class UnselectedCharacterReference(ExtractorValidationError):
    pass


def apply_extractor_output(db: Session, chapter: Chapter, output: dict[str, Any]) -> tuple[list[str], list[str]]:
    if not isinstance(output, dict):
        raise ExtractorValidationError("Extractor output must be an object")
    summary = output.get("summary")
    headline = output.get("headline")
    if not isinstance(summary, str) or not summary.strip():
        raise ExtractorValidationError("Extractor output missing summary")
    if not isinstance(headline, str) or not headline.strip():
        raise ExtractorValidationError("Extractor output missing headline")
    raw_events = output.get("character_events")
    raw_patches = output.get("dynamic_fields_patch")
    if not isinstance(raw_events, list):
        raise ExtractorValidationError("character_events must be an array")
    if not isinstance(raw_patches, list):
        raise ExtractorValidationError("dynamic_fields_patch must be an array")

    character_map = {link.character_id: link.character for link in chapter.character_links}
    selected_ids = set(character_map)

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
        event_type = item.get("event_type")
        if event_type is not None and not isinstance(event_type, str):
            raise ExtractorValidationError("event_type must be a string")
        valid_events.append((character_id, event_type or "story", event_text.strip()))

    valid_patches: list[tuple[str, dict[str, Any]]] = []
    for item in raw_patches:
        if not isinstance(item, dict):
            raise ExtractorValidationError("dynamic_fields_patch item must be an object")
        character_id = item.get("character_id")
        if not isinstance(character_id, str) or character_id not in selected_ids:
            continue
        fields = item.get("fields")
        if not isinstance(fields, dict):
            raise ExtractorValidationError("selected character dynamic fields patch must be an object")
        valid_patches.append((character_id, fields))

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
    for character_id, fields in valid_patches:
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
        merged.update(fields)
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

    chapter.summary = summary.strip()
    chapter.headline = headline.strip()
    chapter.status = "finalized"
    return sorted(set(updated_ids)), added_event_ids
