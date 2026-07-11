"""per-chapter character dynamic field patch records

Revision ID: 20260711_0005
Revises: 20260711_0004
Create Date: 2026-07-11
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260711_0005"
down_revision = "20260711_0004"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "character_field_patches",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("book_id", sa.String(length=36), nullable=False),
        sa.Column("chapter_id", sa.String(length=36), nullable=False, index=True),
        sa.Column("character_id", sa.String(length=36), nullable=False, index=True),
        sa.Column("prior_values", sa.JSON(), nullable=False),
        sa.Column("prior_missing", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["book_id"], ["books.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["chapter_id"], ["chapters.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("chapter_id", "character_id", name="uq_field_patch_chapter_character"),
    )


def downgrade() -> None:
    op.drop_table("character_field_patches")
