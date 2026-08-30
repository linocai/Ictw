"""Deterministic current-state projection for Extractor state changes."""

from __future__ import annotations

from dataclasses import dataclass, field
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


@dataclass
class StateProjectionCursor:
    """Incremental equivalent of :func:`project_state_changes`.

    Archive list pages need the state immediately before every chapter.  The
    old implementation rebuilt that entire prefix for each row.  Keeping the
    replay cursor public lets list-oriented callers advance once per source
    row while the strict detail path remains unchanged.
    """

    fields: dict[str, dict[str, str]]
    names: dict[str, str]
    stable_relationship_keys: bool = False
    relations: dict[tuple[str, str], str] = field(default_factory=dict)
    latest: dict[tuple[str, str, str | None], str] = field(default_factory=dict)
    snapshot_seen: set[tuple[str, str]] = field(default_factory=set)

    @classmethod
    def for_characters(
        cls,
        characters: Iterable[Character],
        *,
        stable_relationship_keys: bool = False,
    ) -> "StateProjectionCursor":
        rows = list(characters)
        return cls(
            fields={character.id: {} for character in rows},
            names={character.id: character.name for character in rows},
            stable_relationship_keys=stable_relationship_keys,
        )

    def apply(self, change: CharacterStateChange | ChapterArchiveStateDelta) -> None:
        """Apply one source row using the exact existing projection rules."""
        if change.scope == "snapshot":
            batch_key = (change.character_id, change.batch_id)
            if batch_key not in self.snapshot_seen:
                self.snapshot_seen.add(batch_key)
                # Keep the legacy/v2 distinction and batch semantics exactly
                # aligned with project_state_changes().
                if isinstance(change, CharacterStateChange):
                    for slot in SNAPSHOT_SLOTS:
                        self.fields.setdefault(change.character_id, {}).pop(slot, None)
            key = (change.character_id, change.slot, None)
            if change.operation == "set" and change.value:
                self.fields.setdefault(change.character_id, {})[change.slot] = change.value
            else:
                self.fields.setdefault(change.character_id, {}).pop(change.slot, None)
            self.latest[key] = change.id
            return
        if change.scope == "persistent":
            key = (change.character_id, change.slot, None)
            if change.operation == "set" and change.value:
                self.fields.setdefault(change.character_id, {})[change.slot] = change.value
            else:
                self.fields.setdefault(change.character_id, {}).pop(change.slot, None)
            self.latest[key] = change.id
            return
        if change.scope == "relationship" and change.other_character_id:
            pair = tuple(sorted((change.character_id, change.other_character_id)))
            key = (pair[0], "relationship", pair[1])
            if change.operation == "set" and change.value:
                self.relations[pair] = change.value
            else:
                self.relations.pop(pair, None)
            self.latest[key] = change.id

    def materialize_fields(self) -> dict[str, dict[str, str]]:
        """Return a detached rendering so callers cannot mutate the cursor."""
        rendered = {character_id: dict(values) for character_id, values in self.fields.items()}
        for (left, right), value in self.relations.items():
            if self.stable_relationship_keys:
                if left in rendered:
                    rendered[left][f"relationship:{right}"] = value
                if right in rendered:
                    rendered[right][f"relationship:{left}"] = value
            else:
                if left in rendered and right in self.names:
                    rendered[left][f"与{self.names[right]}关系"] = value
                if right in rendered and left in self.names:
                    rendered[right][f"与{self.names[left]}关系"] = value
        return rendered


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
        # Deliberately fingerprint-free, unlike archive_v2.active_archive_revision:
        # archive_input_fingerprint() calls back into this projection, so adding
        # the check here would recurse through every preceding chapter. The
        # equivalence rests on an invariant the invalidation paths maintain —
        # a chapter keeps its pointer with is_active/complete only while its
        # fingerprint is current, because invalidate_archive_if_input_changed
        # and invalidate_downstream_archives clear both together. Any new path
        # that stales a revision must clear the pointer in the same transaction.
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
    cursor = StateProjectionCursor.for_characters(
        characters, stable_relationship_keys=stable_relationship_keys
    )
    for change in changes:
        cursor.apply(change)
    return cursor.materialize_fields(), set(cursor.latest.values())


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
