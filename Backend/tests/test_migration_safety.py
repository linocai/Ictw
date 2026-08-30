from __future__ import annotations

import hashlib
import json
import shutil
import sqlite3
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config

from app.config import get_settings
from app.migration_safety import (
    CONFIRMATION_ENV,
    DOWNGRADE_CONFIRMATION,
    MANIFEST_ENV,
    MANIFEST_VERSION,
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _manifest(database: Path, backup: Path, revisions: list[str]) -> dict[str, object]:
    digest = _sha256(database)
    now = datetime.now(UTC)
    return {
        "manifest_version": MANIFEST_VERSION,
        "purpose": "ictw-destructive-downgrade",
        "confirmation": DOWNGRADE_CONFIRMATION,
        "operation_id": str(uuid.uuid4()),
        "issued_at": now.isoformat(),
        "expires_at": (now + timedelta(minutes=10)).isoformat(),
        "service": {"stopped": True, "stopped_at": now.isoformat()},
        "source_database_sha256": digest,
        "backup": {"path": str(backup), "sha256": digest, "size_bytes": backup.stat().st_size},
        "approved_revisions": revisions,
    }


def _table_names(database: Path) -> set[str]:
    connection = sqlite3.connect(database)
    try:
        return {
            row[0]
            for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall()
        }
    finally:
        connection.close()


def _revision(database: Path) -> str:
    connection = sqlite3.connect(database)
    try:
        return connection.execute("SELECT version_num FROM alembic_version").fetchone()[0]
    finally:
        connection.close()


def _upgrade_to(tmp_path: Path, monkeypatch, revision: str) -> tuple[Path, Config]:
    database = tmp_path / f"{revision}.db"
    monkeypatch.setenv("DATABASE_URL", f"sqlite:///{database}")
    monkeypatch.delenv(CONFIRMATION_ENV, raising=False)
    monkeypatch.delenv(MANIFEST_ENV, raising=False)
    get_settings.cache_clear()
    config = Config("alembic.ini")
    command.upgrade(config, revision)
    return database, config


def _authorize(monkeypatch, database: Path, revisions: list[str]) -> None:
    backup = database.with_name(f"{database.stem}.backup.db")
    shutil.copy2(database, backup)
    manifest = database.with_name(f"{database.stem}.manifest.json")
    manifest.write_text(json.dumps(_manifest(database, backup, revisions)), encoding="utf-8")
    monkeypatch.setenv(CONFIRMATION_ENV, DOWNGRADE_CONFIRMATION)
    monkeypatch.setenv(MANIFEST_ENV, str(manifest))


def test_book_persona_downgrade_fails_before_ddl_without_recovery_proof(tmp_path, monkeypatch) -> None:
    database, config = _upgrade_to(tmp_path, monkeypatch, "20260814_0012")
    before = _sha256(database)

    with pytest.raises(RuntimeError, match="destructive downgrade refused"):
        command.downgrade(config, "20260809_0011")

    assert _sha256(database) == before
    assert "book_agent_personas" in _table_names(database)
    assert _revision(database) == "20260814_0012"


def test_book_persona_downgrade_accepts_only_a_verified_stopped_service_backup(tmp_path, monkeypatch) -> None:
    database, config = _upgrade_to(tmp_path, monkeypatch, "20260814_0012")
    _authorize(monkeypatch, database, ["20260814_0012"])

    command.downgrade(config, "20260809_0011")

    assert "book_agent_personas" not in _table_names(database)
    assert _revision(database) == "20260809_0011"


def test_archive_ledger_downgrade_fails_before_ddl_without_recovery_proof(tmp_path, monkeypatch) -> None:
    database, config = _upgrade_to(tmp_path, monkeypatch, "20260805_0010")
    before = _sha256(database)

    with pytest.raises(RuntimeError, match="destructive downgrade refused"):
        command.downgrade(config, "20260804_0009")

    assert _sha256(database) == before
    assert "chapter_archive_revisions" in _table_names(database)
    assert _revision(database) == "20260805_0010"


def test_archive_ledger_downgrade_accepts_a_verified_backup(tmp_path, monkeypatch) -> None:
    database, config = _upgrade_to(tmp_path, monkeypatch, "20260805_0010")
    _authorize(monkeypatch, database, ["20260805_0010"])

    command.downgrade(config, "20260804_0009")

    assert "chapter_archive_revisions" not in _table_names(database)
    assert _revision(database) == "20260804_0009"


def test_one_verified_manifest_can_cover_a_single_multi_revision_command(tmp_path, monkeypatch) -> None:
    database, config = _upgrade_to(tmp_path, monkeypatch, "20260814_0012")
    _authorize(monkeypatch, database, ["20260814_0012", "20260809_0011", "20260805_0010"])

    command.downgrade(config, "20260804_0009")

    tables = _table_names(database)
    assert "book_agent_personas" not in tables
    assert "chapter_archive_revisions" not in tables
    assert _revision(database) == "20260804_0009"


def test_every_existing_logical_data_loss_downgrade_uses_the_guard() -> None:
    versions = Path("alembic/versions")
    protected = {
        "20260709_0001_initial.py",
        "20260710_0002_v1_agent_chain.py",
        "20260710_0003_v1_1_jobs_audit_exemptions.py",
        "20260711_0004_binding_temperature.py",
        "20260711_0005_character_field_patches.py",
        "20260711_0006_error_context.py",
        "20260801_0007_v1_6_agent_foundation.py",
        "20260804_0009_character_state_projection.py",
        "20260805_0010_archive_v2_ledger.py",
        "20260809_0011_writer_generation.py",
        "20260814_0012_book_agent_personas.py",
    }
    for filename in protected:
        source = (versions / filename).read_text(encoding="utf-8")
        downgrade = source[source.index("def downgrade()") :]
        assert "require_destructive_downgrade_authorization" in downgrade, filename
