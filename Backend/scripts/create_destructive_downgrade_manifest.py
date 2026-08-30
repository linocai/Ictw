#!/usr/bin/env python3
"""Create the short-lived proof required by a destructive Alembic downgrade.

This script is intentionally read-only for the database and backup.  Run it
only after the production service is stopped and a separate SQLite backup has
been created.  It does not execute Alembic and does not print database content.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

from app.migration_safety import DOWNGRADE_CONFIRMATION, MANIFEST_VERSION


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _assert_healthy_sqlite(path: Path) -> None:
    connection = sqlite3.connect(f"{path.as_uri()}?mode=ro", uri=True)
    try:
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            raise SystemExit("backup integrity_check failed")
        if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
            raise SystemExit("backup foreign_key_check failed")
    finally:
        connection.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create a one-time manifest for an already approved destructive downgrade."
    )
    parser.add_argument("--database", type=Path, required=True, help="Stopped source SQLite database")
    parser.add_argument("--backup", type=Path, required=True, help="Separate verified SQLite backup")
    parser.add_argument("--output", type=Path, required=True, help="New 0600 manifest path outside Git")
    parser.add_argument(
        "--revision",
        action="append",
        required=True,
        help="A guarded revision that this one Alembic command may downgrade; repeat as needed",
    )
    parser.add_argument(
        "--expires-in-minutes",
        type=int,
        default=15,
        help="Manifest lifetime, from 1 through 60 minutes (default: 15)",
    )
    parser.add_argument(
        "--service-stopped",
        action="store_true",
        help="Required attestation that the application service is stopped",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    database = args.database.resolve()
    backup = args.backup.resolve()
    output = args.output.resolve()
    if not args.service_stopped:
        raise SystemExit("--service-stopped is required")
    if not 1 <= args.expires_in_minutes <= 60:
        raise SystemExit("--expires-in-minutes must be between 1 and 60")
    if not database.is_file() or not backup.is_file() or database == backup:
        raise SystemExit("database and a separate backup file are required")
    if Path(f"{database}-wal").exists() and Path(f"{database}-wal").stat().st_size:
        raise SystemExit("database has a live WAL; checkpoint it after stopping the service")
    digest = _sha256(database)
    if backup.stat().st_size != database.stat().st_size or _sha256(backup) != digest:
        raise SystemExit("backup is not byte-identical to the stopped database")
    _assert_healthy_sqlite(backup)

    now = datetime.now(UTC)
    payload = {
        "manifest_version": MANIFEST_VERSION,
        "purpose": "ictw-destructive-downgrade",
        "confirmation": DOWNGRADE_CONFIRMATION,
        "operation_id": str(uuid.uuid4()),
        "issued_at": now.isoformat(),
        "expires_at": (now + timedelta(minutes=args.expires_in_minutes)).isoformat(),
        "service": {"stopped": True, "stopped_at": now.isoformat()},
        "source_database_sha256": digest,
        "backup": {
            "path": str(backup),
            "sha256": digest,
            "size_bytes": backup.stat().st_size,
        },
        "approved_revisions": args.revision,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
    os.chmod(output, 0o600)
    print(f"created verified destructive-downgrade manifest: {output}")


if __name__ == "__main__":
    main()
