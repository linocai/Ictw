from __future__ import annotations

from collections.abc import Iterator
from threading import Event

from app.llm.base import LLMClient


class WriterAgent:
    def __init__(self, llm: LLMClient, system_prompt: str) -> None:
        self.llm = llm
        self.system_prompt = system_prompt

    def stream(self, user_message: str, cancel_event: Event | None = None) -> Iterator[str]:
        yield from self.llm.complete_stream(
            system=self.system_prompt,
            user=user_message,
            temperature=0.7,
            timeout=180,
            cancel_event=cancel_event,
        )

    @property
    def finish_reason(self) -> str | None:
        return getattr(self.llm, "last_finish_reason", None)
