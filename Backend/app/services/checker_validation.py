"""Deterministic validation of Checker evidence and name-use classifications."""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from typing import Any


SOURCE_KINDS = {
    "bible", "world", "character", "prior_state", "history", "draft", "authorization",
}
NAME_CLASSIFICATIONS = {"character", "ordinary_word", "uncertain"}
MISSING_REQUIREMENT_KIND = "missing_requirement"
IDENTITY_ISSUE_KINDS = {"unselected_character", "ambiguous_character", "uncertain_character"}


class CheckerValidationError(ValueError):
    """A model response cannot truthfully be persisted as a Checker conclusion."""

    def __init__(
        self,
        message: str = "检查结果不符合协议",
        *,
        reason_code: str = "invalid_protocol",
        diagnostics: dict[str, int | str] | None = None,
    ) -> None:
        super().__init__(message)
        self.reason_code = reason_code
        # These are deliberately structural counters only.  They can be kept
        # with a private JobRun without retaining names, candidate prose,
        # model reasons, or copied protocol tokens.
        self.diagnostics = {
            key: value
            for key, value in (diagnostics or {}).items()
            if key in {
                "protocol_version", "expected_group_count", "received_row_count",
                "unknown_group_count", "missing_group_count", "duplicate_group_count",
            }
            and isinstance(value, (int, str))
            and (not isinstance(value, int) or 0 <= value <= 10_000)
        }


def normalize_for_evidence(value: str) -> str:
    """NFKC plus whitespace-only normalization; never a semantic/fuzzy match."""
    return "".join(unicodedata.normalize("NFKC", value or "").split())


def _contains_exact(source: str, evidence: str) -> bool:
    normalized_evidence = normalize_for_evidence(evidence)
    return bool(normalized_evidence) and normalized_evidence in normalize_for_evidence(source)


def _catalog(snapshot: dict[str, Any]) -> dict[str, dict[str, str]]:
    raw = snapshot.get("source_catalog")
    entries = raw.values() if isinstance(raw, dict) else raw
    if not isinstance(entries, list) and not isinstance(entries, type({}.values())):
        raise CheckerValidationError("冻结来源目录不存在")
    result: dict[str, dict[str, str]] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise CheckerValidationError("冻结来源目录无效")
        kind, source_id, text = entry.get("kind"), entry.get("id"), entry.get("text")
        if kind not in SOURCE_KINDS or not isinstance(source_id, str) or not source_id or not isinstance(text, str):
            raise CheckerValidationError("冻结来源目录条目无效")
        if source_id in result:
            raise CheckerValidationError("冻结来源目录含重复 ID")
        result[source_id] = {"kind": kind, "text": text}
    return result


def _issue_error(issue: Any, sources: dict[str, dict[str, str]], *, bible_empty: bool) -> str | None:
    if not isinstance(issue, dict):
        return "issue 不是对象"
    required = {
        "kind", "reason", "draft_evidence", "bible_evidence",
        "source_kind", "source_id", "source_evidence",
    }
    if set(issue) != required:
        return "issue 字段不符合检查协议"
    if any(not isinstance(issue.get(key), str) for key in required):
        return "issue 必须全部使用字符串字段"
    kind = issue["kind"].strip()
    reason = issue["reason"].strip()
    source_kind = issue["source_kind"].strip()
    source_id = issue["source_id"].strip()
    source_evidence = issue["source_evidence"].strip()
    draft_evidence = issue["draft_evidence"].strip()
    bible_evidence = issue["bible_evidence"].strip()
    if not kind or not reason or source_kind not in SOURCE_KINDS or not source_id or not source_evidence:
        return "issue 缺少必要类型、理由或来源证据"
    source = sources.get(source_id)
    if source is None or source["kind"] != source_kind:
        return "issue 引用了不存在或类型不符的来源"
    if source_id == "prior_state:unknown":
        return "待定状态只说明资料范围，不能单独作为正文矛盾或必需事件的证据"
    if not _contains_exact(source["text"], source_evidence):
        return "issue 来源引文不在冻结来源中"
    if source_kind == "bible":
        if bible_empty:
            return "空 Bible 不允许引用 Bible 问题"
        if not bible_evidence or not _contains_exact(source["text"], bible_evidence):
            return "Bible 问题缺少可核实的 Bible 引文"
    elif bible_evidence:
        return "非 Bible 问题不得伪造 Bible 引文"
    if kind == MISSING_REQUIREMENT_KIND:
        if source_kind != "bible" or not bible_evidence:
            return "核心要求遗漏必须引用非空 Bible"
        if draft_evidence:
            return "核心要求遗漏不得把缺失伪造成正文引文"
    elif not draft_evidence:
        # A name may occur in Bible while the checked prose has not used it
        # yet.  The corresponding authorization problem is evidenced by that
        # exact Bible occurrence, not by a fabricated draft quotation.
        if not (kind in IDENTITY_ISSUE_KINDS and source_kind == "bible" and bible_evidence):
            return "非遗漏问题必须引用正文"
    if draft_evidence:
        draft = sources.get("draft")
        if draft is None or not _contains_exact(draft["text"], draft_evidence):
            return "正文引文不在冻结正文中"
    return None


def _program_name_groups(snapshot: dict[str, Any], hits: dict[str, dict[str, Any]]) -> dict[frozenset[str], dict[str, Any]]:
    raw_groups = snapshot.get("name_groups")
    if not isinstance(raw_groups, list):
        raise CheckerValidationError("冻结姓名分组目录无效")
    result: dict[frozenset[str], dict[str, Any]] = {}
    grouped_ids: set[str] = set()
    for group in raw_groups:
        if not isinstance(group, dict) or set(group) != {
            "hit_ids", "source_id", "name", "candidate_key", "local_context",
        }:
            raise CheckerValidationError("冻结姓名分组目录无效")
        hit_ids = group.get("hit_ids")
        if (
            not isinstance(hit_ids, list) or not hit_ids
            or any(not isinstance(value, str) or value not in hits for value in hit_ids)
            or len(set(hit_ids)) != len(hit_ids)
            or any(not isinstance(group.get(key), str) for key in ("source_id", "name", "candidate_key", "local_context"))
        ):
            raise CheckerValidationError("冻结姓名分组目录无效")
        key = frozenset(hit_ids)
        if key in result or grouped_ids.intersection(key):
            raise CheckerValidationError("冻结姓名分组目录重复")
        first = hits[hit_ids[0]]
        if any(
            hits[hit_id]["source_id"] != first["source_id"]
            or hits[hit_id]["text"] != first["text"]
            or hits[hit_id]["candidate_character_ids"] != first["candidate_character_ids"]
            or hits[hit_id]["selected_character_ids"] != first["selected_character_ids"]
            for hit_id in hit_ids
        ):
            raise CheckerValidationError("冻结姓名分组混入不兼容候选")
        if group["source_id"] != first["source_id"] or group["name"] != first["text"]:
            raise CheckerValidationError("冻结姓名分组与命中不一致")
        result[key] = group
        grouped_ids.update(key)
    if grouped_ids != set(hits):
        raise CheckerValidationError("冻结姓名分组未覆盖全部命中")
    return result


def numbered_name_groups(groups: list[dict[str, Any]] | tuple[dict[str, Any], ...]) -> list[tuple[str, dict[str, Any]]]:
    """Give frozen name groups stable request-local IDs in their saved order.

    The same pure numbering is used when rendering the model prompt and when
    interpreting the response.  It intentionally does not rewrite the
    persisted v1 ``name_groups`` rows or any frozen fingerprint.
    """
    return [(f"g{index}", group) for index, group in enumerate(groups, start=1)]


def _checked_name_uses(
    raw_uses: list[Any],
    hits: dict[str, dict[str, Any]],
    snapshot: dict[str, Any],
) -> list[dict[str, Any]]:
    grouped = _program_name_groups(snapshot, hits)
    groups = dict(numbered_name_groups(list(grouped.values())))
    seen_groups: set[str] = set()
    result: list[dict[str, Any]] = []
    for item in raw_uses:
        if not isinstance(item, dict):
            raise CheckerValidationError("name_use 不是对象", reason_code="invalid_name_use_row")
        allowed = {"group_id", "classification", "reason", "character_id"}
        required = {"group_id", "classification", "reason"}
        if not set(item).issubset(allowed) or not required.issubset(item):
            raise CheckerValidationError("name_use 字段不符合协议", reason_code="invalid_name_use_fields")
        group_id = item.get("group_id")
        classification = item.get("classification")
        reason = item.get("reason")
        character_id = item.get("character_id")
        if (
            not isinstance(group_id, str) or not group_id
            or classification not in NAME_CLASSIFICATIONS
            or not isinstance(reason, str) or not reason.strip()
        ):
            raise CheckerValidationError("name_use 缺少分组、分类或理由", reason_code="invalid_name_use_values")
        group = groups.get(group_id)
        if group is None:
            raise CheckerValidationError(
                "name_use 引用了未知分组",
                reason_code="unknown_group_id",
                diagnostics={
                    "protocol_version": "group_id_v1",
                    "expected_group_count": len(groups),
                    "received_row_count": len(raw_uses),
                    "unknown_group_count": 1,
                },
            )
        if group_id in seen_groups:
            raise CheckerValidationError(
                "同一姓名分组被重复分类",
                reason_code="duplicate_group_id",
                diagnostics={
                    "protocol_version": "group_id_v1",
                    "expected_group_count": len(groups),
                    "received_row_count": len(raw_uses),
                    "duplicate_group_count": 1,
                },
            )
        first = hits[group["hit_ids"][0]]
        if character_id is not None and (
            not isinstance(character_id, str) or character_id not in first["candidate_character_ids"]
        ):
            raise CheckerValidationError("name_use 的人物 ID 不属于该姓名候选", reason_code="invalid_character_id")
        if classification == "ordinary_word" and character_id is not None:
            raise CheckerValidationError("普通词不能绑定人物 ID", reason_code="invalid_character_id")
        seen_groups.add(group_id)
        for hit_id in group["hit_ids"]:
            hit = hits[hit_id]
            # Exact evidence and offset are program-reconstructed from the
            # frozen hit.  The model only makes the semantic classification,
            # so 500 distinct hits no longer require 500 copied quotations.
            result.append({
                "hit_id": hit_id,
                "classification": classification,
                "draft_evidence": hit["text"],
                "reason": reason.strip(),
                **({"character_id": character_id} if character_id is not None else {}),
                "evidence_start": hit["source_start"],
                "evidence_end": hit["source_end"],
            })
    if seen_groups != set(groups):
        raise CheckerValidationError(
            "Checker 未逐项处理程序提供的姓名分组",
            reason_code="missing_group_id",
            diagnostics={
                "protocol_version": "group_id_v1",
                "expected_group_count": len(groups),
                "received_row_count": len(raw_uses),
                "missing_group_count": len(set(groups) - seen_groups),
            },
        )
    return result


def _identity_issue_required(hit: dict[str, Any], classification: str) -> str:
    if classification == "uncertain":
        return "uncertain_character"
    owners = hit["candidate_character_ids"]
    selected = hit["selected_character_ids"]
    if len(owners) > 1 and len(selected) != 1:
        return "ambiguous_character"
    return "unselected_character"


def _identity_issue_covers(issue: dict[str, Any], hit: dict[str, Any], expected_kind: str) -> bool:
    evidence = issue.get("draft_evidence") or issue.get("bible_evidence")
    return (
        issue.get("kind") == expected_kind
        and isinstance(evidence, str)
        and _contains_exact(evidence, hit["text"])
    )


def _safe_identity_issues(
    checked_uses: list[dict[str, Any]],
    hits: dict[str, dict[str, Any]],
    snapshot: dict[str, Any],
) -> list[dict[str, Any]]:
    """Derive UI-safe repair choices from program-owned, not model, identity.

    Rejected candidates may never expose their prose or model evidence.  These
    rows carry only a known name and character-card fields already available
    to the book owner, so clients can select a character or add a name
    exemption without parsing a human-language Checker reason.
    """
    raw_known = snapshot.get("known_characters", [])
    if not isinstance(raw_known, list):
        return []
    known: dict[str, dict[str, str]] = {}
    for row in raw_known:
        if not isinstance(row, dict):
            continue
        character_id, name = row.get("id"), row.get("name")
        if not isinstance(character_id, str) or not isinstance(name, str):
            continue
        role = row.get("role")
        profile = row.get("fixed_profile")
        known[character_id] = {
            "character_id": character_id,
            "name": name,
            "role": role if isinstance(role, str) else "",
            "fixed_profile": profile if isinstance(profile, str) else "",
        }
    result: list[dict[str, Any]] = []
    for use in checked_uses:
        if use["classification"] == "ordinary_word":
            continue
        hit = hits[use["hit_id"]]
        candidate_rows = [
            known[character_id]
            for character_id in hit["candidate_character_ids"]
            if character_id in known
        ]
        result.append({
            "kind": _identity_issue_required(hit, use["classification"]),
            "match_id": hit["hit_id"],
            "name": hit["text"],
            "name_candidates": candidate_rows,
        })
    return result


@dataclass(frozen=True)
class ValidatedCheckerResult:
    result: dict[str, Any]


def validate_checker_result(
    raw: Any,
    snapshot: dict[str, Any],
    *,
    check_attempt_id: str | None = None,
) -> dict[str, Any]:
    """Return only a contract-consistent Checker result or raise a safe error.

    The caller must turn :class:`CheckerValidationError` into an unavailable
    Checker attempt.  In particular, this function never deletes malformed
    issues and never converts an invalid non-passing result into ``passed``.
    """
    if not isinstance(raw, dict) or set(raw) != {"verdict", "issues", "name_uses"}:
        raise CheckerValidationError("Checker 返回字段不符合协议")
    verdict = raw.get("verdict")
    issues = raw.get("issues")
    name_uses = raw.get("name_uses")
    if verdict not in {"passed", "suspect", "violation"} or not isinstance(issues, list) or not isinstance(name_uses, list):
        raise CheckerValidationError("Checker 返回结论或数组无效")
    sources = _catalog(snapshot)
    bible_empty = not str(snapshot.get("bible", "")).strip()
    checked_issues: list[dict[str, str]] = []
    for issue in issues:
        problem = _issue_error(issue, sources, bible_empty=bible_empty)
        if problem:
            raise CheckerValidationError(problem)
        checked_issues.append({key: issue[key].strip() for key in (
            "kind", "reason", "draft_evidence", "bible_evidence", "source_kind", "source_id", "source_evidence",
        )})
    if verdict == "passed" and checked_issues:
        raise CheckerValidationError("passed 不能携带 issue")

    raw_hits = snapshot.get("name_hits", [])
    if not isinstance(raw_hits, list):
        raise CheckerValidationError("冻结姓名命中目录无效")
    hits = {item.get("hit_id"): item for item in raw_hits if isinstance(item, dict) and isinstance(item.get("hit_id"), str)}
    if len(hits) != len(raw_hits):
        raise CheckerValidationError("冻结姓名命中目录无效")
    checked_uses = _checked_name_uses(name_uses, hits, snapshot)
    for item in checked_uses:
        if item["classification"] == "ordinary_word":
            continue
        hit = hits[item["hit_id"]]
        expected_kind = _identity_issue_required(hit, item["classification"])
        if not any(_identity_issue_covers(issue, hit, expected_kind) for issue in checked_issues):
            # Classification is the only semantic decision needed from the model.
            # Authorization and its evidence are already frozen program facts;
            # do not fail the whole check because the model omitted a duplicate issue.
            source_id = hit["source_id"]
            source = sources.get(source_id)
            if source is None or not _contains_exact(source["text"], hit["text"]):
                raise CheckerValidationError("姓名命中缺少有效冻结来源")
            checked_issues.append({
                "kind": expected_kind,
                "reason": {
                    "unselected_character": f"“{hit['text']}”被识别为人物，但未加入本章人物；请补选人物或设置姓名豁免。",
                    "ambiguous_character": f"“{hit['text']}”对应多个同名人物；请明确本章使用的人物。",
                    "uncertain_character": f"“{hit['text']}”的身份尚不明确；请确认人物选择或设置姓名豁免。",
                }[expected_kind],
                "draft_evidence": hit["text"] if source_id == "draft" else "",
                "bible_evidence": hit["text"] if source_id == "bible" else "",
                "source_kind": source["kind"], "source_id": source_id,
                "source_evidence": hit["text"],
            })
        if item["classification"] == "character":
            verdict = "violation"
        elif verdict == "passed":
            verdict = "suspect"
    if verdict != "passed" and not checked_issues:
        raise CheckerValidationError("suspect 或 violation 必须携带有效 issue")

    result: dict[str, Any] = {
        "verdict": verdict,
        "issues": checked_issues,
        "name_uses": checked_uses,
        "identity_issues": _safe_identity_issues(checked_uses, hits, snapshot),
        "input_fingerprint": str(snapshot.get("input_fingerprint", "")),
    }
    if check_attempt_id:
        result["check_attempt_id"] = check_attempt_id
    return result


def checker_failure_message(exc: Exception) -> str:
    """Public copy deliberately never exposes protocol internals."""
    if isinstance(exc, CheckerValidationError):
        return "检查未能完成，尚未得到可用结论；可重新复查"
    return "检查模型未返回有效检查结论"


def checker_failure_diagnostics(exc: Exception) -> dict[str, int | str]:
    """Return safe private structure diagnostics for JobRun persistence."""
    if not isinstance(exc, CheckerValidationError):
        return {"reason_code": "invalid_response"}
    return {"reason_code": exc.reason_code, **exc.diagnostics}
