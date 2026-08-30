from __future__ import annotations

import httpx
from fastapi import APIRouter, Depends, Header, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db import get_db
from app.llm.base import LLMError
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models import AgentModelBinding, AgentPersona, BookAgentModelBinding, LLMProfile
from app.schemas.settings import (
    AgentModelBindingPatch,
    AgentModelBindingRead,
    AgentPersonaPatch,
    AgentPersonaRead,
    LLMProfileCreate,
    LLMProfilePatch,
    LLMProfileRead,
)
from app.services.crypto import SecretUndecryptable, decrypt_secret, encrypt_secret
from app.services.model_capabilities import (
    effective_binding_settings,
    requires_bounded_non_thinking,
    resolve_capabilities,
    sanitized_settings,
    sanitized_temperature,
    temperature_sendable,
)
from app.services.personas import AGENT_ROLES, DEFAULT_PERSONAS, PROGRAM_PROTOCOLS
from app.services.content_revisions import bump_content_revision, require_matching_revision

router = APIRouter(tags=["settings"])


def _binding_response(binding: AgentModelBinding, db: Session) -> dict[str, object]:
    profile = db.get(LLMProfile, binding.llm_profile_id) if binding.llm_profile_id else None
    capabilities = resolve_capabilities(
        profile.model_name if profile else None,
        profile.base_url if profile else None,
    )
    effective_thinking, effective_effort = effective_binding_settings(binding, profile)
    configured_thinking, configured_effort = binding.thinking_enabled, binding.reasoning_effort
    if (
        requires_bounded_non_thinking(binding.agent_role)
        and profile is not None
        and capabilities.thinking_can_disable
    ):
        # Report the bounded runtime policy the request will actually use
        # instead of a stale pre-upgrade user preference.
        configured_thinking, configured_effort = False, None
        effective_thinking, effective_effort = False, None
    adjustable = profile is not None and temperature_sendable(effective_thinking, capabilities)
    return {
        "agent_role": binding.agent_role,
        "llm_profile_id": binding.llm_profile_id,
        "thinking_enabled": configured_thinking,
        "reasoning_effort": configured_effort,
        "temperature": binding.temperature,
        "effective_thinking_enabled": effective_thinking,
        "effective_reasoning_effort": effective_effort,
        "effective_temperature": sanitized_temperature(binding.temperature, effective_thinking, capabilities),
        "temperature_adjustable": adjustable,
        "capabilities": capabilities.as_dict(),
        "updated_at": binding.updated_at,
        "content_revision": binding.content_revision,
    }


def _sanitize_profile_bindings(db: Session, profile: LLMProfile) -> None:
    capabilities = resolve_capabilities(profile.model_name, profile.base_url)
    bindings = list(db.scalars(
        select(AgentModelBinding).where(AgentModelBinding.llm_profile_id == profile.id)
    ).all())
    bindings.extend(db.scalars(
        select(BookAgentModelBinding).where(BookAgentModelBinding.llm_profile_id == profile.id)
    ).all())
    for binding in bindings:
        thinking, effort = sanitized_settings(
            binding.thinking_enabled,
            binding.reasoning_effort,
            capabilities,
        )
        temperature = sanitized_temperature(binding.temperature, thinking, capabilities)
        if (thinking, effort, temperature) != (
            binding.thinking_enabled, binding.reasoning_effort, binding.temperature
        ):
            binding.thinking_enabled, binding.reasoning_effort, binding.temperature = thinking, effort, temperature
            bump_content_revision(binding)


def _clear_profile_bindings(db: Session, profile: LLMProfile) -> None:
    bindings = list(db.scalars(
        select(AgentModelBinding).where(AgentModelBinding.llm_profile_id == profile.id)
    ).all())
    bindings.extend(db.scalars(
        select(BookAgentModelBinding).where(BookAgentModelBinding.llm_profile_id == profile.id)
    ).all())
    capabilities = resolve_capabilities(None, None)
    for binding in bindings:
        thinking, effort = sanitized_settings(binding.thinking_enabled, binding.reasoning_effort, capabilities)
        temperature = sanitized_temperature(binding.temperature, thinking, capabilities)
        binding.llm_profile_id = None
        binding.thinking_enabled, binding.reasoning_effort, binding.temperature = thinking, effort, temperature
        bump_content_revision(binding)


@router.get("/agent-personas", response_model=list[AgentPersonaRead])
def list_personas(db: Session = Depends(get_db)) -> list[dict[str, object]]:
    personas = {item.agent_role: item for item in db.scalars(select(AgentPersona)).all()}
    return [_persona_response(role, personas.get(role)) for role in AGENT_ROLES]


def _persona_response(role: str, persona: AgentPersona | None) -> dict[str, object]:
    editable_persona = persona.system_prompt if persona is not None else DEFAULT_PERSONAS[role]
    return {
        "agent_role": role,
        "system_prompt": editable_persona,
        "editable_persona": editable_persona,
        "default_persona": DEFAULT_PERSONAS[role],
        "program_protocol": PROGRAM_PROTOCOLS[role],
        "updated_at": persona.updated_at if persona is not None else None,
        "content_revision": persona.content_revision if persona is not None else 1,
    }


@router.get("/agent-personas/{agent_role}", response_model=AgentPersonaRead)
def get_persona(agent_role: str, db: Session = Depends(get_db)) -> dict[str, object]:
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    return _persona_response(agent_role, db.get(AgentPersona, agent_role))


@router.patch("/agent-personas/{agent_role}", response_model=AgentPersonaRead)
def patch_persona(
    agent_role: str,
    payload: AgentPersonaPatch,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> dict[str, object]:
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    persona = db.get(AgentPersona, agent_role)
    if persona is None:
        persona = AgentPersona(agent_role=agent_role, system_prompt=payload.value)
        db.add(persona)
    else:
        require_matching_revision(persona, if_match, resource_type="agent_persona", resource_id=agent_role, db=db)
        persona.system_prompt = payload.value
        bump_content_revision(persona)
    db.commit()
    db.refresh(persona)
    return _persona_response(agent_role, persona)


@router.post("/agent-personas/{agent_role}/reset", response_model=AgentPersonaRead)
def reset_persona(
    agent_role: str,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> dict[str, object]:
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    persona = db.get(AgentPersona, agent_role)
    if persona is None:
        persona = AgentPersona(agent_role=agent_role, system_prompt=DEFAULT_PERSONAS[agent_role])
        db.add(persona)
    else:
        require_matching_revision(persona, if_match, resource_type="agent_persona", resource_id=agent_role, db=db)
        persona.system_prompt = DEFAULT_PERSONAS[agent_role]
        bump_content_revision(persona)
    db.commit()
    db.refresh(persona)
    return _persona_response(agent_role, persona)


@router.get("/llm_profiles", response_model=list[LLMProfileRead])
def list_profiles(db: Session = Depends(get_db)) -> list[LLMProfile]:
    return list(db.scalars(select(LLMProfile).order_by(LLMProfile.created_at)).all())


@router.get("/llm_profiles/{profile_id}", response_model=LLMProfileRead)
def get_profile(profile_id: str, db: Session = Depends(get_db)) -> LLMProfile:
    profile = db.get(LLMProfile, profile_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="profile not found")
    return profile


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
def patch_profile(
    profile_id: str,
    payload: LLMProfilePatch,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> LLMProfile:
    profile = db.get(LLMProfile, profile_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="profile not found")
    require_matching_revision(profile, if_match, resource_type="llm_profile", resource_id=profile.id, db=db)
    updates = payload.model_dump(exclude_unset=True)
    api_key = updates.pop("api_key", None)
    # Retargeting a profile at a different host must not carry the existing
    # key along: the key is sent to whatever base_url names, so changing the
    # destination requires re-entering it in the same request.
    if (
        "base_url" in updates
        and updates["base_url"] != profile.base_url
        and api_key is None
    ):
        raise HTTPException(
            status_code=422,
            detail={
                "code": "api_key_required_for_new_base_url",
                "message": "更换服务地址时必须同时重新填写模型密钥",
            },
        )
    for key, value in updates.items():
        # exclude_unset still keeps explicitly-sent nulls, and every column
        # here is NOT NULL; writing one used to fail as a 500 at flush time.
        if value is None:
            continue
        setattr(profile, key, value)
    if api_key is not None:
        profile.api_key_encrypted = encrypt_secret(api_key)
    _sanitize_profile_bindings(db, profile)
    if payload.model_fields_set:
        bump_content_revision(profile)
    db.commit()
    db.refresh(profile)
    return profile


@router.delete("/llm_profiles/{profile_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_profile(
    profile_id: str,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> Response:
    profile = db.get(LLMProfile, profile_id)
    if profile is not None:
        require_matching_revision(profile, if_match, resource_type="llm_profile", resource_id=profile.id, db=db)
        _clear_profile_bindings(db, profile)
        db.delete(profile)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/llm_profiles/{profile_id}/test")
def test_profile(profile_id: str, db: Session = Depends(get_db)) -> dict[str, str]:
    profile = db.get(LLMProfile, profile_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="profile not found")
    try:
        api_key = decrypt_secret(profile.api_key_encrypted)
    except SecretUndecryptable as exc:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "api_key_undecryptable",
                "message": "该模型密钥无法用当前 KEK_SECRET 解密，请重新填写密钥",
            },
        ) from exc
    client = OpenAICompatibleClient(
        base_url=profile.base_url,
        api_key=api_key,
        model_name=profile.model_name,
    )
    try:
        client.test_connection()
    except LLMError as exc:
        raise HTTPException(
            status_code=502,
            detail={"code": exc.code, "message": str(exc), "details": exc.safe_details()},
        ) from exc
    except httpx.InvalidURL as exc:
        # InvalidURL is not an httpx.HTTPError, so neither the client nor the
        # branch above catches it; a malformed host used to escape as a 500.
        raise HTTPException(
            status_code=422,
            detail={"code": "invalid_base_url", "message": "服务地址格式不正确"},
        ) from exc
    return {"status": "ok"}


@router.get("/agent-model-bindings", response_model=list[AgentModelBindingRead])
def list_bindings(db: Session = Depends(get_db)) -> list[dict[str, object]]:
    bindings = {item.agent_role: item for item in db.scalars(select(AgentModelBinding)).all()}
    return [_binding_response(bindings[role], db) for role in AGENT_ROLES if role in bindings]


@router.get("/agent-model-bindings/{agent_role}", response_model=AgentModelBindingRead)
def get_binding(agent_role: str, db: Session = Depends(get_db)) -> dict[str, object]:
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    binding = db.get(AgentModelBinding, agent_role)
    if binding is None:
        raise HTTPException(status_code=404, detail="agent model binding not found")
    return _binding_response(binding, db)


@router.patch("/agent-model-bindings/{agent_role}", response_model=AgentModelBindingRead)
def patch_binding(
    agent_role: str,
    payload: AgentModelBindingPatch,
    db: Session = Depends(get_db),
    if_match: str | None = Header(default=None, alias="If-Match"),
) -> dict[str, object]:
    if agent_role not in AGENT_ROLES:
        raise HTTPException(status_code=404, detail="agent role not found")
    binding = db.get(AgentModelBinding, agent_role)
    binding_created = binding is None
    if binding is None:
        binding = AgentModelBinding(
            agent_role=agent_role,
            llm_profile_id=None,
            thinking_enabled=None,
            reasoning_effort=None,
        )
        db.add(binding)
    else:
        require_matching_revision(
            binding, if_match, resource_type="agent_model_binding", resource_id=agent_role, db=db
        )

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

    if requires_bounded_non_thinking(agent_role):
        role_label = "Extractor" if agent_role == "extractor" else "灵感创造师"
        if profile is not None and not capabilities.thinking_can_disable:
            raise HTTPException(status_code=422, detail=f"{role_label} 需要绑定支持关闭思考的模型")
        if payload.thinking_enabled is True or payload.reasoning_effort is not None:
            raise HTTPException(status_code=422, detail=f"{role_label} 固定关闭思考")
        thinking, effort = (False, None) if profile is not None else (None, None)

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
    if not binding_created:
        bump_content_revision(binding)
    db.commit()
    db.refresh(binding)
    return _binding_response(binding, db)
