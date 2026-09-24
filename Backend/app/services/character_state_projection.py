"""Deterministic current-state projection for Extractor state changes."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable

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


@dataclass(frozen=True)
class StateUncertainty:
    """A verified state slot whose chapter-end value is deliberately unknown.

    This is not a synthetic ``clear`` operation.  Replaying it masks an older
    projected value until a later reliable delta for the same slot arrives.
    """

    character_id: str
    other_character_id: str | None
    scope: str
    slot: str
    payload: dict[str, Any]


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
    uncertainties: dict[tuple[str, str, str | None], StateUncertainty] = field(default_factory=dict)

    @staticmethod
    def _key_for(
        character_id: str,
        scope: str,
        slot: str,
        other_character_id: str | None,
    ) -> tuple[str, str, str | None]:
        if scope == "relationship" and other_character_id:
            left, right = sorted((character_id, other_character_id))
            return (left, "relationship", right)
        return (character_id, slot, None)

    def _mask_uncertain(self, change: StateUncertainty) -> None:
        key = self._key_for(
            change.character_id, change.scope, change.slot, change.other_character_id
        )
        if change.scope == "relationship" and change.other_character_id:
            self.relations.pop(tuple(sorted((change.character_id, change.other_character_id))), None)
        else:
            self.fields.setdefault(change.character_id, {}).pop(change.slot, None)
        # ``latest`` drives the materialized effective-delta flags.  An
        # uncertainty masks the old value itself, so it must also remove the
        # old source row; otherwise character history says a hidden value is
        # still current.
        self.latest.pop(key, None)
        self.uncertainties[key] = change

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

    def apply(self, change: CharacterStateChange | ChapterArchiveStateDelta | StateUncertainty) -> None:
        """Apply one source row using the exact existing projection rules."""
        if isinstance(change, StateUncertainty):
            self._mask_uncertain(change)
            return
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
            self.uncertainties.pop(key, None)
            return
        if change.scope == "persistent":
            key = (change.character_id, change.slot, None)
            if change.operation == "set" and change.value:
                self.fields.setdefault(change.character_id, {})[change.slot] = change.value
            else:
                self.fields.setdefault(change.character_id, {}).pop(change.slot, None)
            self.latest[key] = change.id
            self.uncertainties.pop(key, None)
            return
        if change.scope == "relationship" and change.other_character_id:
            pair = tuple(sorted((change.character_id, change.other_character_id)))
            key = (pair[0], "relationship", pair[1])
            if change.operation == "set" and change.value:
                self.relations[pair] = change.value
            else:
                self.relations.pop(pair, None)
            self.latest[key] = change.id
            self.uncertainties.pop(key, None)

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

    def materialize_uncertainties(self) -> list[dict[str, Any]]:
        """Return only slots which remain unknown after the replay prefix."""
        return [
            dict(change.payload)
            for _key, change in sorted(
                self.uncertainties.items(),
                key=lambda item: (item[0][0], item[0][1], item[0][2] or ""),
            )
        ]


def uncertainty_changes_for_revision(revision: ChapterArchiveRevision) -> list[StateUncertainty]:
    """Read the additive JSON without letting malformed rows affect projection."""
    rows = getattr(revision, "state_uncertainties", []) or []
    if not isinstance(rows, list):
        return []
    result: list[StateUncertainty] = []
    for payload in rows:
        if not isinstance(payload, dict):
            continue
        character_id = payload.get("character_id")
        other_character_id = payload.get("other_character_id")
        scope = payload.get("scope")
        slot = payload.get("slot")
        if (
            not isinstance(character_id, str)
            or not isinstance(scope, str)
            or not isinstance(slot, str)
            or (other_character_id is not None and not isinstance(other_character_id, str))
        ):
            continue
        result.append(
            StateUncertainty(
                character_id=character_id,
                other_character_id=other_character_id,
                scope=scope,
                slot=slot,
                payload=dict(payload),
            )
        )
    return result


def _changes_for_projection(db: Session, book_id: str, *, before_index: int | None = None) -> list:
    # Validate each chapter against the already validated prefix. Calling the
    # full fingerprint helper here would recurse back into this projection.
    from app.services.archive_v2 import archive_input_fingerprint_for_projection

    chapter_query = select(Chapter).where(Chapter.book_id == book_id, Chapter.status == "finalized")
    if before_index is not None:
        chapter_query = chapter_query.where(Chapter.index < before_index)
    chapters = list(db.scalars(chapter_query.order_by(Chapter.index, Chapter.id)).all())
    characters = db.scalars(select(Character).where(Character.book_id == book_id)).all()
    cursor = StateProjectionCursor.for_characters(characters, stable_relationship_keys=True)
    changes: list = []
    for chapter in chapters:
        active = None
        if chapter.active_archive_revision_id:
            active = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id)
        active_valid = (
            active is not None and active.is_active and active.status == "complete"
            and active.input_fingerprint == archive_input_fingerprint_for_projection(
                chapter, cursor.materialize_fields(),
                character_ids=[link.character_id for link in chapter.character_links],
                contract_version=active.contract_version,
                state_uncertainties=cursor.materialize_uncertainties(),
            )
        )
        chapter_changes: list = []
        if active_valid:
            chapter_changes.extend(db.scalars(
                    select(ChapterArchiveStateDelta)
                    .where(ChapterArchiveStateDelta.revision_id == active.id)
                    .order_by(ChapterArchiveStateDelta.position, ChapterArchiveStateDelta.id)
                ).all())
            # A v2.1 uncertainty is a first-class projection event.  It comes
            # after the chapter's reliable deltas so it masks all disputed
            # variants independent of the model's array ordering.
            chapter_changes.extend(uncertainty_changes_for_revision(active))
        # Existing databases receive legacy_archive_eligible=true.  The second
        # condition keeps direct v1 apply helpers useful in local compatibility
        # tests, while any attempted v2 revision has a non-null fingerprint and
        # therefore cannot silently fall back after becoming stale/failed.
        elif chapter.legacy_archive_eligible or chapter.archive_input_fingerprint is None:
            chapter_changes.extend(
                db.scalars(
                    select(CharacterStateChange)
                    .where(CharacterStateChange.chapter_id == chapter.id)
                    .order_by(CharacterStateChange.created_at, CharacterStateChange.id)
                ).all()
            )
        for change in chapter_changes:
            cursor.apply(change)
        changes.extend(chapter_changes)
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


def projected_state_before_chapter(
    db: Session,
    chapter: Chapter,
    *,
    stable_relationship_keys: bool = False,
) -> tuple[dict[str, dict[str, str]], list[dict[str, Any]]]:
    """Current deterministic state and surviving unknown slots before a chapter."""
    characters = list(db.scalars(select(Character).where(Character.book_id == chapter.book_id)).all())
    cursor = StateProjectionCursor.for_characters(
        characters, stable_relationship_keys=stable_relationship_keys
    )
    for change in _changes_for_projection(db, chapter.book_id, before_index=chapter.index):
        cursor.apply(change)
    return cursor.materialize_fields(), cursor.materialize_uncertainties()


def state_uncertainties_before_chapter(
    db: Session,
    chapter: Chapter,
    *,
    stable_relationship_keys: bool = False,
) -> list[dict[str, Any]]:
    """Convenience read API shared by readiness and prompt-context callers."""
    return projected_state_before_chapter(
        db, chapter, stable_relationship_keys=stable_relationship_keys
    )[1]


def projected_fields_before_chapter(
    db: Session,
    chapter: Chapter,
    *,
    stable_relationship_keys: bool = False,
) -> dict[str, dict[str, str]]:
    return projected_state_before_chapter(
        db, chapter, stable_relationship_keys=stable_relationship_keys
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
