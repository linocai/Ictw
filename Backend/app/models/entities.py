from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from sqlalchemy import Boolean, CheckConstraint, DateTime, ForeignKey, Index, Integer, String, Text, UniqueConstraint, text
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
    headline: Mapped[str] = mapped_column(Text, default="", nullable=False)
    # Canonical narrative summary.  The old ``summary`` synopsis column was
    # merged here in v1.6.3; API compatibility is handled by the router.
    long_summary: Mapped[str] = mapped_column(Text, default="", nullable=False)
    state_changes: Mapped[list[dict[str, Any]]] = mapped_column(
        MutableList.as_mutable(JSON), default=list, nullable=False, server_default="[]"
    )
    unresolved_items: Mapped[list[dict[str, Any]]] = mapped_column(
        MutableList.as_mutable(JSON), default=list, nullable=False, server_default="[]"
    )
    atomic_memories: Mapped[list[dict[str, Any]]] = mapped_column(
        MutableList.as_mutable(JSON), default=list, nullable=False, server_default="[]"
    )
    exempted_character_names: Mapped[list[str]] = mapped_column(
        MutableList.as_mutable(JSON), default=list, nullable=False, server_default="[]"
    )
    status: Mapped[str] = mapped_column(String(32), default="draft", nullable=False)
    # v1.8 separates accepted prose from its asynchronous memory archive.
    # Existing production rows are marked legacy by the migration; newly
    # created chapters explicitly start stale until their first v2 archive.
    archive_status: Mapped[str] = mapped_column(String(16), default="stale", nullable=False)
    active_archive_revision_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    archive_input_fingerprint: Mapped[str | None] = mapped_column(String(64), nullable=True)
    legacy_archive_eligible: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    source: Mapped[str] = mapped_column(String(32), default="agent", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)

    book = relationship("Book", back_populates="chapters")
    character_links = relationship("ChapterCharacter", back_populates="chapter", cascade="all, delete-orphan")
    events = relationship("CharacterEvent", back_populates="chapter", cascade="all, delete-orphan")
    archive_revisions = relationship(
        "ChapterArchiveRevision", back_populates="chapter", cascade="all, delete-orphan"
    )


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


class CharacterStateChange(Base):
    """An Extractor-owned, replayable change to a character's current state.

    ``characters.dynamic_fields`` remains the public materialized projection;
    this table is its only v1.7.2 source of truth.  Relationship endpoints are
    stored in lexical ID order so a pair has exactly one state slot.
    """

    __tablename__ = "character_state_changes"
    __table_args__ = (
        CheckConstraint("scope IN ('snapshot', 'persistent', 'relationship')", name="ck_state_change_scope"),
        CheckConstraint("operation IN ('set', 'clear')", name="ck_state_change_operation"),
        CheckConstraint(
            "(operation = 'set' AND value IS NOT NULL AND length(trim(value)) > 0) "
            "OR (operation = 'clear' AND value IS NULL)",
            name="ck_state_change_value_matches_operation",
        ),
        CheckConstraint("length(trim(evidence)) > 0", name="ck_state_change_evidence_nonempty"),
        CheckConstraint(
            "(scope = 'snapshot' AND other_character_id IS NULL "
            "AND slot IN ('当前位置', '当前行动', '情绪状态') AND batch_id <> '') "
            "OR (scope = 'persistent' AND other_character_id IS NULL "
            "AND slot IN ('身体状态', '当前目标', '秘密状态') AND batch_id = '') "
            "OR (scope = 'relationship' AND other_character_id IS NOT NULL "
            "AND other_character_id <> character_id AND slot = 'relationship' AND batch_id = '')",
            name="ck_state_change_shape",
        ),
        Index(
            "uq_state_change_nonrelationship",
            "chapter_id", "character_id", "scope", "slot", "batch_id",
            unique=True,
            sqlite_where=text("other_character_id IS NULL"),
        ),
        Index(
            "uq_state_change_relationship",
            "chapter_id", "character_id", "other_character_id", "scope", "slot", "batch_id",
            unique=True,
            sqlite_where=text("other_character_id IS NOT NULL"),
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    book_id: Mapped[str] = mapped_column(String(36), ForeignKey("books.id", ondelete="CASCADE"), nullable=False, index=True)
    chapter_id: Mapped[str] = mapped_column(String(36), ForeignKey("chapters.id", ondelete="CASCADE"), nullable=False, index=True)
    character_id: Mapped[str] = mapped_column(String(36), ForeignKey("characters.id", ondelete="CASCADE"), nullable=False, index=True)
    other_character_id: Mapped[str | None] = mapped_column(String(36), ForeignKey("characters.id", ondelete="CASCADE"), nullable=True, index=True)
    scope: Mapped[str] = mapped_column(String(16), nullable=False)
    slot: Mapped[str] = mapped_column(String(64), nullable=False)
    operation: Mapped[str] = mapped_column(String(8), nullable=False)
    value: Mapped[str | None] = mapped_column(Text, nullable=True)
    evidence: Mapped[str] = mapped_column(Text, nullable=False)
    batch_id: Mapped[str] = mapped_column(String(36), default="", nullable=False)
    is_effective: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


class ChapterArchiveRevision(Base):
    """Immutable v2 extraction attempt; only a complete revision may be active."""

    __tablename__ = "chapter_archive_revisions"
    __table_args__ = (
        UniqueConstraint("chapter_id", "revision", name="uq_archive_revision_number"),
        CheckConstraint(
            "status IN ('pending', 'extracting', 'complete', 'partial', 'failed', 'stale')",
            name="ck_archive_revision_status",
        ),
        CheckConstraint(
            "provenance IN ('live', 'manual_retry', 'selective_reextract')",
            name="ck_archive_revision_provenance",
        ),
        CheckConstraint(
            "is_active = 0 OR status = 'complete'",
            name="ck_archive_revision_active_complete",
        ),
        CheckConstraint("schema_version = 2", name="ck_archive_revision_schema_v2"),
        Index(
            "uq_archive_active_chapter",
            "chapter_id",
            unique=True,
            sqlite_where=text("is_active = 1"),
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    chapter_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("chapters.id", ondelete="CASCADE"), nullable=False, index=True
    )
    revision: Mapped[int] = mapped_column(Integer, nullable=False)
    schema_version: Mapped[int] = mapped_column(Integer, default=2, nullable=False)
    provenance: Mapped[str] = mapped_column(String(32), nullable=False)
    input_fingerprint: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    status: Mapped[str] = mapped_column(String(16), default="pending", nullable=False, index=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    summary: Mapped[str] = mapped_column(Text, default="", nullable=False)
    model_name: Mapped[str | None] = mapped_column(Text, nullable=True)
    contract_version: Mapped[str] = mapped_column(String(32), default="archive-v2.0", nullable=False)
    validation_errors: Mapped[list[str]] = mapped_column(
        MutableList.as_mutable(JSON), default=list, nullable=False, server_default="[]"
    )
    error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    chapter = relationship("Chapter", back_populates="archive_revisions")
    facts = relationship(
        "ChapterArchiveFact", back_populates="revision", cascade="all, delete-orphan",
        order_by="ChapterArchiveFact.position",
    )
    state_deltas = relationship(
        "ChapterArchiveStateDelta", back_populates="revision", cascade="all, delete-orphan",
        order_by="ChapterArchiveStateDelta.position",
    )


class ChapterArchiveFact(Base):
    __tablename__ = "chapter_archive_facts"
    __table_args__ = (
        UniqueConstraint("revision_id", "position", name="uq_archive_fact_position"),
        UniqueConstraint("revision_id", "fact_ref", name="uq_archive_fact_ref"),
        CheckConstraint(
            "fact_type IN ('剧情', '决定', '关系', '认知', '未决', '状态')",
            name="ck_archive_fact_type",
        ),
        CheckConstraint("importance BETWEEN 1 AND 3", name="ck_archive_fact_importance"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    revision_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("chapter_archive_revisions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    fact_ref: Mapped[str] = mapped_column(String(16), nullable=False)
    fact_type: Mapped[str] = mapped_column(String(16), nullable=False)
    importance: Mapped[int] = mapped_column(Integer, nullable=False)
    fact_text: Mapped[str] = mapped_column(Text, nullable=False)
    start_id: Mapped[str] = mapped_column(String(16), nullable=False)
    end_id: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)

    revision = relationship("ChapterArchiveRevision", back_populates="facts")
    participants = relationship(
        "ChapterArchiveFactParticipant", back_populates="fact", cascade="all, delete-orphan",
        order_by="ChapterArchiveFactParticipant.position",
    )
    state_deltas = relationship("ChapterArchiveStateDelta", back_populates="fact")


class ChapterArchiveFactParticipant(Base):
    __tablename__ = "chapter_archive_fact_participants"
    __table_args__ = (
        UniqueConstraint("fact_id", "character_id", name="uq_archive_fact_participant"),
        UniqueConstraint("fact_id", "position", name="uq_archive_fact_participant_position"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    fact_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("chapter_archive_facts.id", ondelete="CASCADE"), nullable=False, index=True
    )
    character_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("characters.id", ondelete="CASCADE"), nullable=False, index=True
    )
    position: Mapped[int] = mapped_column(Integer, nullable=False)

    fact = relationship("ChapterArchiveFact", back_populates="participants")
    character = relationship("Character")


class ChapterArchiveStateDelta(Base):
    __tablename__ = "chapter_archive_state_deltas"
    __table_args__ = (
        UniqueConstraint("revision_id", "position", name="uq_archive_delta_position"),
        CheckConstraint("scope IN ('snapshot', 'persistent', 'relationship')", name="ck_archive_delta_scope"),
        CheckConstraint("operation IN ('set', 'clear')", name="ck_archive_delta_operation"),
        CheckConstraint(
            "(operation = 'set' AND value IS NOT NULL AND length(trim(value)) > 0) "
            "OR (operation = 'clear' AND value IS NULL)",
            name="ck_archive_delta_value_matches_operation",
        ),
        CheckConstraint(
            "(scope = 'snapshot' AND other_character_id IS NULL "
            "AND slot IN ('当前位置', '当前行动', '情绪状态') AND batch_id <> '') "
            "OR (scope = 'persistent' AND other_character_id IS NULL "
            "AND slot IN ('身体状态', '当前目标', '秘密状态') AND batch_id = '') "
            "OR (scope = 'relationship' AND other_character_id IS NOT NULL "
            "AND other_character_id <> character_id AND slot = 'relationship' AND batch_id = '')",
            name="ck_archive_delta_shape",
        ),
        Index(
            "uq_archive_delta_nonrelationship",
            "revision_id", "character_id", "scope", "slot", "batch_id",
            unique=True,
            sqlite_where=text("other_character_id IS NULL"),
        ),
        Index(
            "uq_archive_delta_relationship",
            "revision_id", "character_id", "other_character_id", "scope", "slot", "batch_id",
            unique=True,
            sqlite_where=text("other_character_id IS NOT NULL"),
        ),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    revision_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("chapter_archive_revisions.id", ondelete="CASCADE"), nullable=False, index=True
    )
    fact_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("chapter_archive_facts.id", ondelete="CASCADE"), nullable=False, index=True
    )
    position: Mapped[int] = mapped_column(Integer, nullable=False)
    character_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("characters.id", ondelete="CASCADE"), nullable=False, index=True
    )
    other_character_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("characters.id", ondelete="CASCADE"), nullable=True, index=True
    )
    scope: Mapped[str] = mapped_column(String(16), nullable=False)
    slot: Mapped[str] = mapped_column(String(64), nullable=False)
    operation: Mapped[str] = mapped_column(String(8), nullable=False)
    value: Mapped[str | None] = mapped_column(Text, nullable=True)
    batch_id: Mapped[str] = mapped_column(String(36), default="", nullable=False)
    is_effective: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)

    revision = relationship("ChapterArchiveRevision", back_populates="state_deltas")
    fact = relationship("ChapterArchiveFact", back_populates="state_deltas")
    character = relationship("Character", foreign_keys=[character_id])
    other_character = relationship("Character", foreign_keys=[other_character_id])


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
    memory_context: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    checker_result: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    bible_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    draft_fingerprint: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # Logical audit link.  Kept without a database FK so the additive SQLite
    # migration never has to rebuild the high-write job_runs table.
    archive_revision_id: Mapped[str | None] = mapped_column(String(36), index=True, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class ChapterDraftCandidate(Base):
    __tablename__ = "chapter_draft_candidates"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=uuid_str)
    chapter_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("chapters.id", ondelete="CASCADE"), index=True, nullable=False
    )
    job_id: Mapped[str | None] = mapped_column(
        String(36), ForeignKey("job_runs.id", ondelete="SET NULL"), index=True, nullable=True
    )
    attempt: Mapped[int] = mapped_column(Integer, nullable=False)
    draft_text: Mapped[str] = mapped_column(Text, nullable=False)
    non_whitespace_count: Mapped[int] = mapped_column(Integer, nullable=False)
    finish_reason: Mapped[str | None] = mapped_column(String(64), nullable=True)
    deterministic_violations: Mapped[list | None] = mapped_column(JSON, nullable=True)
    checker_result: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    bible_sha256: Mapped[str | None] = mapped_column(String(64), nullable=True)
    draft_fingerprint: Mapped[str | None] = mapped_column(String(64), nullable=True)
    is_current: Mapped[bool] = mapped_column(default=False, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now, nullable=False)


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
