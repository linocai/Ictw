from __future__ import annotations

import logging
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
                    "body": {"type": "string", "minLength": 200, "maxLength": 300},
                    "history_basis": {"type": ["string", "null"]},
                    "note": {"type": ["string", "null"]},
                    "source_ids": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["body", "history_basis", "note", "source_ids"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["cards"],
    "additionalProperties": False,
}

MIN_BODY_NONSPACE_CHARS = 200
MAX_BODY_NONSPACE_CHARS = 300
MAX_HISTORY_BASIS_NONSPACE_CHARS = 120
MAX_NOTE_NONSPACE_CHARS = 120
MIN_CARDS = 3
MAX_CARDS = 5
MAX_SOURCE_IDS_PER_CARD = 6
DIRECTION_TITLES = ("方向一", "方向二", "方向三", "方向四", "方向五")
SENTENCE_ENDINGS = frozenset("。！？!?")

logger = logging.getLogger(__name__)


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
                    max_tokens=8192,
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
                logger.warning(
                    "inspiration_validation_failed attempt=%s category=%s",
                    attempt + 1,
                    exc.category,
                )
                _audit(audit_attempt, started, "inspiration_invalid_response", None)
                if attempt == 0:
                    correction = (
                        "\n\n# 程序退回\n上一次结果未通过程序校验（"
                        + exc.category
                        + "）。请重新给出 3 条真正不同的连贯剧情方向，"
                        "每个 body 必须完整展开到 200–300 个去空白字符并自然收束，"
                        "不要另拟标题、不要只写一句抽象梗概、不要靠重复凑字；严格遵守 JSON、推进边界、来源与人物白名单。"
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
                        "请重新输出完整 object，并严格遵守 3 条、人物与每个 body 200–300 字。"
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
    if not isinstance(output, dict):
        raise InspirationValidationError("response_shape")
    raw_cards = output.get("cards")
    if not isinstance(raw_cards, list) or len(raw_cards) < MIN_CARDS:
        raise InspirationValidationError("card_count")
    cards: list[InspirationCard] = []
    normalized_ideas: list[str] = []
    rejected_categories: list[str] = []
    for raw in raw_cards:
        try:
            card = _validated_card(
                raw,
                direction_title=DIRECTION_TITLES[len(cards)],
                source_chapter_indexes=source_chapter_indexes,
                known_characters=known_characters,
                selected_character_ids=selected_character_ids,
            )
        except InspirationValidationError as exc:
            rejected_categories.append(exc.category)
            continue
        normalized = _idea_identity(card.body)
        if any(_ideas_too_similar(normalized, previous) for previous in normalized_ideas):
            rejected_categories.append("duplicate_ideas")
            continue
        normalized_ideas.append(normalized)
        cards.append(card)
        if len(cards) == MAX_CARDS:
            break
    if len(cards) < MIN_CARDS:
        categories = ",".join(dict.fromkeys(rejected_categories)) or "card_count"
        raise InspirationValidationError(f"insufficient_valid_cards:{len(cards)}:{categories}")
    return cards


def _validated_card(
    raw: Any,
    *,
    direction_title: str,
    source_chapter_indexes: Mapping[str, int],
    known_characters: Sequence[Any],
    selected_character_ids: set[str],
) -> InspirationCard:
    if not isinstance(raw, dict):
        raise InspirationValidationError("card_shape")
    body = _body_with_natural_limit(raw.get("body"))
    body_length = nonspace_len(body)
    if body_length < MIN_BODY_NONSPACE_CHARS:
        raise InspirationValidationError("body_too_short")
    if body_length > MAX_BODY_NONSPACE_CHARS:
        raise InspirationValidationError("body_too_long")

    try:
        note = _optional_text(raw.get("note"))
    except InspirationValidationError:
        note = None
    history_basis, source_ids = _safe_history_metadata(
        raw.get("history_basis"),
        raw.get("source_ids"),
        source_chapter_indexes,
    )
    if note is not None and nonspace_len(note) > MAX_NOTE_NONSPACE_CHARS:
        note = None
    if history_basis is not None and nonspace_len(history_basis) > MAX_HISTORY_BASIS_NONSPACE_CHARS:
        history_basis, source_ids = None, ()

    if _contains_unselected_character(
        "\n".join(filter(None, (body, note))),
        known_characters,
        selected_character_ids,
    ):
        raise InspirationValidationError("unselected_character")
    return InspirationCard(
        title=direction_title,
        body=body,
        history_basis=history_basis,
        note=note,
        history_chapter_indexes=tuple(
            sorted({source_chapter_indexes[source_id] for source_id in source_ids})
        ),
    )


def _body_with_natural_limit(value: Any) -> str:
    body = _required_text(value)
    if nonspace_len(body) <= MAX_BODY_NONSPACE_CHARS:
        return body

    nonspace_count = 0
    last_natural_end: int | None = None
    for index, character in enumerate(body):
        if not character.isspace():
            nonspace_count += 1
        if (
            character in SENTENCE_ENDINGS
            and MIN_BODY_NONSPACE_CHARS <= nonspace_count <= MAX_BODY_NONSPACE_CHARS
        ):
            last_natural_end = index + 1
        if nonspace_count > MAX_BODY_NONSPACE_CHARS:
            break
    if last_natural_end is None:
        raise InspirationValidationError("body_too_long")
    return body[:last_natural_end].strip()


def _safe_history_metadata(
    raw_history_basis: Any,
    raw_source_ids: Any,
    source_chapter_indexes: Mapping[str, int],
) -> tuple[str | None, tuple[str, ...]]:
    if not source_chapter_indexes:
        return None, ()
    try:
        history_basis = _optional_text(raw_history_basis)
    except InspirationValidationError:
        return None, ()
    if not isinstance(raw_source_ids, list):
        return None, ()
    source_ids = tuple(
        dict.fromkeys(
            item.strip() for item in raw_source_ids if isinstance(item, str) and item.strip()
        )
    )
    if len(source_ids) != len(raw_source_ids) or len(source_ids) > MAX_SOURCE_IDS_PER_CARD:
        return None, ()
    if bool(history_basis) != bool(source_ids):
        return None, ()
    if any(source_id not in source_chapter_indexes for source_id in source_ids):
        return None, ()
    return history_basis, source_ids


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


def _idea_identity(body: str) -> str:
    normalized = normalize_text(body).casefold()
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
