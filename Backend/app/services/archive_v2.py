"""Deterministic v2 chapter archive ledger and lifecycle.

The model proposes a compact summary, canonical facts and state deltas.  This
module owns every identity, source-span and activation decision; partial model
output is never allowed to become active memory.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any

from sqlalchemy import func, select, update
from sqlalchemy.orm import Session, object_session

from app.models import (
    Chapter,
    ChapterArchiveFact,
    ChapterArchiveFactParticipant,
    ChapterArchiveRevision,
    ChapterArchiveStateDelta,
)
from app.models.entities import utc_now
from app.services.character_state_projection import (
    PERSISTENT_SLOTS,
    SNAPSHOT_SLOTS,
    projected_fields_before_chapter,
)
from app.services.context import normalize_text


ARCHIVE_SCHEMA_VERSION = 2
ARCHIVE_CONTRACT_VERSION = "archive-v2.0"
SOURCE_SPAN_VERSION = "sentence-v1"
MAX_FACTS = 8
RECOMMENDED_FACT_SPAN_SENTENCES = 4
MAX_STATE_DELTAS = 18
MAX_SUMMARY_CHARS = 4000
MAX_FACT_REF_CHARS = 16
MAX_FACT_TEXT_CHARS = 500
MAX_STATE_VALUE_CHARS = 300
FACT_TYPES = ("剧情", "决定", "关系", "认知", "未决", "状态")
_FORBIDDEN_VALUES = ("未知", "未明确", "不明确", "暂无", "无从得知", "待定")
_SENTENCE_END = re.compile(r"(?<=[。！？!?；;])")


class ArchiveV2ValidationError(ValueError):
    pass


class ArchiveFingerprintMismatch(ArchiveV2ValidationError):
    pass


@dataclass(frozen=True)
class SourceSpan:
    id: str
    text: str
    ordinal: int


@dataclass(frozen=True)
class ValidatedFact:
    fact_ref: str
    fact_type: str
    importance: int
    text: str
    participant_ids: tuple[str, ...]
    start_id: str
    end_id: str


@dataclass(frozen=True)
class ValidatedDelta:
    fact_ref: str
    character_id: str
    other_character_id: str | None
    scope: str
    slot: str
    operation: str
    value: str | None
    batch_id: str


@dataclass(frozen=True)
class ValidatedArchive:
    summary: str
    facts: tuple[ValidatedFact, ...]
    deltas: tuple[ValidatedDelta, ...]


def segment_source(text: str) -> list[SourceSpan]:
    """Assign stable paragraph/sentence IDs without interpreting prose."""
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    paragraphs = [part.strip() for part in re.split(r"\n\s*\n|\n", normalized) if part.strip()]
    spans: list[SourceSpan] = []
    ordinal = 0
    for paragraph_index, paragraph in enumerate(paragraphs, start=1):
        sentences = [part.strip() for part in _SENTENCE_END.split(paragraph) if part.strip()]
        if not sentences:
            sentences = [paragraph]
        for sentence_index, sentence in enumerate(sentences, start=1):
            ordinal += 1
            spans.append(SourceSpan(f"P{paragraph_index:04d}-S{sentence_index:02d}", sentence, ordinal))
    return spans


def _selected_character_identity(chapter: Chapter) -> list[dict[str, str]]:
    return sorted(
        ({"id": link.character_id, "name": link.character.name.strip()} for link in chapter.character_links),
        key=lambda item: (item["id"], item["name"]),
    )


def archive_input_fingerprint(chapter: Chapter) -> str:
    session = object_session(chapter)
    identities = _selected_character_identity(chapter)
    projected = (
        projected_fields_before_chapter(session, chapter, stable_relationship_keys=True)
        if session is not None
        else {}
    )
    # The Extractor prompt receives prior state only for this chapter's
    # selected characters.  Hashing unrelated characters would make an
    # independent story line stale even though none of its model input changed.
    prior_fields = {item["id"]: projected.get(item["id"], {}) for item in identities}
    payload = {
        "contract": ARCHIVE_CONTRACT_VERSION,
        "span_version": SOURCE_SPAN_VERSION,
        "draft_text": chapter.draft_text,
        # The selected-character identity, not its mutable display name, is the
        # whitelist. Renaming a card does not change what prose was accepted.
        "character_ids": [item["id"] for item in identities],
        "prior_state": prior_fields,
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def build_archive_user_message(chapter: Chapter, prior_fields: dict[str, dict[str, str]]) -> str:
    spans = segment_source(chapter.draft_text)
    characters = _selected_character_identity(chapter)
    character_names = "\n".join(f"- {item['name']}" for item in characters) or "（无已选人物）"
    state_lines = []
    for item in characters:
        fields = prior_fields.get(item["id"], {})
        rendered = "；".join(f"{key}={value}" for key, value in sorted(fields.items())) or "（无）"
        state_lines.append(f"- {item['name']}：{rendered}")
    numbered_text = "\n".join(f"[{span.id}] {span.text}" for span in spans)
    return "\n\n".join(
        [
            "# 唯一事实来源\n只能从下方已接受正文提取；不得使用 Bible、人物卡或历史补写。",
            "# 人物白名单\n" + character_names,
            "# 本章开始前状态（只用于判断章末净变化）\n" + ("\n".join(state_lines) or "（无）"),
            (
                "# 输出规则\nsummary 是唯一摘要。facts 按重要性排序，最多 8 条；"
                "每条只表达一个可追溯事实。fact_ref 只需在本次输出内唯一，建议按 facts 数组顺序使用 F1、F2……；"
                "后端会按数组顺序机械归一化编号。用正文中已有的连续 start_id/end_id 定位，不复制证据；"
                f"首尾句均计入，优先把证据收敛在连续 {RECOMMENDED_FACT_SPAN_SENTENCES} 句以内；"
                "若同一事实确实跨越更多句子，可返回最小充分连续区间，但不得为了覆盖整段情节任意扩大。"
                "代词叙事可以引用人物，但 participant_names 必须是白名单精确姓名；"
                "无法可靠归属时留空并作章节级事实。关系事实必须恰好两人。"
                "end_state_delta 只引用一条与变化有关的 fact，不再改写事实；fact 的类型不限制状态更新。"
                "状态槽由 slot 机械决定，不需要输出 scope。snapshot 只输出实际变化的"
                "当前位置、当前行动或情绪状态，不必为了凑齐三槽重复未变化内容；"
                "persistent 只允许身体状态、当前目标、秘密状态；relationship 只允许关系槽。"
                "没有明确章末净变化就不输出 delta，不得填未知或占位值。"
            ),
            "# 已接受正文（稳定句号）\n" + numbered_text,
        ]
    )


def _clean_text(value: Any, *, field: str, maximum: int) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ArchiveV2ValidationError(f"{field} is required")
    cleaned = value.strip()
    if len(cleaned) > maximum:
        raise ArchiveV2ValidationError(f"{field} exceeds {maximum} characters")
    return cleaned


def validate_archive_output(chapter: Chapter, output: dict[str, Any]) -> ValidatedArchive:
    if not isinstance(output, dict):
        raise ArchiveV2ValidationError("archive output must be an object")
    if set(output) != {"summary", "facts", "end_state_delta"}:
        raise ArchiveV2ValidationError("archive output contains unsupported fields")
    summary = _clean_text(output.get("summary"), field="summary", maximum=MAX_SUMMARY_CHARS)
    raw_facts = output.get("facts")
    raw_deltas = output.get("end_state_delta")
    if not isinstance(raw_facts, list):
        raise ArchiveV2ValidationError("facts must be an array")
    if len(raw_facts) > MAX_FACTS:
        raise ArchiveV2ValidationError(f"facts exceed chapter limit {MAX_FACTS}")
    if not isinstance(raw_deltas, list):
        raise ArchiveV2ValidationError("end_state_delta must be an array")
    if len(raw_deltas) > MAX_STATE_DELTAS:
        raise ArchiveV2ValidationError(f"end_state_delta exceeds limit {MAX_STATE_DELTAS}")

    span_by_id = {span.id: span for span in segment_source(chapter.draft_text)}
    name_to_id: dict[str, str] = {}
    for link in chapter.character_links:
        name = link.character.name.strip()
        if not name or (name in name_to_id and name_to_id[name] != link.character_id):
            raise ArchiveV2ValidationError("selected character names must be non-empty and unique")
        name_to_id[name] = link.character_id

    facts: list[ValidatedFact] = []
    fact_by_source_ref: dict[str, ValidatedFact] = {}
    duplicate_facts: set[tuple[Any, ...]] = set()
    for position, raw in enumerate(raw_facts, start=1):
        if not isinstance(raw, dict):
            raise ArchiveV2ValidationError("fact must be an object")
        if set(raw) != {
            "fact_ref", "type", "importance", "text", "participant_names", "start_id", "end_id"
        }:
            raise ArchiveV2ValidationError("fact contains unsupported fields")
        source_fact_ref = _clean_text(
            raw.get("fact_ref"), field="fact_ref", maximum=MAX_FACT_REF_CHARS
        )
        if source_fact_ref in fact_by_source_ref:
            raise ArchiveV2ValidationError("duplicate fact_ref")
        fact_ref = f"F{position}"
        fact_type = raw.get("type")
        if fact_type not in FACT_TYPES:
            raise ArchiveV2ValidationError("fact type is unsupported")
        importance = raw.get("importance")
        if not isinstance(importance, int) or isinstance(importance, bool) or not 1 <= importance <= 3:
            raise ArchiveV2ValidationError("fact importance must be 1..3")
        text = _clean_text(raw.get("text"), field="fact text", maximum=MAX_FACT_TEXT_CHARS)
        raw_names = raw.get("participant_names")
        if not isinstance(raw_names, list) or len(raw_names) > 4:
            raise ArchiveV2ValidationError("participant_names must be an array of at most 4 names")
        participant_ids: list[str] = []
        for name in raw_names:
            if not isinstance(name, str) or name not in name_to_id:
                raise ArchiveV2ValidationError("fact references an unselected character")
            character_id = name_to_id[name]
            if character_id in participant_ids:
                raise ArchiveV2ValidationError("duplicate fact participant")
            participant_ids.append(character_id)
        if fact_type == "关系" and len(participant_ids) != 2:
            raise ArchiveV2ValidationError("relationship fact must have exactly two participants")
        start_id, end_id = raw.get("start_id"), raw.get("end_id")
        if start_id not in span_by_id or end_id not in span_by_id:
            raise ArchiveV2ValidationError("fact source span does not exist")
        start, end = span_by_id[start_id], span_by_id[end_id]
        if end.ordinal < start.ordinal:
            raise ArchiveV2ValidationError("fact source span is reversed")
        duplicate_key = (
            fact_type,
            "".join(ch for ch in normalize_text(text).casefold() if ch.isalnum()),
            tuple(sorted(participant_ids)),
        )
        if duplicate_key in duplicate_facts:
            raise ArchiveV2ValidationError("duplicate canonical fact")
        duplicate_facts.add(duplicate_key)
        fact = ValidatedFact(
            fact_ref,
            fact_type,
            importance,
            text,
            tuple(participant_ids),
            str(start_id),
            str(end_id),
        )
        facts.append(fact)
        fact_by_source_ref[source_fact_ref] = fact

    deltas: list[ValidatedDelta] = []
    delta_keys: set[tuple[Any, ...]] = set()
    for raw in raw_deltas:
        if not isinstance(raw, dict):
            raise ArchiveV2ValidationError("state delta must be an object")
        required_fields = {"fact_ref", "character_name", "slot", "operation", "value"}
        allowed_fields = required_fields | {"other_character_name", "scope"}
        if not required_fields.issubset(raw) or not set(raw).issubset(allowed_fields):
            raise ArchiveV2ValidationError("state delta contains unsupported fields")
        source_fact_ref = raw.get("fact_ref")
        fact = fact_by_source_ref.get(source_fact_ref.strip()) if isinstance(source_fact_ref, str) else None
        if fact is None:
            raise ArchiveV2ValidationError("state delta references an unknown fact")
        name = raw.get("character_name")
        if not isinstance(name, str) or name not in name_to_id:
            raise ArchiveV2ValidationError("state delta references an unselected character")
        character_id = name_to_id[name]
        if character_id not in fact.participant_ids:
            raise ArchiveV2ValidationError("state delta owner must participate in its fact")
        slot, operation = raw.get("slot"), raw.get("operation")
        value = raw.get("value")
        if operation not in {"set", "clear"}:
            raise ArchiveV2ValidationError("state delta operation must be set or clear")
        if operation == "set":
            value = _clean_text(
                value, field="state delta value", maximum=MAX_STATE_VALUE_CHARS
            )
            if any(part in value for part in _FORBIDDEN_VALUES):
                raise ArchiveV2ValidationError("state delta value cannot be unknown or a placeholder")
        elif value is not None:
            raise ArchiveV2ValidationError("clear state delta value must be null")

        supplied_other_name = raw.get("other_character_name")
        if supplied_other_name is not None and (
            not isinstance(supplied_other_name, str) or supplied_other_name not in name_to_id
        ):
            raise ArchiveV2ValidationError("state delta references an unselected character")

        other_id: str | None = None
        batch_id = ""
        if slot in SNAPSHOT_SLOTS:
            scope = "snapshot"
            batch_id = f"snapshot:{character_id}"
            key = (character_id, scope, slot, None)
        elif slot in PERSISTENT_SLOTS:
            scope = "persistent"
            key = (character_id, scope, slot, None)
        elif slot == "relationship":
            scope = "relationship"
            other_name = supplied_other_name
            if not isinstance(other_name, str) or other_name not in name_to_id:
                raise ArchiveV2ValidationError("relationship target must be selected")
            other_id = name_to_id[other_name]
            if other_id == character_id:
                raise ArchiveV2ValidationError("relationship target must be another character")
            if set(fact.participant_ids) != {character_id, other_id}:
                raise ArchiveV2ValidationError("relationship delta participants must match its fact")
            character_id, other_id = sorted((character_id, other_id))
            key = (character_id, scope, slot, other_id)
        else:
            raise ArchiveV2ValidationError("state delta slot is unsupported")
        if key in delta_keys:
            raise ArchiveV2ValidationError("duplicate state delta slot")
        delta_keys.add(key)
        deltas.append(
            ValidatedDelta(fact.fact_ref, character_id, other_id, scope, str(slot), operation, value, batch_id)
        )
    return ValidatedArchive(summary, tuple(facts), tuple(deltas))


def create_archive_revision(
    db: Session,
    chapter: Chapter,
    *,
    provenance: str,
    input_fingerprint: str | None = None,
) -> ChapterArchiveRevision:
    if provenance not in {"live", "manual_retry", "selective_reextract"}:
        raise ValueError("unsupported archive provenance")
    fingerprint = input_fingerprint or archive_input_fingerprint(chapter)
    number = int(
        db.scalar(
            select(func.max(ChapterArchiveRevision.revision)).where(
                ChapterArchiveRevision.chapter_id == chapter.id
            )
        )
        or 0
    ) + 1
    revision = ChapterArchiveRevision(
        chapter_id=chapter.id,
        revision=number,
        provenance=provenance,
        input_fingerprint=fingerprint,
        status="pending",
    )
    db.add(revision)
    db.flush()
    if chapter.active_archive_revision_id is None and not chapter.legacy_archive_eligible:
        chapter.archive_status = "pending"
    chapter.archive_input_fingerprint = fingerprint
    return revision


def mark_revision_extracting(revision: ChapterArchiveRevision, chapter: Chapter) -> None:
    revision.status = "extracting"
    if chapter.active_archive_revision_id is None and not chapter.legacy_archive_eligible:
        chapter.archive_status = "extracting"


def activate_archive_revision(
    db: Session,
    chapter: Chapter,
    revision: ChapterArchiveRevision,
    validated: ValidatedArchive,
    *,
    model_name: str | None,
) -> tuple[list[str], list[str]]:
    current = archive_input_fingerprint(chapter)
    if current != revision.input_fingerprint:
        revision.status = "stale"
        revision.error_code = "archive_input_changed"
        revision.error_message = "正文或人物白名单已变更，本次归档不再适用"
        revision.finished_at = utc_now()
        chapter.archive_status = "stale"
        chapter.active_archive_revision_id = None
        chapter.legacy_archive_eligible = False
        raise ArchiveFingerprintMismatch(revision.error_message)

    db.execute(
        update(ChapterArchiveRevision)
        .where(ChapterArchiveRevision.chapter_id == chapter.id, ChapterArchiveRevision.is_active.is_(True))
        .values(is_active=False)
    )
    revision.summary = validated.summary
    revision.model_name = model_name
    fact_models: dict[str, ChapterArchiveFact] = {}
    for position, fact in enumerate(validated.facts, start=1):
        model = ChapterArchiveFact(
            revision_id=revision.id,
            position=position,
            fact_ref=fact.fact_ref,
            fact_type=fact.fact_type,
            importance=fact.importance,
            fact_text=fact.text,
            start_id=fact.start_id,
            end_id=fact.end_id,
        )
        db.add(model)
        db.flush()
        fact_models[fact.fact_ref] = model
        for participant_position, character_id in enumerate(fact.participant_ids, start=1):
            db.add(
                ChapterArchiveFactParticipant(
                    fact_id=model.id,
                    character_id=character_id,
                    position=participant_position,
                )
            )
    updated_character_ids: set[str] = set()
    for position, delta in enumerate(validated.deltas, start=1):
        db.add(
            ChapterArchiveStateDelta(
                revision_id=revision.id,
                fact_id=fact_models[delta.fact_ref].id,
                position=position,
                character_id=delta.character_id,
                other_character_id=delta.other_character_id,
                scope=delta.scope,
                slot=delta.slot,
                operation=delta.operation,
                value=delta.value,
                batch_id=(revision.id if delta.batch_id else ""),
            )
        )
        updated_character_ids.add(delta.character_id)
        if delta.other_character_id:
            updated_character_ids.add(delta.other_character_id)
    revision.status = "complete"
    revision.is_active = True
    revision.validation_errors = []
    revision.error_code = None
    revision.error_message = None
    revision.finished_at = utc_now()
    chapter.active_archive_revision_id = revision.id
    chapter.archive_status = "complete"
    chapter.archive_input_fingerprint = revision.input_fingerprint
    chapter.legacy_archive_eligible = False
    db.flush()
    return sorted(updated_character_ids), []


def mark_revision_partial(
    revision: ChapterArchiveRevision,
    chapter: Chapter,
    *,
    reason: str,
    summary: str = "",
) -> None:
    revision.status = "partial"
    revision.summary = summary.strip() if isinstance(summary, str) else ""
    revision.validation_errors = [reason]
    revision.error_code = "archive_validation_failed"
    revision.error_message = reason
    revision.finished_at = utc_now()
    chapter.archive_status = "complete" if chapter.active_archive_revision_id else "partial"


def mark_revision_failed(
    revision: ChapterArchiveRevision,
    chapter: Chapter,
    *,
    error_code: str,
    error_message: str,
) -> None:
    revision.status = "failed"
    revision.error_code = error_code
    revision.error_message = error_message
    revision.finished_at = utc_now()
    chapter.archive_status = "complete" if chapter.active_archive_revision_id else "failed"


def invalidate_archive_if_input_changed(
    db: Session,
    chapter: Chapter,
    *,
    previous_fingerprint: str | None = None,
    force: bool = False,
) -> bool:
    fingerprint = archive_input_fingerprint(chapter)
    baseline = previous_fingerprint or chapter.archive_input_fingerprint
    if not force and (baseline is None or baseline == fingerprint):
        return False
    changed = bool(chapter.active_archive_revision_id or chapter.legacy_archive_eligible)
    active = None
    if chapter.active_archive_revision_id:
        active = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id)
    if active is not None and active.is_active:
        active.is_active = False
        active.status = "stale"
        active.error_code = "archive_input_changed"
        active.error_message = "正文或人物白名单已变更"
        active.finished_at = utc_now()
    chapter.active_archive_revision_id = None
    chapter.archive_status = "stale"
    chapter.archive_input_fingerprint = fingerprint
    chapter.legacy_archive_eligible = False
    return changed


def invalidate_downstream_archives(db: Session, book_id: str, *, after_index: int) -> list[str]:
    """Cascade prior-state fingerprint changes through later active v2 rows."""
    invalidated: list[str] = []
    chapters = db.scalars(
        select(Chapter)
        .where(Chapter.book_id == book_id, Chapter.index > after_index, Chapter.status == "finalized")
        .order_by(Chapter.index, Chapter.id)
    ).all()
    for chapter in chapters:
        if not chapter.active_archive_revision_id:
            continue
        revision = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id)
        if revision is None or not revision.is_active or revision.status != "complete":
            continue
        if revision.input_fingerprint == archive_input_fingerprint(chapter):
            continue
        revision.is_active = False
        revision.status = "stale"
        revision.error_code = "prior_state_changed"
        revision.error_message = "前置章节的有效状态已变更，本章归档需重新生成"
        revision.finished_at = utc_now()
        chapter.active_archive_revision_id = None
        chapter.archive_status = "stale"
        chapter.archive_input_fingerprint = archive_input_fingerprint(chapter)
        chapter.legacy_archive_eligible = False
        db.flush()
        invalidated.append(chapter.id)
    return invalidated


def active_archive_revision(db: Session, chapter: Chapter) -> ChapterArchiveRevision | None:
    if not chapter.active_archive_revision_id:
        return None
    revision = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id)
    if revision is None or not revision.is_active or revision.status != "complete":
        return None
    if revision.input_fingerprint != archive_input_fingerprint(chapter):
        return None
    return revision


def archive_read_model(db: Session, chapter: Chapter) -> dict[str, Any]:
    active = active_archive_revision(db, chapter)
    latest = db.scalars(
        select(ChapterArchiveRevision)
        .where(ChapterArchiveRevision.chapter_id == chapter.id)
        .order_by(ChapterArchiveRevision.revision.desc())
    ).first()
    retry_allowed = (
        chapter.status == "finalized"
        and latest is not None
        and latest.status in {"partial", "failed", "stale"}
    )
    if active is not None:
        return {
            "status": "complete",
            "schema": "v2",
            "revision_id": active.id,
            "revision": active.revision,
            "summary": active.summary,
            "facts": [
                {
                    "id": fact.id,
                    "type": fact.fact_type,
                    "importance": fact.importance,
                    "text": fact.fact_text,
                    "participant_ids": [item.character_id for item in fact.participants],
                    "start_id": fact.start_id,
                    "end_id": fact.end_id,
                }
                for fact in active.facts
            ],
            "state_delta_count": len(active.state_deltas),
            "error_code": None,
            "error_message": None,
            "can_retry": retry_allowed,
            "latest_attempt_status": latest.status if latest is not None else active.status,
        }
    if chapter.status == "finalized" and chapter.legacy_archive_eligible:
        return {
            "status": "complete",
            "schema": "legacy",
            "revision_id": None,
            "revision": None,
            "summary": chapter.long_summary,
            "facts": [],
            "state_delta_count": 0,
            "error_code": latest.error_code if latest is not None else None,
            "error_message": latest.error_message if latest is not None else None,
            "can_retry": retry_allowed,
            "latest_attempt_status": latest.status if latest is not None else "legacy",
        }
    return {
        "status": chapter.archive_status,
        "schema": "none",
        "revision_id": None,
        "revision": None,
        "summary": "",
        "facts": [],
        "state_delta_count": 0,
        "error_code": latest.error_code if latest is not None else None,
        "error_message": latest.error_message if latest is not None else None,
        "can_retry": retry_allowed,
        "latest_attempt_status": latest.status if latest is not None else chapter.archive_status,
    }
