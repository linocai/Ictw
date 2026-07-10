from __future__ import annotations

from app.llm.base import LLMClient


class ReviserAgent:
    def __init__(self, llm: LLMClient, system_prompt: str) -> None:
        self.llm = llm
        self.system_prompt = system_prompt

    def revise(self, user_message: str) -> str:
        return self.llm.complete(
            system=self.system_prompt,
            user=user_message,
            temperature=0.2,
            timeout=300,
        )
