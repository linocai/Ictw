"""add persistent writer ownership generation

Revision ID: 20260809_0011
Revises: 20260805_0010
Create Date: 2026-08-09
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260809_0011"
down_revision = "20260805_0010"
branch_labels = None
depends_on = None


def _assert_foreign_keys_clean(connection) -> None:
    if connection.dialect.name != "sqlite":
        return
    connection.exec_driver_sql("PRAGMA foreign_keys=ON")
    violations = connection.exec_driver_sql("PRAGMA foreign_key_check").fetchall()
    if violations:
        raise RuntimeError(f"foreign_key_check failed before migration: {violations!r}")


def upgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)
    # Native SQLite ADD COLUMN keeps the chapters table and its production
    # uniqueness constraint intact.  Existing jobs remain NULL-compatible.
    op.add_column(
        "chapters",
        sa.Column("write_generation", sa.Integer(), nullable=False, server_default="0"),
    )
    op.add_column("job_runs", sa.Column("chapter_write_generation", sa.Integer(), nullable=True))
    _assert_foreign_keys_clean(connection)


def downgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)
    op.drop_column("job_runs", "chapter_write_generation")
    op.drop_column("chapters", "write_generation")
    _assert_foreign_keys_clean(connection)
