from __future__ import annotations

import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from difflib import SequenceMatcher
from typing import Any

from app.llm.base import LLMClient, LLMError
from app.services.context import nonspace_len, normalize_text, scan_known_character_names
from app.services.personas import compose_system_prompt


INSPIRATION_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "cards": {
            "type": "array",
            "minItems": 3,
            "maxItems": 5,
            "items": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                    "history_basis": {"type": ["string", "null"]},
                    "note": {"type": ["string", "null"]},
                    "source_ids": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["title", "body", "history_basis", "note", "source_ids"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["cards"],
    "additionalProperties": False,
}

MAX_CARD_NONSPACE_CHARS = 300
MIN_CARDS = 3
MAX_CARDS = 5
MAX_SOURCE_IDS_PER_CARD = 6


@dataclass(frozen=True)
class InspirationCard:
    title: str
    body: str
    history_basis: str | None
    note: str | None
    history_chapter_indexes: tuple[int, ...]


AuditAttempt = Callable[[int, str | None, str | None], None]


class InspirationValidationError(ValueError):
    def __init__(self, category: str) -> None:
        self.category = category
        super().__init__(category)


class InspirationCreatorAgent:
    def __init__(self, llm: LLMClient, editable_persona: str) -> None:
        self.llm = llm
        self.system_prompt = compose_system_prompt("inspiration_creator", editable_persona)

    def generate(
        self,
        user_message: str,
        *,
        source_chapter_indexes: Mapping[str, int],
        known_characters: Sequence[Any],
        selected_character_ids: set[str],
        audit_attempt: AuditAttempt | None = None,
    ) -> list[InspirationCard]:
        correction = ""
        for attempt in range(2):
            started = time.monotonic()
            try:
                output = self.llm.complete_json(
                    system=self.system_prompt,
                    user=user_message + correction,
                    schema=INSPIRATION_SCHEMA,
                    temperature=0.8,
                    max_tokens=2500,
                    timeout=180,
                    hard_timeout=True,
                )
                cards = validate_inspiration_output(
                    output,
                    source_chapter_indexes=source_chapter_indexes,
                    known_characters=known_characters,
                    selected_character_ids=selected_character_ids,
                )
            except InspirationValidationError as exc:
                _audit(audit_attempt, started, "inspiration_invalid_response", None)
                if attempt == 0:
                    correction = (
                        "\n\n# 程序退回\n上一次结果未通过程序校验（"
                        + exc.category
                        + "）。请重新给出 3–5 条真正不同的灵感，并严格遵守 JSON、来源、人物与每条 300 字上限。"
                    )
                    continue
                raise LLMError(
                    "Inspiration output failed deterministic validation",
                    code="inspiration_invalid_response",
                    retryable=False,
                    agent_role="inspiration_creator",
                ) from exc
            except LLMError as exc:
                _audit(audit_attempt, started, exc.code, exc.upstream_reason)
                if attempt == 0 and exc.code in {"llm_invalid_response", "llm_output_truncated"}:
                    correction = (
                        "\n\n# 程序退回\n上一次结果不是完整合法的 JSON。"
                        "请重新输出完整 object，并严格遵守 3–5 条、人物与 300 字上限。"
                    )
                    continue
                exc.agent_role = "inspiration_creator"
                raise
            _audit(audit_attempt, started, None, None)
            return cards
        raise LLMError(
            "Inspiration output failed deterministic validation",
            code="inspiration_invalid_response",
            retryable=False,
            agent_role="inspiration_creator",
        )


def validate_inspiration_output(
    output: dict[str, Any],
    *,
    source_chapter_indexes: Mapping[str, int],
    known_characters: Sequence[Any],
    selected_character_ids: set[str],
) -> list[InspirationCard]:
    if set(output) != {"cards"}:
        raise InspirationValidationError("response_shape")
    raw_cards = output.get("cards")
    if not isinstance(raw_cards, list) or not MIN_CARDS <= len(raw_cards) <= MAX_CARDS:
        raise InspirationValidationError("card_count")
    cards: list[InspirationCard] = []
    normalized_ideas: list[str] = []
    for raw in raw_cards:
        if not isinstance(raw, dict):
            raise InspirationValidationError("card_shape")
        if set(raw) != {"title", "body", "history_basis", "note", "source_ids"}:
            raise InspirationValidationError("card_shape")
        title = _required_text(raw.get("title"))
        body = _required_text(raw.get("body"))
        history_basis = _optional_text(raw.get("history_basis"))
        note = _optional_text(raw.get("note"))
        if nonspace_len(title + body + (history_basis or "") + (note or "")) > MAX_CARD_NONSPACE_CHARS:
            raise InspirationValidationError("card_length")
        raw_source_ids = raw.get("source_ids")
        if not isinstance(raw_source_ids, list):
            raise InspirationValidationError("history_sources")
        source_ids = tuple(
            dict.fromkeys(
                item.strip() for item in raw_source_ids if isinstance(item, str) and item.strip()
            )
        )
        if len(source_ids) != len(raw_source_ids) or len(source_ids) > MAX_SOURCE_IDS_PER_CARD:
            raise InspirationValidationError("history_sources")
        if bool(history_basis) != bool(source_ids):
            raise InspirationValidationError("history_sources")
        if any(source_id not in source_chapter_indexes for source_id in source_ids):
            raise InspirationValidationError("history_sources")
        if _contains_unselected_character(
            "\n".join(filter(None, (title, body, note))),
            known_characters,
            selected_character_ids,
        ):
            raise InspirationValidationError("unselected_character")
        normalized = _idea_identity(title, body)
        if any(_ideas_too_similar(normalized, previous) for previous in normalized_ideas):
            raise InspirationValidationError("duplicate_ideas")
        normalized_ideas.append(normalized)
        cards.append(
            InspirationCard(
                title=title,
                body=body,
                history_basis=history_basis,
                note=note,
                history_chapter_indexes=tuple(
                    sorted({source_chapter_indexes[source_id] for source_id in source_ids})
                ),
            )
        )
    return cards


def _required_text(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InspirationValidationError("required_text")
    return value.strip()


def _optional_text(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise InspirationValidationError("optional_text")
    return value.strip() or None


def _contains_unselected_character(
    text: str,
    known_characters: Sequence[Any],
    selected_character_ids: set[str],
) -> bool:
    matched, ambiguous = scan_known_character_names(text, known_characters)
    if any(character.id not in selected_character_ids for character in matched):
        return True
    if ambiguous:
        by_name: dict[str, list[Any]] = {}
        for character in known_characters:
            name = normalize_text(character.name).strip()
            if name:
                by_name.setdefault(name, []).append(character)
        return any(
            any(character.id not in selected_character_ids for character in by_name.get(name, []))
            for name in ambiguous
        )
    return False


def _idea_identity(title: str, body: str) -> str:
    normalized = normalize_text(title + body).casefold()
    return "".join(character for character in normalized if character.isalnum())


def _ideas_too_similar(left: str, right: str) -> bool:
    if left == right:
        return True
    if not left or not right:
        return False
    if min(len(left), len(right)) >= 16 and (left in right or right in left):
        return True
    return SequenceMatcher(a=left, b=right, autojunk=False).ratio() >= 0.86


def _audit(
    callback: AuditAttempt | None,
    started: float,
    error_code: str | None,
    upstream_reason: str | None,
) -> None:
    if callback is not None:
        callback(int((time.monotonic() - started) * 1000), error_code, upstream_reason)
