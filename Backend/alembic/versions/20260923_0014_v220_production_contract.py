"""persist v2.2 production inputs and archive state gaps

Revision ID: 20260923_0014
Revises: 20260830_0013
Create Date: 2026-09-23
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa

from app.migration_safety import require_destructive_downgrade_authorization


revision = "20260923_0014"
down_revision = "20260830_0013"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # All additions deliberately carry SQLite-safe defaults. Existing archive
    # revisions retain archive-v2.0 semantics until an explicit v2.1 retry.
    op.add_column(
        "chapter_archive_revisions",
        sa.Column("diagnostics", sa.JSON(), nullable=False, server_default=sa.text("'[]'")),
    )
    op.add_column(
        "chapter_archive_revisions",
        sa.Column("state_uncertainties", sa.JSON(), nullable=False, server_default=sa.text("'[]'")),
    )
    op.add_column(
        "chapter_draft_candidates",
        sa.Column("checker_input_snapshot", sa.JSON(), nullable=False, server_default=sa.text("'{}'")),
    )
    op.add_column("chapter_draft_candidates", sa.Column("checker_input_fingerprint", sa.String(length=64), nullable=True))
    op.add_column("chapter_draft_candidates", sa.Column("latest_checker_attempt_id", sa.String(length=36), nullable=True))
    op.create_index("ix_chapter_draft_candidates_latest_checker_attempt_id", "chapter_draft_candidates", ["latest_checker_attempt_id"])
    op.add_column("job_runs", sa.Column("candidate_id", sa.String(length=36), nullable=True))
    op.add_column("job_runs", sa.Column("parent_job_id", sa.String(length=36), nullable=True))
    op.add_column("job_runs", sa.Column("input_snapshot", sa.JSON(), nullable=True))
    op.add_column("job_runs", sa.Column("input_fingerprint", sa.String(length=64), nullable=True))
    op.add_column("job_runs", sa.Column("context_limitations", sa.JSON(), nullable=True))
    op.create_index("ix_job_runs_candidate_id", "job_runs", ["candidate_id"])
    op.create_index("ix_job_runs_parent_job_id", "job_runs", ["parent_job_id"])
    op.create_index("ix_job_runs_input_fingerprint", "job_runs", ["input_fingerprint"])


def downgrade() -> None:
    # Every column below contains a persisted production decision, frozen
    # model input, or state-gap recovery record.  Refuse before the first DDL
    # unless the stopped-service, byte-identical backup proof is present.
    require_destructive_downgrade_authorization(op.get_bind(), revision=revision)
    op.drop_index("ix_job_runs_input_fingerprint", table_name="job_runs")
    op.drop_index("ix_job_runs_parent_job_id", table_name="job_runs")
    op.drop_index("ix_job_runs_candidate_id", table_name="job_runs")
    op.drop_column("job_runs", "context_limitations")
    op.drop_column("job_runs", "input_fingerprint")
    op.drop_column("job_runs", "input_snapshot")
    op.drop_column("job_runs", "parent_job_id")
    op.drop_column("job_runs", "candidate_id")
    op.drop_index("ix_chapter_draft_candidates_latest_checker_attempt_id", table_name="chapter_draft_candidates")
    op.drop_column("chapter_draft_candidates", "latest_checker_attempt_id")
    op.drop_column("chapter_draft_candidates", "checker_input_fingerprint")
    op.drop_column("chapter_draft_candidates", "checker_input_snapshot")
    op.drop_column("chapter_archive_revisions", "state_uncertainties")
    op.drop_column("chapter_archive_revisions", "diagnostics")
