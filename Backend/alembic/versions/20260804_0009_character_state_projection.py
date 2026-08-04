"""add replayable character current-state changes

Revision ID: 20260804_0009
Revises: 20260801_0008
Create Date: 2026-08-04
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260804_0009"
down_revision = "20260801_0008"
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
        "character_state_changes",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("book_id", sa.String(length=36), nullable=False),
        sa.Column("chapter_id", sa.String(length=36), nullable=False),
        sa.Column("character_id", sa.String(length=36), nullable=False),
        sa.Column("other_character_id", sa.String(length=36), nullable=True),
        sa.Column("scope", sa.String(length=16), nullable=False),
        sa.Column("slot", sa.String(length=64), nullable=False),
        sa.Column("operation", sa.String(length=8), nullable=False),
        sa.Column("value", sa.Text(), nullable=True),
        sa.Column("evidence", sa.Text(), nullable=False),
        sa.Column("batch_id", sa.String(length=36), nullable=False, server_default=""),
        sa.Column("is_effective", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("scope IN ('snapshot', 'persistent', 'relationship')", name="ck_state_change_scope"),
        sa.CheckConstraint("operation IN ('set', 'clear')", name="ck_state_change_operation"),
        sa.CheckConstraint(
            "(operation = 'set' AND value IS NOT NULL AND length(trim(value)) > 0) "
            "OR (operation = 'clear' AND value IS NULL)",
            name="ck_state_change_value_matches_operation",
        ),
        sa.CheckConstraint("length(trim(evidence)) > 0", name="ck_state_change_evidence_nonempty"),
        sa.CheckConstraint(
            "(scope = 'snapshot' AND other_character_id IS NULL "
            "AND slot IN ('当前位置', '当前行动', '情绪状态') AND batch_id <> '') "
            "OR (scope = 'persistent' AND other_character_id IS NULL "
            "AND slot IN ('身体状态', '当前目标', '秘密状态') AND batch_id = '') "
            "OR (scope = 'relationship' AND other_character_id IS NOT NULL "
            "AND other_character_id <> character_id AND slot = 'relationship' AND batch_id = '')",
            name="ck_state_change_shape",
        ),
        sa.ForeignKeyConstraint(["book_id"], ["books.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["chapter_id"], ["chapters.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["other_character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    for name, columns in (
        ("ix_state_changes_book", ["book_id"]),
        ("ix_state_changes_chapter", ["chapter_id"]),
        ("ix_state_changes_character", ["character_id"]),
        ("ix_state_changes_other_character", ["other_character_id"]),
        ("ix_state_changes_effective", ["is_effective"]),
    ):
        op.create_index(name, "character_state_changes", columns)
    op.create_index(
        "uq_state_change_nonrelationship",
        "character_state_changes",
        ["chapter_id", "character_id", "scope", "slot", "batch_id"],
        unique=True,
        sqlite_where=sa.text("other_character_id IS NULL"),
    )
    op.create_index(
        "uq_state_change_relationship",
        "character_state_changes",
        ["chapter_id", "character_id", "other_character_id", "scope", "slot", "batch_id"],
        unique=True,
        sqlite_where=sa.text("other_character_id IS NOT NULL"),
    )
    _assert_foreign_keys_clean(connection)


def downgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)
    op.drop_table("character_state_changes")
    _assert_foreign_keys_clean(connection)
