from __future__ import annotations

import hmac

from fastapi import Header, HTTPException, status

from app.config import get_settings


def require_token(authorization: str | None = Header(default=None)) -> None:
    expected = f"Bearer {get_settings().app_token}"
    # Compare as bytes: Starlette decodes headers as latin-1, and
    # hmac.compare_digest raises TypeError on non-ASCII str operands. A single
    # high byte in the header used to escape as an unauthenticated 500.
    if authorization is None or not hmac.compare_digest(
        authorization.encode("utf-8", "surrogateescape"),
        expected.encode("utf-8", "surrogateescape"),
    ):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="unauthorized")
