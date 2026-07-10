from __future__ import annotations

import hmac

from fastapi import Header, HTTPException, status

from app.config import get_settings


def require_token(authorization: str | None = Header(default=None)) -> None:
    expected = f"Bearer {get_settings().app_token}"
    if authorization is None or not hmac.compare_digest(authorization, expected):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="unauthorized")
