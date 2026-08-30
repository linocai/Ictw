"""Fail-closed guard for Alembic downgrades that discard logical data.

An Alembic downgrade is not ICTW's normal production rollback mechanism.  The
only escape hatch is deliberately awkward: an operator must stop the service,
make and verify a byte-identical SQLite backup, create a short-lived manifest,
and explicitly authorize this one invocation.  The migrations call this helper
*before* their first destructive DDL.
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any


DOWNGRADE_CONFIRMATION = "ICTW_ALLOW_DESTRUCTIVE_DOWNGRADE_ONCE"
MANIFEST_ENV = "ICTW_DESTRUCTIVE_DOWNGRADE_MANIFEST"
CONFIRMATION_ENV = "ICTW_DESTRUCTIVE_DOWNGRADE_CONFIRM"
MANIFEST_VERSION = 1
MAX_MANIFEST_LIFETIME = timedelta(hours=1)

# A single Alembic command can cross several guarded revisions.  The first
# guard proves the stopped-service backup matches the database; later guards in
# the same process reuse that proof only for revisions named in the manifest.
_approved_invocations: set[tuple[Path, str]] = set()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _require_string(payload: dict[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise RuntimeError(f"destructive downgrade manifest has invalid {key}")
    return value


def _parse_timestamp(value: str, key: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise RuntimeError(f"destructive downgrade manifest has invalid {key}") from exc
    if parsed.tzinfo is None:
        raise RuntimeError(f"destructive downgrade manifest {key} must include a timezone")
    return parsed.astimezone(UTC)


def _sqlite_database_path(connection) -> Path:
    if connection.dialect.name != "sqlite":
        raise RuntimeError("destructive downgrade guard currently requires a file-backed SQLite database")
    row = connection.exec_driver_sql("PRAGMA database_list").fetchone()
    if row is None or not row[2]:
        raise RuntimeError("destructive downgrade guard requires a file-backed SQLite database")
    path = Path(row[2]).resolve()
    if not path.is_file():
        raise RuntimeError("destructive downgrade guard cannot locate the SQLite database file")
    wal_path = Path(f"{path}-wal")
    if wal_path.exists() and wal_path.stat().st_size:
        raise RuntimeError("destructive downgrade requires a checkpointed SQLite database with no live WAL")
    return path


def _assert_sqlite_backup_healthy(path: Path) -> None:
    wal_path = Path(f"{path}-wal")
    if wal_path.exists() and wal_path.stat().st_size:
        raise RuntimeError("destructive downgrade backup must be checkpointed with no WAL")
    try:
        connection = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)
    except sqlite3.Error as exc:
        raise RuntimeError("destructive downgrade backup cannot be opened read-only") from exc
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchall()
        if integrity != [("ok",)]:
            raise RuntimeError("destructive downgrade backup integrity_check failed")
        if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise RuntimeError("destructive downgrade backup foreign_key_check failed")
    finally:
        connection.close()


def _load_manifest(path: Path) -> tuple[dict[str, Any], str]:
    try:
        raw = path.read_bytes()
        payload = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError("destructive downgrade manifest cannot be read") from exc
    if not isinstance(payload, dict):
        raise RuntimeError("destructive downgrade manifest must be a JSON object")
    return payload, hashlib.sha256(raw).hexdigest()


def _validate_manifest(
    *,
    database_path: Path,
    revision: str,
    manifest_path: Path,
) -> str:
    payload, manifest_digest = _load_manifest(manifest_path)
    if payload.get("manifest_version") != MANIFEST_VERSION:
        raise RuntimeError("destructive downgrade manifest version is not supported")
    if payload.get("purpose") != "ictw-destructive-downgrade":
        raise RuntimeError("destructive downgrade manifest purpose is invalid")
    if _require_string(payload, "confirmation") != DOWNGRADE_CONFIRMATION:
        raise RuntimeError("destructive downgrade manifest confirmation is invalid")
    try:
        uuid.UUID(_require_string(payload, "operation_id"))
    except ValueError as exc:
        raise RuntimeError("destructive downgrade manifest operation_id must be a UUID") from exc

    issued_at = _parse_timestamp(_require_string(payload, "issued_at"), "issued_at")
    expires_at = _parse_timestamp(_require_string(payload, "expires_at"), "expires_at")
    now = datetime.now(UTC)
    if issued_at > now + timedelta(minutes=5) or expires_at <= now or expires_at - issued_at > MAX_MANIFEST_LIFETIME:
        raise RuntimeError("destructive downgrade manifest is expired or not short-lived")

    service = payload.get("service")
    if not isinstance(service, dict) or service.get("stopped") is not True:
        raise RuntimeError("destructive downgrade manifest must attest that the service is stopped")
    stopped_at = _parse_timestamp(_require_string(service, "stopped_at"), "service.stopped_at")
    if stopped_at < issued_at - timedelta(minutes=5) or stopped_at > now + timedelta(minutes=5):
        raise RuntimeError("destructive downgrade manifest service stop time is invalid")

    approved_revisions = payload.get("approved_revisions")
    if not isinstance(approved_revisions, list) or revision not in approved_revisions or not all(
        isinstance(item, str) and item for item in approved_revisions
    ):
        raise RuntimeError(f"destructive downgrade manifest does not approve revision {revision}")

    backup = payload.get("backup")
    if not isinstance(backup, dict):
        raise RuntimeError("destructive downgrade manifest backup is missing")
    backup_path_value = _require_string(backup, "path")
    backup_path = Path(backup_path_value)
    if not backup_path.is_absolute():
        raise RuntimeError("destructive downgrade backup path must be absolute")
    backup_path = backup_path.resolve()
    if not backup_path.is_file() or backup_path == database_path:
        raise RuntimeError("destructive downgrade backup must be a separate regular file")
    expected_sha256 = _require_string(backup, "sha256")
    expected_size = backup.get("size_bytes")
    if not isinstance(expected_size, int) or expected_size <= 0:
        raise RuntimeError("destructive downgrade backup size is invalid")
    if backup_path.stat().st_size != expected_size or _sha256(backup_path) != expected_sha256:
        raise RuntimeError("destructive downgrade backup does not match its manifest")
    if _require_string(payload, "source_database_sha256") != expected_sha256:
        raise RuntimeError("destructive downgrade manifest does not prove an exact database backup")
    if _sha256(database_path) != expected_sha256:
        raise RuntimeError("destructive downgrade database changed after the verified backup")
    _assert_sqlite_backup_healthy(backup_path)
    return manifest_digest


def require_destructive_downgrade_authorization(connection, *, revision: str) -> None:
    """Refuse a logical-data-loss downgrade unless its recovery proof is present.

    This function performs reads only.  Call it before the first DDL or DELETE
    in every destructive migration's ``downgrade`` function.
    """
    if os.environ.get(CONFIRMATION_ENV) != DOWNGRADE_CONFIRMATION:
        raise RuntimeError(
            "destructive downgrade refused: set the one-time confirmation and provide a verified manifest"
        )
    manifest_value = os.environ.get(MANIFEST_ENV)
    if not manifest_value:
        raise RuntimeError("destructive downgrade refused: verified manifest path is required")
    manifest_path = Path(manifest_value).resolve()
    if not manifest_path.is_file():
        raise RuntimeError("destructive downgrade refused: verified manifest file is missing")
    database_path = _sqlite_database_path(connection)
    payload, manifest_digest = _load_manifest(manifest_path)
    cache_key = (database_path, manifest_digest)
    if cache_key in _approved_invocations:
        approved_revisions = payload.get("approved_revisions")
        if isinstance(approved_revisions, list) and revision in approved_revisions:
            return
        raise RuntimeError(f"destructive downgrade manifest does not approve revision {revision}")
    manifest_digest = _validate_manifest(
        database_path=database_path,
        revision=revision,
        manifest_path=manifest_path,
    )
    _approved_invocations.add((database_path, manifest_digest))
