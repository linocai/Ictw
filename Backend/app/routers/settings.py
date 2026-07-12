from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.llm.base import LLMError
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models import AgentModelBinding, AgentPersona, LLMProfile
from app.schemas.settings import (
    AgentModelBindingPatch,
    AgentModelBindingRead,
    AgentPersonaPatch,
    AgentPersonaRead,
    LLMProfileCreate,
    LLMProfilePatch,
    LLMProfileRead,
)
from app.services.crypto import decrypt_secret, encrypt_secret
from app.services.model_capabilities import (
    effective_binding_settings,
    resolve_capabilities,
    sanitized_settings,
    sanitized_temperature,
    temperature_sendable,
)
from app.services.personas import AGENT_ROLES, DEFAULT_PERSONAS

router = APIRouter(tags=["settings"])


def _binding_response(binding: AgentModelBinding, db: Session) -> dict[str, object]:
    profile = db.get(LLMProfile, binding.llm_profile_id) if binding.llm_profile_id else None
    capabilities = resolve_capabilities(
        profile.model_name if profile else None,
        profile.base_url if profile else None,
    )
    effective_thinking, effective_effort = effective_binding_settings(binding, profile)
    adjustable = profile is not None and temperature_sendable(effective_thinking, capabilities)
    return {
        "agent_role": binding.agent_role,
        "llm_profile_id": binding.llm_profile_id,
        "thinking_enabled": binding.thinking_enabled,
        "reasoning_effort": binding.reasoning_effort,
        "temperature": binding.temperature,
        "effective_thinking_enabled": effective_thinking,
        "effective_reasoning_effort": effective_effort,
        "effective_temperature": sanitized_temperature(binding.temperature, effective_thinking, capabilities),
        "temperature_adjustable": adjustable,
        "capabilities": capabilities.as_dict(),
        "updated_at": binding.updated_at,
    }


def _sanitize_profile_bindings(db: Session, profile: LLMProfile) -> None:
    capabilities = resolve_capabilities(profile.model_name, profile.base_url)
    bindings = db.scalars(
        select(AgentModelBinding).where(AgentModelBinding.llm_profile_id == profile.id)
    ).all()
    for binding in bindings:
        binding.thinking_enabled, binding.reasoning_effort = sanitized_settings(
            binding.thinking_enabled,
            binding.reasoning_effort,
            capabilities,
        )
        binding.temperature = sanitized_temperature(
            binding.temperature, binding.thinking_enabled, capabilities
        )


@router.get("/agent-personas", response_model=list[AgentPersonaRead])
def list_personas(db: Session = Depends(get_db)) -> list[AgentPersona]:
    return list(db.scalars(select(AgentPersona).order_by(AgentPersona.agent_role)).all())


@router.patch("/agent-personas/{agent_role}", response_model=AgentPersonaRead)
def patch_persona(agent_role: str, payload: AgentPersonaPatch, db: Session = Depends(get_db)) -> AgentPersona:
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    persona = db.get(AgentPersona, agent_role)
    if persona is None:
        persona = AgentPersona(agent_role=agent_role, system_prompt=payload.system_prompt)
        db.add(persona)
    else:
        persona.system_prompt = payload.system_prompt
    db.commit()
    db.refresh(persona)
    return persona


@router.post("/agent-personas/{agent_role}/reset", response_model=AgentPersonaRead)
def reset_persona(agent_role: str, db: Session = Depends(get_db)) -> AgentPersona:
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    persona = db.get(AgentPersona, agent_role)
    if persona is None:
        persona = AgentPersona(agent_role=agent_role, system_prompt=DEFAULT_PERSONAS[agent_role])
        db.add(persona)
    else:
        persona.system_prompt = DEFAULT_PERSONAS[agent_role]
    db.commit()
    db.refresh(persona)
    return persona


@router.get("/llm_profiles", response_model=list[LLMProfileRead])
def list_profiles(db: Session = Depends(get_db)) -> list[LLMProfile]:
    return list(db.scalars(select(LLMProfile).order_by(LLMProfile.created_at)).all())


@router.post("/llm_profiles", response_model=LLMProfileRead, status_code=status.HTTP_201_CREATED)
def create_profile(payload: LLMProfileCreate, db: Session = Depends(get_db)) -> LLMProfile:
    profile = LLMProfile(
        name=payload.name,
        provider=payload.provider,
        base_url=payload.base_url,
        api_key_encrypted=encrypt_secret(payload.api_key),
        model_name=payload.model_name,
    )
    db.add(profile)
    db.commit()
    db.refresh(profile)
    return profile


@router.patch("/llm_profiles/{profile_id}", response_model=LLMProfileRead)
def patch_profile(profile_id: str, payload: LLMProfilePatch, db: Session = Depends(get_db)) -> LLMProfile:
    profile = db.get(LLMProfile, profile_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="profile not found")
    updates = payload.model_dump(exclude_unset=True)
    api_key = updates.pop("api_key", None)
    for key, value in updates.items():
        setattr(profile, key, value)
    if api_key is not None:
        profile.api_key_encrypted = encrypt_secret(api_key)
    _sanitize_profile_bindings(db, profile)
    db.commit()
    db.refresh(profile)
    return profile


@router.delete("/llm_profiles/{profile_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_profile(profile_id: str, db: Session = Depends(get_db)) -> Response:
    profile = db.get(LLMProfile, profile_id)
    if profile is not None:
        db.delete(profile)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/llm_profiles/{profile_id}/test")
def test_profile(profile_id: str, db: Session = Depends(get_db)) -> dict[str, str]:
    profile = db.get(LLMProfile, profile_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="profile not found")
    client = OpenAICompatibleClient(
        base_url=profile.base_url,
        api_key=decrypt_secret(profile.api_key_encrypted),
        model_name=profile.model_name,
    )
    try:
        client.test_connection()
    except LLMError as exc:
        raise HTTPException(
            status_code=502,
            detail={"code": exc.code, "message": str(exc), "details": exc.safe_details()},
        ) from exc
    return {"status": "ok"}


@router.get("/agent-model-bindings", response_model=list[AgentModelBindingRead])
def list_bindings(db: Session = Depends(get_db)) -> list[dict[str, object]]:
    bindings = db.scalars(select(AgentModelBinding).order_by(AgentModelBinding.agent_role)).all()
    return [_binding_response(binding, db) for binding in bindings]


@router.patch("/agent-model-bindings/{agent_role}", response_model=AgentModelBindingRead)
def patch_binding(agent_role: str, payload: AgentModelBindingPatch, db: Session = Depends(get_db)) -> dict[str, object]:
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    binding = db.get(AgentModelBinding, agent_role)
    if binding is None:
        binding = AgentModelBinding(
            agent_role=agent_role,
            llm_profile_id=None,
            thinking_enabled=None,
            reasoning_effort=None,
        )
        db.add(binding)

    fields = payload.model_fields_set
    if "llm_profile_id" in fields:
        if payload.llm_profile_id is not None and db.get(LLMProfile, payload.llm_profile_id) is None:
            raise HTTPException(status_code=404, detail="profile not found")
        binding.llm_profile_id = payload.llm_profile_id

    profile = db.get(LLMProfile, binding.llm_profile_id) if binding.llm_profile_id else None
    capabilities = resolve_capabilities(
        profile.model_name if profile else None,
        profile.base_url if profile else None,
    )
    thinking, effort = binding.thinking_enabled, binding.reasoning_effort
    temperature = binding.temperature
    if "llm_profile_id" in fields:
        thinking, effort = sanitized_settings(thinking, effort, capabilities)
        temperature = sanitized_temperature(temperature, thinking, capabilities)
    if "thinking_enabled" in fields:
        thinking = payload.thinking_enabled
        if thinking is not True and "reasoning_effort" not in fields:
            effort = None
    if "reasoning_effort" in fields:
        effort = payload.reasoning_effort
    if "temperature" in fields:
        temperature = payload.temperature

    if capabilities.family == "unknown" and (thinking is not None or effort is not None):
        raise HTTPException(status_code=422, detail="此模型未声明可调思考参数")
    # Only an explicit temperature in this request is rejected; a carried-over
    # value is silently sanitized away below (mirrors effort clearing).
    if temperature is not None and "temperature" in fields:
        if not (0.0 <= temperature <= 2.0):
            raise HTTPException(status_code=422, detail="temperature 需在 0.0～2.0 之间")
        effective_thinking = True if capabilities.thinking_required else thinking
        if not temperature_sendable(effective_thinking, capabilities):
            detail = (
                "此模型不支持调整 temperature"
                if capabilities.thinking_required
                else "关闭思考后才能调整 temperature"
            )
            raise HTTPException(status_code=422, detail=detail)
    if capabilities.thinking_required and thinking is False:
        raise HTTPException(status_code=422, detail="此模型的思考模式不能关闭")
    if effort is not None and effort not in capabilities.reasoning_effort_levels:
        raise HTTPException(status_code=422, detail="该思考强度不受当前模型支持")
    if capabilities.thinking_toggle_supported and effort is not None and thinking is not True:
        raise HTTPException(status_code=422, detail="启用思考后才能选择思考强度")

    # Required thinking is represented by the effective field, not a fabricated
    # user preference. This keeps configured and effective values distinct.
    if capabilities.thinking_required and thinking is True:
        thinking = None
    binding.thinking_enabled, binding.reasoning_effort = sanitized_settings(
        thinking,
        effort,
        capabilities,
    )
    binding.temperature = sanitized_temperature(temperature, binding.thinking_enabled, capabilities)
    db.commit()
    db.refresh(binding)
    return _binding_response(binding, db)
