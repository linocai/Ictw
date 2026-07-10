"""v1.1 job runs, llm audit, chapter exemptions

Revision ID: 20260710_0003
Revises: 20260710_0002
Create Date: 2026-07-10
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260710_0003"
down_revision = "20260710_0002"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Native ADD COLUMN (never batch): rebuilding `chapters` while foreign keys
    # are enabled would cascade-delete every chapter link/event (see 0002).
    op.add_column(
        "chapters",
        sa.Column("exempted_character_names", sa.JSON(), nullable=False, server_default="[]"),
    )
    op.create_table(
        "job_runs",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("chapter_id", sa.String(length=36), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("phase", sa.String(length=32), nullable=False),
        sa.Column("attempt", sa.Integer(), nullable=True),
        sa.Column("error_code", sa.String(length=64), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("violations", sa.JSON(), nullable=True),
        sa.Column("updated_character_ids", sa.JSON(), nullable=True),
        sa.Column("added_event_ids", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(["chapter_id"], ["chapters.id"], ondelete="CASCADE"),
    )
    op.create_index("ix_job_runs_chapter_id", "job_runs", ["chapter_id"])
    op.create_table(
        "llm_call_audits",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("agent_role", sa.String(length=32), nullable=False),
        sa.Column("model_name", sa.Text(), nullable=False),
        sa.Column("duration_ms", sa.Integer(), nullable=False),
        sa.Column("prompt_tokens", sa.Integer(), nullable=True),
        sa.Column("completion_tokens", sa.Integer(), nullable=True),
        sa.Column("total_tokens", sa.Integer(), nullable=True),
        sa.Column("finish_reason", sa.String(length=64), nullable=True),
        sa.Column("error_code", sa.String(length=64), nullable=True),
        sa.Column("chapter_id", sa.String(length=36), nullable=True),
        sa.Column("job_id", sa.String(length=36), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("llm_call_audits")
    op.drop_index("ix_job_runs_chapter_id", table_name="job_runs")
    op.drop_table("job_runs")
    with op.batch_alter_table("chapters") as batch_op:
        batch_op.drop_column("exempted_character_names")
