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
from app.llm.factory import LLMConfigurationError, build_llm_client
from app.models import AgentModelBinding, LLMProfile
from app.routers.settings import _sanitize_profile_bindings, patch_binding, patch_profile
from app.schemas.settings import AgentModelBindingPatch, LLMProfilePatch
from app.services.model_capabilities import resolve_capabilities
from app.services.personas import DEFAULT_PERSONAS


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


@pytest.mark.parametrize(
    ("agent_role", "profile_id", "expected_code"),
    [
        ("writer", None, "llm_profile_not_configured"),
        ("checker", "missing-profile", "llm_profile_missing"),
    ],
)
def test_llm_configuration_errors_have_fixed_safe_codes(tmp_path, agent_role, profile_id, expected_code) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'config-errors.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        binding = AgentModelBinding(agent_role=agent_role, llm_profile_id=None)
        db.add(binding)
        db.commit()
        binding.llm_profile_id = profile_id
        with db.no_autoflush:
            with pytest.raises(LLMConfigurationError) as caught:
                build_llm_client(db, agent_role)
    assert caught.value.code == expected_code
    assert caught.value.agent_role == agent_role
    assert "missing-profile" not in caught.value.message


@pytest.mark.parametrize("agent_role", ["extractor", "inspiration_creator"])
def test_bounded_agent_incompatible_capability_is_safe_configuration_error(tmp_path, agent_role) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'extractor-config-error.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        profile = LLMProfile(
            id="profile",
            name="P",
            provider="openai-compatible",
            base_url="https://api.example",
            api_key_encrypted="encrypted",
            model_name="unknown-model",
        )
        db.add(profile)
        db.commit()
        db.add(AgentModelBinding(agent_role=agent_role, llm_profile_id=profile.id))
        db.commit()
        with pytest.raises(LLMConfigurationError) as caught:
            build_llm_client(db, agent_role)
    assert caught.value.code == f"{agent_role}_thinking_not_disableable"
    assert caught.value.agent_role == agent_role


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


@pytest.mark.parametrize("agent_role", ["extractor", "inspiration_creator"])
def test_bounded_agent_binding_reports_and_persists_forced_thinking_off(tmp_path, agent_role) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'extractor-policy.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        profile = LLMProfile(
            id="profile",
            name="DeepSeek",
            provider="openai-compatible",
            base_url="https://api.deepseek.example",
            api_key_encrypted="unused",
            model_name="deepseek-v4-flash",
        )
        db.add(profile)
        db.commit()
        db.add(
            AgentModelBinding(
                agent_role=agent_role,
                llm_profile_id=profile.id,
                thinking_enabled=True,
                reasoning_effort="high",
            )
        )
        db.commit()

        response = patch_binding(agent_role, AgentModelBindingPatch(), db)
        assert response["thinking_enabled"] is False
        assert response["reasoning_effort"] is None
        assert response["effective_thinking_enabled"] is False
        binding = db.get(AgentModelBinding, agent_role)
        assert binding.thinking_enabled is False
        assert binding.reasoning_effort is None

        with pytest.raises(HTTPException) as blocked:
            patch_binding(agent_role, AgentModelBindingPatch(thinking_enabled=True), db)
        assert blocked.value.status_code == 422


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


def test_v1_6_migration_preserves_notes_custom_persona_and_child_rows(tmp_path, monkeypatch) -> None:
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
                'c','b',1,'章','Bible',3000,'旧备注','正文','旧版梗概','','draft','agent','2026-01-01','2026-01-01'
            );
            INSERT INTO chapters VALUES(
                'c2','b',2,'章二','Bible',3000,'','正文二','不应覆盖的旧梗概','','draft','agent','2026-01-01','2026-01-01'
            );
            INSERT INTO chapters VALUES(
                'c3','b',3,'章三','Bible',3000,'','正文三','空白摘要应回填','','draft','agent','2026-01-01','2026-01-01'
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

    command.upgrade(config, "20260801_0007")
    connection = sqlite3.connect(database_path)
    try:
        connection.execute("UPDATE chapters SET long_summary='已经存在的新摘要' WHERE id='c2'")
        connection.execute("UPDATE chapters SET long_summary='\n\t ' WHERE id='c3'")
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
            text("SELECT count(*) FROM agent_personas WHERE agent_role IN ('reviser', 'compressor')")
        ).scalar_one() == 0
        assert migrated.execute(
            text("SELECT system_prompt FROM agent_personas WHERE agent_role='writer'")
        ).scalar_one() == "writer persona"
        assert migrated.execute(
            text("SELECT system_prompt FROM agent_personas WHERE agent_role='memory_selector'")
        ).scalar_one() == DEFAULT_PERSONAS["memory_selector"]
        assert migrated.execute(
            text("SELECT llm_profile_id FROM agent_model_bindings WHERE agent_role='memory_selector'")
        ).scalar_one() == "lp"
        assert migrated.execute(
            text("SELECT llm_profile_id FROM agent_model_bindings WHERE agent_role='checker'")
        ).scalar_one() == "lp"
        assert migrated.execute(text("SELECT count(*) FROM chapter_draft_candidates")).scalar_one() == 0
        columns = {row[1] for row in migrated.exec_driver_sql("PRAGMA table_info(job_runs)").fetchall()}
        assert {"memory_context", "checker_result", "bible_sha256", "draft_fingerprint"} <= columns
        chapter_columns = {row[1] for row in migrated.exec_driver_sql("PRAGMA table_info(chapters)").fetchall()}
        assert {"long_summary", "state_changes", "unresolved_items", "atomic_memories"} <= chapter_columns
        assert "summary" not in chapter_columns
        assert migrated.execute(text("SELECT long_summary FROM chapters WHERE id='c'")).scalar_one() == "旧版梗概"
        assert migrated.execute(text("SELECT long_summary FROM chapters WHERE id='c2'")).scalar_one() == "已经存在的新摘要"
        assert migrated.execute(text("SELECT long_summary FROM chapters WHERE id='c3'")).scalar_one() == "空白摘要应回填"
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
    assert deepseek_off._payload(system="s", user="u", stream=False, temperature=0.7)["top_p"] == 0.95

    deepseek_on = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="deepseek-v4-pro",
        thinking_enabled=True,
        temperature_override=1.1,
        capability_family="deepseek_v4",
    )
    assert "temperature" not in deepseek_on._payload(system="s", user="u", stream=False, temperature=0.7)
    assert "top_p" not in deepseek_on._payload(system="s", user="u", stream=False, temperature=0.7)

    gemini = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="gemini-3.5-flash",
        temperature_override=1.1,
        capability_family="gemini_3_5_flash",
    )
    assert "temperature" not in gemini._payload(system="s", user="u", stream=False, temperature=0.7)
    assert "top_p" not in gemini._payload(system="s", user="u", stream=False, temperature=0.7)

    unknown = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="custom",
        temperature_override=0.3,
        capability_family="unknown",
    )
    assert unknown._payload(system="s", user="u", stream=False, temperature=0.7)["temperature"] == 0.3
    assert unknown._payload(system="s", user="u", stream=False, temperature=0.7)["top_p"] == 0.95


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
    assert "top_p" not in payload


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


def test_deepseek_unset_binding_reports_default_on_then_persists_explicit_off(tmp_path) -> None:
    with _binding_db(tmp_path, "deepseek-v4-pro", temperature=0.3) as db:
        response = patch_binding("writer", AgentModelBindingPatch(), db)
        assert response["thinking_enabled"] is None
        assert response["effective_thinking_enabled"] is True
        assert response["effective_temperature"] is None
        assert response["temperature_adjustable"] is False

        response = patch_binding("writer", AgentModelBindingPatch(thinking_enabled=False), db)
        assert response["thinking_enabled"] is False
        assert response["effective_thinking_enabled"] is False
        assert response["effective_temperature"] == 0.3
        assert response["temperature_adjustable"] is True

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
    assert payload["top_p"] == 0.95


def test_model_change_to_gemini_clears_temperature(tmp_path) -> None:
    with _binding_db(tmp_path, "deepseek-v4-pro", thinking_enabled=False, temperature=1.2) as db:
        profile = db.get(LLMProfile, "profile")
        profile.model_name = "gemini-3.5-flash"
        _sanitize_profile_bindings(db, profile)
        db.commit()
        assert db.get(AgentModelBinding, "writer").temperature is None


def test_profile_never_returns_the_api_key(client, auth_headers) -> None:
    created = client.post(
        "/api/v1/llm_profiles",
        headers=auth_headers,
        json={
            "name": "p",
            "base_url": "https://api.example.com/v1",
            "api_key": "sk-should-never-come-back",
            "model_name": "glm-5",
        },
    )
    assert created.status_code == 201
    assert "api_key" not in created.json()
    listed = client.get("/api/v1/llm_profiles", headers=auth_headers)
    assert "should-never-come-back" not in listed.text


def test_profile_rejects_non_http_and_hostless_base_urls(client, auth_headers) -> None:
    for base_url in ("", "file:///etc/passwd", "ftp://example.com", "https://", "not-a-url"):
        response = client.post(
            "/api/v1/llm_profiles",
            headers=auth_headers,
            json={"name": "p", "base_url": base_url, "api_key": "k", "model_name": "glm-5"},
        )
        assert response.status_code == 422, base_url


def test_retargeting_base_url_requires_re_entering_the_api_key(client, auth_headers) -> None:
    # The stored key is sent to whatever base_url names, so moving a profile to
    # another host must not carry the existing credential along.
    profile = client.post(
        "/api/v1/llm_profiles",
        headers=auth_headers,
        json={
            "name": "p",
            "base_url": "https://api.example.com/v1",
            "api_key": "sk-original",
            "model_name": "glm-5",
        },
    ).json()

    moved = client.patch(
        f"/api/v1/llm_profiles/{profile['id']}",
        headers=auth_headers,
        json={"base_url": "https://elsewhere.example.net/v1"},
    )
    assert moved.status_code == 422
    assert moved.json()["detail"]["code"] == "api_key_required_for_new_base_url"

    unchanged = client.get("/api/v1/llm_profiles", headers=auth_headers).json()[0]
    assert unchanged["base_url"] == "https://api.example.com/v1"

    with_key = client.patch(
        f"/api/v1/llm_profiles/{profile['id']}",
        headers=auth_headers,
        json={"base_url": "https://elsewhere.example.net/v1", "api_key": "sk-new"},
    )
    assert with_key.status_code == 200


def test_patching_a_profile_with_explicit_null_is_rejected_not_crashed(client, auth_headers) -> None:
    profile = client.post(
        "/api/v1/llm_profiles",
        headers=auth_headers,
        json={
            "name": "p",
            "base_url": "https://api.example.com/v1",
            "api_key": "k",
            "model_name": "glm-5",
        },
    ).json()
    for field in ("name", "base_url", "model_name"):
        response = client.patch(
            f"/api/v1/llm_profiles/{profile['id']}", headers=auth_headers, json={field: None}
        )
        assert response.status_code < 500, field


def test_patching_a_book_with_explicit_null_is_rejected_not_crashed(client, auth_headers) -> None:
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    for field in ("title", "world_setting"):
        response = client.patch(
            f"/api/v1/books/{book['id']}", headers=auth_headers, json={field: None}
        )
        assert response.status_code < 500, field


def test_undecryptable_api_key_surfaces_as_configuration_error(client, auth_headers) -> None:
    # KEK rotation and restoring a production database onto another host both
    # land here; a bare 500 with an empty message is not diagnosable.
    import app.db as db_module

    profile = client.post(
        "/api/v1/llm_profiles",
        headers=auth_headers,
        json={
            "name": "p",
            "base_url": "https://api.example.com/v1",
            "api_key": "k",
            "model_name": "glm-5",
        },
    ).json()
    with db_module.SessionLocal() as db:
        stored = db.get(LLMProfile, profile["id"])
        stored.api_key_encrypted = "gAAAAABmnot-a-valid-fernet-token"
        db.commit()

    response = client.post(f"/api/v1/llm_profiles/{profile['id']}/test", headers=auth_headers)
    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "api_key_undecryptable"


def test_placeholder_secrets_are_refused_at_startup(monkeypatch) -> None:
    from app.config import Settings

    monkeypatch.setenv("APP_TOKEN", "change-me-to-a-long-random-token")
    monkeypatch.setenv("KEK_SECRET", "a-real-kek-secret-value")
    with pytest.raises(ValueError):
        Settings(_env_file=None)


def test_expected_alembic_head_matches_the_migration_chain() -> None:
    # health() gates deployment on this constant, so it must not drift from the
    # real head when a migration is added.
    from alembic.script import ScriptDirectory

    from app.main import EXPECTED_ALEMBIC_HEAD

    script = ScriptDirectory.from_config(Config("alembic.ini"))
    assert list(script.get_heads()) == [EXPECTED_ALEMBIC_HEAD]


def test_schema_matches_alembic_head(tmp_path, monkeypatch) -> None:
    """The ORM metadata and `alembic upgrade head` must describe one schema.

    The suite builds its database with `Base.metadata.create_all`, so a model
    change shipped without a migration would leave every test green and only
    fail in production at `alembic upgrade head`. This is the guard for that.
    """
    from sqlalchemy import inspect

    database_path = tmp_path / "schema_parity.db"
    database_url = f"sqlite:///{database_path}"
    monkeypatch.setenv("DATABASE_URL", database_url)
    get_settings.cache_clear()
    command.upgrade(Config("alembic.ini"), "head")

    migrated = make_engine(database_url)
    orm_path = tmp_path / "schema_parity_orm.db"
    orm = make_engine(f"sqlite:///{orm_path}")
    Base.metadata.create_all(bind=orm)

    migrated_inspector = inspect(migrated)
    orm_inspector = inspect(orm)

    migrated_tables = set(migrated_inspector.get_table_names()) - {"alembic_version"}
    orm_tables = set(orm_inspector.get_table_names())
    assert migrated_tables == orm_tables

    def columns(inspector, table):
        # server_default is deliberately excluded: migrations carry defaults to
        # backfill existing rows, while the ORM expresses the same values as
        # Python-side defaults. Names, types and nullability must still agree.
        return {
            column["name"]: (str(column["type"]).upper(), bool(column["nullable"]))
            for column in inspector.get_columns(table)
        }

    drift = {}
    for table in sorted(orm_tables):
        left, right = columns(migrated_inspector, table), columns(orm_inspector, table)
        if left != right:
            drift[table] = {
                "only_in_migration": sorted(set(left) - set(right)),
                "only_in_orm": sorted(set(right) - set(left)),
                "mismatched": sorted(
                    name for name in set(left) & set(right) if left[name] != right[name]
                ),
            }
    assert drift == {}

    get_settings.cache_clear()
