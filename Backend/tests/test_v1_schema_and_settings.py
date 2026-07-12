from __future__ import annotations

import sqlite3

import pytest
from alembic import command
from alembic.config import Config
from fastapi import HTTPException
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import Base, make_engine
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models import AgentModelBinding, LLMProfile
from app.routers.settings import _sanitize_profile_bindings, patch_binding, patch_profile
from app.schemas.settings import AgentModelBindingPatch, LLMProfilePatch
from app.services.model_capabilities import resolve_capabilities


def test_registered_model_capabilities_are_explicit() -> None:
    deepseek = resolve_capabilities("DeepSeek-V4-Pro")
    assert deepseek.family == "deepseek_v4"
    assert deepseek.reasoning_effort_levels == ("high", "max")
    assert deepseek.thinking_can_disable is True

    for model_name in ("glm-5", "GLM_5.0", "glm 5.1", "glm-5.2"):
        glm = resolve_capabilities(model_name)
        assert glm.family == "glm_5"
        assert glm.thinking_can_disable is True
        assert glm.reasoning_effort_levels == ("high", "max")
        assert glm.temperature_effective_when_thinking is True

    gemini = resolve_capabilities("gemini-3.5-flash")
    assert gemini.family == "gemini_3_5_flash"
    assert gemini.thinking_required is True
    assert gemini.reasoning_effort_levels == ("minimal", "low", "medium", "high")

    unknown = resolve_capabilities("deepseek-chat")
    assert unknown.family == "unknown"
    assert unknown.thinking_toggle_supported is False


def test_binding_patch_distinguishes_omitted_and_null_and_clears_effort(tmp_path) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'settings.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        profile = LLMProfile(
            id="profile",
            name="DeepSeek",
            provider="openai-compatible",
            base_url="https://api.deepseek.example",
            api_key_encrypted="unused",
            model_name="deepseek-v4-pro",
        )
        binding = AgentModelBinding(
            agent_role="writer",
            llm_profile_id=profile.id,
            thinking_enabled=True,
            reasoning_effort="high",
        )
        db.add(profile)
        db.commit()
        db.add(binding)
        db.commit()

        response = patch_binding("writer", AgentModelBindingPatch(thinking_enabled=False), db)
        assert response["thinking_enabled"] is False
        assert response["reasoning_effort"] is None

        response = patch_binding("writer", AgentModelBindingPatch(llm_profile_id=None), db)
        assert response["llm_profile_id"] is None
        assert response["thinking_enabled"] is None


def test_unknown_model_rejects_non_null_thinking_configuration(tmp_path) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'unknown.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        profile = LLMProfile(
            id="profile",
            name="Unknown",
            provider="openai-compatible",
            base_url="https://example.invalid",
            api_key_encrypted="unused",
            model_name="vendor-model",
        )
        db.add(profile)
        db.commit()
        db.add(AgentModelBinding(agent_role="writer", llm_profile_id=profile.id))
        db.commit()
        with pytest.raises(HTTPException) as exc:
            patch_binding("writer", AgentModelBindingPatch(thinking_enabled=True), db)
        assert exc.value.status_code == 422


def test_model_name_change_clears_incompatible_binding_settings(tmp_path) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'profile-change.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        profile = LLMProfile(
            id="profile",
            name="DeepSeek",
            provider="openai-compatible",
            base_url="https://api.deepseek.example",
            api_key_encrypted="unused",
            model_name="deepseek-v4-pro",
        )
        db.add(profile)
        db.commit()
        db.add(
            AgentModelBinding(
                agent_role="writer",
                llm_profile_id=profile.id,
                thinking_enabled=True,
                reasoning_effort="max",
            )
        )
        db.commit()
        patch_profile(profile.id, LLMProfilePatch(model_name="vendor-model"), db)
        binding = db.get(AgentModelBinding, "writer")
        assert binding.thinking_enabled is None
        assert binding.reasoning_effort is None


def test_sqlite_connections_enable_foreign_keys(tmp_path) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'fk.db'}")
    with engine.connect() as connection:
        assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar_one() == 1


def test_profile_delete_sets_agent_binding_to_null(tmp_path) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'set-null.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        profile = LLMProfile(
            id="profile",
            name="Profile",
            provider="openai-compatible",
            base_url="https://example.invalid",
            api_key_encrypted="unused",
            model_name="unknown",
        )
        db.add(profile)
        db.commit()
        db.add(AgentModelBinding(agent_role="writer", llm_profile_id=profile.id))
        db.commit()
        db.delete(profile)
        db.commit()
        db.expire_all()
        assert db.get(AgentModelBinding, "writer").llm_profile_id is None


def test_v1_migration_preserves_notes_bindings_and_child_rows(tmp_path, monkeypatch) -> None:
    database_path = tmp_path / "migration.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("DATABASE_URL", database_url)
    get_settings.cache_clear()
    config = Config("alembic.ini")
    command.upgrade(config, "20260709_0001")

    connection = sqlite3.connect(database_path)
    try:
        connection.executescript(
            """
            PRAGMA foreign_keys=ON;
            INSERT INTO books VALUES('b','书','世界','2026-01-01','2026-01-01',NULL);
            INSERT INTO chapters VALUES(
                'c','b',1,'章','Bible',3000,'旧备注','正文','','','draft','agent','2026-01-01','2026-01-01'
            );
            INSERT INTO characters VALUES(
                'p','b','林夕','主角','设定','{}','2026-01-01','2026-01-01'
            );
            INSERT INTO chapter_characters VALUES('cc','c','p','脚伤恢复中');
            INSERT INTO character_events VALUES(
                'e','b','p','c','story','发生事件','2026-01-01','2026-01-01'
            );
            INSERT INTO llm_profiles VALUES(
                'lp','模型','openai-compatible','https://api.example','secret','deepseek-v4-pro',
                '2026-01-01','2026-01-01'
            );
            INSERT INTO agent_personas VALUES('writer','writer persona','2026-01-01');
            INSERT INTO agent_personas VALUES('compressor','custom compressor','2026-01-01');
            INSERT INTO agent_model_bindings VALUES('writer','lp','2026-01-01');
            INSERT INTO agent_model_bindings VALUES('compressor','lp','2026-01-01');
            """
        )
        connection.commit()
    finally:
        connection.close()

    command.upgrade(config, "head")
    engine = make_engine(database_url)
    with engine.connect() as migrated:
        author_note = migrated.execute(text("SELECT author_note FROM chapters WHERE id='c'"))
        note = author_note.scalar_one()
        assert "旧备注" in note
        assert "## 旧版人物本章备注" in note
        assert "林夕：脚伤恢复中" in note
        assert migrated.execute(text("SELECT count(*) FROM chapter_characters")).scalar_one() == 1
        assert migrated.execute(text("SELECT count(*) FROM character_events")).scalar_one() == 1
        assert migrated.execute(
            text("SELECT system_prompt FROM agent_personas WHERE agent_role='reviser'")
        ).scalar_one() == "custom compressor"
        assert migrated.execute(
            text("SELECT llm_profile_id FROM agent_model_bindings WHERE agent_role='memory_selector'")
        ).scalar_one() == "lp"
        assert migrated.exec_driver_sql("PRAGMA foreign_key_check").fetchall() == []
    get_settings.cache_clear()


def _binding_db(tmp_path, model_name: str, **binding_kwargs):
    engine = make_engine(f"sqlite:///{tmp_path / f'temp-{model_name}.db'}")
    Base.metadata.create_all(engine)
    db = Session(engine)
    profile = LLMProfile(
        id="profile",
        name="P",
        provider="openai-compatible",
        base_url="https://api.example",
        api_key_encrypted="unused",
        model_name=model_name,
    )
    db.add(profile)
    db.commit()
    db.add(AgentModelBinding(agent_role="writer", llm_profile_id="profile", **binding_kwargs))
    db.commit()
    return db


def test_temperature_adjustable_and_persisted_when_thinking_off(tmp_path) -> None:
    with _binding_db(tmp_path, "deepseek-v4-pro", thinking_enabled=False) as db:
        response = patch_binding("writer", AgentModelBindingPatch(temperature=1.3), db)
        assert response["temperature"] == 1.3
        assert response["effective_temperature"] == 1.3
        assert response["temperature_adjustable"] is True


def test_temperature_rejected_while_thinking_on_and_cleared_by_enabling(tmp_path) -> None:
    with _binding_db(tmp_path, "deepseek-v4-pro", thinking_enabled=True) as db:
        with pytest.raises(HTTPException) as blocked:
            patch_binding("writer", AgentModelBindingPatch(temperature=0.9), db)
        assert blocked.value.status_code == 422

        patch_binding("writer", AgentModelBindingPatch(thinking_enabled=False), db)
        patch_binding("writer", AgentModelBindingPatch(temperature=0.9), db)
        # Turning thinking back on clears the stored temperature.
        response = patch_binding("writer", AgentModelBindingPatch(thinking_enabled=True), db)
        assert response["temperature"] is None
        assert response["temperature_adjustable"] is False


def test_temperature_rejected_for_locked_thinking_and_out_of_range(tmp_path) -> None:
    with _binding_db(tmp_path, "gemini-3.5-flash") as db:
        with pytest.raises(HTTPException) as blocked:
            patch_binding("writer", AgentModelBindingPatch(temperature=0.7), db)
        assert blocked.value.status_code == 422
        assert db.get(AgentModelBinding, "writer").temperature is None
    with _binding_db(tmp_path, "custom-model") as db:
        with pytest.raises(HTTPException) as out_of_range:
            patch_binding("writer", AgentModelBindingPatch(temperature=2.5), db)
        assert out_of_range.value.status_code == 422
        response = patch_binding("writer", AgentModelBindingPatch(temperature=0.4), db)
        assert response["temperature"] == 0.4
        assert response["temperature_adjustable"] is True


def test_temperature_override_reaches_payload_only_when_sendable() -> None:
    deepseek_off = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="deepseek-v4-pro",
        thinking_enabled=False,
        temperature_override=1.1,
        capability_family="deepseek_v4",
    )
    assert deepseek_off._payload(system="s", user="u", stream=False, temperature=0.7)["temperature"] == 1.1

    deepseek_on = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="deepseek-v4-pro",
        thinking_enabled=True,
        temperature_override=1.1,
        capability_family="deepseek_v4",
    )
    assert "temperature" not in deepseek_on._payload(system="s", user="u", stream=False, temperature=0.7)

    gemini = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="gemini-3.5-flash",
        temperature_override=1.1,
        capability_family="gemini_3_5_flash",
    )
    assert "temperature" not in gemini._payload(system="s", user="u", stream=False, temperature=0.7)

    unknown = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="custom",
        temperature_override=0.3,
        capability_family="unknown",
    )
    assert unknown._payload(system="s", user="u", stream=False, temperature=0.7)["temperature"] == 0.3


def test_glm_thinking_effort_and_temperature_reach_payload(tmp_path) -> None:
    with _binding_db(
        tmp_path,
        "glm-5.2",
        thinking_enabled=True,
        reasoning_effort="high",
        temperature=0.9,
    ) as db:
        response = patch_binding("writer", AgentModelBindingPatch(), db)
        assert response["effective_thinking_enabled"] is True
        assert response["effective_reasoning_effort"] == "high"
        assert response["effective_temperature"] == 0.9

    enabled = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="glm-5.2",
        thinking_enabled=True,
        reasoning_effort="high",
        temperature_override=0.9,
        capability_family="glm_5",
    )
    payload = enabled._payload(system="s", user="u", stream=False)
    assert payload["thinking"] == {"type": "enabled"}
    assert payload["reasoning_effort"] == "high"
    assert payload["temperature"] == 0.9


def test_glm_unset_binding_reports_and_sends_effective_default_on(tmp_path) -> None:
    with _binding_db(tmp_path, "glm-5.2", temperature=0.9) as db:
        response = patch_binding("writer", AgentModelBindingPatch(), db)
        assert response["thinking_enabled"] is None
        assert response["effective_thinking_enabled"] is True
        assert response["temperature"] == 0.9

        response = patch_binding("writer", AgentModelBindingPatch(thinking_enabled=False), db)
        assert response["thinking_enabled"] is False
        assert response["effective_thinking_enabled"] is False
        assert response["effective_temperature"] == 0.9

    disabled = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="glm-5.2",
        thinking_enabled=False,
        temperature_override=0.9,
        capability_family="glm_5",
    )
    payload = disabled._payload(system="s", user="u", stream=False)
    assert payload["thinking"] == {"type": "disabled"}
    assert "reasoning_effort" not in payload
    assert payload["temperature"] == 0.9


def test_model_change_to_gemini_clears_temperature(tmp_path) -> None:
    with _binding_db(tmp_path, "deepseek-v4-pro", thinking_enabled=False, temperature=1.2) as db:
        profile = db.get(LLMProfile, "profile")
        profile.model_name = "gemini-3.5-flash"
        _sanitize_profile_bindings(db, profile)
        db.commit()
        assert db.get(AgentModelBinding, "writer").temperature is None
