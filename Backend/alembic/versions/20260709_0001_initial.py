"""initial schema

Revision ID: 20260709_0001
Revises:
Create Date: 2026-07-09
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260709_0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "books",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("world_setting", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_opened_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "agent_personas",
        sa.Column("agent_role", sa.String(length=32), primary_key=True),
        sa.Column("system_prompt", sa.Text(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "llm_profiles",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("provider", sa.Text(), nullable=False),
        sa.Column("base_url", sa.Text(), nullable=False),
        sa.Column("api_key_encrypted", sa.Text(), nullable=False),
        sa.Column("model_name", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "agent_model_bindings",
        sa.Column("agent_role", sa.String(length=32), primary_key=True),
        sa.Column("llm_profile_id", sa.String(length=36), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["llm_profile_id"], ["llm_profiles.id"], ondelete="SET NULL"),
    )
    op.create_table(
        "chapters",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("book_id", sa.String(length=36), nullable=False),
        sa.Column("index", sa.Integer(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("user_prompt", sa.Text(), nullable=False),
        sa.Column("target_word_count", sa.Integer(), nullable=False),
        sa.Column("chapter_style", sa.Text(), nullable=False),
        sa.Column("draft_text", sa.Text(), nullable=False),
        sa.Column("summary", sa.Text(), nullable=False),
        sa.Column("headline", sa.Text(), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("source", sa.String(length=32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["book_id"], ["books.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("book_id", "index", name="uq_chapters_book_index"),
    )
    op.create_table(
        "characters",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("book_id", sa.String(length=36), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("role", sa.Text(), nullable=False),
        sa.Column("fixed_profile", sa.Text(), nullable=False),
        sa.Column("dynamic_fields", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["book_id"], ["books.id"], ondelete="CASCADE"),
    )
    op.create_table(
        "chapter_characters",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("chapter_id", sa.String(length=36), nullable=False),
        sa.Column("character_id", sa.String(length=36), nullable=False),
        sa.Column("chapter_note", sa.Text(), nullable=False),
        sa.ForeignKeyConstraint(["chapter_id"], ["chapters.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.UniqueConstraint("chapter_id", "character_id", name="uq_chapter_character"),
    )
    op.create_table(
        "character_events",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("book_id", sa.String(length=36), nullable=False),
        sa.Column("character_id", sa.String(length=36), nullable=False),
        sa.Column("chapter_id", sa.String(length=36), nullable=False),
        sa.Column("event_type", sa.String(length=64), nullable=False),
        sa.Column("event_text", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["book_id"], ["books.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["chapter_id"], ["chapters.id"], ondelete="CASCADE"),
    )


def downgrade() -> None:
    op.drop_table("character_events")
    op.drop_table("chapter_characters")
    op.drop_table("characters")
    op.drop_table("chapters")
    op.drop_table("agent_model_bindings")
    op.drop_table("llm_profiles")
    op.drop_table("agent_personas")
    op.drop_table("books")
