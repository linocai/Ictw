from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, Field, model_validator

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
    summary: str | None = None
    headline: str | None = None
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
    summary: str
    headline: str
    exempted_character_names: list[str] = Field(default_factory=list)
    status: str
    source: str
    created_at: datetime
    updated_at: datetime
    character_links: list[ChapterCharacterLink] = Field(default_factory=list)


class WriteRequest(BaseModel):
    replace_draft: bool = False


class WriteJobStatus(BaseModel):
    chapter_id: str
    kind: str
    phase: str
    attempt: int | None = None
    error_code: str | None = None
    error_message: str | None = None
    violations: list[dict] | None = None
    chapter: ChapterRead | None = None
    updated_character_ids: list[str] | None = None
    added_event_ids: list[str] | None = None
