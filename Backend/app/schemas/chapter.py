from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.schemas.common import ORMModel


class ChapterCharacterLink(BaseModel):
    character_id: str
    # Deprecated wire field kept during the v1 compatibility window. It is no
    # longer persisted or used by any agent.
    chapter_note: str = ""


class _AuthorNoteCompat(BaseModel):
    author_note: str | None = None
    chapter_style: str | None = None

    @model_validator(mode="after")
    def mirror_legacy_author_note(self):
        if self.author_note is None and self.chapter_style is not None:
            self.author_note = self.chapter_style
        return self


class ChapterCreate(_AuthorNoteCompat):
    title: str = ""
    user_prompt: str = ""
    target_word_count: int = Field(default=3000, gt=0)
    character_links: list[ChapterCharacterLink] = Field(default_factory=list)


class ChapterPatch(_AuthorNoteCompat):
    title: str | None = None
    user_prompt: str | None = None
    target_word_count: int | None = Field(default=None, gt=0)
    draft_text: str | None = None
    # Deprecated old-App wire alias; the router maps it to long_summary.
    summary: str | None = None
    headline: str | None = None
    # v1.6 additive archive fields.  Older clients neither send nor need to
    # decode them; hand edits become the next Selector's source material.
    long_summary: str | None = None
    state_changes: list[dict] | None = None
    unresolved_items: list[dict] | None = None
    atomic_memories: list[dict] | None = None
    exempted_character_names: list[str] | None = None
    character_links: list[ChapterCharacterLink] | None = None


class ChapterImportRequest(_AuthorNoteCompat):
    draft_text: str
    title: str | None = None
    user_prompt: str | None = None
    target_word_count: int | None = Field(default=None, gt=0)
    character_links: list[ChapterCharacterLink] | None = None


class ChapterSummary(ORMModel):
    id: str
    book_id: str
    index: int
    title: str
    status: str
    source: str
    updated_at: datetime


class ArchiveFactRead(BaseModel):
    id: str
    type: str
    importance: int
    text: str
    participant_ids: list[str] = Field(default_factory=list)
    start_id: str
    end_id: str


class ChapterArchiveRead(BaseModel):
    status: str
    archive_schema: str = Field(alias="schema", serialization_alias="schema")
    revision_id: str | None = None
    revision: int | None = None
    summary: str = ""
    facts: list[ArchiveFactRead] = Field(default_factory=list)
    state_delta_count: int = 0
    error_code: str | None = None
    error_message: str | None = None
    can_retry: bool = False
    latest_attempt_status: str | None = None


class ChapterRead(ORMModel):
    id: str
    book_id: str
    index: int
    title: str
    user_prompt: str
    target_word_count: int
    author_note: str
    # Deprecated response mirror for old App versions.
    chapter_style: str
    draft_text: str
    # Deprecated response alias for v1.6.2 and older App builds.
    summary: str
    headline: str
    long_summary: str = ""
    state_changes: list[dict] = Field(default_factory=list)
    unresolved_items: list[dict] = Field(default_factory=list)
    atomic_memories: list[dict] = Field(default_factory=list)
    exempted_character_names: list[str] = Field(default_factory=list)
    status: str
    source: str
    created_at: datetime
    updated_at: datetime
    character_links: list[ChapterCharacterLink] = Field(default_factory=list)
    archive: ChapterArchiveRead | None = None


class WriteRequest(BaseModel):
    replace_draft: bool = False


class InspirationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = ""
    bible: str = ""
    selected_character_ids: list[str] = Field(default_factory=list)


class InspirationCardRead(BaseModel):
    title: str
    body: str
    history_basis: str | None = None
    note: str | None = None
    history_chapter_indexes: list[int] = Field(default_factory=list)


class InspirationResponse(BaseModel):
    cards: list[InspirationCardRead]


class CheckerAcceptRequest(BaseModel):
    # Required for an invalid/unavailable Checker state; omitted remains
    # compatible for the normal passed path used by old clients.
    override_checker: bool = False


class ArchiveRetryRequest(BaseModel):
    # The clients omit this body and always receive the normal manual retry.
    # The selective value is reserved for the count-only, user-confirmed
    # maintenance flow and requires the report's exact draft hash.
    provenance: Literal["manual_retry", "selective_reextract"] = "manual_retry"
    expected_draft_sha256: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")


class CheckerRunRead(ORMModel):
    id: str
    chapter_id: str
    job_id: str | None = None
    attempt: int
    # Empty compatibility placeholder for v1.6.0/1.6.1 clients whose decoder
    # still requires the key. The actual candidate text never leaves Backend.
    draft_text: str = ""
    non_whitespace_count: int
    finish_reason: str | None = None
    deterministic_violations: list[dict] | None = None
    checker_result: dict | None = None
    bible_sha256: str | None = None
    draft_fingerprint: str | None = None
    is_current: bool
    created_at: datetime


class WriteJobStatus(BaseModel):
    chapter_id: str
    # Additive identity/currentness fields used by v1.5 clients to reconcile
    # cold-start and cross-device terminal outcomes without replaying an old
    # failure after the chapter has since been edited or finalized.
    job_id: str | None = None
    outcome_current: bool | None = None
    kind: str
    phase: str
    attempt: int | None = None
    error_code: str | None = None
    error_message: str | None = None
    # Additive: old iOS clients ignore this and keep reading error_message.
    error_context: dict | None = None
    violations: list[dict] | None = None
    chapter: ChapterRead | None = None
    updated_character_ids: list[str] | None = None
    added_event_ids: list[str] | None = None
    memory_context: dict | None = None
    checker_result: dict | None = None
    # The Checker result that belongs to the currently visible chapter text.
    # Rejected candidate text and metadata remain backend-only.
    visible_checker_result: dict | None = None
