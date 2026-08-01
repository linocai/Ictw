"""merge legacy chapter synopses into canonical summaries

Revision ID: 20260801_0008
Revises: 20260801_0007
Create Date: 2026-08-01
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260801_0008"
down_revision = "20260801_0007"
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
    # Historical books only have ``summary`` (the old synopsis).  Copy it
    # verbatim when the v1.6 canonical archive is empty; never overwrite an
    # already generated long summary and never ask an LLM to reinterpret it.
    connection.execute(
        sa.text(
            """
            UPDATE chapters
            SET long_summary = summary
            WHERE trim(long_summary, char(9) || char(10) || char(13) || ' ') = ''
              AND trim(summary, char(9) || char(10) || char(13) || ' ') <> ''
            """
        )
    )
    # Modern SQLite supports native DROP COLUMN.  Avoid Alembic batch-table
    # recreation here: replacing the parent table while foreign keys are on
    # can cascade-delete chapter child rows.
    op.drop_column("chapters", "summary")
    _assert_foreign_keys_clean(connection)


def downgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)
    op.add_column("chapters", sa.Column("summary", sa.Text(), nullable=False, server_default=""))
    connection.execute(sa.text("UPDATE chapters SET summary = long_summary"))
    _assert_foreign_keys_clean(connection)
