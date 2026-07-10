from __future__ import annotations

from collections.abc import Iterator

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import get_settings


class Base(DeclarativeBase):
    pass


def _connect_args(url: str) -> dict[str, object]:
    if url.startswith("sqlite"):
        return {"check_same_thread": False}
    return {}


def make_engine(url: str | None = None):
    database_url = url or get_settings().database_url
    database_engine = create_engine(database_url, connect_args=_connect_args(database_url), future=True)
    if database_url.startswith("sqlite"):
        event.listen(database_engine, "connect", _enable_sqlite_foreign_keys)
    return database_engine


def _enable_sqlite_foreign_keys(dbapi_connection, _connection_record) -> None:
    cursor = dbapi_connection.cursor()
    try:
        cursor.execute("PRAGMA foreign_keys=ON")
    finally:
        cursor.close()


engine = make_engine()
SessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db() -> None:
    # Schema changes are owned by Alembic. Importing the models here keeps mapper
    # configuration deterministic without silently mutating a production database.
    import app.models  # noqa: F401
