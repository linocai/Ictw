"""agent model binding temperature

Revision ID: 20260711_0004
Revises: 20260710_0003
Create Date: 2026-07-11
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260711_0004"
down_revision = "20260710_0003"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Native add_column: rebuilding via batch would cascade-delete child rows on
    # SQLite with foreign keys enabled (see the 0002 lesson for chapters).
    op.add_column("agent_model_bindings", sa.Column("temperature", sa.Float(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("agent_model_bindings") as batch_op:
        batch_op.drop_column("temperature")
