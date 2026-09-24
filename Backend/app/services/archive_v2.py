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
    ChapterCharacter,
    Character,
    CharacterStateChange,
    JobRun,
)
from app.models.entities import utc_now
from app.services.character_state_projection import (
    PERSISTENT_SLOTS,
    SNAPSHOT_SLOTS,
    StateProjectionCursor,
    projected_state_before_chapter,
    uncertainty_changes_for_revision,
)
from app.services.context import normalize_text
from app.services.content_revisions import begin_sqlite_write_cas


ARCHIVE_SCHEMA_VERSION = 2
ARCHIVE_CONTRACT_VERSION = "archive-v2.1"
LEGACY_ARCHIVE_CONTRACT_VERSION = "archive-v2.0"
SOURCE_SPAN_VERSION = "sentence-v1"
MAX_FACTS = 8
RECOMMENDED_FACT_SPAN_SENTENCES = 4
MAX_STATE_DELTAS = 18
MAX_SUMMARY_CHARS = 4000
MAX_FACT_REF_CHARS = 16
MAX_FACT_TEXT_CHARS = 500
MAX_STATE_VALUE_CHARS = 300
MAX_RAW_FACTS = MAX_FACTS * 3
MAX_RAW_STATE_DELTAS = MAX_STATE_DELTAS * 3
FACT_TYPES = ("剧情", "决定", "关系", "认知", "未决", "状态")
_FORBIDDEN_VALUES = ("未知", "未明确", "不明确", "暂无", "无从得知", "待定")
_SENTENCE_END = re.compile(r"(?<=[。！？!?；;])")


class ArchiveV2ValidationError(ValueError):
    """A deterministic rejection with controlled author-visible diagnostics."""

    def __init__(self, reason: str, *, diagnostics: list[dict[str, Any]] | None = None) -> None:
        super().__init__(reason)
        self.diagnostics = diagnostics or []


def archive_validation_message(reason: str | None) -> str | None:
    prefix = "归档未通过确定性校验："
    if reason and reason.startswith(prefix):
        return prefix + archive_validation_message(reason[len(prefix):])
    return {
        "duplicate state delta slot": "归档结果中，同一人物状态或人物关系被重复记录",
        "conflicting state delta slot": "同一人物状态或人物关系出现互相冲突的记录，无法确定章末状态",
        "state delta owner must participate in its fact": "人物状态所引用的事实未包含该人物",
    }.get(reason, reason)


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
class ValidatedUncertainty:
    character_id: str
    other_character_id: str | None
    scope: str
    slot: str
    payload: dict[str, Any]


@dataclass(frozen=True)
class ValidatedArchive:
    summary: str
    facts: tuple[ValidatedFact, ...]
    deltas: tuple[ValidatedDelta, ...]
    state_uncertainties: tuple[ValidatedUncertainty, ...] = ()
    diagnostics: tuple[dict[str, Any], ...] = ()


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


def archive_input_fingerprint(
    chapter: Chapter,
    *,
    contract_version: str = ARCHIVE_CONTRACT_VERSION,
) -> str:
    session = object_session(chapter)
    identities = _selected_character_identity(chapter)
    if session is not None:
        projected, uncertainties = projected_state_before_chapter(
            session, chapter, stable_relationship_keys=True
        )
    else:
        projected, uncertainties = {}, []
    return archive_input_fingerprint_for_projection(
        chapter,
        projected,
        character_ids=[item["id"] for item in identities],
        contract_version=contract_version,
        state_uncertainties=uncertainties,
    )


def archive_input_fingerprint_for_projection(
    chapter: Chapter,
    projected: dict[str, dict[str, str]],
    *,
    character_ids: list[str],
    contract_version: str = ARCHIVE_CONTRACT_VERSION,
    state_uncertainties: list[dict[str, Any]] | None = None,
) -> str:
    """Hash an archive input from a caller-provided pre-chapter projection.

    This is intentionally the same payload as ``archive_input_fingerprint``.
    List rendering supplies a rolling projection to avoid recursively fetching
    every prior chapter for every row.
    """
    character_ids = sorted(character_ids)
    # The Extractor prompt receives prior state only for this chapter's
    # selected characters.  Hashing unrelated characters would make an
    # independent story line stale even though none of its model input changed.
    prior_fields = {character_id: projected.get(character_id, {}) for character_id in character_ids}
    if contract_version not in {LEGACY_ARCHIVE_CONTRACT_VERSION, ARCHIVE_CONTRACT_VERSION}:
        raise ValueError("unsupported archive contract version")
    payload: dict[str, Any] = {
        "contract": contract_version,
        "span_version": SOURCE_SPAN_VERSION,
        "draft_text": chapter.draft_text,
        # The selected-character identity, not its mutable display name, is the
        # whitelist. Renaming a card does not change what prose was accepted.
        "character_ids": character_ids,
        "prior_state": prior_fields,
    }
    if contract_version == ARCHIVE_CONTRACT_VERSION:
        payload["prior_state_uncertainties"] = [
            _fingerprint_uncertainty(item)
            for item in _relevant_prior_state_uncertainties(
                state_uncertainties, selected_character_ids=character_ids
            )
        ]
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def _fingerprint_uncertainty(item: dict[str, Any]) -> dict[str, Any]:
    """Only semantic identity belongs in a dependency fingerprint."""
    return {
        "character_id": item.get("character_id"),
        "other_character_id": item.get("other_character_id"),
        "scope": item.get("scope"),
        "slot": item.get("slot"),
    }


def _relevant_prior_state_uncertainties(
    items: list[dict[str, Any]] | None,
    *,
    selected_character_ids: list[str],
) -> list[dict[str, Any]]:
    """Use one bounded, deterministic unknown-state set for hash and prompt.

    A chapter only receives state for people it selected.  Relationship slots
    can affect either endpoint, so either selected ID is sufficient.  The
    bound must be applied *before* fingerprinting: otherwise an unknown that
    cannot reach the Extractor prompt would still stale an archive.
    """
    selected = set(selected_character_ids)
    relevant = [
        item
        for item in items or []
        if isinstance(item, dict)
        and (
            item.get("character_id") in selected
            or item.get("other_character_id") in selected
        )
    ]
    return sorted(
        relevant,
        key=lambda item: (
            str(item.get("character_id") or ""),
            str(item.get("scope") or ""),
            str(item.get("slot") or ""),
            str(item.get("other_character_id") or ""),
        ),
    )[:8]


def build_archive_user_message(
    chapter: Chapter,
    prior_fields: dict[str, dict[str, str]],
    *,
    previous_diagnostics: list[dict[str, Any]] | None = None,
    prior_state_uncertainties: list[dict[str, Any]] | None = None,
) -> str:
    spans = segment_source(chapter.draft_text)
    characters = _selected_character_identity(chapter)
    character_names = "\n".join(f"- {item['name']}" for item in characters) or "（无已选人物）"
    state_lines = []
    for item in characters:
        fields = prior_fields.get(item["id"], {})
        rendered = "；".join(f"{key}={value}" for key, value in sorted(fields.items())) or "（无）"
        state_lines.append(f"- {item['name']}：{rendered}")
    numbered_text = "\n".join(f"[{span.id}] {span.text}" for span in spans)
    sections = [
            "# 唯一事实来源\n只能从下方已接受正文提取；不得使用 Bible、人物卡或历史补写。",
            "# 人物白名单\n" + character_names,
            "# 本章开始前状态（只用于判断章末净变化）\n" + ("\n".join(state_lines) or "（无）"),
            (
                "# 输出规则\nsummary 是唯一摘要。facts 按重要性排序，去除完全重复后最多 8 条；"
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
                "relationship delta 所引用 fact 的 participant_names 必须恰好两人；"
                "delta 不要重复输出 character_name 或 other_character_name，后端直接从 fact 推导关系双方。"
                "没有明确章末净变化就不输出 delta，不得填未知或占位值。"
            ),
        "# 已接受正文（稳定句号）\n" + numbered_text,
    ]
    uncertainty_lines = []
    selected_names = {item["id"]: item["name"] for item in characters}
    for item in _relevant_prior_state_uncertainties(
        prior_state_uncertainties,
        selected_character_ids=list(selected_names),
    ):
        character_id = item.get("character_id")
        other_character_id = item.get("other_character_id")
        slot = item.get("slot")
        if not isinstance(slot, str):
            continue
        # Names stored in a historical diagnostic are descriptive only.  The
        # IDs are canonical, so render the chapter's current selected name.
        name = selected_names.get(character_id) or selected_names.get(other_character_id)
        if name:
            uncertainty_lines.append(f"- {name}：{slot}尚无法确定（来源章状态待整理）")
    if uncertainty_lines:
        sections.insert(-1, "# 本章开始前的未知状态\n" + "\n".join(uncertainty_lines))
    feedback = _retry_feedback(previous_diagnostics, character_names=selected_names)
    if feedback:
        sections.insert(-1, "# 上次整理需纠正项\n" + feedback)
    return "\n\n".join(sections)


def _retry_feedback(
    diagnostics: list[dict[str, Any]] | None,
    *,
    character_names: dict[str, str] | None = None,
) -> str:
    """Render a bounded, controlled correction hint without replaying model output."""
    if not diagnostics:
        return ""
    messages = []
    for item in _controlled_diagnostics(diagnostics, character_names=character_names)[:6]:
        message = item.get("message")
        recovery = item.get("recovery")
        if isinstance(message, str) and message.strip():
            messages.append(message.strip()[:240])
        if isinstance(recovery, str) and recovery.strip():
            messages.append(recovery.strip()[:180])
    return "\n".join(f"- {message}" for message in messages[:8])


def _clean_text(value: Any, *, field: str, maximum: int) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ArchiveV2ValidationError(f"{field} is required")
    cleaned = value.strip()
    if len(cleaned) > maximum:
        raise ArchiveV2ValidationError(f"{field} exceeds {maximum} characters")
    return cleaned


def _validate_archive_output_v20(chapter: Chapter, output: dict[str, Any]) -> ValidatedArchive:
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
    delta_values: dict[tuple[Any, ...], tuple[str, str | None]] = {}
    for raw in raw_deltas:
        if not isinstance(raw, dict):
            raise ArchiveV2ValidationError("state delta must be an object")
        required_fields = {"fact_ref", "slot", "operation", "value"}
        allowed_fields = required_fields | {"character_name", "other_character_name", "scope"}
        if not required_fields.issubset(raw) or not set(raw).issubset(allowed_fields):
            raise ArchiveV2ValidationError("state delta contains unsupported fields")
        source_fact_ref = raw.get("fact_ref")
        fact = fact_by_source_ref.get(source_fact_ref.strip()) if isinstance(source_fact_ref, str) else None
        if fact is None:
            raise ArchiveV2ValidationError("state delta references an unknown fact")
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

        other_id: str | None = None
        batch_id = ""
        if slot == "relationship":
            scope = "relationship"
            if len(fact.participant_ids) != 2:
                raise ArchiveV2ValidationError(
                    "relationship delta fact must have exactly two participants"
                )
            character_id, other_id = sorted(fact.participant_ids)
            supplied_name = raw.get("character_name")
            supplied_other_name = raw.get("other_character_name")
            if supplied_name is not None or supplied_other_name is not None:
                if (
                    not isinstance(supplied_name, str)
                    or supplied_name not in name_to_id
                    or not isinstance(supplied_other_name, str)
                    or supplied_other_name not in name_to_id
                    or supplied_name == supplied_other_name
                    or {name_to_id[supplied_name], name_to_id[supplied_other_name]}
                    != {character_id, other_id}
                ):
                    raise ArchiveV2ValidationError(
                        "legacy relationship delta participants must match its fact"
                    )
            key = (character_id, scope, slot, other_id)
        elif slot in SNAPSHOT_SLOTS or slot in PERSISTENT_SLOTS:
            name = raw.get("character_name")
            if not isinstance(name, str) or name not in name_to_id:
                raise ArchiveV2ValidationError("state delta references an unselected character")
            character_id = name_to_id[name]
            if character_id not in fact.participant_ids:
                raise ArchiveV2ValidationError("state delta owner must participate in its fact")
            supplied_other_name = raw.get("other_character_name")
            if supplied_other_name is not None and (
                not isinstance(supplied_other_name, str) or supplied_other_name not in name_to_id
            ):
                raise ArchiveV2ValidationError("state delta references an unselected character")
            if slot in SNAPSHOT_SLOTS:
                scope = "snapshot"
                batch_id = f"snapshot:{character_id}"
                key = (character_id, scope, slot, None)
            else:
                scope = "persistent"
                key = (character_id, scope, slot, None)
        else:
            raise ArchiveV2ValidationError("state delta slot is unsupported")
        state_value = (operation, value)
        if key in delta_values:
            if delta_values[key] == state_value:
                # All references/ownership were validated above. Retain the
                # first valid evidence for the same canonical state change.
                continue
            raise ArchiveV2ValidationError("conflicting state delta slot")
        delta_values[key] = state_value
        deltas.append(
            ValidatedDelta(fact.fact_ref, character_id, other_id, scope, str(slot), operation, value, batch_id)
        )
    return ValidatedArchive(summary, tuple(facts), tuple(deltas))


def _root_diagnostic(reason: str) -> dict[str, Any]:
    return {
        "code": "archive_validation_failed",
        "severity": "error",
        "message": archive_validation_message(reason) or "归档结果未通过确定性校验",
        "recovery": "请根据已接受正文重新整理归档。",
    }


def is_whole_state_placeholder(value: str) -> bool:
    # The model often wraps a whole placeholder in quote marks or terminates
    # it with a full stop.  Remove only exterior punctuation, never wording in
    # the middle of a real state such as “调查身份未知的来客”.
    normalized = re.sub(r"\s+", "", value).strip(
        "\"'“”‘’「」『』（）()[]【】<>《》〈〉,，。；;:：!?！？…"
    ).casefold()
    return normalized in {item.casefold() for item in _FORBIDDEN_VALUES}


def _whole_placeholder(value: str) -> bool:
    """Private compatibility alias for the validator implementation."""
    return is_whole_state_placeholder(value)


def _delta_identity(
    raw: Any,
    *,
    facts_by_source_ref: dict[str, ValidatedFact],
    name_to_id: dict[str, str],
) -> tuple[tuple[str, str, str, str | None], ValidatedFact, str, str, str | None, str, str]:
    """Validate source/ownership first, then return a mechanically known slot."""
    if not isinstance(raw, dict):
        raise ArchiveV2ValidationError("state delta must be an object")
    required_fields = {"fact_ref", "slot", "operation", "value"}
    allowed_fields = required_fields | {"character_name", "other_character_name", "scope"}
    if not required_fields.issubset(raw) or not set(raw).issubset(allowed_fields):
        raise ArchiveV2ValidationError("state delta contains unsupported fields")
    source_ref = raw.get("fact_ref")
    fact = facts_by_source_ref.get(source_ref.strip()) if isinstance(source_ref, str) else None
    if fact is None:
        raise ArchiveV2ValidationError("state delta references an unknown fact")
    slot, operation = raw.get("slot"), raw.get("operation")
    if not isinstance(operation, str) or operation not in {"set", "clear"}:
        raise ArchiveV2ValidationError("state delta operation must be set or clear")
    if slot == "relationship":
        if len(fact.participant_ids) != 2:
            raise ArchiveV2ValidationError("relationship delta fact must have exactly two participants")
        character_id, other_id = sorted(fact.participant_ids)
        supplied_name, supplied_other_name = raw.get("character_name"), raw.get("other_character_name")
        if supplied_name is not None or supplied_other_name is not None:
            if (
                not isinstance(supplied_name, str)
                or supplied_name not in name_to_id
                or not isinstance(supplied_other_name, str)
                or supplied_other_name not in name_to_id
                or supplied_name == supplied_other_name
                or {name_to_id[supplied_name], name_to_id[supplied_other_name]} != {character_id, other_id}
            ):
                raise ArchiveV2ValidationError("legacy relationship delta participants must match its fact")
        return (character_id, "relationship", "relationship", other_id), fact, character_id, "relationship", other_id, "relationship", operation
    if slot not in SNAPSHOT_SLOTS and slot not in PERSISTENT_SLOTS:
        raise ArchiveV2ValidationError("state delta slot is unsupported")
    name = raw.get("character_name")
    if not isinstance(name, str) or name not in name_to_id:
        raise ArchiveV2ValidationError("state delta references an unselected character")
    character_id = name_to_id[name]
    if character_id not in fact.participant_ids:
        raise ArchiveV2ValidationError("state delta owner must participate in its fact")
    supplied_other_name = raw.get("other_character_name")
    if supplied_other_name is not None and (
        not isinstance(supplied_other_name, str) or supplied_other_name not in name_to_id
    ):
        raise ArchiveV2ValidationError("state delta references an unselected character")
    scope = "snapshot" if slot in SNAPSHOT_SLOTS else "persistent"
    return (character_id, scope, str(slot), None), fact, character_id, scope, None, str(slot), operation


def _delta_value_problem(operation: str, value: Any) -> str | None:
    if operation == "clear":
        return None if value is None else "clear state delta value must be null"
    if not isinstance(value, str) or not value.strip():
        return "state delta value is required"
    if len(value.strip()) > MAX_STATE_VALUE_CHARS:
        return f"state delta value exceeds {MAX_STATE_VALUE_CHARS} characters"
    if _whole_placeholder(value):
        return "state delta value cannot be unknown or a placeholder"
    return None


def _uncertainty_for_slot(
    key: tuple[str, str, str, str | None],
    candidates: list[dict[str, Any]],
    *,
    id_to_name: dict[str, str],
) -> ValidatedUncertainty:
    character_id, scope, slot, other_id = key
    fact_refs = list(dict.fromkeys(item["fact"].fact_ref for item in candidates))[:8]
    span_ids = list(
        dict.fromkeys(
            span
            for item in candidates
            for span in (item["fact"].start_id, item["fact"].end_id)
        )
    )[:16]
    variants: list[dict[str, str | None]] = []
    for item in candidates:
        value = item["value"] if isinstance(item["value"], str) and len(item["value"]) <= MAX_STATE_VALUE_CHARS else None
        variant = {"operation": item["operation"], "value": value}
        if variant not in variants:
            variants.append(variant)
    character_name = id_to_name.get(character_id, "相关人物")
    other_name = id_to_name.get(other_id) if other_id else None
    subject = f"{character_name}与{other_name}的关系" if other_name else f"{character_name}的{slot}"
    payload: dict[str, Any] = {
        "code": "state_slot_uncertain",
        "severity": "warning",
        "character_id": character_id,
        "character_name": character_name,
        "other_character_id": other_id,
        "other_character_name": other_name,
        "scope": scope,
        "slot": slot,
        "fact_refs": fact_refs,
        "span_ids": span_ids,
        "variants": variants[:4],
        "message": f"本章中{subject}有多个不一致或不完整的结果，当前无法确定章末状态。",
        "recovery": "请重新整理本章，并为该状态槽保留唯一、可追溯的章末结果。",
    }
    return ValidatedUncertainty(character_id, other_id, scope, slot, payload)


def _validate_archive_output_v21(chapter: Chapter, output: dict[str, Any]) -> ValidatedArchive:
    if not isinstance(output, dict):
        raise ArchiveV2ValidationError("archive output must be an object")
    if set(output) != {"summary", "facts", "end_state_delta"}:
        raise ArchiveV2ValidationError("archive output contains unsupported fields")
    summary = _clean_text(output.get("summary"), field="summary", maximum=MAX_SUMMARY_CHARS)
    raw_facts, raw_deltas = output.get("facts"), output.get("end_state_delta")
    if not isinstance(raw_facts, list):
        raise ArchiveV2ValidationError("facts must be an array")
    if not isinstance(raw_deltas, list):
        raise ArchiveV2ValidationError("end_state_delta must be an array")
    if len(raw_facts) > MAX_RAW_FACTS:
        raise ArchiveV2ValidationError(f"facts exceed raw safety limit {MAX_RAW_FACTS}")
    if len(raw_deltas) > MAX_RAW_STATE_DELTAS:
        raise ArchiveV2ValidationError(f"end_state_delta exceeds raw safety limit {MAX_RAW_STATE_DELTAS}")

    span_by_id = {span.id: span for span in segment_source(chapter.draft_text)}
    name_to_id: dict[str, str] = {}
    id_to_name: dict[str, str] = {}
    for link in chapter.character_links:
        name = link.character.name.strip()
        if not name or (name in name_to_id and name_to_id[name] != link.character_id):
            raise ArchiveV2ValidationError("selected character names must be non-empty and unique")
        name_to_id[name] = link.character_id
        id_to_name[link.character_id] = name

    facts: list[ValidatedFact] = []
    facts_by_source_ref: dict[str, ValidatedFact] = {}
    canonical_facts: dict[tuple[Any, ...], ValidatedFact] = {}
    for raw in raw_facts:
        if not isinstance(raw, dict):
            raise ArchiveV2ValidationError("fact must be an object")
        if set(raw) != {"fact_ref", "type", "importance", "text", "participant_names", "start_id", "end_id"}:
            raise ArchiveV2ValidationError("fact contains unsupported fields")
        source_ref = _clean_text(raw.get("fact_ref"), field="fact_ref", maximum=MAX_FACT_REF_CHARS)
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
        if span_by_id[end_id].ordinal < span_by_id[start_id].ordinal:
            raise ArchiveV2ValidationError("fact source span is reversed")
        duplicate_key = (
            fact_type,
            "".join(ch for ch in normalize_text(text).casefold() if ch.isalnum()),
            tuple(sorted(participant_ids)),
        )
        source_payload = (
            fact_type,
            importance,
            text,
            tuple(participant_ids),
            str(start_id),
            str(end_id),
        )
        previous_source = facts_by_source_ref.get(source_ref)
        if previous_source is not None:
            previous_payload = (
                previous_source.fact_type,
                previous_source.importance,
                previous_source.text,
                previous_source.participant_ids,
                previous_source.start_id,
                previous_source.end_id,
            )
            if previous_payload != source_payload:
                raise ArchiveV2ValidationError("duplicate fact_ref")
            # The duplicate object has still passed every structural/source
            # check above.  Keep its source reference mapped to the existing
            # canonical fact so deltas remain deterministic.
            continue
        fact = canonical_facts.get(duplicate_key)
        if fact is None:
            fact = ValidatedFact(
                f"F{len(facts) + 1}", fact_type, importance, text, tuple(participant_ids), str(start_id), str(end_id)
            )
            canonical_facts[duplicate_key] = fact
            facts.append(fact)
        facts_by_source_ref[source_ref] = fact
    if len(facts) > MAX_FACTS:
        raise ArchiveV2ValidationError(f"facts exceed chapter limit {MAX_FACTS}")

    candidates_by_key: dict[tuple[str, str, str, str | None], list[dict[str, Any]]] = {}
    for raw in raw_deltas:
        key, fact, character_id, scope, other_id, slot, operation = _delta_identity(
            raw, facts_by_source_ref=facts_by_source_ref, name_to_id=name_to_id
        )
        value = raw.get("value")
        problem = _delta_value_problem(operation, value)
        candidates_by_key.setdefault(key, []).append(
            {
                "fact": fact,
                "character_id": character_id,
                "scope": scope,
                "other_character_id": other_id,
                "slot": slot,
                "operation": operation,
                "value": value.strip() if isinstance(value, str) and not problem else value,
                "problem": problem,
            }
        )

    deltas: list[ValidatedDelta] = []
    uncertainties: list[ValidatedUncertainty] = []
    for key, candidates in candidates_by_key.items():
        signatures = {
            (item["operation"], item["value"])
            for item in candidates
            if item["problem"] is None
        }
        if any(item["problem"] is not None for item in candidates) or len(signatures) > 1:
            uncertainties.append(_uncertainty_for_slot(key, candidates, id_to_name=id_to_name))
            continue
        if not candidates:
            continue
        item = candidates[0]
        batch_id = f"snapshot:{item['character_id']}" if item["scope"] == "snapshot" else ""
        deltas.append(
            ValidatedDelta(
                item["fact"].fact_ref,
                item["character_id"],
                item["other_character_id"],
                item["scope"],
                item["slot"],
                item["operation"],
                item["value"],
                batch_id,
            )
        )
    if len(deltas) + len(uncertainties) > MAX_STATE_DELTAS:
        raise ArchiveV2ValidationError(
            f"end_state_delta and state uncertainties exceed limit {MAX_STATE_DELTAS}"
        )
    if len(deltas) > MAX_STATE_DELTAS:
        raise ArchiveV2ValidationError(f"end_state_delta exceeds limit {MAX_STATE_DELTAS}")
    diagnostics = tuple(item.payload for item in uncertainties)
    return ValidatedArchive(summary, tuple(facts), tuple(deltas), tuple(uncertainties), diagnostics)


def validate_archive_output(
    chapter: Chapter,
    output: dict[str, Any],
    *,
    contract_version: str = ARCHIVE_CONTRACT_VERSION,
) -> ValidatedArchive:
    """Validate the revision's own contract; v2.0 remains byte-compatible."""
    try:
        if contract_version == LEGACY_ARCHIVE_CONTRACT_VERSION:
            return _validate_archive_output_v20(chapter, output)
        if contract_version != ARCHIVE_CONTRACT_VERSION:
            raise ArchiveV2ValidationError("unsupported archive contract version")
        return _validate_archive_output_v21(chapter, output)
    except ArchiveV2ValidationError as exc:
        if exc.diagnostics:
            raise
        raise ArchiveV2ValidationError(str(exc), diagnostics=[_root_diagnostic(str(exc))]) from exc


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
        contract_version=ARCHIVE_CONTRACT_VERSION,
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
    job_id: str | None = None,
) -> tuple[list[str], list[str]]:
    # Model work has finished. SQLite SELECTs alone do not reserve a
    # transaction: a reopen could otherwise land between proof and activation.
    begin_sqlite_write_cas(db)
    db.expire_all()
    db.refresh(chapter)
    db.refresh(revision)
    run = db.get(JobRun, job_id) if job_id else None
    current = archive_input_fingerprint(chapter, contract_version=revision.contract_version)
    if (
        chapter.status != "finalized"
        or revision.status != "extracting"
        or current != revision.input_fingerprint
        or (job_id is not None and (
            run is None
            or run.kind != "extract"
            or run.archive_revision_id != revision.id
            or run.phase != "extracting"
        ))
    ):
        revision.status = "stale"
        revision.is_active = False
        revision.error_code = "archive_lifecycle_changed"
        revision.error_message = "章节归档生命周期已变更，本次归档不再适用"
        revision.finished_at = utc_now()
        if chapter.status == "finalized":
            # A failed attempt only invalidates itself. The chapter's own
            # memory source is untouched: the fingerprint also covers prior
            # state, so editing an *earlier* chapter lands here without this
            # chapter's text or whitelist having changed at all. Whoever did
            # invalidate the source already cleared these two fields via
            # invalidate_archive_if_input_changed / _downstream_archives.
            chapter.archive_status = "stale"
        raise ArchiveFingerprintMismatch(revision.error_message)

    if (
        len(validated.deltas) + len(validated.state_uncertainties) > MAX_STATE_DELTAS
        or len(validated.diagnostics) > MAX_STATE_DELTAS
    ):
        raise ArchiveV2ValidationError(
            f"end_state_delta and state uncertainties exceed limit {MAX_STATE_DELTAS}"
        )

    db.execute(
        update(ChapterArchiveRevision)
        .where(ChapterArchiveRevision.chapter_id == chapter.id, ChapterArchiveRevision.is_active.is_(True))
        .values(is_active=False)
    )
    revision.summary = validated.summary
    revision.model_name = model_name
    revision.diagnostics = [dict(item) for item in validated.diagnostics]
    revision.state_uncertainties = [dict(item.payload) for item in validated.state_uncertainties]
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
    for uncertainty in validated.state_uncertainties:
        updated_character_ids.add(uncertainty.character_id)
        if uncertainty.other_character_id:
            updated_character_ids.add(uncertainty.other_character_id)
    revision.status = "complete"
    revision.is_active = True
    revision.validation_errors = []
    revision.error_code = None
    revision.error_message = None
    revision.finished_at = utc_now()
    chapter.active_archive_revision_id = revision.id
    chapter.archive_status = "partial" if validated.state_uncertainties else "complete"
    chapter.archive_input_fingerprint = revision.input_fingerprint
    chapter.legacy_archive_eligible = False
    db.flush()
    return sorted(updated_character_ids), []


def stale_archives_for_reopen(db: Session, chapter: Chapter) -> list[str]:
    """Invalidate every unfinished extractor attempt within the reopen txn."""
    runs = list(
        db.scalars(
            select(JobRun).where(
                JobRun.chapter_id == chapter.id,
                JobRun.kind == "extract",
                JobRun.phase.notin_(("done", "failed", "cancelled")),
            )
        ).all()
    )
    now = utc_now()
    for run in runs:
        run.phase = "cancelled"
        run.error_code = "archive_reopened"
        run.error_message = "章节已重开，归档任务已取消"
        run.finished_at = now
    revisions = db.scalars(
        select(ChapterArchiveRevision).where(
            ChapterArchiveRevision.chapter_id == chapter.id,
            ChapterArchiveRevision.status.in_(("pending", "extracting")),
        )
    ).all()
    for revision in revisions:
        revision.status = "stale"
        revision.is_active = False
        revision.error_code = "archive_reopened"
        revision.error_message = "章节已重开，归档结果已失效"
        revision.finished_at = now
    return [run.id for run in runs]


def mark_revision_partial(
    revision: ChapterArchiveRevision,
    chapter: Chapter,
    *,
    reason: str,
    summary: str = "",
    diagnostics: list[dict[str, Any]] | None = None,
) -> None:
    revision.status = "partial"
    revision.summary = summary.strip() if isinstance(summary, str) else ""
    revision.validation_errors = [reason]
    revision.diagnostics = diagnostics or [_root_diagnostic(reason)]
    revision.state_uncertainties = []
    revision.error_code = "archive_validation_failed"
    revision.error_message = archive_validation_message(reason)
    revision.finished_at = utc_now()
    chapter.archive_status = "complete" if chapter.active_archive_revision_id else "partial"


def mark_revision_failed(
    revision: ChapterArchiveRevision,
    chapter: Chapter,
    *,
    error_code: str,
    error_message: str,
    diagnostics: list[dict[str, Any]] | None = None,
) -> None:
    revision.status = "failed"
    revision.error_code = error_code
    revision.error_message = error_message
    revision.diagnostics = diagnostics or [_root_diagnostic(error_message)]
    revision.state_uncertainties = []
    revision.finished_at = utc_now()
    chapter.archive_status = "complete" if chapter.active_archive_revision_id else "failed"


def invalidate_archive_if_input_changed(
    db: Session,
    chapter: Chapter,
    *,
    previous_fingerprint: str | None = None,
    force: bool = False,
) -> bool:
    active = db.get(ChapterArchiveRevision, chapter.active_archive_revision_id) if chapter.active_archive_revision_id else None
    contract_version = active.contract_version if active is not None else ARCHIVE_CONTRACT_VERSION
    fingerprint = archive_input_fingerprint(chapter, contract_version=contract_version)
    baseline = previous_fingerprint or chapter.archive_input_fingerprint
    if not force and (baseline is None or baseline == fingerprint):
        return False
    changed = bool(chapter.active_archive_revision_id or chapter.legacy_archive_eligible)
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
        if revision.input_fingerprint == archive_input_fingerprint(
            chapter, contract_version=revision.contract_version
        ):
            continue
        revision.is_active = False
        revision.status = "stale"
        revision.error_code = "prior_state_changed"
        revision.error_message = "前置章节的有效状态已变更，本章归档需重新生成"
        revision.finished_at = utc_now()
        chapter.active_archive_revision_id = None
        chapter.archive_status = "stale"
        chapter.archive_input_fingerprint = archive_input_fingerprint(
            chapter, contract_version=revision.contract_version
        )
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
    if revision.input_fingerprint != archive_input_fingerprint(
        chapter, contract_version=revision.contract_version
    ):
        return None
    return revision


def archive_health_summaries(db: Session, chapters: list[Chapter]) -> dict[str, dict[str, Any]]:
    """Return list-safe archive health with a fixed number of SQL statements.

    This is deliberately count/status-only; display previews stay on the
    chapter detail endpoint and inactive rows are never fed back into memory.
    The health decision remains byte-for-byte equivalent to strict detail
    validation: a single rolling projection supplies each chapter's prior
    state rather than making ``archive_input_fingerprint`` re-query history.
    """
    if not chapters:
        return {}
    chapter_ids = [chapter.id for chapter in chapters]
    book_ids = {chapter.book_id for chapter in chapters}
    if len(book_ids) != 1:
        raise ValueError("archive health summaries require one book")
    book_id = next(iter(book_ids))
    revisions = db.scalars(
        select(ChapterArchiveRevision)
        .where(ChapterArchiveRevision.chapter_id.in_(chapter_ids))
        .order_by(ChapterArchiveRevision.chapter_id, ChapterArchiveRevision.revision.desc())
    ).all()
    latest_by_chapter: dict[str, ChapterArchiveRevision] = {}
    by_id = {revision.id: revision for revision in revisions}
    for revision in revisions:
        latest_by_chapter.setdefault(revision.chapter_id, revision)
    active_ids = [chapter.active_archive_revision_id for chapter in chapters if chapter.active_archive_revision_id]
    deltas_by_revision: dict[str, list[ChapterArchiveStateDelta]] = {}
    if active_ids:
        for delta in db.scalars(
            select(ChapterArchiveStateDelta)
            .where(ChapterArchiveStateDelta.revision_id.in_(active_ids))
            .order_by(
                ChapterArchiveStateDelta.revision_id,
                ChapterArchiveStateDelta.position,
                ChapterArchiveStateDelta.id,
            )
        ).all():
            deltas_by_revision.setdefault(delta.revision_id, []).append(delta)
    legacy_by_chapter: dict[str, list[CharacterStateChange]] = {}
    for change in db.scalars(
        select(CharacterStateChange)
        .where(CharacterStateChange.book_id == book_id)
        .order_by(CharacterStateChange.chapter_id, CharacterStateChange.created_at, CharacterStateChange.id)
    ).all():
        legacy_by_chapter.setdefault(change.chapter_id, []).append(change)
    selected_by_chapter: dict[str, list[str]] = {}
    for link in db.scalars(
        select(ChapterCharacter)
        .where(ChapterCharacter.chapter_id.in_(chapter_ids))
        .order_by(ChapterCharacter.chapter_id, ChapterCharacter.character_id)
    ).all():
        selected_by_chapter.setdefault(link.chapter_id, []).append(link.character_id)
    characters = db.scalars(select(Character).where(Character.book_id == book_id)).all()
    cursor = StateProjectionCursor.for_characters(characters, stable_relationship_keys=True)
    result: dict[str, dict[str, Any]] = {}
    for chapter in sorted(chapters, key=lambda item: (item.index, item.id)):
        active = by_id.get(chapter.active_archive_revision_id or "")
        contract_version = active.contract_version if active is not None else ARCHIVE_CONTRACT_VERSION
        expected_fingerprint = archive_input_fingerprint_for_projection(
            chapter,
            cursor.materialize_fields(),
            character_ids=selected_by_chapter.get(chapter.id, []),
            contract_version=contract_version,
            state_uncertainties=cursor.materialize_uncertainties(),
        )
        active_valid = (
            active is not None
            and active.is_active
            and active.status == "complete"
            and active.input_fingerprint == expected_fingerprint
        )
        latest = latest_by_chapter.get(chapter.id)
        has_state_gaps = bool(getattr(active, "state_uncertainties", []) or []) if active_valid else False
        retry_allowed = (
            chapter.status == "finalized"
            and latest is not None
            and (
                latest.status in {"partial", "failed", "stale"}
                or (not active_valid and latest.status == "complete")
                # A v2.1 revision remains DB-complete and active while a
                # verified unknown slot is outstanding.  It is still an
                # author-actionable recovery state, not a terminal success.
                or (
                    latest.is_active
                    and latest.status == "complete"
                    and bool(getattr(latest, "state_uncertainties", []) or [])
                )
            )
        )
        if active_valid:
            schema, status = "v2", ("partial" if has_state_gaps else "complete")
        elif chapter.status == "finalized" and chapter.legacy_archive_eligible:
            schema, status = "legacy", "complete"
        else:
            schema = "none"
            status = _unusable_archive_status(chapter, latest)
        result[chapter.id] = {
            "archive_status": status,
            "archive_schema": schema,
            "archive_can_retry": retry_allowed,
            "archive_latest_attempt_status": latest.status if latest is not None else chapter.archive_status,
            "archive_effective_status": (
                "with_state_gaps" if has_state_gaps else "full"
            ) if active_valid or schema == "legacy" else "none",
            "archive_state_status": "partial" if has_state_gaps else (
                "complete" if active_valid or schema == "legacy" else "none"
            ),
        }
        # Advance only the verified prefix, exactly as _changes_for_projection
        # does; a stale complete pointer must not leak into later prior state.
        if chapter.status != "finalized":
            continue
        if active_valid:
            for delta in deltas_by_revision.get(active.id, []):
                cursor.apply(delta)
            for uncertainty in uncertainty_changes_for_revision(active):
                cursor.apply(uncertainty)
        elif chapter.legacy_archive_eligible or chapter.archive_input_fingerprint is None:
            for change in legacy_by_chapter.get(chapter.id, []):
                cursor.apply(change)
    return result


_DIAGNOSTIC_STRING_LIMITS = {
    "code": 64,
    "severity": 16,
    "character_id": 64,
    "character_name": 120,
    "other_character_id": 64,
    "other_character_name": 120,
    "scope": 32,
    "slot": 64,
    "message": 500,
    "recovery": 300,
}


def _state_uncertainty_display_message(
    record: dict[str, Any],
    *,
    character_names: dict[str, str],
) -> str | None:
    """Regenerate name-bearing text from canonical IDs for public records."""
    character_id = record.get("character_id")
    scope = record.get("scope")
    slot = record.get("slot")
    if not isinstance(character_id, str) or not isinstance(scope, str) or not isinstance(slot, str):
        return None
    character_name = character_names.get(character_id)
    if not character_name:
        return None
    if scope == "relationship":
        other_id = record.get("other_character_id")
        other_name = character_names.get(other_id) if isinstance(other_id, str) else None
        if not other_name:
            return None
        subject = f"{character_name}与{other_name}的关系"
    elif scope in {"snapshot", "persistent"}:
        subject = f"{character_name}的{slot}"
    else:
        return None
    return f"本章中{subject}有多个不一致或不完整的结果，当前无法确定章末状态。"


def _controlled_diagnostics(
    value: Any,
    *,
    character_names: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    """Whitelist persisted diagnostics before exposing them or reusing prompts."""
    if not isinstance(value, list):
        return []
    records: list[dict[str, Any]] = []
    for item in value[:MAX_STATE_DELTAS]:
        if not isinstance(item, dict):
            continue
        record: dict[str, Any] = {}
        for key, limit in _DIAGNOSTIC_STRING_LIMITS.items():
            field = item.get(key)
            if field is None and key in {"other_character_id", "other_character_name"}:
                record[key] = None
            elif isinstance(field, str) and field.strip():
                record[key] = field.strip()[:limit]
        for key, limit in (("fact_refs", 8), ("span_ids", 16)):
            values = item.get(key)
            if isinstance(values, list):
                record[key] = [entry[:16] for entry in values[:limit] if isinstance(entry, str) and entry.strip()]
            else:
                record[key] = []
        variants = item.get("variants")
        record["variants"] = [
            {
                "operation": entry["operation"],
                "value": entry.get("value")[:MAX_STATE_VALUE_CHARS]
                if isinstance(entry.get("value"), str) else None,
            }
            for entry in variants[:4]
            if isinstance(entry, dict)
            and isinstance(entry.get("operation"), str)
            and entry.get("operation") in {"set", "clear"}
        ] if isinstance(variants, list) else []
        # IDs, rather than old diagnostic display names, are the durable
        # identity.  A renamed card must be rendered with its current name.
        if character_names:
            for id_key, name_key in (
                ("character_id", "character_name"),
                ("other_character_id", "other_character_name"),
            ):
                character_id = record.get(id_key)
                if isinstance(character_id, str) and character_id in character_names:
                    record[name_key] = character_names[character_id]
            if record.get("code") == "state_slot_uncertain":
                message = _state_uncertainty_display_message(record, character_names=character_names)
                if message is not None:
                    record["message"] = message
                    record["recovery"] = "请重新整理本章，并为该状态槽保留唯一、可追溯的章末结果。"
        if all(key in record for key in ("code", "severity", "message", "recovery")):
            records.append(record)
    return records


def canonicalize_archive_diagnostics(
    value: Any,
    *,
    character_names: dict[str, str],
) -> list[dict[str, Any]]:
    """Return a controlled archive diagnostic rendering for public transport."""
    return _controlled_diagnostics(value, character_names=character_names)


def _latest_attempt_read(revision: ChapterArchiveRevision | None) -> dict[str, Any] | None:
    if revision is None:
        return None
    return {
        "revision_id": revision.id,
        "revision": revision.revision,
        "status": revision.status,
        "error_code": revision.error_code,
        "error_message": archive_validation_message(revision.error_message),
        "finished_at": revision.finished_at,
    }


def _unusable_archive_status(chapter: Chapter, latest: ChapterArchiveRevision | None) -> str:
    if chapter.archive_status == "complete" or (latest is not None and latest.status == "complete"):
        return latest.status if latest is not None and latest.status != "complete" else "stale"
    return chapter.archive_status


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
        and (
            latest.status in {"partial", "failed", "stale"}
            or (active is None and latest.status == "complete")
            or (
                latest.is_active
                and latest.status == "complete"
                and bool(getattr(latest, "state_uncertainties", []) or [])
            )
        )
    )
    inactive_preview = None
    if latest is not None and latest is not active and latest.status in {"partial", "failed", "stale"}:
        # This deliberately exposes only a compact, inactive display record.
        # It is not shaped like active facts and no selector/projection reads it.
        inactive_preview = {
            "revision_id": latest.id,
            "revision": latest.revision,
            "status": latest.status,
            "summary": latest.summary,
            "fact_count": len(latest.facts),
            "state_delta_count": len(latest.state_deltas),
        }
    if active is not None:
        current_names = {
            link.character_id: link.character.name
            for link in chapter.character_links
            if link.character_id and link.character.name
        }
        state_uncertainties = _controlled_diagnostics(
            getattr(active, "state_uncertainties", []), character_names=current_names
        )
        diagnostics = _controlled_diagnostics(
            getattr(active, "diagnostics", []), character_names=current_names
        )
        has_state_gaps = bool(state_uncertainties)
        return {
            # The legacy field is a display aggregate.  It deliberately does
            # not turn the complete DB revision into a partial active row.
            "status": "partial" if has_state_gaps else "complete",
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
            "inactive_preview": inactive_preview,
            "effective_status": "with_state_gaps" if has_state_gaps else "full",
            "state_status": "partial" if has_state_gaps else "complete",
            "state_uncertainties": state_uncertainties,
            "diagnostics": diagnostics,
            "latest_attempt": _latest_attempt_read(latest),
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
            "error_message": archive_validation_message(latest.error_message) if latest is not None else None,
            "can_retry": retry_allowed,
            "latest_attempt_status": latest.status if latest is not None else "legacy",
            "inactive_preview": inactive_preview,
            "effective_status": "full",
            "state_status": "complete",
            "state_uncertainties": [],
            "diagnostics": _controlled_diagnostics(getattr(latest, "diagnostics", [])) if latest else [],
            "latest_attempt": _latest_attempt_read(latest),
        }
    return {
        "status": _unusable_archive_status(chapter, latest),
        "schema": "none",
        "revision_id": None,
        "revision": None,
        "summary": "",
        "facts": [],
        "state_delta_count": 0,
        "error_code": latest.error_code if latest is not None else None,
        "error_message": archive_validation_message(latest.error_message) if latest is not None else None,
        "can_retry": retry_allowed,
        "latest_attempt_status": latest.status if latest is not None else chapter.archive_status,
        "inactive_preview": inactive_preview,
        "effective_status": "none",
        "state_status": "none",
        "state_uncertainties": [],
        "diagnostics": _controlled_diagnostics(getattr(latest, "diagnostics", [])) if latest else [],
        "latest_attempt": _latest_attempt_read(latest),
    }
