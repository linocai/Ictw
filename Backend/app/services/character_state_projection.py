"""Deterministic current-state projection for Extractor state changes."""

from __future__ import annotations

from typing import Iterable

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import (
    Chapter,
    ChapterArchiveRevision,
    ChapterArchiveStateDelta,
    Character,
    CharacterStateChange,
)


SNAPSHOT_SLOTS = ("当前位置", "当前行动", "情绪状态")
PERSISTENT_SLOTS = ("身体状态", "当前目标", "秘密状态")


def _changes_for_projection(db: Session, book_id: str, *, before_index: int | None = None) -> list:
    chapter_query = select(Chapter).where(Chapter.book_id == book_id, Chapter.status == "finalized")
    if before_index is not None:
        chapter_query = chapter_query.where(Chapter.index < before_index)
    chapters = list(db.scalars(chapter_query.order_by(Chapter.index, Chapter.id)).all())
    changes: list = []
    for chapter in chapters:
        active = None
        if chapter.active_archive_revision_id:
            active = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id)
        if active is not None and active.is_active and active.status == "complete":
            changes.extend(
                db.scalars(
                    select(ChapterArchiveStateDelta)
                    .where(ChapterArchiveStateDelta.revision_id == active.id)
                    .order_by(ChapterArchiveStateDelta.position, ChapterArchiveStateDelta.id)
                ).all()
            )
            continue
        # Existing databases receive legacy_archive_eligible=true.  The second
        # condition keeps direct v1 apply helpers useful in local compatibility
        # tests, while any attempted v2 revision has a non-null fingerprint and
        # therefore cannot silently fall back after becoming stale/failed.
        if chapter.legacy_archive_eligible or chapter.archive_input_fingerprint is None:
            changes.extend(
                db.scalars(
                    select(CharacterStateChange)
                    .where(CharacterStateChange.chapter_id == chapter.id)
                    .order_by(CharacterStateChange.created_at, CharacterStateChange.id)
                ).all()
            )
    return changes


def project_state_changes(
    changes: Iterable,
    characters: Iterable[Character],
    *,
    stable_relationship_keys: bool = False,
) -> tuple[dict[str, dict[str, str]], set[str]]:
    """Pure replay.  Returns materialized fields and the latest source row IDs."""
    fields: dict[str, dict[str, str]] = {character.id: {} for character in characters}
    names = {character.id: character.name for character in characters}
    relations: dict[tuple[str, str], str] = {}
    latest: dict[tuple[str, str, str | None], str] = {}
    snapshot_seen: set[tuple[str, str]] = set()
    for change in changes:
        if change.scope == "snapshot":
            batch_key = (change.character_id, change.batch_id)
            if batch_key not in snapshot_seen:
                snapshot_seen.add(batch_key)
                # Legacy snapshots are complete three-slot replacements.  v2
                # ledger deltas are intentionally sparse: an omitted volatile
                # slot means unchanged, not cleared.
                if isinstance(change, CharacterStateChange):
                    for slot in SNAPSHOT_SLOTS:
                        fields.setdefault(change.character_id, {}).pop(slot, None)
            key = (change.character_id, change.slot, None)
            if change.operation == "set" and change.value:
                fields.setdefault(change.character_id, {})[change.slot] = change.value
            else:
                fields.setdefault(change.character_id, {}).pop(change.slot, None)
            latest[key] = change.id
        elif change.scope == "persistent":
            key = (change.character_id, change.slot, None)
            if change.operation == "set" and change.value:
                fields.setdefault(change.character_id, {})[change.slot] = change.value
            else:
                fields.setdefault(change.character_id, {}).pop(change.slot, None)
            latest[key] = change.id
        elif change.scope == "relationship" and change.other_character_id:
            pair = tuple(sorted((change.character_id, change.other_character_id)))
            key = (pair[0], "relationship", pair[1])
            if change.operation == "set" and change.value:
                relations[pair] = change.value
            else:
                relations.pop(pair, None)
            latest[key] = change.id
    for (left, right), value in relations.items():
        if stable_relationship_keys:
            if left in fields:
                fields[left][f"relationship:{right}"] = value
            if right in fields:
                fields[right][f"relationship:{left}"] = value
        else:
            if left in fields and right in names:
                fields[left][f"与{names[right]}关系"] = value
            if right in fields and left in names:
                fields[right][f"与{names[left]}关系"] = value
    return fields, set(latest.values())


def projected_fields_before_chapter(
    db: Session,
    chapter: Chapter,
    *,
    stable_relationship_keys: bool = False,
) -> dict[str, dict[str, str]]:
    characters = list(db.scalars(select(Character).where(Character.book_id == chapter.book_id)).all())
    return project_state_changes(
        _changes_for_projection(db, chapter.book_id, before_index=chapter.index),
        characters,
        stable_relationship_keys=stable_relationship_keys,
    )[0]


def rebuild_book_projection(db: Session, book_id: str) -> dict[str, int]:
    """Materialize the whole book and update effective markers in this transaction."""
    characters = list(db.scalars(select(Character).where(Character.book_id == book_id)).all())
    changes = _changes_for_projection(db, book_id)
    fields, effective_ids = project_state_changes(changes, characters)
    db.execute(update(CharacterStateChange).where(CharacterStateChange.book_id == book_id).values(is_effective=False))
    revision_ids = select(ChapterArchiveRevision.id).join(
        Chapter, ChapterArchiveRevision.chapter_id == Chapter.id
    ).where(Chapter.book_id == book_id)
    db.execute(
        update(ChapterArchiveStateDelta)
        .where(ChapterArchiveStateDelta.revision_id.in_(revision_ids))
        .values(is_effective=False)
    )
    if changes:
        legacy_ids = {change.id for change in changes if isinstance(change, CharacterStateChange)} & effective_ids
        v2_ids = {change.id for change in changes if isinstance(change, ChapterArchiveStateDelta)} & effective_ids
        if legacy_ids:
            db.execute(update(CharacterStateChange).where(CharacterStateChange.id.in_(legacy_ids)).values(is_effective=True))
        if v2_ids:
            db.execute(update(ChapterArchiveStateDelta).where(ChapterArchiveStateDelta.id.in_(v2_ids)).values(is_effective=True))
    for character in characters:
        character.dynamic_fields = fields.get(character.id, {})
    return {"changes": len(changes), "effective": len(effective_ids), "characters": len(characters)}
