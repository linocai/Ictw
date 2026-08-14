"""add book-scoped agent persona overrides

Revision ID: 20260814_0012
Revises: 20260809_0011
Create Date: 2026-08-14
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260814_0012"
down_revision = "20260809_0011"
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
    op.create_table(
        "book_agent_personas",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("book_id", sa.String(length=36), nullable=False),
        sa.Column("agent_role", sa.String(length=32), nullable=False),
        sa.Column("editable_persona", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["book_id"], ["books.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("book_id", "agent_role", name="uq_book_agent_persona_role"),
    )
    op.create_index("ix_book_agent_personas_book_id", "book_agent_personas", ["book_id"], unique=False)
    _assert_foreign_keys_clean(connection)


def downgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)
    op.drop_index("ix_book_agent_personas_book_id", table_name="book_agent_personas")
    op.drop_table("book_agent_personas")
    _assert_foreign_keys_clean(connection)
