from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field

from app.schemas.common import ORMModel


class CharacterCreate(BaseModel):
    name: str
    role: str = ""
    fixed_profile: str = ""
    dynamic_fields: dict[str, Any] = Field(default_factory=dict)


class CharacterPatch(BaseModel):
    name: str | None = None
    role: str | None = None
    fixed_profile: str | None = None
    dynamic_fields: dict[str, Any] | None = None


class CharacterEventPatch(BaseModel):
    event_text: str


class CharacterImportItem(BaseModel):
    name: str
    role: str = ""
    fixed_profile: str


class CharacterImportRequest(BaseModel):
    items: list[CharacterImportItem]


class CharacterEventRead(ORMModel):
    id: str
    book_id: str
    character_id: str
    chapter_id: str
    event_type: str
    event_text: str
    created_at: datetime
    updated_at: datetime
    chapter_index: int | None = None


class CharacterRead(ORMModel):
    id: str
    book_id: str
    name: str
    role: str
    fixed_profile: str
    dynamic_fields: dict[str, Any]
    created_at: datetime
    updated_at: datetime
    events: list[CharacterEventRead] = Field(default_factory=list)
