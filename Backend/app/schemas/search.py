from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class SearchResultRead(BaseModel):
    id: str
    book_id: str
    chapter_id: str | None = None
    character_id: str | None = None
    result_type: Literal["book", "chapter", "character", "archive"]
    title: str
    snippet: str


class SearchResponse(BaseModel):
    query: str
    total: int
    items: list[SearchResultRead] = Field(default_factory=list)
