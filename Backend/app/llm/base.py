from __future__ import annotations

from collections.abc import Iterator
from threading import Event
from typing import Any, Protocol


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
