from __future__ import annotations

from app.llm.base import LLMClient


class CompressorAgent:
    def __init__(self, llm: LLMClient, system_prompt: str) -> None:
        self.llm = llm
        self.system_prompt = system_prompt

    def compress(self, user_message: str) -> str:
        return self.llm.complete(
            system=self.system_prompt,
            user=user_message,
            temperature=0.3,
            timeout=300,
        )
