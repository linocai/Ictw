"""HTTP conditional-write helpers for author-visible resources.

The compatibility window deliberately makes If-Match optional.  New clients
send a quoted server content revision; legacy clients continue their existing
last-write-wins behavior until they are retired.
"""

from __future__ import annotations

from typing import Protocol

from fastapi import HTTPException
from sqlalchemy import text
from sqlalchemy.orm import Session


class Revisioned(Protocol):
    content_revision: int


def _parse_if_match(value: str | None, *, allow_zero: bool = False) -> int | None:
    # Router unit tests call endpoint functions directly, where FastAPI's
    # Header(None) descriptor is passed instead of a resolved header value.
    # Treat any non-string as absent exactly like a real omitted header.
    if not isinstance(value, str) or not value.strip():
        return None
    candidate = value.strip()
    if candidate.startswith("W/"):
        candidate = candidate[2:].strip()
    if len(candidate) >= 2 and candidate[0] == candidate[-1] == '"':
        candidate = candidate[1:-1]
    try:
        parsed = int(candidate)
    except ValueError as exc:
        raise HTTPException(
            status_code=400,
            detail={"code": "invalid_if_match", "message": "If-Match 必须是内容版本号"},
        ) from exc
    if parsed < 0 or (parsed == 0 and not allow_zero):
        raise HTTPException(
            status_code=400,
            detail={"code": "invalid_if_match", "message": "If-Match 必须是正整数"},
        )
    return parsed


def parse_if_match(value: str | None) -> int | None:
    return _parse_if_match(value)


def raise_write_conflict(
    *, resource_type: str, resource_id: str, submitted_revision: int, current_revision: int
) -> None:
    raise HTTPException(
        status_code=409,
        detail={
            "code": "write_conflict",
            "message": "内容已在其他设备更新，请先同步后再保存",
            "details": {
                "resource_type": resource_type,
                "resource_id": resource_id,
                "submitted_revision": submitted_revision,
                "current_revision": current_revision,
            },
        },
    )


def require_absent_revision(if_match: str | None) -> int | None:
    """Accept ``If-Match: 0`` only for a resource that does not yet exist.

    A local override has no server revision before its first creation.  New
    clients therefore use zero to make that create conditional, while legacy
    requests without a header retain their existing last-write-wins behavior.
    """
    submitted = _parse_if_match(if_match, allow_zero=True)
    if submitted is not None and submitted != 0:
        raise_write_conflict(
            resource_type="missing_resource",
            resource_id="missing",
            submitted_revision=submitted,
            current_revision=0,
        )
    return submitted


def require_matching_revision(
    resource: Revisioned,
    if_match: str | None,
    *,
    resource_type: str,
    resource_id: str,
    db: Session | None = None,
) -> bool:
    """Return whether this is conditional, otherwise retain legacy semantics."""
    # A create request can race with another device.  If its ``If-Match: 0``
    # arrives after the row was inserted, report the same structured conflict
    # here rather than treating the valid create token as malformed.
    submitted = _parse_if_match(if_match, allow_zero=True)
    if submitted is None:
        return False
    if db is not None and db.bind is not None and db.bind.dialect.name == "sqlite":
        # SQLite has no SELECT ... FOR UPDATE. Acquiring the write reservation
        # before refreshing the resource makes the version comparison and the
        # following mutation one serialized transaction rather than merely a
        # best-effort timestamp check.
        db.execute(text("BEGIN IMMEDIATE"))
        db.refresh(resource)
    current = int(resource.content_revision)
    if submitted != current:
        raise_write_conflict(
            resource_type=resource_type,
            resource_id=resource_id,
            submitted_revision=submitted,
            current_revision=current,
        )
    return True


def bump_content_revision(resource: Revisioned) -> None:
    resource.content_revision = int(resource.content_revision or 0) + 1
