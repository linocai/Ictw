from __future__ import annotations

import asyncio
import json
from collections.abc import Iterator
from threading import Event
from typing import Any

import httpx

from app.llm.base import LLMError, LLMStreamIncompleteError, safe_block_reason, safe_finish_reason, safe_upstream_reason


NON_THINKING_TOP_P = 0.95


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
        data = self._post(
            payload,
            timeout=kwargs.get("timeout", 300),
            hard_timeout=bool(kwargs.get("hard_timeout", False)),
        )
        self.last_finish_reason = _extract_finish_reason(data)
        self.last_usage = _extract_usage(data)
        _validate_response_end(data)
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
        data = self._post(
            payload,
            timeout=kwargs.get("timeout", 300),
            hard_timeout=bool(kwargs.get("hard_timeout", False)),
        )
        self.last_usage = _extract_usage(data)
        self.last_finish_reason = _extract_finish_reason(data)
        _validate_response_end(data)
        try:
            parsed = json.loads(_extract_content(data))
        except json.JSONDecodeError as exc:
            if _is_length_finish_reason(self.last_finish_reason):
                raise LLMError(
                    "LLM JSON output was truncated",
                    code="llm_output_truncated",
                    retryable=True,
                    finish_reason=self.last_finish_reason,
                ) from exc
            raise LLMError(
                "LLM returned invalid JSON",
                code="llm_invalid_response",
                retryable=False,
                finish_reason=self.last_finish_reason,
            ) from exc
        if not isinstance(parsed, dict):
            raise LLMError(
                "LLM JSON response was not an object",
                code="llm_invalid_response",
                retryable=False,
                finish_reason=self.last_finish_reason,
            )
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
        saw_done = False
        normal_finish_reasons = {"stop", "end_turn", "completed", "complete"}
        timeout = httpx.Timeout(connect=15, read=kwargs.get("timeout", 180), write=30, pool=15)
        url = f"{self.base_url}/chat/completions"
        if cancel_event is not None and cancel_event.is_set():
            return
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
                        saw_done = True
                        break
                    try:
                        chunk = json.loads(data)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(chunk, dict):
                        continue
                    _raise_embedded_error(chunk)
                    prompt_feedback = chunk.get("promptFeedback") or chunk.get("prompt_feedback")
                    if isinstance(prompt_feedback, dict):
                        block_reason = prompt_feedback.get("blockReason") or prompt_feedback.get("block_reason")
                        if block_reason:
                            raise LLMError(
                                "LLM blocked the request",
                                code="llm_content_blocked",
                                block_reason=safe_block_reason(block_reason),
                            )
                    usage = _extract_usage(chunk)
                    if usage is not None:
                        self.last_usage = usage
                    reason = _extract_finish_reason(chunk)
                    if reason is not None:
                        # Once length has ended the content, a subsequent
                        # stop/DONE tail cannot turn it into a complete draft.
                        if self.last_finish_reason in normal_finish_reasons or self.last_finish_reason is None:
                            self.last_finish_reason = reason
                        if reason in {"safety", "content_filter"}:
                            self.last_finish_reason = reason
                            raise LLMError("上游安全规则拦截了生成", code="llm_content_blocked",
                                           finish_reason=reason, block_reason=safe_block_reason(reason))
                        if reason not in normal_finish_reasons | {"length"}:
                            self.last_finish_reason = reason
                            raise LLMError("上游未以可用的正文终态结束生成", code="llm_invalid_finish",
                                           finish_reason=reason)
                    choices = chunk.get("choices")
                    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
                        continue
                    delta = choices[0].get("delta", {})
                    if isinstance(delta, dict) and (delta.get("tool_calls") or delta.get("function_call")):
                        raise LLMError("上游返回工具调用，未生成可用的正文", code="llm_invalid_finish",
                                       finish_reason=self.last_finish_reason)
                    text = delta.get("content") if isinstance(delta, dict) else None
                    if isinstance(text, str) and text:
                        yield text
        except httpx.HTTPError as exc:
            if cancel_event is not None and cancel_event.is_set():
                return
            raise LLMError("LLM transport failed", code="llm_transport", retryable=True) from exc
        if cancel_event is not None and cancel_event.is_set():
            return
        if self.last_finish_reason is None and not saw_done:
            raise LLMStreamIncompleteError()

    def test_connection(self) -> None:
        url = f"{self.base_url}/models"
        try:
            response = httpx.get(url, headers=self._headers(), timeout=20)
        except httpx.HTTPError as exc:
            raise LLMError("LLM transport failed", code="llm_transport", retryable=True) from exc
        if response.status_code >= 400:
            raise _http_error(
                response.status_code,
                response.headers,
                response.content,
                prefix="LLM profile test failed",
            )

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
        for key in ("temperature", "top_p", "max_tokens", "response_format"):
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
                payload.pop("top_p", None)
                if self.reasoning_effort is not None:
                    payload["reasoning_effort"] = self.reasoning_effort
        elif self.capability_family == "glm_5" and self.thinking_enabled is not None:
            payload["thinking"] = {"type": "enabled" if self.thinking_enabled else "disabled"}
            if self.thinking_enabled and self.reasoning_effort is not None:
                payload["reasoning_effort"] = self.reasoning_effort
            if self.thinking_enabled:
                payload.pop("top_p", None)
        elif self.capability_family == "gemini_3_5_flash":
            payload.pop("temperature", None)
            payload.pop("top_p", None)
            if self.reasoning_effort is not None:
                payload["reasoning_effort"] = self.reasoning_effort
        thinking_active = self.capability_family == "gemini_3_5_flash" or (
            self.capability_family in {"deepseek_v4", "glm_5"} and self.thinking_enabled is True
        )
        if not thinking_active:
            payload["top_p"] = NON_THINKING_TOP_P
        return payload

    def _post(
        self, payload: dict[str, Any], *, timeout: int | float, hard_timeout: bool = False
    ) -> dict[str, Any]:
        url = f"{self.base_url}/chat/completions"
        try:
            if hard_timeout:
                async def request() -> httpx.Response:
                    per_operation = httpx.Timeout(connect=15, read=timeout, write=30, pool=15)
                    async with httpx.AsyncClient(timeout=per_operation) as client:
                        return await client.post(url, headers=self._headers(), json=payload)

                response = asyncio.run(asyncio.wait_for(request(), timeout=float(timeout)))
            else:
                response = httpx.post(url, headers=self._headers(), json=payload, timeout=timeout)
        except TimeoutError as exc:
            raise LLMError("LLM request timed out", code="llm_timeout", retryable=True) from exc
        except httpx.TimeoutException as exc:
            raise LLMError("LLM request timed out", code="llm_timeout", retryable=True) from exc
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


def _raise_embedded_error(data: dict[str, Any]) -> None:
    if "error" not in data or data["error"] is None:
        return
    reason = _safe_upstream_reason(data["error"])
    code = {
        "content_policy": "llm_content_blocked",
        "rate_limited": "llm_rate_limited",
        "upstream_unavailable": "llm_upstream_unavailable",
        "authentication": "llm_upstream_rejected",
        "invalid_request": "llm_upstream_rejected",
    }.get(reason, "llm_upstream_error")
    raise LLMError("上游返回错误，当前输出未被采用", code=code,
                   retryable=reason in {"rate_limited", "upstream_unavailable"},
                   upstream_reason=reason)


def _validate_response_end(data: dict[str, Any]) -> None:
    _raise_embedded_error(data)
    reason = _extract_finish_reason(data)
    if reason in {"safety", "content_filter"}:
        raise LLMError("上游安全规则拦截了生成", code="llm_content_blocked",
                       finish_reason=reason, block_reason=safe_block_reason(reason))
    if reason == "length":
        raise LLMError("上游输出被截断，未采用不完整结果", code="llm_output_truncated",
                       retryable=True, finish_reason=reason)
    if reason is not None and reason not in {"stop", "end_turn", "completed", "complete"}:
        raise LLMError("上游未正常完成输出", code="llm_invalid_finish", finish_reason=reason)


def _extract_content(data: dict[str, Any]) -> str:
    prompt_feedback = data.get("promptFeedback") or data.get("prompt_feedback")
    if isinstance(prompt_feedback, dict):
        block_reason = prompt_feedback.get("blockReason") or prompt_feedback.get("block_reason")
        if block_reason:
            raise LLMError(
                "LLM blocked the request",
                code="llm_content_blocked",
                retryable=False,
                block_reason=safe_block_reason(block_reason),
            )
    try:
        content = data["choices"][0]["message"]["content"]
        if not isinstance(content, str) or not content:
            raise KeyError("empty content")
        return content
    except (KeyError, IndexError, TypeError) as exc:
        finish_reason = _extract_finish_reason(data)
        if _is_length_finish_reason(finish_reason):
            raise LLMError(
                "LLM response was truncated before message content",
                code="llm_output_truncated",
                retryable=True,
                finish_reason=finish_reason,
            ) from exc
        raise LLMError(
            "LLM response did not contain message content",
            code="llm_empty_candidate",
            retryable=False,
            finish_reason=finish_reason,
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
    value = None
    try:
        choice = data["choices"][0]
        value = choice.get("finish_reason")
        if value is None:
            value = choice.get("finishReason")
    except (KeyError, IndexError, TypeError, AttributeError):
        pass
    if value is None:
        candidates = data.get("candidates")
        if isinstance(candidates, list) and candidates and isinstance(candidates[0], dict):
            value = candidates[0].get("finishReason")
    # Streaming content deltas commonly carry a null placeholder. An explicit
    # non-null value that is not recognized is still an abnormal terminal event.
    if value is None:
        return None
    return safe_finish_reason(value) or "other"


def _is_length_finish_reason(value: str | None) -> bool:
    if value is None:
        return False
    normalized = value.strip().lower().replace("-", "_")
    return normalized in {"length", "max_tokens", "max_output_tokens", "max_token"}


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
    finish_reason, block_reason, upstream_reason = _safe_provider_reasons(body)
    return LLMError(
        f"{prefix}: {status_code}",
        code=code,
        retryable=retryable,
        status_code=status_code,
        retry_after=headers.get("Retry-After") if headers is not None else None,
        finish_reason=finish_reason,
        block_reason=block_reason,
        upstream_reason=upstream_reason,
    )


def _safe_provider_reasons(body: bytes | None) -> tuple[str | None, str | None, str | None]:
    """Extract only stable provider reasons; never retain upstream bodies."""
    if not body:
        return None, None, None
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
        return None, None, None
    if not isinstance(data, dict):
        return None, None, None
    finish_reason = _extract_finish_reason(data)
    feedback = data.get("promptFeedback") or data.get("prompt_feedback")
    block_reason = None
    if isinstance(feedback, dict):
        value = feedback.get("blockReason") or feedback.get("block_reason")
        block_reason = safe_block_reason(value)
    upstream_reason = _safe_upstream_reason(data.get("error"))
    return finish_reason, block_reason, upstream_reason


def _safe_upstream_reason(error: Any) -> str | None:
    """Map known provider machine codes only; never inspect ``error.message``."""
    if not isinstance(error, dict):
        return None
    return safe_upstream_reason(error.get("code")) or safe_upstream_reason(error.get("type"))
