from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# The values shipped in .env.example are long enough to satisfy min_length, and
# README tells operators to copy that file verbatim. Refuse to boot on them so
# a documented placeholder can never become a live credential.
_PLACEHOLDER_PREFIX = "change-me"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_token: str = Field(min_length=16)
    kek_secret: str = Field(min_length=16)
    database_url: str = "sqlite:///./linoi.db"
    api_prefix: str = "/api/v1"

    @field_validator("app_token", "kek_secret")
    @classmethod
    def _reject_placeholder(cls, value: str, info) -> str:
        if value.strip().lower().startswith(_PLACEHOLDER_PREFIX):
            raise ValueError(
                f"{info.field_name} is still the .env.example placeholder; generate a real secret"
            )
        return value


@lru_cache
def get_settings() -> Settings:
    return Settings()
