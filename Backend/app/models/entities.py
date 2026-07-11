from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.ext.mutable import MutableDict, MutableList
from sqlalchemy.orm import Mapped, mapped_column, relationship
from sqlalchemy.types import JSON

from app.db import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def uuid_str() -> str:
    return str(uuid.uuid4())


class Book(Base):
    __tablename__ = "books"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    title: Mapped[str] = mapped_column(Text, nullable=False)
    world_setting: Mapped[str] = mapped_column(Text, default="", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)
    last_opened_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    chapters = relationship("Chapter", back_populates="book", cascade="all, delete-orphan")
    characters = relationship("Character", back_populates="book", cascade="all, delete-orphan")


class Character(Base):
    __tablename__ = "characters"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    book_id: Mapped[str] = mapped_column(String(36), ForeignKey("books.id", ondelete="CASCADE"), nullable=False)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    role: Mapped[str] = mapped_column(Text, default="", nullable=False)
    fixed_profile: Mapped[str] = mapped_column(Text, default="", nullable=False)
    dynamic_fields: Mapped[dict[str, Any]] = mapped_column(MutableDict.as_mutable(JSON), default=dict, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)

    book = relationship("Book", back_populates="characters")
    chapter_links = relationship("ChapterCharacter", back_populates="character", cascade="all, delete-orphan")
    events = relationship("CharacterEvent", back_populates="character", cascade="all, delete-orphan")


class Chapter(Base):
    __tablename__ = "chapters"
    __table_args__ = (UniqueConstraint("book_id", "index", name="uq_chapters_book_index"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    book_id: Mapped[str] = mapped_column(String(36), ForeignKey("books.id", ondelete="CASCADE"), nullable=False)
    index: Mapped[int] = mapped_column(Integer, nullable=False)
    title: Mapped[str] = mapped_column(Text, default="", nullable=False)
    user_prompt: Mapped[str] = mapped_column(Text, default="", nullable=False)
    target_word_count: Mapped[int] = mapped_column(Integer, default=3000, nullable=False)
    author_note: Mapped[str] = mapped_column(Text, default="", nullable=False)
    draft_text: Mapped[str] = mapped_column(Text, default="", nullable=False)
    summary: Mapped[str] = mapped_column(Text, default="", nullable=False)
    headline: Mapped[str] = mapped_column(Text, default="", nullable=False)
    exempted_character_names: Mapped[list[str]] = mapped_column(
        MutableList.as_mutable(JSON), default=list, nullable=False, server_default="[]"
    )
    status: Mapped[str] = mapped_column(String(32), default="draft", nullable=False)
    source: Mapped[str] = mapped_column(String(32), default="agent", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)

    book = relationship("Book", back_populates="chapters")
    character_links = relationship("ChapterCharacter", back_populates="chapter", cascade="all, delete-orphan")
    events = relationship("CharacterEvent", back_populates="chapter", cascade="all, delete-orphan")


class ChapterCharacter(Base):
    __tablename__ = "chapter_characters"
    __table_args__ = (UniqueConstraint("chapter_id", "character_id", name="uq_chapter_character"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    chapter_id: Mapped[str] = mapped_column(String(36), ForeignKey("chapters.id", ondelete="CASCADE"), nullable=False)
    character_id: Mapped[str] = mapped_column(String(36), ForeignKey("characters.id", ondelete="CASCADE"), nullable=False)
    chapter = relationship("Chapter", back_populates="character_links")
    character = relationship("Character", back_populates="chapter_links")


class CharacterEvent(Base):
    __tablename__ = "character_events"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    book_id: Mapped[str] = mapped_column(String(36), ForeignKey("books.id", ondelete="CASCADE"), nullable=False)
    character_id: Mapped[str] = mapped_column(String(36), ForeignKey("characters.id", ondelete="CASCADE"), nullable=False)
    chapter_id: Mapped[str] = mapped_column(String(36), ForeignKey("chapters.id", ondelete="CASCADE"), nullable=False)
    event_type: Mapped[str] = mapped_column(String(64), default="story", nullable=False)
    event_text: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)

    character = relationship("Character", back_populates="events")
    chapter = relationship("Chapter", back_populates="events")


class CharacterFieldPatch(Base):
    """Per-chapter record of which dynamic fields a chapter's extraction touched.

    prior_values holds the pre-merge value for keys that existed before the
    chapter; prior_missing lists keys the chapter introduced. Together they are
    the chapter's applied-key set and allow per-key rollback on chapter delete.
    """

    __tablename__ = "character_field_patches"
    __table_args__ = (UniqueConstraint("chapter_id", "character_id", name="uq_field_patch_chapter_character"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    book_id: Mapped[str] = mapped_column(String(36), ForeignKey("books.id", ondelete="CASCADE"), nullable=False)
    chapter_id: Mapped[str] = mapped_column(String(36), ForeignKey("chapters.id", ondelete="CASCADE"), nullable=False, index=True)
    character_id: Mapped[str] = mapped_column(String(36), ForeignKey("characters.id", ondelete="CASCADE"), nullable=False, index=True)
    prior_values: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict, nullable=False)
    prior_missing: Mapped[list[str]] = mapped_column(JSON, default=list, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


class AgentPersona(Base):
    __tablename__ = "agent_personas"

    agent_role: Mapped[str] = mapped_column(String(32), primary_key=True)
    system_prompt: Mapped[str] = mapped_column(Text, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


class LLMProfile(Base):
    __tablename__ = "llm_profiles"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    provider: Mapped[str] = mapped_column(Text, default="openai-compatible", nullable=False)
    base_url: Mapped[str] = mapped_column(Text, nullable=False)
    api_key_encrypted: Mapped[str] = mapped_column(Text, nullable=False)
    model_name: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


class AgentModelBinding(Base):
    __tablename__ = "agent_model_bindings"

    agent_role: Mapped[str] = mapped_column(String(32), primary_key=True)
    llm_profile_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("llm_profiles.id", ondelete="SET NULL"))
    thinking_enabled: Mapped[bool | None] = mapped_column(nullable=True)
    reasoning_effort: Mapped[str | None] = mapped_column(String(32), nullable=True)
    temperature: Mapped[float | None] = mapped_column(nullable=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


class JobRun(Base):
    __tablename__ = "job_runs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    chapter_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("chapters.id", ondelete="CASCADE"), index=True, nullable=False
    )
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    phase: Mapped[str] = mapped_column(String(32), nullable=False)
    attempt: Mapped[int | None] = mapped_column(Integer, nullable=True)
    error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    error_context: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    violations: Mapped[list | None] = mapped_column(JSON, nullable=True)
    updated_character_ids: Mapped[list | None] = mapped_column(JSON, nullable=True)
    added_event_ids: Mapped[list | None] = mapped_column(JSON, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class LLMCallAudit(Base):
    __tablename__ = "llm_call_audits"

    # No prompt / body / api_key columns are defined here on purpose.
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    agent_role: Mapped[str] = mapped_column(String(32), nullable=False)
    model_name: Mapped[str] = mapped_column(Text, default="", nullable=False)
    duration_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    prompt_tokens: Mapped[int | None] = mapped_column(Integer, nullable=True)
    completion_tokens: Mapped[int | None] = mapped_column(Integer, nullable=True)
    total_tokens: Mapped[int | None] = mapped_column(Integer, nullable=True)
    finish_reason: Mapped[str | None] = mapped_column(String(64), nullable=True)
    error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Offline-troubleshooting only; already whitelist-extracted, never a raw body.
    upstream_reason: Mapped[str | None] = mapped_column(Text, nullable=True)
    chapter_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    job_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
