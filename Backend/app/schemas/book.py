from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel

from app.schemas.common import ORMModel


class BookCreate(BaseModel):
    title: str
    world_setting: str = ""


class BookPatch(BaseModel):
    title: str | None = None
    world_setting: str | None = None


class BookRead(ORMModel):
    id: str
    title: str
    world_setting: str
    created_at: datetime
    updated_at: datetime
    last_opened_at: datetime | None
    content_revision: int = 1
    chapter_count: int = 0
    character_count: int = 0
    # Count-only archive health lets chapter rails render book-level attention
    # without fetching every chapter detail.
    archive_pending_count: int = 0
    archive_attention_count: int = 0


class ProjectImportWarning(BaseModel):
    code: str
    message: str


class ProjectImportRead(BaseModel):
    book_id: str
    title: str
    warnings: list[ProjectImportWarning] = []


class BookExportChapterRead(BaseModel):
    id: str
    index: int
    title: str
    draft_text: str
    status: str


class BookExportCharacterRead(BaseModel):
    id: str
    name: str
    role: str
    fixed_profile: str


class BookExportDataRead(BaseModel):
    book_id: str
    title: str
    world_setting: str
    chapters: list[BookExportChapterRead]
    characters: list[BookExportCharacterRead]
