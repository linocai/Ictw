"""Mechanical previous-chapter delivery and source-only distant memory selection.

No model interprets, summarises or truncates these sources. The original
v1/v2 context helpers remain unchanged for retained production snapshots.
"""
from __future__ import annotations

import hashlib
import json
import re
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Chapter, Character
from app.services.archive_v2 import active_archive_revision, archive_input_fingerprint, CONTINUITY_KEYS
from app.services.context import (
    MemoryBlock, MEMORY_BUDGET_CHARS, PREVIOUS_ENDING_MAX_CHARS,
    MAX_MEMORY_BRIEFS, MAX_MEMORY_CONFLICTS, PackedWriterContext,
    has_usable_legacy_memory, memory_candidates, memory_participant_ids,
    nonspace_len, prefilter_memory_candidates,
)

SELECTOR_CONTRACT_VERSION = "source-selection-v1"
_LABELS = dict(zip(CONTINUITY_KEYS, ("已发生起点", "已知事实", "最后落点", "未决事项")))


def _hash(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def complete_ending(text: str) -> str:
    """Keep complete final sentences/paragraphs within the existing tail budget."""
    paragraphs = [part.strip() for part in re.split(r"\n\s*", text.strip()) if part.strip()]
    # Sentence-final punctuation and closing quotes belong to the same unit;
    # otherwise an oversized final quote can leave only its closing mark.
    units = [sentence.strip() for paragraph in paragraphs
             for sentence in re.findall(r""".+?(?:[。！？!?；;]+[”’」』"']*|$)""", paragraph)
             if sentence.strip()]
    chosen: list[str] = []
    used = 0
    for unit in reversed(units):
        size = nonspace_len(unit)
        if used + size > PREVIOUS_ENDING_MAX_CHARS:
            break
        chosen.append(unit)
        used += size
    return "\n".join(reversed(chosen))


def previous_context_identity(context: dict[str, Any]) -> str:
    """Ignore only durable row IDs; retain order, classification and all wording."""
    return _hash({
        key: value for key, value in context.items()
        if key not in {"semantic_identity", "revision_id", "sources", "limitations"}
    } | {"sources": [{key: value for key, value in row.items() if key not in {"id", "original_source_id"}}
                     for row in context.get("sources", [])]})


def previous_chapter_context(db: Session, chapter: Chapter) -> dict[str, Any]:
    previous = db.scalar(select(Chapter).where(
        Chapter.book_id == chapter.book_id, Chapter.index == chapter.index - 1,
    )) if chapter.index > 1 else None
    result: dict[str, Any] = {
        "chapter_id": previous.id if previous else None,
        "chapter_index": previous.index if previous else max(0, chapter.index - 1),
        "title": previous.title if previous else "",
        "mode": "none" if chapter.index <= 1 else "unavailable",
        "status": previous.status if previous else "missing",
        "contract_version": None, "revision_id": None,
        "sources": [], "previous_ending": "", "limitations": [],
    }

    def limitation(kind: str, reason: str) -> None:
        if any(item["kind"] == kind for item in result["limitations"]):
            return
        result["limitations"].append({
            "chapter_id": previous.id if previous else chapter.id,
            "chapter_index": previous.index if previous else chapter.index - 1,
            "title": previous.title if previous else "上一章",
            "kind": kind, "reason": reason,
        })

    if previous is None or previous.status != "finalized":
        if chapter.index > 1:
            limitation("missing_previous_chapter", "紧邻上一章不存在或尚未接受，不能提供承接资料")
        result["semantic_identity"] = previous_context_identity(result)
        return result

    revision = active_archive_revision(db, previous)
    legacy = revision is None and has_usable_legacy_memory(previous)
    # A matching extraction attempt proves the accepted manuscript identity
    # even when that single attempt failed. Edited/reopened prose is excluded.
    accepted = revision is not None or legacy or any(
        item.input_fingerprint == archive_input_fingerprint(previous, contract_version=item.contract_version)
        and previous.archive_input_fingerprint == item.input_fingerprint
        for item in previous.archive_revisions
    )
    result["accepted_draft_sha256"] = hashlib.sha256(previous.draft_text.encode()).hexdigest() if accepted else None
    if accepted:
        result["previous_ending"] = complete_ending(previous.draft_text)
        if previous.draft_text.strip() and not result["previous_ending"]:
            limitation("previous_ending_unavailable", "上一章末句超过700字，无法提供完整结尾原文")
    blocks = [block for block in memory_candidates(db, chapter)
              if block.source_chapter_id == previous.id and block.memory_type != "previous_ending"]
    if revision is not None:
        result.update(mode="v2", contract_version=revision.contract_version, revision_id=revision.id)
        refs_by_id = {fact.id: fact.fact_ref for fact in revision.facts}
        continuity = revision.continuity or {}
        result["state_uncertainties"] = [{key: value for key, value in item.items()
                                          if key not in {"revision_id", "fact_id"}}
                                         for item in revision.state_uncertainties or []]
        # Preserve physical canonical fact order, independently of relevance.
        blocks.sort(key=lambda block: (block.memory_type != "summary", block.source_position))
        for block in blocks:
            fact_ref = refs_by_id.get(block.id.removeprefix("archive_v2_fact:"))
            labels = [_LABELS[key] for key in CONTINUITY_KEYS if fact_ref in continuity.get(key, [])]
            _append_source(result, block, labels or (["章节摘要"] if block.memory_type == "summary" else ["无分类事实"]), db)
    elif legacy:
        result["mode"] = "legacy"
        used = 0
        for block in sorted(blocks, key=lambda block: (block.memory_type != "summary", block.source_position, block.id)):
            size = nonspace_len(block.text)
            if used + size > 8000:
                limitation("legacy_previous_omitted", "上一章旧记忆超过承接范围，部分整条来源未采用")
                continue
            _append_source(result, block, ["章节摘要"] if block.memory_type == "summary" else ["未决事项"] if block.memory_type == "unresolved_item" else ["无分类事实"], db)
            used += size
    elif accepted:
        result["mode"] = "ending_only"
    if result["previous_ending"]:
        result["sources"].append({
            "id": f"history:previous:{previous.id}:ending", "text": result["previous_ending"],
            "original_source_id": f"previous_ending:{previous.id}",
            "kind": "ending", "labels": ["已接受结尾"], "participant_ids": [],
        })
    result["semantic_identity"] = previous_context_identity(result)
    return result


def _append_source(context: dict[str, Any], block: MemoryBlock, labels: list[str], db: Session) -> None:
    context["sources"].append({
        "id": f"history:previous:{context['chapter_id']}:" + ("summary" if block.memory_type == "summary" else f"fact:{len(context['sources'])}"),
        "original_source_id": block.id, "text": block.text,
        "kind": "summary" if block.memory_type == "summary" else "fact",
        "labels": labels, "participant_ids": list(memory_participant_ids(block)),
        "fact_type": block.fact_type,
        "participant_names": [character.name for participant_id in memory_participant_ids(block)
                              if (character := db.get(Character, participant_id)) is not None],
    })


def render_previous_context(context: dict[str, Any]) -> str:
    if not context.get("sources"):
        return "（没有可用的紧邻上一章承接资料）"
    heading = f"第 {context['chapter_index']} 章：{context['title']}；来源模式：{context['mode']}"
    if context["mode"] == "v2" and context.get("contract_version") != "archive-v2.2":
        heading += "（旧归档无承接分类，不推断分类）"
    if context["mode"] == "ending_only":
        heading += "（仅结尾，不代表完整承接记忆）"
    return heading + "\n\n" + "\n\n".join(
        f"[{row['id']}] {'／'.join(row['labels'])}" +
        (f"；事实参与者：{'、'.join(row['participant_names'])}（名单不代表人人均已知）" if row.get("participant_names") else "") +
        f"\n{row['text']}" for row in context["sources"]
    ) + ("\n\n章末状态待定，仅说明资料不足，不能作为相反事实。" if context.get("state_uncertainties") else "")


def distant_candidates(db: Session, chapter: Chapter) -> list[MemoryBlock]:
    blocks = [block for block in memory_candidates(db, chapter)
              if block.chapter_index <= chapter.index - 2 and block.memory_type != "previous_ending"
              and nonspace_len(block.text) <= MEMORY_BUDGET_CHARS]
    return prefilter_memory_candidates(blocks, chapter=chapter,
        selected_character_ids={link.character_id for link in chapter.character_links})


def source_selection_problem(blocks: list[MemoryBlock], briefs: Any, conflicts: Any, ending: Any = None,
                             *, budget: int = MEMORY_BUDGET_CHARS) -> str | None:
    if ending is not None:
        return "新选择协议不得返回上一章结尾"
    if not isinstance(briefs, list) or not isinstance(conflicts, list):
        return "选择来源必须为数组"
    if len(briefs) > MAX_MEMORY_BRIEFS or len(conflicts) > MAX_MEMORY_CONFLICTS:
        return "选择来源超过条数上限"
    by_id = {block.id: block for block in blocks}
    seen: set[str] = set()
    size = 0
    for row in briefs + conflicts:
        if not isinstance(row, dict) or set(row) != {"text", "source_ids"} or not isinstance(row["source_ids"], list) or len(row["source_ids"]) != 1:
            return "每条只允许引用一个原文来源"
        source_id = row["source_ids"][0]
        if not isinstance(source_id, str) or source_id not in by_id or source_id in seen:
            return "来源不存在、重复或跨数组重用"
        block = by_id[source_id]
        if row["text"] != block.text:
            return "选择文本必须完全等于原始来源"
        seen.add(source_id)
        size += nonspace_len(block.text)
    return "选择的整条原文超过2400字预算" if size > budget else None


def pack_source_selection(blocks: list[MemoryBlock], briefs: list[dict], conflicts: list[dict],
                          *, budget: int = MEMORY_BUDGET_CHARS) -> PackedWriterContext:
    problem = source_selection_problem(blocks, briefs, conflicts, budget=budget)
    if problem:
        raise ValueError(problem)
    by_id = {block.id: block for block in blocks}
    return PackedWriterContext([by_id[row["source_ids"][0]] for row in briefs],
                               conflicts=[by_id[row["source_ids"][0]] for row in conflicts])
