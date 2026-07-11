"""job run error context + llm audit upstream reason

Revision ID: 20260711_0006
Revises: 20260711_0005
Create Date: 2026-07-11
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260711_0006"
down_revision = "20260711_0005"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Native add_column: rebuilding via batch would cascade-delete child rows on
    # SQLite with foreign keys enabled (see the 0002 lesson for chapters).
    op.add_column("job_runs", sa.Column("error_context", sa.JSON(), nullable=True))
    op.add_column("llm_call_audits", sa.Column("upstream_reason", sa.Text(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("job_runs") as batch_op:
        batch_op.drop_column("error_context")
    with op.batch_alter_table("llm_call_audits") as batch_op:
        batch_op.drop_column("upstream_reason")
