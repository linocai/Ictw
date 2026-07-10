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
    chapter_count: int = 0
    character_count: int = 0
