from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class Message(BaseModel):
    message: str


class DynamicFieldPatch(BaseModel):
    character_id: str
    fields: dict[str, Any] = Field(default_factory=dict)
