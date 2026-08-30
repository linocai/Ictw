from __future__ import annotations

from fastapi import Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models import AgentModelBinding, BookAgentModelBinding, Chapter, LLMProfile
from app.services.crypto import SecretUndecryptable, decrypt_secret
from app.services.model_capabilities import (
    effective_binding_settings,
    requires_bounded_non_thinking,
    resolve_capabilities,
    sanitized_temperature,
)


class LLMConfigurationError(Exception):
    """Safe, client-displayable configuration failure for one agent role."""

    def __init__(self, code: str, agent_role: str) -> None:
        super().__init__(code)
        self.code = code
        self.agent_role = agent_role
        self.message = "该 Agent 尚未完成可用模型配置"


def resolve_model_binding(db: Session, agent_role: str, *, book_id: str | None = None):
    """Resolve a complete book override or the global binding.

    A dangling profile reference can exist after profile deletion because the
    row is retained for author inspection.  It is not an executable override,
    so the safe effective value is the global binding.
    """
    global_binding = db.get(AgentModelBinding, agent_role)
    if book_id is not None:
        override = db.scalars(select(BookAgentModelBinding).where(
            BookAgentModelBinding.book_id == book_id,
            BookAgentModelBinding.agent_role == agent_role,
        )).first()
        if override is not None and override.llm_profile_id and db.get(LLMProfile, override.llm_profile_id) is not None:
            return override, "book"
    return global_binding, "global"


def build_llm_client(db: Session, agent_role: str, *, book_id: str | None = None) -> OpenAICompatibleClient:
    binding, _source = resolve_model_binding(db, agent_role, book_id=book_id)
    if binding is None or binding.llm_profile_id is None:
        raise LLMConfigurationError("llm_profile_not_configured", agent_role)
    profile = db.get(LLMProfile, binding.llm_profile_id)
    if profile is None:
        raise LLMConfigurationError("llm_profile_missing", agent_role)
    thinking_enabled, reasoning_effort = effective_binding_settings(binding, profile)
    capabilities = resolve_capabilities(profile.model_name, profile.base_url)
    # Extraction and synchronous inspiration generation are bounded work.  They
    # must preserve their output/request window instead of spending it on
    # provider thinking tokens.
    if requires_bounded_non_thinking(agent_role):
        if not capabilities.thinking_can_disable:
            raise LLMConfigurationError(f"{agent_role}_thinking_not_disableable", agent_role)
        thinking_enabled, reasoning_effort = False, None
    try:
        api_key = decrypt_secret(profile.api_key_encrypted)
    except SecretUndecryptable as exc:
        # Same 409 shape as the other configuration failures, so a rotated KEK
        # or a database restored onto another host is diagnosable instead of
        # surfacing as an empty 500.
        raise LLMConfigurationError("api_key_undecryptable", agent_role) from exc
    return OpenAICompatibleClient(
        base_url=profile.base_url,
        api_key=api_key,
        model_name=profile.model_name,
        thinking_enabled=thinking_enabled,
        reasoning_effort=reasoning_effort,
        temperature_override=sanitized_temperature(binding.temperature, thinking_enabled, capabilities),
        capability_family=capabilities.family,
    )


def _chapter_client(db: Session, chapter_id: str, role: str):
    chapter = db.get(Chapter, chapter_id)
    if chapter is None:
        raise HTTPException(status_code=404, detail="chapter not found")
    return build_llm_client(db, role, book_id=chapter.book_id)


def get_writer_client(chapter_id: str, db: Session = Depends(get_db)):
    return _chapter_client(db, chapter_id, "writer")


def get_memory_selector_client(chapter_id: str, db: Session = Depends(get_db)):
    return _chapter_client(db, chapter_id, "memory_selector")


def get_checker_client(chapter_id: str, db: Session = Depends(get_db)):
    return _chapter_client(db, chapter_id, "checker")


def get_extractor_client(chapter_id: str, db: Session = Depends(get_db)):
    return _chapter_client(db, chapter_id, "extractor")


def get_inspiration_creator_client(chapter_id: str, db: Session = Depends(get_db)):
    return _chapter_client(db, chapter_id, "inspiration_creator")
