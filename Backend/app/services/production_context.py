"""Frozen, source-addressable inputs for writing and Checker work.

This module has no router or job-lifecycle knowledge.  Callers freeze one
JSON-safe object inside a short transaction, release their session before a
model call, then use :func:`is_frozen_input_current` as the final CAS proof.
"""

from __future__ import annotations

import hashlib
import json
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from itertools import product
from typing import Any, Iterable

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Chapter, ChapterArchiveRevision, Character
from app.services.context import (
    MEMORY_BUDGET_CHARS,
    MemoryBlock,
    memory_participant_ids,
    memory_candidates,
    nonspace_len,
    pack_selector_context,
    pack_writer_context,
    prefilter_memory_candidates,
    prefilter_memory_candidates_v1,
    writing_reference_context,
)


PRODUCTION_INPUT_V1 = "production-input-v1"
PRODUCTION_INPUT_V2 = "production-input-v2"
PRODUCTION_INPUT_VERSION = PRODUCTION_INPUT_V2


class ProductionInputChanged(ValueError):
    """Selector sources changed semantically before Writer could start."""


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _stable_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _normal(value: str) -> str:
    return unicodedata.normalize("NFKC", value or "")


def normalized_exemptions(values: Iterable[Any]) -> list[str]:
    return sorted({_normal(value).strip() for value in values if isinstance(value, str) and _normal(value).strip()})


def _nonspace(value: str) -> str:
    return "".join(_normal(value).split())


def _block_semantic_id_v1(block: MemoryBlock) -> str:
    """Stable historical identity independent of an archive revision row ID."""
    normalized = _nonspace(block.text)
    payload = {
        "chapter_index": block.chapter_index,
        "character_id": block.character_id,
        "memory_type": block.memory_type,
        # A re-archive of the same fact gets a new database fact ID but must
        # not stale a Checker result solely for that bookkeeping change.
        "text": normalized,
    }
    return "history:" + _sha256(_stable_json(payload))


def _block_semantic_id_v2(block: MemoryBlock) -> str:
    """Content identity for v2 source rebinding; database IDs never enter."""
    payload = {
        "source_chapter_id": block.source_chapter_id or f"legacy-index:{block.chapter_index}",
        "chapter_index": block.chapter_index,
        "memory_type": block.memory_type,
        "participant_ids": list(memory_participant_ids(block)),
        # v2 treats wording and whitespace as source content.  Unlike the
        # legacy v1 fingerprint, it must not collapse “A B” into “AB” while
        # deciding whether a Selector source may be rebound.
        "text": block.text,
        # Only ending paragraphs require their physical ordering identity.
        "source_position": block.source_position if block.memory_type == "previous_ending" else 0,
    }
    return "history:" + _sha256(_stable_json(payload))


# Retain the legacy helper name for old callers/tests; new snapshots select
# v2 explicitly through _candidate_range.
def _block_semantic_id(block: MemoryBlock) -> str:
    return _block_semantic_id_v2(block)


def _catalog_entry(kind: str, source_id: str, text: str, *, semantic_id: str | None = None) -> dict[str, str]:
    return {
        "kind": kind,
        "id": source_id,
        "semantic_id": semantic_id or f"{kind}:{source_id}",
        "text": text,
        "content_sha256": _sha256(text),
    }


def _selected(chapter: Chapter) -> list[Character]:
    return sorted((link.character for link in chapter.character_links), key=lambda item: item.id)


def _all_characters(db: Session, chapter: Chapter) -> list[Character]:
    return list(db.scalars(select(Character).where(Character.book_id == chapter.book_id).order_by(Character.id)).all())


def _projection_before(db: Session, chapter: Chapter) -> tuple[dict[str, dict[str, str]], list[dict[str, Any]]]:
    """Use archive-v2.1's unknown-state semantics when available.

    The fallback keeps the module importable while a migration is being
    introduced; it is deliberately only a compatibility bridge for old test
    databases and disappears from the returned data as soon as the projection
    service exposes its v2.1 API.
    """
    from app.services import character_state_projection as projection

    fn = getattr(projection, "projected_state_before_chapter", None)
    if callable(fn):
        fields, uncertainties = fn(db, chapter, stable_relationship_keys=True)
        return ({key: dict(value) for key, value in fields.items()}, list(uncertainties or []))
    fields = projection.projected_fields_before_chapter(db, chapter, stable_relationship_keys=True)
    return ({key: dict(value) for key, value in fields.items()}, [])


def _referenced_prior_state(
    fields: dict[str, dict[str, str]],
    uncertainties: list[dict[str, Any]],
    selected: list[Character],
) -> tuple[dict[str, dict[str, str]], list[dict[str, Any]]]:
    """Keep snapshot dependencies to cards actually supplied to the models."""
    selected_ids = {item.id for item in selected}
    selected_fields = {
        character_id: dict(fields[character_id])
        for character_id in sorted(selected_ids)
        if character_id in fields
    }
    selected_uncertainties = [
        item for item in uncertainties
        if isinstance(item, dict) and (
            item.get("character_id") in selected_ids
            or item.get("other_character_id") in selected_ids
        )
    ]
    return selected_fields, selected_uncertainties


def _referenced_relationship_ids(
    fields: dict[str, dict[str, str]],
    unknown_slots: Iterable[dict[str, Any]] = (),
) -> set[str]:
    """Return every relationship endpoint whose identity reaches a model."""
    referenced = {
        key.removeprefix("relationship:")
        for values in fields.values()
        for key in values
        if isinstance(key, str) and key.startswith("relationship:") and key.removeprefix("relationship:")
    }
    for item in unknown_slots:
        if not isinstance(item, dict) or item.get("scope") != "relationship":
            continue
        for key in ("character_id", "other_character_id"):
            value = item.get(key)
            if isinstance(value, str) and value:
                referenced.add(value)
    return referenced


def _relationship_identities(
    fields: dict[str, dict[str, str]],
    characters: list[Character],
    unknown_slots: Iterable[dict[str, Any]] = (),
) -> dict[str, str]:
    """Resolve only relationship IDs actually present in supplied state."""
    referenced = _referenced_relationship_ids(fields, unknown_slots)
    by_id = {item.id: item for item in characters}
    name_counts = Counter(item.name for item in characters)
    result: dict[str, str] = {}
    for character_id in sorted(referenced):
        character = by_id.get(character_id)
        if character is None:
            result[character_id] = f"关系对象已不可用（ID:{character_id[:8]}）"
        elif name_counts[character.name] > 1:
            result[character_id] = f"{character.name}（ID:{character_id[:8]}）"
        else:
            result[character_id] = character.name
    return result


def _display_prior_state(
    fields: dict[str, dict[str, str]], relationship_identities: dict[str, str],
) -> dict[str, dict[str, str]]:
    displayed: dict[str, dict[str, str]] = {}
    for character_id, values in fields.items():
        row: dict[str, str] = {}
        for key, value in values.items():
            if key.startswith("relationship:"):
                other_id = key.removeprefix("relationship:")
                label = relationship_identities.get(other_id, f"关系对象已不可用（ID:{other_id[:8]}）")
                row[f"与{label}的关系"] = value
            else:
                row[key] = value
        displayed[character_id] = row
    return displayed


def _display_unknown_state_slots(
    unknown_slots: Iterable[dict[str, Any]],
    relationship_identities: dict[str, str],
    characters: list[Character],
) -> list[dict[str, str]]:
    """Render pending state from durable IDs without exposing IDs to models."""
    by_id = {item.id: item for item in characters}
    name_counts = Counter(item.name for item in characters)

    def current_label(character_id: Any) -> str:
        if not isinstance(character_id, str):
            return "人物"
        character = by_id.get(character_id)
        if character is None:
            return f"关系对象已不可用（ID:{character_id[:8]}）"
        if name_counts[character.name] > 1:
            return f"{character.name}（ID:{character_id[:8]}）"
        return character.name

    displayed: list[dict[str, str]] = []
    for item in unknown_slots:
        if not isinstance(item, dict):
            continue
        scope = item.get("scope") if isinstance(item.get("scope"), str) else "状态"
        slot = item.get("slot") if isinstance(item.get("slot"), str) else "状态"
        character_id = item.get("character_id")
        row = {
            "scope": scope,
            "slot": slot,
            "character_name": current_label(character_id),
        }
        if scope == "relationship":
            other_id = item.get("other_character_id")
            row["other_character_name"] = relationship_identities.get(
                other_id, "关系对象已不可用",
            ) if isinstance(other_id, str) else "关系对象已不可用"
            row["message"] = "该关系的章末状态尚无法确定"
        else:
            row["message"] = "该状态尚无法确定"
        displayed.append(row)
    return displayed


def _history_blocks(db: Session, chapter: Chapter) -> list[MemoryBlock]:
    selected_ids = {item.id for item in _selected(chapter)}
    return prefilter_memory_candidates(
        memory_candidates(db, chapter), chapter=chapter, selected_character_ids=selected_ids,
    )


def _history_blocks_v1(db: Session, chapter: Chapter) -> list[MemoryBlock]:
    """Use the original Build63 filter only for retained v1 snapshots."""
    selected_ids = {item.id for item in _selected(chapter)}
    return prefilter_memory_candidates_v1(
        memory_candidates(db, chapter), chapter=chapter, selected_character_ids=selected_ids,
    )


def _candidate_row_v1(block: MemoryBlock) -> dict[str, Any]:
    """Return every source field Build63 persisted for a v1 candidate row."""
    return {
        "semantic_id": _block_semantic_id_v1(block),
        "content_sha256": _sha256(block.text),
        "chapter_index": block.chapter_index,
        "memory_type": block.memory_type,
    }


def _candidate_range_v1(blocks: list[MemoryBlock]) -> list[dict[str, Any]]:
    return [
        _candidate_row_v1(block)
        for block in sorted(blocks, key=lambda item: (item.chapter_index, item.memory_type, item.id))
    ]


def _candidate_range(blocks: list[MemoryBlock], *, version: str = PRODUCTION_INPUT_VERSION) -> list[dict[str, Any]]:
    if version == PRODUCTION_INPUT_V1:
        return _candidate_range_v1(blocks)
    if version != PRODUCTION_INPUT_V2:
        raise ValueError("unknown production input version")
    rows = [
        {
            "semantic_id": _block_semantic_id_v2(block),
            "content_sha256": _sha256(block.text),
            "chapter_index": block.chapter_index,
            "memory_type": block.memory_type,
            "participant_ids": list(memory_participant_ids(block)),
            "source_chapter_id": block.source_chapter_id or f"legacy-index:{block.chapter_index}",
            "source_position": block.source_position if block.memory_type == "previous_ending" else 0,
        }
        for block in blocks
    ]
    return sorted(rows, key=lambda item: _stable_json(item))


def _v1_candidate_counter(blocks: Iterable[MemoryBlock]) -> Counter[str]:
    """Compare full v1-visible source rows, including exact source text."""
    return Counter(_stable_json(_candidate_row_v1(block)) for block in blocks)


def _revision_v1_blocks(chapter: Chapter, revision: ChapterArchiveRevision) -> list[MemoryBlock]:
    """Recreate one retained v2 revision as the Build63 memory source shape."""
    blocks: list[MemoryBlock] = []
    if revision.summary.strip():
        blocks.append(MemoryBlock(
            id=f"archive_v2:{revision.id}:summary",
            text=f"第 {chapter.index} 章摘要：{revision.summary.strip()}",
            chapter_index=chapter.index,
            memory_type="summary",
            source_chapter_id=chapter.id,
        ))
    for position, fact in enumerate(revision.facts, start=1):
        participant_ids = tuple(sorted({participant.character_id for participant in fact.participants}))
        blocks.append(MemoryBlock(
            id=f"archive_v2_fact:{fact.id}",
            text=f"第 {chapter.index} 章{fact.fact_type}事实：{fact.fact_text.strip()}",
            chapter_index=chapter.index,
            character_id=participant_ids[0] if len(participant_ids) == 1 else None,
            memory_type="canonical_fact",
            participant_ids=participant_ids,
            source_chapter_id=chapter.id,
            source_position=position,
        ))
    return blocks


def _is_archive_revision_block(block: MemoryBlock, chapter_id: str) -> bool:
    return (
        block.source_chapter_id == chapter_id
        and (block.id.startswith("archive_v2:") or block.id.startswith("archive_v2_fact:"))
    )


_MAX_V1_REARCHIVE_PROOF_COMBINATIONS = 256


def _v1_rearchive_range_is_proved_current(
    db: Session,
    chapter: Chapter,
    frozen_range: list[dict[str, Any]],
) -> bool:
    """Prove an old v1 boundary result came from an equivalent retained source.

    A v1 range deliberately omits database IDs.  That means equality of the
    frozen 300 rows alone cannot rule out a new high-priority row just beyond
    the limit.  This compatibility path only accepts a retained, formerly
    complete revision whose *entire* v1-visible contribution equals the
    current one, then reruns the historical prefilter with those real IDs.
    """
    current_full = memory_candidates(db, chapter)
    selected_ids = {item.id for item in _selected(chapter)}
    current_range = _candidate_range_v1(prefilter_memory_candidates_v1(
        current_full, chapter=chapter, selected_character_ids=selected_ids,
    ))
    if current_range == frozen_range:
        return True

    ordinary = [block for block in current_full if block.memory_type != "previous_ending"]
    if len(ordinary) <= 300 and sum(nonspace_len(block.text) for block in ordinary) <= 30_000:
        # Below both Build63 gates the frozen range was the complete input.
        # Its full row multiset therefore proves exact semantic equality even
        # when a re-archive changed UUID ordering inside the serialized list.
        # This is deliberately not used at either gate, where a frozen subset
        # cannot disprove an unseen addition or mutation.
        return _v1_candidate_counter(current_full) == Counter(
            _stable_json(row) for row in frozen_range if isinstance(row, dict)
        )

    # The v1 range contains every preceding-ending paragraph, so its exact
    # rows can still prove that deterministic continuation source. Other
    # legacy-shaped rows may be omitted by the 300/30k gate and have no frozen
    # source identity; without a retained v2 revision they cannot prove that a
    # later addition or edit was absent at freeze time.
    endings = [block for block in current_full if block.memory_type == "previous_ending"]
    frozen_endings = [
        row for row in frozen_range
        if isinstance(row, dict) and row.get("memory_type") == "previous_ending"
    ]
    if _v1_candidate_counter(endings) != Counter(_stable_json(row) for row in frozen_endings):
        return False

    prior_chapters = list(db.scalars(
        select(Chapter).where(
            Chapter.book_id == chapter.book_id,
            Chapter.index < chapter.index,
            Chapter.status == "finalized",
        ).order_by(Chapter.index, Chapter.id)
    ).all())
    replacement_options: list[tuple[str, list[list[MemoryBlock]]]] = []
    remaining_frozen_rows = Counter(
        _stable_json(row) for row in frozen_range if isinstance(row, dict)
    )
    for prior in prior_chapters:
        current_contribution = [
            block for block in current_full if _is_archive_revision_block(block, prior.id)
        ]
        if not current_contribution:
            continue
        active_id = prior.active_archive_revision_id
        if not isinstance(active_id, str) or not active_id:
            # A current source without an active v2 revision is not a
            # re-archive proof candidate.  Do not infer old provenance.
            return False
        active_revision = db.get(ChapterArchiveRevision, active_id)
        if (
            active_revision is None
            or not active_revision.is_active
            or active_revision.status != "complete"
            or _v1_candidate_counter(_revision_v1_blocks(prior, active_revision))
            != _v1_candidate_counter(current_contribution)
        ):
            return False
        historic_revisions = list(db.scalars(
            select(ChapterArchiveRevision).where(
                ChapterArchiveRevision.chapter_id == prior.id,
                ChapterArchiveRevision.id != active_id,
                ChapterArchiveRevision.status == "complete",
                ChapterArchiveRevision.is_active.is_(False),
            ).order_by(ChapterArchiveRevision.revision, ChapterArchiveRevision.id)
        ).all())
        alternatives = [
            _revision_v1_blocks(prior, revision)
            for revision in historic_revisions
        ]
        alternatives = [
            blocks for blocks in alternatives
            if _v1_candidate_counter(blocks) == _v1_candidate_counter(current_contribution)
        ]
        if not alternatives:
            # No retained revision proves an equivalent substitution for this
            # source. Older, semantically different revisions are irrelevant:
            # they neither prove nor disprove the current contribution.
            # It may stay only when its entire current contribution is
            # explicitly represented in the frozen range; consume those rows
            # so another active-only source cannot borrow the same evidence.
            contribution_rows = _v1_candidate_counter(current_contribution)
            if any(remaining_frozen_rows[row] < count for row, count in contribution_rows.items()):
                return False
            remaining_frozen_rows.subtract(contribution_rows)
        else:
            replacement_options.append((prior.id, [current_contribution, *alternatives]))

    archive_blocks = [
        block for prior in prior_chapters
        for block in current_full
        if _is_archive_revision_block(block, prior.id)
    ]
    if not replacement_options or len(archive_blocks) + len(endings) != len(current_full):
        return False
    combinations = 1
    for _chapter_id, options in replacement_options:
        combinations *= len(options)
        if combinations > _MAX_V1_REARCHIVE_PROOF_COMBINATIONS:
            return False

    replaced_ids = {chapter_id for chapter_id, _options in replacement_options}
    unchanged = [
        block for block in current_full
        if not any(_is_archive_revision_block(block, chapter_id) for chapter_id in replaced_ids)
    ]
    for selected_indexes in product(*(range(len(options)) for _chapter_id, options in replacement_options)):
        # A current-only combination would merely repeat the already unequal
        # current range. At least one actual old revision must reproduce the
        # frozen range before this compatibility proof can succeed.
        if not any(index > 0 for index in selected_indexes):
            continue
        selected_options = [
            options[index]
            for index, (_chapter_id, options) in zip(selected_indexes, replacement_options, strict=True)
        ]
        historical_full = [*unchanged, *(block for option in selected_options for block in option)]
        # This construction is a complete semantic proof, not a frozen-range
        # subset check: every replaced chapter was compared above and every
        # non-replaced source remains in the same full candidate collection.
        if _v1_candidate_counter(historical_full) != _v1_candidate_counter(current_full):
            continue
        historical_range = _candidate_range_v1(prefilter_memory_candidates_v1(
            historical_full, chapter=chapter, selected_character_ids=selected_ids,
        ))
        if historical_range == frozen_range:
            return True
    return False


def freeze_selector_input(
    db: Session,
    chapter: Chapter,
    candidates: list[MemoryBlock],
) -> dict[str, Any]:
    """Freeze the pure values that are actually supplied to Selector.

    Source database IDs are intentionally absent so an equivalent re-archive
    may be rebound after Selector returns. Rendered relationship identities
    remain present because they are part of the state cards the model read.
    """
    selected = _selected(chapter)
    projected_state, projected_unknown_slots = _projection_before(db, chapter)
    prior_state, unknown_slots = _referenced_prior_state(projected_state, projected_unknown_slots, selected)
    all_characters = _all_characters(db, chapter)
    identities = _relationship_identities(prior_state, all_characters, unknown_slots)
    displayed_unknown_slots = _display_unknown_state_slots(unknown_slots, identities, all_characters)
    return {
        "protocol_version": PRODUCTION_INPUT_V2,
        "chapter": {"id": chapter.id, "index": chapter.index, "title": chapter.title},
        "bible": chapter.user_prompt,
        "selected_characters": _selected_payload(selected),
        "normalized_exemptions": normalized_exemptions(chapter.exempted_character_names or []),
        "prior_state": _display_prior_state(prior_state, identities),
        "unknown_state_slots": displayed_unknown_slots,
        "unknown_state_slot_identity": unknown_slots,
        "relationship_identities": identities,
        "selector_candidate_range": _candidate_range(candidates, version=PRODUCTION_INPUT_V2),
    }


def is_frozen_selector_input_current(
    db: Session,
    chapter: Chapter,
    frozen: dict[str, Any],
) -> bool:
    """Prove Selector's model-facing inputs did not materially change in flight."""
    if not isinstance(frozen, dict) or frozen.get("protocol_version") != PRODUCTION_INPUT_V2:
        return False
    return frozen == freeze_selector_input(db, chapter, _history_blocks(db, chapter))


def _lookup_used_sources(
    available: list[MemoryBlock],
    memories: Iterable[MemoryBlock],
    conflicts: Iterable[MemoryBlock],
    previous_ending: str,
) -> list[dict[str, str]]:
    by_id = {block.id: block for block in available}
    selected_ids: list[str] = []
    for block in list(memories) + list(conflicts):
        selected_ids.extend(value for value in block.id.split("|") if value)
    entries: list[dict[str, str]] = []
    for source_id in dict.fromkeys(selected_ids):
        block = by_id.get(source_id)
        if block is None:
            raise ValueError(f"selected history source is unavailable: {source_id}")
        entries.append(_catalog_entry(
            "history", f"history:{source_id}", block.text, semantic_id=_block_semantic_id(block),
        ))
    if previous_ending:
        # Ending paragraphs are not model-compressed.  Keep every emitted
        # candidate paragraph as an individually addressable source.
        for block in available:
            if block.memory_type == "previous_ending" and _nonspace(block.text) in _nonspace(previous_ending):
                entries.append(_catalog_entry(
                    "history", f"history:{block.id}", block.text, semantic_id=_block_semantic_id(block),
                ))
    return entries


def _name_hits_for_known_characters(
    texts: list[tuple[str, str]],
    known_characters: list[dict[str, str]],
    selected_ids: set[str],
    exemptions: set[str],
) -> list[dict[str, Any]]:
    """Find every program-addressable name occurrence needing classification.

    ``source_start``/``source_end`` are zero-based, end-exclusive code-point
    offsets into the NFKC-normalized frozen source.  They make each occurrence
    distinct even when the same name (or sentence) appears more than once.
    ``local_excerpt`` is only prompt aid; validation relies on the offsets and
    exact source slice rather than a heuristic match anywhere in the source.
    """
    owners_by_name: dict[str, list[dict[str, str]]] = {}
    for character in known_characters:
        character_id, raw_name = character.get("id"), character.get("name")
        if not isinstance(character_id, str) or not isinstance(raw_name, str):
            raise ValueError("known character payload is invalid")
        name = _normal(raw_name).strip()
        if name:
            owners_by_name.setdefault(name, []).append({"id": character_id, "name": raw_name})
    names = sorted(owners_by_name, key=lambda value: (-len(value), value))
    hits: list[dict[str, Any]] = []
    ordinal = 0
    for source_id, original in texts:
        normalized = _normal(original)
        position = 0
        while position < len(normalized):
            candidates = [name for name in names if normalized.startswith(name, position)]
            if not candidates:
                position += 1
                continue
            name = candidates[0]
            # Retain the prior single-character CJK boundary safeguard while
            # allowing multi-character names through for semantic review.
            previous = normalized[position - 1] if position else ""
            if len(name) == 1 and previous and "一" <= previous <= "鿿":
                position += 1
                continue
            owners = owners_by_name[name]
            selected_owners = [item for item in owners if item["id"] in selected_ids]
            # Explicit name exemptions take precedence over same-name ambiguity.
            if name in exemptions or (len(selected_owners) == 1 and len(owners) > 1) or (
                len(owners) == 1 and selected_owners
            ):
                position += len(name)
                continue
            ordinal += 1
            # Compact IDs are only private model-protocol tokens.  The frozen
            # source/offset fields retain the real traceability, while a
            # 500-hit chapter no longer spends most of its prompt on hashes.
            hit_id = f"n{ordinal}"
            source_end = position + len(name)
            excerpt_start = max(0, position - 16)
            excerpt_end = min(len(normalized), source_end + 16)
            hits.append({
                "hit_id": hit_id,
                "source_id": source_id,
                "text": normalized[position:source_end],
                "normalized_name": name,
                "candidate_character_ids": [item["id"] for item in owners],
                "selected_character_ids": [item["id"] for item in selected_owners],
                "source_start": position,
                "source_end": source_end,
                "local_excerpt": normalized[excerpt_start:excerpt_end],
            })
            position += len(name)
    return hits


def _name_group_context(source: str, start: int, end: int, *, bounded: bool = True) -> str:
    """Mark the hit in its sentence; truncate only the displayed excerpt."""
    left_boundary = max(source.rfind(mark, 0, start) + 1 for mark in "。！？\n")
    right_candidates = [source.find(mark, end) for mark in "。！？\n"]
    right_boundary = min((value + 1 for value in right_candidates if value >= 0), default=len(source))
    left = max(left_boundary, start - 24) if bounded else left_boundary
    right = min(right_boundary, end + 24) if bounded else right_boundary
    return source[left:start] + "【" + source[start:end] + "】" + source[end:right]


def _name_groups(
    hits: list[dict[str, Any]], source_texts: dict[str, str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Compact same-context classifications without merging different senses.

    A group is intentionally scoped to one source, candidate set and marked
    complete marked sentence. Thus a seasonal ``夏天`` and a later speaking ``夏天``
    cannot receive one blanket classification merely because their spellings
    match. Repeated identical sentences share one row and one compact
    ``hit_ids`` list.
    """
    candidate_keys: dict[tuple[tuple[str, ...], tuple[str, ...]], str] = {}
    candidate_rows: list[dict[str, Any]] = []
    grouped: dict[tuple[Any, ...], dict[str, Any]] = {}
    for hit in hits:
        candidate_ids = tuple(hit["candidate_character_ids"])
        selected_ids = tuple(hit["selected_character_ids"])
        candidate_key = candidate_keys.get((candidate_ids, selected_ids))
        if candidate_key is None:
            candidate_key = f"c{len(candidate_rows) + 1}"
            candidate_keys[(candidate_ids, selected_ids)] = candidate_key
            candidate_rows.append({
                "candidate_key": candidate_key,
                "character_ids": list(candidate_ids),
                "selected_character_ids": list(selected_ids),
            })
        source = source_texts.get(hit["source_id"])
        if not isinstance(source, str):
            raise ValueError("name hit source is missing")
        normalized_source = _normal(source)
        local_context = _name_group_context(normalized_source, hit["source_start"], hit["source_end"])
        sentence_context = _name_group_context(
            normalized_source, hit["source_start"], hit["source_end"], bounded=False,
        )
        key = (hit["source_id"], hit["text"], candidate_key, sentence_context)
        row = grouped.get(key)
        if row is None:
            row = {
                "hit_ids": [],
                "source_id": hit["source_id"],
                "name": hit["text"],
                "candidate_key": candidate_key,
                "local_context": local_context,
            }
            grouped[key] = row
        row["hit_ids"].append(hit["hit_id"])
    return list(grouped.values()), candidate_rows


def _name_hits(
    texts: list[tuple[str, str]],
    characters: list[Character],
    selected_ids: set[str],
    exemptions: set[str],
) -> list[dict[str, Any]]:
    return _name_hits_for_known_characters(
        texts,
        [{"id": item.id, "name": item.name} for item in characters],
        selected_ids,
        exemptions,
    )


def _selected_payload(characters: list[Character]) -> list[dict[str, str]]:
    return [
        {"id": item.id, "name": item.name, "role": item.role, "fixed_profile": item.fixed_profile}
        for item in characters
    ]


def _known_character_identity(characters: list[Character]) -> list[dict[str, str]]:
    """The full book directory contributes only names to name-use matching.

    Selected cards carry their role/profile in both Writer and Checker input.
    Other cards are retained in a frozen snapshot solely so the client can
    show a safe repair choice for a name hit; their role/profile is not model
    input and must not invalidate an otherwise identical run.
    """
    return [{"id": item.id, "name": item.name} for item in characters]


def _base_catalog(
    chapter: Chapter,
    draft_text: str,
    selected: list[Character],
    prior_state: dict[str, dict[str, str]],
    unknown_state_slots: list[dict[str, Any]],
    exemptions: list[str],
) -> list[dict[str, str]]:
    entries = [
        _catalog_entry("draft", "draft", draft_text),
        _catalog_entry("bible", "bible", chapter.user_prompt),
        _catalog_entry("world", "world", chapter.book.world_setting),
    ]
    authorization = _stable_json({"selected_character_ids": [item.id for item in selected], "exempted_names": exemptions})
    entries.append(_catalog_entry("authorization", "authorization", authorization))
    # Unknown slots are a source-addressable scope limitation.  They are not
    # a claim that any opposite state is true, and Checker validation refuses
    # to use this entry as a contradiction/requirement issue source.
    unknown_payload = _stable_json(unknown_state_slots)
    entries.append(_catalog_entry(
        "prior_state", "prior_state:unknown", unknown_payload,
        semantic_id="prior_state:unknown",
    ))
    for character in selected:
        card = _stable_json({
            "id": character.id,
            "name": character.name,
            "role": character.role,
            "fixed_profile": character.fixed_profile,
        })
        entries.append(_catalog_entry("character", f"character:{character.id}", card, semantic_id=f"character:{character.id}"))
        state = _stable_json(prior_state.get(character.id, {}))
        entries.append(_catalog_entry("prior_state", f"prior_state:{character.id}", state, semantic_id=f"prior_state:{character.id}"))
    return entries


def _stable_catalog(catalog: Iterable[dict[str, Any]]) -> list[dict[str, str]]:
    return sorted(
        [
            {
                "kind": str(item["kind"]),
                "semantic_id": str(item["semantic_id"]),
                "content_sha256": str(item["content_sha256"]),
            }
            for item in catalog
        ],
        key=lambda item: (item["kind"], item["semantic_id"], item["content_sha256"]),
    )


def _input_fingerprint(snapshot: dict[str, Any]) -> str:
    """Fingerprint every frozen dependency after a candidate draft is bound."""
    payload = {
        "protocol_version": snapshot["protocol_version"],
        "chapter": snapshot["chapter"],
        "draft": snapshot["draft"],
        "bible_sha256": _sha256(snapshot["bible"]),
        "world_sha256": _sha256(snapshot["world"]),
        "selected_characters": snapshot["selected_characters"],
        "normalized_exemptions": snapshot["normalized_exemptions"],
        "prior_state": snapshot["prior_state"],
        "unknown_state_slots": snapshot["unknown_state_slots"],
        "reference_context_sha256": _sha256(snapshot["reference_context"]),
        "source_catalog": _stable_catalog(snapshot["source_catalog"]),
        "selector_candidate_range": snapshot["selector_candidate_range"],
        "memory_manifest": snapshot["memory_manifest"],
        "context_limitations": snapshot["context_limitations"],
        "name_hits": snapshot["name_hits"],
        "name_groups": snapshot["name_groups"],
        "name_candidate_groups": snapshot["name_candidate_groups"],
    }
    if snapshot["protocol_version"] == PRODUCTION_INPUT_V2:
        payload["relationship_identities"] = snapshot.get("relationship_identities", {})
        payload["unknown_state_slot_identity"] = snapshot.get("unknown_state_slot_identity", [])
    return _sha256(_stable_json(payload))


def _limitations(db: Session, chapter: Chapter) -> list[dict[str, Any]]:
    from app.services.archive_v2 import active_archive_revision

    prior = list(db.scalars(
        select(Chapter).where(
            Chapter.book_id == chapter.book_id,
            Chapter.index < chapter.index,
            Chapter.status == "finalized",
        ).order_by(Chapter.index, Chapter.id)
    ).all())
    # Readiness follows the inputs actually supplied to this chapter. A usable
    # legacy source is supported history, not a reason to demand re-extraction.
    available_indices = {block.chapter_index for block in memory_candidates(db, chapter)
                         if block.memory_type != "previous_ending"}
    _, effective_unknowns = _projection_before(db, chapter)
    _, relevant_unknowns = _referenced_prior_state({}, effective_unknowns, _selected(chapter))
    from app.services.character_state_projection import StateProjectionCursor

    def unknown_key(row: dict) -> tuple:
        return StateProjectionCursor._key_for(row.get("character_id"), row.get("scope"),
                                              row.get("slot"), row.get("other_character_id"))

    effective_keys = {unknown_key(row) for row in relevant_unknowns}
    revisions = {item.id: active_archive_revision(db, item) for item in prior}
    # Attribute an unresolved slot only to its latest active producer.
    owners = {}
    for item in prior:
        revision = revisions[item.id]
        if revision is not None:
            for row in revision.state_uncertainties or []:
                if isinstance(row, dict) and unknown_key(row) in effective_keys:
                    owners[unknown_key(row)] = item.id
    result: list[dict[str, Any]] = []
    for item in prior:
        revision = revisions[item.id]
        if revision is not None:
            uncertainties = [row for row in revision.state_uncertainties or []
                             if isinstance(row, dict) and owners.get(unknown_key(row)) == item.id]
            if uncertainties:
                result.append({
                    "chapter_id": item.id, "chapter_index": item.index, "title": item.title,
                    "kind": "partial_state", "reason": "该章有效记忆存在未确定的人物状态",
                    "uncertainties": uncertainties,
                })
            continue
        if (item.legacy_archive_eligible or item.archive_input_fingerprint is None) and item.index in available_indices:
            continue
        reason = {
            "pending": "该章记忆整理尚未完成",
            "extracting": "该章记忆整理仍在进行",
            "failed": "该章最近一次记忆整理失败",
            "partial": "该章记忆整理不完整",
            "stale": "该章记忆已过期",
        }.get(item.archive_status, "该章缺少可用记忆")
        result.append({
            "chapter_id": item.id, "chapter_index": item.index, "title": item.title,
            "kind": "missing_memory", "reason": reason,
        })
    return result


def production_readiness(db: Session, chapter: Chapter) -> dict[str, Any]:
    """One read-model for readiness and frozen-input limitations."""
    limitations = _limitations(db, chapter)
    token_payload = {
        "chapter_id": chapter.id,
        "chapter_index": chapter.index,
        "title": chapter.title,
        "bible_sha256": _sha256(chapter.user_prompt),
        "limitations": limitations,
    }
    token = _sha256(_stable_json(token_payload))
    return {
        "context_token": token,
        "context_limitations": limitations,
        "is_complete": not limitations,
        "recommended_recovery": limitations[0] if limitations else None,
    }


def _memory_from_manifest(
    blocks: list[MemoryBlock], memory_manifest: dict[str, Any],
) -> tuple[list[MemoryBlock], list[MemoryBlock], str]:
    raw_briefs = memory_manifest.get("memory_brief", [])
    raw_conflicts = memory_manifest.get("conflicts", [])
    start_id = memory_manifest.get("previous_ending_start_id")
    if not isinstance(raw_briefs, list) or not isinstance(raw_conflicts, list):
        raise ValueError("memory manifest lacks validated selection arrays")
    # JobRun's public memory manifest carries harmless rendering metadata
    # (chapter_index/memory_type).  Reconstruct the exact protocol projection
    # before passing it to the strict selector validator; do not let either
    # stored metadata or an unknown field become implicit model input.
    def selection_rows(items: list[Any]) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for item in items:
            if not isinstance(item, dict) or not {"text", "source_ids"}.issubset(item):
                raise ValueError("memory manifest contains invalid selected entry")
            rows.append({"text": item["text"], "source_ids": item["source_ids"]})
        return rows

    briefs = selection_rows(raw_briefs)
    conflicts = selection_rows(raw_conflicts)
    context = pack_selector_context(
        blocks, briefs, conflicts, start_id if isinstance(start_id, str) else None,
        budget=MEMORY_BUDGET_CHARS,
    )
    return context.memories, list(context.conflicts or []), context.previous_ending


def _snapshot(
    db: Session,
    chapter: Chapter,
    draft_text: str,
    *,
    memories: list[MemoryBlock],
    conflicts: list[MemoryBlock],
    previous_ending: str,
    candidate_blocks: list[MemoryBlock],
    memory_manifest: dict[str, Any],
    draft_source: str,
) -> dict[str, Any]:
    selected = _selected(chapter)
    exemptions = normalized_exemptions(chapter.exempted_character_names or [])
    projected_state, projected_unknown_slots = _projection_before(db, chapter)
    prior_state, unknown_slots = _referenced_prior_state(projected_state, projected_unknown_slots, selected)
    all_characters = _all_characters(db, chapter)
    relationship_identities = _relationship_identities(prior_state, all_characters, unknown_slots)
    displayed_prior_state = _display_prior_state(prior_state, relationship_identities)
    displayed_unknown_slots = _display_unknown_state_slots(unknown_slots, relationship_identities, all_characters)
    limitations = production_readiness(db, chapter)
    reference_context = writing_reference_context(
        chapter.book, chapter, memories, previous_ending,
        conflicts=conflicts, dynamic_fields_by_character=displayed_prior_state,
        unknown_state_slots=displayed_unknown_slots,
    )
    catalog = _base_catalog(chapter, draft_text, selected, displayed_prior_state, displayed_unknown_slots, exemptions)
    catalog.extend(_lookup_used_sources(candidate_blocks, memories, conflicts, previous_ending))
    hits = _name_hits(
        [("draft", draft_text), ("bible", chapter.user_prompt)], all_characters,
        {item.id for item in selected}, set(exemptions),
    )
    name_groups, name_candidate_groups = _name_groups(
        hits, {"draft": draft_text, "bible": chapter.user_prompt},
    )
    snapshot: dict[str, Any] = {
        "protocol_version": PRODUCTION_INPUT_VERSION,
        "chapter": {"id": chapter.id, "index": chapter.index, "title": chapter.title},
        "draft": {"sha256": _sha256(draft_text), "source": draft_source},
        "bible": chapter.user_prompt,
        "world": chapter.book.world_setting,
        "selected_characters": _selected_payload(selected),
        "normalized_exemptions": exemptions,
        "prior_state": prior_state,
        "relationship_identities": relationship_identities,
        "unknown_state_slots": displayed_unknown_slots,
        "unknown_state_slot_identity": unknown_slots,
        "reference_context": reference_context,
        "source_catalog": catalog,
        "selector_candidate_range": _candidate_range(candidate_blocks, version=PRODUCTION_INPUT_VERSION),
        "memory_manifest": memory_manifest,
        "context_limitations": limitations["context_limitations"],
        "context_token": limitations["context_token"],
        "name_hits": hits,
        "name_groups": name_groups,
        "name_candidate_groups": name_candidate_groups,
        "known_characters": [
            {
                "id": item.id,
                "name": item.name,
                "role": item.role,
                "fixed_profile": item.fixed_profile,
            }
            for item in all_characters
        ],
    }
    snapshot["input_fingerprint"] = _input_fingerprint(snapshot)
    return snapshot


def freeze_manual_checker_input(db: Session, chapter: Chapter, draft_text: str) -> dict[str, Any]:
    """Freeze a manual check without invoking Selector or any model."""
    candidates = _history_blocks(db, chapter)
    source_ids = [block.id for block in candidates if block.memory_type != "previous_ending"]
    packed = pack_writer_context(candidates, source_ids, None, MEMORY_BUDGET_CHARS)
    manifest = {
        "memory_brief": [
            {"text": block.text, "source_ids": block.id.split("|")}
            for block in packed.memories
        ],
        "conflicts": [],
        "previous_ending_start_id": None,
        "previous_ending": packed.previous_ending,
        "selection_mode": "manual_deterministic",
    }
    return _snapshot(
        db, chapter, draft_text, memories=packed.memories, conflicts=[],
        previous_ending=packed.previous_ending, candidate_blocks=candidates,
        memory_manifest=manifest, draft_source="chapter",
    )


def freeze_selected_write_input(
    db: Session,
    chapter: Chapter,
    draft_text: str,
    *,
    memory_manifest: dict[str, Any],
) -> dict[str, Any]:
    """Freeze the exact validated Selector output shared by Writer and Checker."""
    prepared = prepare_selected_write_input(db, chapter, memory_manifest=memory_manifest)
    return bind_selected_candidate_draft(prepared, draft_text)


def prepare_selected_write_input(
    db: Session,
    chapter: Chapter,
    *,
    memory_manifest: dict[str, Any],
    selector_candidates: list[MemoryBlock] | None = None,
) -> dict[str, Any]:
    """Freeze all pre-Writer dependencies before a candidate model call.

    The returned JSON is deliberately not valid Checker input yet: its draft
    entry is an empty ``candidate_pending`` placeholder.  It is immutable
    input for Writer; :func:`bind_selected_candidate_draft` is the only
    follow-up operation and does no database read.
    """
    candidates = _history_blocks(db, chapter)
    rebound_manifest = memory_manifest
    if selector_candidates is not None:
        rebound_manifest = _rebind_selector_manifest(selector_candidates, candidates, memory_manifest)
    memories, conflicts, ending = _memory_from_manifest(candidates, rebound_manifest)
    return _snapshot(
        db, chapter, "", memories=memories, conflicts=conflicts,
        previous_ending=ending, candidate_blocks=candidates, memory_manifest=rebound_manifest,
        draft_source="candidate_pending",
    )


def _rebind_selector_manifest(
    frozen_candidates: list[MemoryBlock],
    current_candidates: list[MemoryBlock],
    manifest: dict[str, Any],
) -> dict[str, Any]:
    """Map a validated Selector manifest across an equivalent re-archive.

    Each group is proved equivalent by a full v2 semantic key before its IDs
    are paired in a deterministic order.  This never treats a changed fact as
    an ordering difference, and it never silently drops a source.
    """
    if not isinstance(manifest, dict):
        raise ProductionInputChanged("Selector 来源清单无效")
    frozen_counts = Counter(_block_semantic_id_v2(block) for block in frozen_candidates)
    current_counts = Counter(_block_semantic_id_v2(block) for block in current_candidates)
    if frozen_counts != current_counts:
        raise ProductionInputChanged("生成前历史资料已发生实质变化")
    frozen_by_semantic: dict[str, list[MemoryBlock]] = defaultdict(list)
    current_by_semantic: dict[str, list[MemoryBlock]] = defaultdict(list)
    for block in frozen_candidates:
        frozen_by_semantic[_block_semantic_id_v2(block)].append(block)
    for block in current_candidates:
        current_by_semantic[_block_semantic_id_v2(block)].append(block)
    source_id_map: dict[str, str] = {}
    for semantic_id, old_blocks in frozen_by_semantic.items():
        old_sorted = sorted(old_blocks, key=lambda item: item.id)
        new_sorted = sorted(current_by_semantic[semantic_id], key=lambda item: item.id)
        if len(old_sorted) != len(new_sorted):
            raise ProductionInputChanged("生成前历史资料已发生实质变化")
        source_id_map.update({old.id: new.id for old, new in zip(old_sorted, new_sorted, strict=True)})

    rebound = json.loads(_stable_json(manifest))
    def rebind_ids(value: Any) -> Any:
        if not isinstance(value, list) or any(not isinstance(item, str) or item not in source_id_map for item in value):
            raise ProductionInputChanged("生成前历史来源无法对应")
        return [source_id_map[item] for item in value]

    for key in ("memory_brief", "conflicts"):
        rows = rebound.get(key, [])
        if not isinstance(rows, list):
            raise ProductionInputChanged("Selector 来源清单无效")
        for row in rows:
            if not isinstance(row, dict):
                raise ProductionInputChanged("Selector 来源清单无效")
            row["source_ids"] = rebind_ids(row.get("source_ids"))
    start_id = rebound.get("previous_ending_start_id")
    if start_id is not None:
        if not isinstance(start_id, str) or start_id not in source_id_map:
            raise ProductionInputChanged("生成前结尾来源无法对应")
        rebound["previous_ending_start_id"] = source_id_map[start_id]
    sources = rebound.get("sources")
    if isinstance(sources, list):
        for row in sources:
            if not isinstance(row, dict) or not isinstance(row.get("id"), str) or row["id"] not in source_id_map:
                raise ProductionInputChanged("生成前历史来源无法对应")
            row["id"] = source_id_map[row["id"]]
    return rebound


def bind_selected_candidate_draft(prepared: dict[str, Any], draft_text: str) -> dict[str, Any]:
    """Bind Writer output to a prepared snapshot without observing new state."""
    if not isinstance(prepared, dict) or prepared.get("protocol_version") not in {PRODUCTION_INPUT_V1, PRODUCTION_INPUT_V2}:
        raise ValueError("prepared selected input is invalid")
    # JSON cloning preserves only the DB-safe protocol fields and prevents a
    # caller from mutating the pre-Writer object while a model request runs.
    snapshot = json.loads(_stable_json(prepared))
    draft = snapshot.get("draft")
    if not isinstance(draft, dict) or draft.get("source") != "candidate_pending" or draft.get("sha256") != _sha256(""):
        raise ValueError("prepared selected input is already bound or invalid")
    bible = snapshot.get("bible")
    catalog = snapshot.get("source_catalog")
    selected = snapshot.get("selected_characters")
    known = snapshot.get("known_characters")
    exemptions = snapshot.get("normalized_exemptions")
    if (
        not isinstance(bible, str)
        or not isinstance(catalog, list)
        or not isinstance(selected, list)
        or not isinstance(known, list)
        or not isinstance(exemptions, list)
    ):
        raise ValueError("prepared selected input lacks frozen name dependencies")
    selected_ids = {
        item.get("id") for item in selected
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    known_rows = [
        {"id": item.get("id"), "name": item.get("name")}
        for item in known
        if isinstance(item, dict) and isinstance(item.get("id"), str) and isinstance(item.get("name"), str)
    ]
    if len(known_rows) != len(known) or any(not isinstance(item, str) for item in exemptions):
        raise ValueError("prepared selected input has invalid frozen character directory")
    draft_entry = _catalog_entry("draft", "draft", draft_text)
    draft_positions = [index for index, item in enumerate(catalog) if isinstance(item, dict) and item.get("id") == "draft"]
    if draft_positions != [0]:
        raise ValueError("prepared selected input lacks a unique draft source")
    catalog[0] = draft_entry
    snapshot["draft"] = {"sha256": _sha256(draft_text), "source": "candidate"}
    snapshot["name_hits"] = _name_hits_for_known_characters(
        [("draft", draft_text), ("bible", bible)], known_rows, selected_ids, set(exemptions),
    )
    snapshot["name_groups"], snapshot["name_candidate_groups"] = _name_groups(
        snapshot["name_hits"], {"draft": draft_text, "bible": bible},
    )
    snapshot["input_fingerprint"] = _input_fingerprint(snapshot)
    return snapshot


def is_frozen_input_current(db: Session, chapter: Chapter, snapshot: dict[str, Any]) -> bool:
    """Check real dependencies without replacing a frozen reference with today’s text."""
    if not isinstance(snapshot, dict) or snapshot.get("protocol_version") not in {PRODUCTION_INPUT_V1, PRODUCTION_INPUT_V2}:
        return False
    version = snapshot["protocol_version"]
    try:
        if snapshot.get("input_fingerprint") != _input_fingerprint(snapshot):
            return False
    except (KeyError, TypeError, ValueError):
        return False
    saved_chapter = snapshot.get("chapter")
    saved_draft = snapshot.get("draft")
    if not isinstance(saved_chapter, dict) or not isinstance(saved_draft, dict):
        return False
    if saved_chapter != {"id": chapter.id, "index": chapter.index, "title": chapter.title}:
        return False
    draft_source = saved_draft.get("source")
    if draft_source == "chapter" and saved_draft.get("sha256") != _sha256(chapter.draft_text):
        return False
    if draft_source not in {"chapter", "candidate"}:
        return False
    if snapshot.get("bible") != chapter.user_prompt or snapshot.get("world") != chapter.book.world_setting:
        return False
    selected = _selected(chapter)
    if snapshot.get("selected_characters") != _selected_payload(selected):
        return False
    exemptions = normalized_exemptions(chapter.exempted_character_names or [])
    if snapshot.get("normalized_exemptions") != exemptions:
        return False
    projected_state, projected_unknown_slots = _projection_before(db, chapter)
    prior_state, unknown_slots = _referenced_prior_state(projected_state, projected_unknown_slots, selected)
    if snapshot.get("prior_state") != prior_state:
        return False
    if version == PRODUCTION_INPUT_V2:
        identities = _relationship_identities(prior_state, _all_characters(db, chapter), unknown_slots)
        if (
            snapshot.get("relationship_identities") != identities
            or snapshot.get("unknown_state_slot_identity") != unknown_slots
            or snapshot.get("unknown_state_slots") != _display_unknown_state_slots(
                unknown_slots, identities, _all_characters(db, chapter),
            )
        ):
            return False
    elif snapshot.get("unknown_state_slots") != unknown_slots:
        return False
    frozen_range = snapshot.get("selector_candidate_range")
    if not isinstance(frozen_range, list):
        return False
    if version == PRODUCTION_INPUT_V1:
        if not _v1_rearchive_range_is_proved_current(db, chapter, frozen_range):
            return False
    elif frozen_range != _candidate_range(_history_blocks(db, chapter), version=version):
        return False
    # Readiness warnings are presentation/acknowledgement metadata. All real
    # model dependencies were compared above; changing warning classification
    # must not strand an otherwise identical retained candidate after upgrade.
    known = _all_characters(db, chapter)
    draft_for_hits = chapter.draft_text
    if draft_source == "candidate":
        catalog = snapshot.get("source_catalog", [])
        draft_entry = next(
            (item for item in catalog if isinstance(item, dict) and item.get("id") == "draft"), None,
        )
        if not isinstance(draft_entry, dict) or not isinstance(draft_entry.get("text"), str):
            return False
        draft_for_hits = draft_entry["text"]
        if saved_draft.get("sha256") != _sha256(draft_for_hits):
            return False
    expected_hits = _name_hits(
        [("draft", draft_for_hits), ("bible", chapter.user_prompt)], known,
        {item.id for item in selected}, set(exemptions),
    )
    if snapshot.get("name_hits") != expected_hits:
        return False
    expected_groups, expected_candidate_groups = _name_groups(
        expected_hits, {"draft": draft_for_hits, "bible": chapter.user_prompt},
    )
    if (
        snapshot.get("name_groups") != expected_groups
        or snapshot.get("name_candidate_groups") != expected_candidate_groups
    ):
        return False
    # Unselected role/profile fields are repair-display metadata, not Writer
    # or Checker input.  Their mutation cannot change a name hit or model
    # conclusion.  IDs and names remain an exact dependency because they do
    # determine the candidate set for each semantic name-use classification.
    return True


@dataclass(frozen=True)
class FrozenInputProof:
    input_fingerprint: str
    current: bool


def frozen_input_proof(db: Session, chapter: Chapter, snapshot: dict[str, Any]) -> FrozenInputProof:
    """Small CAS-friendly value for job/route owners; no database mutation."""
    return FrozenInputProof(
        input_fingerprint=str(snapshot.get("input_fingerprint", "")),
        current=is_frozen_input_current(db, chapter, snapshot),
    )
