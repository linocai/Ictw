from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session, sessionmaker

from app.models import LLMCallAudit


def record_llm_call(
    session_factory: sessionmaker[Session],
    *,
    agent_role: str,
    client: Any,
    duration_ms: int,
    error_code: str | None = None,
    chapter_id: str | None = None,
    job_id: str | None = None,
    upstream_reason: str | None = None,
) -> None:
    """Persist a single LLM-call audit row in an independent short session.

    Decoupled from the worker transaction so a rollback there never loses the
    audit, and vice versa. Never records prompts, response bodies or API keys.
    Defensive against Fake clients that lack ``last_usage`` / ``model_name``.
    ``upstream_reason`` is already whitelist-extracted (see
    ``openai_compatible._safe_upstream_reason``) and is kept here for offline
    troubleshooting only.
    """
    usage = getattr(client, "last_usage", None)
    if not isinstance(usage, dict):
        usage = {}
    finish_reason = getattr(client, "last_finish_reason", None)
    db = session_factory()
    try:
        db.add(
            LLMCallAudit(
                agent_role=agent_role,
                model_name=str(getattr(client, "model_name", "") or ""),
                duration_ms=duration_ms,
                prompt_tokens=usage.get("prompt_tokens"),
                completion_tokens=usage.get("completion_tokens"),
                total_tokens=usage.get("total_tokens"),
                finish_reason=str(finish_reason) if finish_reason is not None else None,
                error_code=error_code,
                chapter_id=chapter_id,
                job_id=job_id,
                upstream_reason=upstream_reason,
            )
        )
        db.commit()
    except Exception:  # noqa: BLE001 - auditing must never break the main flow
        db.rollback()
    finally:
        db.close()
