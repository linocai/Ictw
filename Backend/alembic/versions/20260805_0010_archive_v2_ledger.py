"""add v2 chapter archive fact ledger

Revision ID: 20260805_0010
Revises: 20260804_0009
Create Date: 2026-08-05
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260805_0010"
down_revision = "20260804_0009"
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

    # Existing rows keep serving their v1 archive through the legacy adapter.
    op.add_column(
        "chapters",
        sa.Column("archive_status", sa.String(length=16), nullable=False, server_default="legacy"),
    )
    op.add_column("chapters", sa.Column("active_archive_revision_id", sa.String(length=36), nullable=True))
    op.add_column("chapters", sa.Column("archive_input_fingerprint", sa.String(length=64), nullable=True))
    op.add_column(
        "chapters",
        sa.Column("legacy_archive_eligible", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.create_index("ix_chapters_active_archive_revision_id", "chapters", ["active_archive_revision_id"])

    op.create_table(
        "chapter_archive_revisions",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("chapter_id", sa.String(length=36), nullable=False),
        sa.Column("revision", sa.Integer(), nullable=False),
        sa.Column("schema_version", sa.Integer(), nullable=False, server_default="2"),
        sa.Column("provenance", sa.String(length=32), nullable=False),
        sa.Column("input_fingerprint", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False, server_default="pending"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("summary", sa.Text(), nullable=False, server_default=""),
        sa.Column("model_name", sa.Text(), nullable=True),
        sa.Column("contract_version", sa.String(length=32), nullable=False, server_default="archive-v2.0"),
        sa.Column("validation_errors", sa.JSON(), nullable=False, server_default="[]"),
        sa.Column("error_code", sa.String(length=64), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("schema_version = 2", name="ck_archive_revision_schema_v2"),
        sa.CheckConstraint(
            "status IN ('pending', 'extracting', 'complete', 'partial', 'failed', 'stale')",
            name="ck_archive_revision_status",
        ),
        sa.CheckConstraint(
            "provenance IN ('live', 'manual_retry', 'selective_reextract')",
            name="ck_archive_revision_provenance",
        ),
        sa.CheckConstraint(
            "is_active = 0 OR status = 'complete'",
            name="ck_archive_revision_active_complete",
        ),
        sa.ForeignKeyConstraint(["chapter_id"], ["chapters.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("chapter_id", "revision", name="uq_archive_revision_number"),
    )
    op.create_index("ix_archive_revisions_chapter", "chapter_archive_revisions", ["chapter_id"])
    op.create_index("ix_archive_revisions_fingerprint", "chapter_archive_revisions", ["input_fingerprint"])
    op.create_index("ix_archive_revisions_status", "chapter_archive_revisions", ["status"])
    op.create_index("ix_archive_revisions_active", "chapter_archive_revisions", ["is_active"])
    op.create_index(
        "uq_archive_active_chapter",
        "chapter_archive_revisions",
        ["chapter_id"],
        unique=True,
        sqlite_where=sa.text("is_active = 1"),
    )

    op.create_table(
        "chapter_archive_facts",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("revision_id", sa.String(length=36), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("fact_ref", sa.String(length=16), nullable=False),
        sa.Column("fact_type", sa.String(length=16), nullable=False),
        sa.Column("importance", sa.Integer(), nullable=False),
        sa.Column("fact_text", sa.Text(), nullable=False),
        sa.Column("start_id", sa.String(length=16), nullable=False),
        sa.Column("end_id", sa.String(length=16), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "fact_type IN ('剧情', '决定', '关系', '认知', '未决', '状态')",
            name="ck_archive_fact_type",
        ),
        sa.CheckConstraint("importance BETWEEN 1 AND 3", name="ck_archive_fact_importance"),
        sa.ForeignKeyConstraint(["revision_id"], ["chapter_archive_revisions.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("revision_id", "position", name="uq_archive_fact_position"),
        sa.UniqueConstraint("revision_id", "fact_ref", name="uq_archive_fact_ref"),
    )
    op.create_index("ix_archive_facts_revision", "chapter_archive_facts", ["revision_id"])

    op.create_table(
        "chapter_archive_fact_participants",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("fact_id", sa.String(length=36), nullable=False),
        sa.Column("character_id", sa.String(length=36), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["fact_id"], ["chapter_archive_facts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("fact_id", "character_id", name="uq_archive_fact_participant"),
        sa.UniqueConstraint("fact_id", "position", name="uq_archive_fact_participant_position"),
    )
    op.create_index("ix_archive_fact_participants_fact", "chapter_archive_fact_participants", ["fact_id"])
    op.create_index("ix_archive_fact_participants_character", "chapter_archive_fact_participants", ["character_id"])

    op.create_table(
        "chapter_archive_state_deltas",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("revision_id", sa.String(length=36), nullable=False),
        sa.Column("fact_id", sa.String(length=36), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("character_id", sa.String(length=36), nullable=False),
        sa.Column("other_character_id", sa.String(length=36), nullable=True),
        sa.Column("scope", sa.String(length=16), nullable=False),
        sa.Column("slot", sa.String(length=64), nullable=False),
        sa.Column("operation", sa.String(length=8), nullable=False),
        sa.Column("value", sa.Text(), nullable=True),
        sa.Column("batch_id", sa.String(length=36), nullable=False, server_default=""),
        sa.Column("is_effective", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("scope IN ('snapshot', 'persistent', 'relationship')", name="ck_archive_delta_scope"),
        sa.CheckConstraint("operation IN ('set', 'clear')", name="ck_archive_delta_operation"),
        sa.CheckConstraint(
            "(operation = 'set' AND value IS NOT NULL AND length(trim(value)) > 0) "
            "OR (operation = 'clear' AND value IS NULL)",
            name="ck_archive_delta_value_matches_operation",
        ),
        sa.CheckConstraint(
            "(scope = 'snapshot' AND other_character_id IS NULL "
            "AND slot IN ('当前位置', '当前行动', '情绪状态') AND batch_id <> '') "
            "OR (scope = 'persistent' AND other_character_id IS NULL "
            "AND slot IN ('身体状态', '当前目标', '秘密状态') AND batch_id = '') "
            "OR (scope = 'relationship' AND other_character_id IS NOT NULL "
            "AND other_character_id <> character_id AND slot = 'relationship' AND batch_id = '')",
            name="ck_archive_delta_shape",
        ),
        sa.ForeignKeyConstraint(["revision_id"], ["chapter_archive_revisions.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["fact_id"], ["chapter_archive_facts.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["other_character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("revision_id", "position", name="uq_archive_delta_position"),
    )
    for name, columns in (
        ("ix_archive_deltas_revision", ["revision_id"]),
        ("ix_archive_deltas_fact", ["fact_id"]),
        ("ix_archive_deltas_character", ["character_id"]),
        ("ix_archive_deltas_other_character", ["other_character_id"]),
        ("ix_archive_deltas_effective", ["is_effective"]),
    ):
        op.create_index(name, "chapter_archive_state_deltas", columns)
    op.create_index(
        "uq_archive_delta_nonrelationship",
        "chapter_archive_state_deltas",
        ["revision_id", "character_id", "scope", "slot", "batch_id"],
        unique=True,
        sqlite_where=sa.text("other_character_id IS NULL"),
    )
    op.create_index(
        "uq_archive_delta_relationship",
        "chapter_archive_state_deltas",
        ["revision_id", "character_id", "other_character_id", "scope", "slot", "batch_id"],
        unique=True,
        sqlite_where=sa.text("other_character_id IS NOT NULL"),
    )

    op.add_column("job_runs", sa.Column("archive_revision_id", sa.String(length=36), nullable=True))
    op.create_index("ix_job_runs_archive_revision_id", "job_runs", ["archive_revision_id"])
    _assert_foreign_keys_clean(connection)


def downgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)
    op.drop_index("ix_job_runs_archive_revision_id", table_name="job_runs")
    op.drop_column("job_runs", "archive_revision_id")
    op.drop_table("chapter_archive_state_deltas")
    op.drop_table("chapter_archive_fact_participants")
    op.drop_table("chapter_archive_facts")
    op.drop_table("chapter_archive_revisions")
    op.drop_index("ix_chapters_active_archive_revision_id", table_name="chapters")
    op.drop_column("chapters", "legacy_archive_eligible")
    op.drop_column("chapters", "archive_input_fingerprint")
    op.drop_column("chapters", "active_archive_revision_id")
    op.drop_column("chapters", "archive_status")
    _assert_foreign_keys_clean(connection)
