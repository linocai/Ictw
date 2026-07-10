from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_token: str = Field(min_length=16)
    kek_secret: str = Field(min_length=16)
    database_url: str = "sqlite:///./linoi.db"
    api_prefix: str = "/api/v1"


@lru_cache
def get_settings() -> Settings:
    return Settings()
