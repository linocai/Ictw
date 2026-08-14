from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.schemas.common import ORMModel


class AgentPersonaRead(ORMModel):
    agent_role: str
    # system_prompt remains for pre-v1.6 clients.  It is the same editable
    # text as editable_persona, never the program-owned protocol.
    system_prompt: str
    editable_persona: str
    default_persona: str
    program_protocol: str
    updated_at: datetime | None


class AgentPersonaPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    editable_persona: str | None = Field(default=None, max_length=8000)
    # Compatibility input for older clients.  It changes only editable text.
    system_prompt: str | None = Field(default=None, max_length=8000)

    @model_validator(mode="after")
    def exactly_one_editable_value(self) -> "AgentPersonaPatch":
        supplied = [value for value in (self.editable_persona, self.system_prompt) if value is not None]
        if len(supplied) != 1:
            raise ValueError("provide exactly one editable persona value")
        if not self.value.strip():
            raise ValueError("editable persona must not be blank")
        return self

    @property
    def value(self) -> str:
        return self.editable_persona if self.editable_persona is not None else self.system_prompt or ""


class BookAgentPersonaPut(BaseModel):
    """A complete book-local replacement, with the old input alias retained."""

    model_config = ConfigDict(extra="forbid")

    editable_persona: str | None = Field(default=None, max_length=8000)
    system_prompt: str | None = Field(default=None, max_length=8000)

    @model_validator(mode="after")
    def exactly_one_editable_value(self) -> "BookAgentPersonaPut":
        supplied = [value for value in (self.editable_persona, self.system_prompt) if value is not None]
        if len(supplied) != 1:
            raise ValueError("provide exactly one editable persona value")
        if not self.value.strip():
            raise ValueError("editable persona must not be blank")
        return self

    @property
    def value(self) -> str:
        return self.editable_persona if self.editable_persona is not None else self.system_prompt or ""


class BookAgentPersonaRead(BaseModel):
    agent_role: str
    # "book" means this book owns an override. "global" and "default"
    # distinguish a saved global value from the built-in fallback.
    source: Literal["book", "global", "default"]
    book_persona: str | None
    global_persona: str
    default_persona: str
    effective_persona: str
    program_protocol: str
    updated_at: datetime | None


class LLMProfileCreate(BaseModel):
    name: str
    provider: str = "openai-compatible"
    base_url: str
    api_key: str
    model_name: str


class LLMProfilePatch(BaseModel):
    name: str | None = None
    provider: str | None = None
    base_url: str | None = None
    api_key: str | None = None
    model_name: str | None = None


class LLMProfileRead(ORMModel):
    id: str
    name: str
    provider: str
    base_url: str
    model_name: str
    created_at: datetime
    updated_at: datetime


class AgentModelBindingRead(ORMModel):
    agent_role: str
    llm_profile_id: str | None
    thinking_enabled: bool | None
    reasoning_effort: str | None
    temperature: float | None
    effective_thinking_enabled: bool | None
    effective_reasoning_effort: str | None
    effective_temperature: float | None
    temperature_adjustable: bool
    capabilities: "ModelCapabilitiesRead"
    updated_at: datetime


class AgentModelBindingPatch(BaseModel):
    llm_profile_id: str | None = None
    thinking_enabled: bool | None = None
    reasoning_effort: str | None = None
    temperature: float | None = None


class ModelCapabilitiesRead(BaseModel):
    family: str
    thinking_toggle_supported: bool
    thinking_can_disable: bool
    thinking_required: bool
    reasoning_effort_levels: list[str]
    temperature_effective_when_thinking: bool
