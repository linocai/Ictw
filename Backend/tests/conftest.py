from __future__ import annotations

import os
import tempfile
from collections.abc import Iterator
from threading import Event

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("APP_TOKEN", "test-token-123456")
os.environ.setdefault("KEK_SECRET", "test-kek-secret-123456")

from app.config import get_settings
from app.db import Base, get_db, make_engine
from app.llm.factory import (
    get_compressor_client,
    get_extractor_client,
    get_memory_selector_client,
    get_reviser_client,
    get_writer_client,
)
from app.main import create_app
from app.models import AgentModelBinding, AgentPersona
from app.services.personas import DEFAULT_PERSONAS
from app.services.write_jobs import write_registry
from sqlalchemy.orm import Session, sessionmaker


class FakeWriter:
    def __init__(self, text: str = "短句。" * 20) -> None:
        self.text = text

    def complete_stream(self, *, system: str, user: str, cancel_event: Event | None = None, **kwargs):
        for ch in self.text:
            if cancel_event is not None and cancel_event.is_set():
                break
            yield ch

    def complete(self, **kwargs):
        return self.text

    def complete_json(self, **kwargs):
        return {}


class FakeCompressor:
    def complete(self, *, system: str, user: str, **kwargs):
        return "压缩后正文"

    def complete_stream(self, **kwargs):
        yield "压"

    def complete_json(self, **kwargs):
        return {"memory_ids": []}


class FakeExtractor:
    def __init__(self, fail: bool = False) -> None:
        self.fail = fail

    def complete_json(self, *, system: str, user: str, schema: dict, **kwargs):
        if self.fail:
            raise RuntimeError("extract failed")
        return {
            "summary": "本章完成了关键行动。",
            "headline": "主角完成关键行动。",
            "character_events": [
                {"character_id": pytest.character_id, "event_type": "story", "event_text": "完成关键行动。"}
            ],
            "dynamic_fields_patch": [
                {"character_id": pytest.character_id, "fields": {"current_status": "完成关键行动后休整"}}
            ],
        }

    def complete(self, **kwargs):
        return ""

    def complete_stream(self, **kwargs):
        yield ""


@pytest.fixture()
def client() -> Iterator[TestClient]:
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    url = f"sqlite:///{path}"
    get_settings.cache_clear()
    os.environ["DATABASE_URL"] = url

    import app.db as db_module
    import app.routers.chapters as chapters_router

    engine = make_engine(url)
    TestingSessionLocal = sessionmaker(bind=engine, autocommit=False, autoflush=False, expire_on_commit=False)
    db_module.engine = engine
    db_module.SessionLocal = TestingSessionLocal
    chapters_router.SessionLocal = TestingSessionLocal
    Base.metadata.create_all(bind=engine)

    db = TestingSessionLocal()
    for role, prompt in DEFAULT_PERSONAS.items():
        db.add(AgentPersona(agent_role=role, system_prompt=prompt))
        db.add(AgentModelBinding(agent_role=role, llm_profile_id=None))
    db.commit()
    db.close()
    write_registry.clear()

    app = create_app()

    def override_db():
        session = TestingSessionLocal()
        try:
            yield session
        finally:
            session.close()

    app.dependency_overrides[get_db] = override_db
    app.dependency_overrides[get_writer_client] = lambda: FakeWriter()
    app.dependency_overrides[get_compressor_client] = lambda: FakeCompressor()
    app.dependency_overrides[get_reviser_client] = lambda: FakeCompressor()
    app.dependency_overrides[get_memory_selector_client] = lambda: FakeCompressor()
    app.dependency_overrides[get_extractor_client] = lambda: FakeExtractor()
    with TestClient(app) as test_client:
        yield test_client
    os.remove(path)


@pytest.fixture()
def auth_headers() -> dict[str, str]:
    return {"Authorization": "Bearer test-token-123456"}


@pytest.fixture()
def wait_for_terminal():
    import time

    def _wait(client: TestClient, chapter_id: str, headers: dict[str, str], timeout: float = 15.0) -> dict:
        deadline = time.time() + timeout
        last: dict = {}
        while time.time() < deadline:
            last = client.get(f"/api/v1/chapters/{chapter_id}/job", headers=headers).json()
            if last.get("phase") in ("done", "failed", "cancelled"):
                return last
            time.sleep(0.05)
        raise AssertionError(f"job never reached a terminal phase: {last}")

    return _wait
