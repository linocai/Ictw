from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel

from app.schemas.common import ORMModel


class AgentPersonaRead(ORMModel):
    agent_role: str
    system_prompt: str
    updated_at: datetime


class AgentPersonaPatch(BaseModel):
    system_prompt: str


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
    effective_thinking_enabled: bool | None
    effective_reasoning_effort: str | None
    capabilities: "ModelCapabilitiesRead"
    updated_at: datetime


class AgentModelBindingPatch(BaseModel):
    llm_profile_id: str | None = None
    thinking_enabled: bool | None = None
    reasoning_effort: str | None = None


class ModelCapabilitiesRead(BaseModel):
    family: str
    thinking_toggle_supported: bool
    thinking_can_disable: bool
    thinking_required: bool
    reasoning_effort_levels: list[str]
    temperature_effective_when_thinking: bool
