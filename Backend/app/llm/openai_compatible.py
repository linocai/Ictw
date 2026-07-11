from __future__ import annotations

import json
from collections.abc import Iterator
from threading import Event
from typing import Any

import httpx

from app.llm.base import LLMError


class OpenAICompatibleClient:
    def __init__(
        self,
        *,
        base_url: str,
        api_key: str,
        model_name: str,
        thinking_enabled: bool | None = None,
        reasoning_effort: str | None = None,
        temperature_override: float | None = None,
        capability_family: str = "unknown",
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model_name = model_name
        self.thinking_enabled = thinking_enabled
        self.reasoning_effort = reasoning_effort
        self.temperature_override = temperature_override
        self.capability_family = capability_family
        self.last_finish_reason: str | None = None
        self.last_usage: dict[str, Any] | None = None

    def complete(self, *, system: str, user: str, **kwargs: Any) -> str:
        self.last_usage = None
        payload = self._payload(system=system, user=user, stream=False, **kwargs)
        data = self._post(payload, timeout=kwargs.get("timeout", 300))
        self.last_finish_reason = _extract_finish_reason(data)
        self.last_usage = _extract_usage(data)
        return _extract_content(data)

    def complete_json(self, *, system: str, user: str, schema: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        self.last_usage = None
        schema_text = json.dumps(schema, ensure_ascii=False)
        system = f"{system}\n\n只返回合法 JSON object。JSON schema: {schema_text}"
        payload = self._payload(
            system=system,
            user=user,
            stream=False,
            response_format={"type": "json_object"},
            **kwargs,
        )
        data = self._post(payload, timeout=kwargs.get("timeout", 300))
        self.last_usage = _extract_usage(data)
        try:
            self.last_finish_reason = _extract_finish_reason(data)
            parsed = json.loads(_extract_content(data))
        except json.JSONDecodeError as exc:
            raise LLMError(f"LLM returned invalid JSON: {exc}", retryable=False) from exc
        if not isinstance(parsed, dict):
            raise LLMError("LLM JSON response was not an object", retryable=False)
        return parsed

    def complete_stream(
        self,
        *,
        system: str,
        user: str,
        cancel_event: Event | None = None,
        **kwargs: Any,
    ) -> Iterator[str]:
        payload = self._payload(system=system, user=user, stream=True, **kwargs)
        payload["stream_options"] = {"include_usage": True}
        self.last_finish_reason = None
        self.last_usage = None
        timeout = httpx.Timeout(connect=15, read=kwargs.get("timeout", 180), write=30, pool=15)
        url = f"{self.base_url}/chat/completions"
        try:
            with httpx.stream("POST", url, headers=self._headers(), json=payload, timeout=timeout) as response:
                if response.status_code >= 400:
                    response.read()
                    raise _http_error(response.status_code, response.headers, response.content)
                for line in response.iter_lines():
                    if cancel_event is not None and cancel_event.is_set():
                        break
                    if not line or not line.startswith("data:"):
                        continue
                    data = line.removeprefix("data:").strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(chunk, dict):
                        continue
                    prompt_feedback = chunk.get("promptFeedback") or chunk.get("prompt_feedback")
                    if isinstance(prompt_feedback, dict):
                        block_reason = prompt_feedback.get("blockReason") or prompt_feedback.get("block_reason")
                        if block_reason:
                            raise LLMError(
                                "LLM blocked the request",
                                code="llm_content_blocked",
                                block_reason=str(block_reason),
                            )
                    usage = _extract_usage(chunk)
                    if usage is not None:
                        self.last_usage = usage
                    choices = chunk.get("choices")
                    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
                        continue
                    choice = choices[0]
                    delta = choice.get("delta", {})
                    finish_reason = choice.get("finish_reason") or choice.get("finishReason")
                    if finish_reason is not None:
                        self.last_finish_reason = str(finish_reason)
                    text = delta.get("content") or ""
                    if text:
                        yield text
        except httpx.HTTPError as exc:
            raise LLMError("LLM transport failed", code="llm_transport", retryable=True) from exc

    def test_connection(self) -> None:
        url = f"{self.base_url}/models"
        try:
            response = httpx.get(url, headers=self._headers(), timeout=20)
        except httpx.HTTPError as exc:
            raise LLMError("LLM transport failed", code="llm_transport", retryable=True) from exc
        if response.status_code >= 400:
            raise _http_error(response.status_code, response.headers, prefix="LLM profile test failed")

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

    def _payload(self, *, system: str, user: str, stream: bool, **kwargs: Any) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": kwargs.get("model") or self.model_name,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "stream": stream,
        }
        for key in ("temperature", "max_tokens", "response_format"):
            if kwargs.get(key) is not None:
                payload[key] = kwargs[key]
        # A user-configured binding temperature beats the per-agent default; the
        # family rules below still drop it whenever thinking makes it inert.
        if self.temperature_override is not None:
            payload["temperature"] = self.temperature_override
        if self.capability_family == "deepseek_v4" and self.thinking_enabled is not None:
            payload["thinking"] = {"type": "enabled" if self.thinking_enabled else "disabled"}
            if self.thinking_enabled:
                payload.pop("temperature", None)
                if self.reasoning_effort is not None:
                    payload["reasoning_effort"] = self.reasoning_effort
        elif self.capability_family == "gemini_3_5_flash":
            payload.pop("temperature", None)
            if self.reasoning_effort is not None:
                payload["reasoning_effort"] = self.reasoning_effort
        return payload

    def _post(self, payload: dict[str, Any], *, timeout: int) -> dict[str, Any]:
        url = f"{self.base_url}/chat/completions"
        try:
            response = httpx.post(url, headers=self._headers(), json=payload, timeout=timeout)
        except httpx.HTTPError as exc:
            raise LLMError("LLM transport failed", code="llm_transport", retryable=True) from exc
        if response.status_code >= 400:
            raise _http_error(response.status_code, response.headers, response.content)
        try:
            data = response.json()
        except ValueError as exc:
            raise LLMError("LLM returned invalid response JSON", code="llm_invalid_response") from exc
        if not isinstance(data, dict):
            raise LLMError("LLM returned invalid response shape", code="llm_invalid_response")
        return data


def _extract_content(data: dict[str, Any]) -> str:
    prompt_feedback = data.get("promptFeedback") or data.get("prompt_feedback")
    if isinstance(prompt_feedback, dict):
        block_reason = prompt_feedback.get("blockReason") or prompt_feedback.get("block_reason")
        if block_reason:
            raise LLMError(
                "LLM blocked the request",
                code="llm_content_blocked",
                retryable=False,
                block_reason=str(block_reason),
            )
    try:
        content = data["choices"][0]["message"]["content"]
        if not isinstance(content, str) or not content:
            raise KeyError("empty content")
        return content
    except (KeyError, IndexError, TypeError) as exc:
        raise LLMError(
            "LLM response did not contain message content",
            code="llm_empty_candidate",
            retryable=False,
            finish_reason=_extract_finish_reason(data),
        ) from exc


def _extract_usage(data: dict[str, Any]) -> dict[str, Any] | None:
    usage = data.get("usage")
    if not isinstance(usage, dict):
        return None
    return {
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "total_tokens": usage.get("total_tokens"),
    }


def _extract_finish_reason(data: dict[str, Any]) -> str | None:
    try:
        value = data["choices"][0].get("finish_reason")
    except (KeyError, IndexError, TypeError):
        candidates = data.get("candidates")
        if isinstance(candidates, list) and candidates and isinstance(candidates[0], dict):
            value = candidates[0].get("finishReason")
        else:
            value = None
    return str(value) if value is not None else None


def _http_error(
    status_code: int,
    headers: Any,
    body: bytes | None = None,
    *,
    prefix: str = "LLM upstream request failed",
) -> LLMError:
    retryable = status_code == 429 or status_code >= 500
    if status_code == 429:
        code = "llm_rate_limited"
    elif status_code >= 500:
        code = "llm_upstream_unavailable"
    else:
        code = "llm_upstream_rejected"
    finish_reason, block_reason = _safe_provider_reasons(body)
    return LLMError(
        f"{prefix}: {status_code}",
        code=code,
        retryable=retryable,
        status_code=status_code,
        retry_after=headers.get("Retry-After") if headers is not None else None,
        finish_reason=finish_reason,
        block_reason=block_reason,
    )


def _safe_provider_reasons(body: bytes | None) -> tuple[str | None, str | None]:
    """Extract only stable provider reasons; never retain upstream bodies."""
    if not body:
        return None, None
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
        return None, None
    if not isinstance(data, dict):
        return None, None
    finish_reason = _extract_finish_reason(data)
    feedback = data.get("promptFeedback") or data.get("prompt_feedback")
    block_reason = None
    if isinstance(feedback, dict):
        value = feedback.get("blockReason") or feedback.get("block_reason")
        block_reason = str(value) if value is not None else None
    return finish_reason, block_reason
