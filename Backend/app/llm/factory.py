from __future__ import annotations

from fastapi import Depends
from sqlalchemy.orm import Session

from app.db import get_db
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models import AgentModelBinding, LLMProfile
from app.services.crypto import decrypt_secret
from app.services.model_capabilities import (
    effective_binding_settings,
    resolve_capabilities,
    sanitized_temperature,
)


def build_llm_client(db: Session, agent_role: str) -> OpenAICompatibleClient:
    binding = db.get(AgentModelBinding, agent_role)
    if binding is None or binding.llm_profile_id is None:
        raise RuntimeError(f"No LLM profile bound for {agent_role}")
    profile = db.get(LLMProfile, binding.llm_profile_id)
    if profile is None:
        raise RuntimeError(f"Bound LLM profile missing for {agent_role}")
    thinking_enabled, reasoning_effort = effective_binding_settings(binding, profile)
    capabilities = resolve_capabilities(profile.model_name, profile.base_url)
    return OpenAICompatibleClient(
        base_url=profile.base_url,
        api_key=decrypt_secret(profile.api_key_encrypted),
        model_name=profile.model_name,
        thinking_enabled=thinking_enabled,
        reasoning_effort=reasoning_effort,
        temperature_override=sanitized_temperature(binding.temperature, thinking_enabled, capabilities),
        capability_family=capabilities.family,
    )


def get_writer_client(db: Session = Depends(get_db)):
    return build_llm_client(db, "writer")


def get_compressor_client(db: Session = Depends(get_db)):
    return build_llm_client(db, "reviser")


def get_reviser_client(db: Session = Depends(get_db)):
    return build_llm_client(db, "reviser")


def get_memory_selector_client(db: Session = Depends(get_db)):
    return build_llm_client(db, "memory_selector")


def get_extractor_client(db: Session = Depends(get_db)):
    return build_llm_client(db, "extractor")
