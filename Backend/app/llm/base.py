from __future__ import annotations

from collections.abc import Iterator
from threading import Event
from typing import Any, Protocol


_FINISH_REASONS = {
    "stop": "stop",
    "length": "length",
    "max_tokens": "length",
    "max_output_tokens": "length",
    "content_filter": "content_filter",
    "safety": "safety",
    "sensitive": "safety",
}
_BLOCK_REASONS = {
    "prohibited_content": "PROHIBITED_CONTENT",
    "safety": "SAFETY",
    "content_filter": "CONTENT_FILTER",
    "blocked": "BLOCKED",
}
_UPSTREAM_REASONS = {
    "content_policy_violation": "content_policy",
    "content_policy": "content_policy",
    "invalid_request_error": "invalid_request",
    "invalid_request": "invalid_request",
    "authentication_error": "authentication",
    "authentication": "authentication",
    "rate_limit_error": "rate_limited",
    "rate_limited": "rate_limited",
    "server_error": "upstream_unavailable",
    "upstream_unavailable": "upstream_unavailable",
}


def _normalized(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower().replace("-", "_").replace(" ", "_")
    return normalized or None


def safe_finish_reason(value: Any) -> str | None:
    return _FINISH_REASONS.get(_normalized(value) or "")


def safe_block_reason(value: Any) -> str | None:
    return _BLOCK_REASONS.get(_normalized(value) or "")


def safe_upstream_reason(value: Any) -> str | None:
    return _UPSTREAM_REASONS.get(_normalized(value) or "")


class LLMClient(Protocol):
    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        ...

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        ...

    def complete_stream(self, *, system: str, user: str, cancel_event: Event | None = None, **kwargs: Any) -> Iterator[str]:
        ...


class LLMError(Exception):
    def __init__(
        self,
        message: str,
        *,
        code: str = "llm_upstream_error",
        retryable: bool = False,
        status_code: int | None = None,
        retry_after: str | None = None,
        finish_reason: str | None = None,
        block_reason: str | None = None,
        agent_role: str | None = None,
        model_name: str | None = None,
        upstream_reason: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.retryable = retryable
        self.status_code = status_code
        self.retry_after = retry_after
        self.finish_reason = finish_reason
        self.block_reason = block_reason
        # Stamped by the write_jobs worker once the call site is known; not set
        # at raise time inside openai_compatible.py itself.
        self.agent_role = agent_role
        self.model_name = model_name
        self.upstream_reason = upstream_reason

    def safe_details(self) -> dict[str, Any]:
        return {
            key: value
            for key, value in {
                "upstream_status": self.status_code,
                "retry_after": self.retry_after,
                "finish_reason": self.finish_reason,
                "block_reason": self.block_reason,
                "agent_role": self.agent_role,
                "model_name": self.model_name,
                "upstream_reason": self.upstream_reason,
            }.items()
            if value is not None
        }
