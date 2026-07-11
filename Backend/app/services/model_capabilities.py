from __future__ import annotations

from dataclasses import asdict, dataclass

from app.models import AgentModelBinding, LLMProfile


@dataclass(frozen=True)
class ModelCapabilities:
    family: str
    thinking_toggle_supported: bool
    thinking_can_disable: bool
    thinking_required: bool
    reasoning_effort_levels: tuple[str, ...]
    temperature_effective_when_thinking: bool

    def as_dict(self) -> dict[str, object]:
        result = asdict(self)
        result["reasoning_effort_levels"] = list(self.reasoning_effort_levels)
        return result


UNKNOWN_CAPABILITIES = ModelCapabilities(
    family="unknown",
    thinking_toggle_supported=False,
    thinking_can_disable=False,
    thinking_required=False,
    reasoning_effort_levels=(),
    temperature_effective_when_thinking=True,
)

DEEPSEEK_V4_CAPABILITIES = ModelCapabilities(
    family="deepseek_v4",
    thinking_toggle_supported=True,
    thinking_can_disable=True,
    thinking_required=False,
    reasoning_effort_levels=("high", "max"),
    temperature_effective_when_thinking=False,
)

GEMINI_3_5_FLASH_CAPABILITIES = ModelCapabilities(
    family="gemini_3_5_flash",
    thinking_toggle_supported=False,
    thinking_can_disable=False,
    thinking_required=True,
    reasoning_effort_levels=("minimal", "low", "medium", "high"),
    temperature_effective_when_thinking=False,
)


def _normalized_model_name(model_name: str | None) -> str:
    return (model_name or "").strip().lower().replace("_", "-").replace(" ", "-")


def resolve_capabilities(model_name: str | None, base_url: str | None = None) -> ModelCapabilities:
    """Return only explicitly registered capabilities; unknown models stay inert."""
    model = _normalized_model_name(model_name)
    host_hint = (base_url or "").lower()
    if "deepseek" in model and "v4" in model and ("pro" in model or "flash" in model):
        return DEEPSEEK_V4_CAPABILITIES
    if "gemini" in model and ("3.5" in model or "3-5" in model) and "flash" in model:
        return GEMINI_3_5_FLASH_CAPABILITIES

    # Some compatible gateways expose a short model alias. A provider host hint is
    # accepted only when the version and variant remain explicit in the model name.
    if "deepseek" in host_hint and "v4" in model and ("pro" in model or "flash" in model):
        return DEEPSEEK_V4_CAPABILITIES
    if "google" in host_hint and ("3.5" in model or "3-5" in model) and "flash" in model:
        return GEMINI_3_5_FLASH_CAPABILITIES
    return UNKNOWN_CAPABILITIES


def sanitized_settings(
    thinking_enabled: bool | None,
    reasoning_effort: str | None,
    capabilities: ModelCapabilities,
) -> tuple[bool | None, str | None]:
    """Remove stale values after a profile/model change without inventing defaults."""
    if capabilities.family == "unknown":
        return None, None
    if capabilities.thinking_required:
        thinking_enabled = None
    elif not capabilities.thinking_toggle_supported:
        thinking_enabled = None
    if reasoning_effort not in capabilities.reasoning_effort_levels:
        reasoning_effort = None
    if capabilities.family == "deepseek_v4" and thinking_enabled is not True:
        reasoning_effort = None
    return thinking_enabled, reasoning_effort


def effective_binding_settings(
    binding: AgentModelBinding,
    profile: LLMProfile | None,
) -> tuple[bool | None, str | None]:
    if profile is None:
        return None, None
    capabilities = resolve_capabilities(profile.model_name, profile.base_url)
    thinking, effort = sanitized_settings(binding.thinking_enabled, binding.reasoning_effort, capabilities)
    if capabilities.thinking_required:
        thinking = True
    return thinking, effort


def temperature_sendable(thinking_enabled: bool | None, capabilities: ModelCapabilities) -> bool:
    """Whether a request in this state would actually carry a temperature value.

    Mirrors OpenAICompatibleClient._payload: gemini always drops temperature,
    deepseek drops it only while thinking is explicitly enabled, and every other
    family (including unknown) passes it through.
    """
    if capabilities.family == "gemini_3_5_flash":
        return False
    if capabilities.family == "deepseek_v4" and thinking_enabled is True:
        return False
    return True


def sanitized_temperature(
    temperature: float | None,
    thinking_enabled: bool | None,
    capabilities: ModelCapabilities,
) -> float | None:
    if temperature is None:
        return None
    return temperature if temperature_sendable(thinking_enabled, capabilities) else None
