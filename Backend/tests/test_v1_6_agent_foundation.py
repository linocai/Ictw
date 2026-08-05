from __future__ import annotations

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.agents.checker import CHECKER_SCHEMA, CheckerAgent
from app.agents.memory_selector import MemorySelectorAgent
from app.agents.writer import WriterAgent
from app.db import Base, make_engine
from app.llm.factory import get_checker_client
from app.models import AgentModelBinding, AgentPersona
from app.services.personas import (
    AGENT_ROLES,
    DEFAULT_PERSONAS,
    LEGACY_EXTRACTOR_PERSONAS,
    PROGRAM_PROTOCOLS,
    seed_defaults,
)


class RecordingJSONLLM:
    def __init__(self) -> None:
        self.system = ""
        self.schema: dict = {}

    def complete_json(self, *, system: str, schema: dict, **_kwargs):
        self.system = system
        self.schema = schema
        if "previous_ending_start_id" in schema.get("properties", {}):
            return {"briefs": [], "conflicts": [], "previous_ending_start_id": None}
        return {"verdict": "passed", "issues": []}


class RecordingStreamLLM:
    def __init__(self) -> None:
        self.system = ""

    def complete_stream(self, *, system: str, **_kwargs):
        self.system = system
        yield "正文"


def test_checker_foundation_uses_its_fixed_protocol() -> None:
    llm = RecordingJSONLLM()
    result = CheckerAgent(llm, "可编辑人格").check("Bible 与正文")
    assert result == {"verdict": "passed", "issues": []}
    assert llm.schema == CHECKER_SCHEMA
    assert llm.system == f"可编辑人格\n\n{PROGRAM_PROTOCOLS['checker']}"


def test_selector_and_writer_append_program_protocols_at_runtime() -> None:
    selector_llm = RecordingJSONLLM()
    MemorySelectorAgent(selector_llm, "可编辑 Selector 人格").select("候选记忆")
    assert selector_llm.system.startswith("可编辑 Selector 人格\n\n")
    assert PROGRAM_PROTOCOLS["memory_selector"] in selector_llm.system
    assert "允许压缩和合并候选历史" in selector_llm.system

    writer_llm = RecordingStreamLLM()
    list(WriterAgent(writer_llm, "可编辑 Writer 人格").stream("Bible"))
    assert writer_llm.system == f"可编辑 Writer 人格\n\n{PROGRAM_PROTOCOLS['writer']}"


def test_settings_exposes_four_active_roles_and_protects_protocol(client: TestClient, auth_headers: dict[str, str]) -> None:
    response = client.get("/api/v1/agent-personas", headers=auth_headers)
    assert response.status_code == 200
    personas = response.json()
    assert [item["agent_role"] for item in personas] == list(AGENT_ROLES)
    for item in personas:
        assert item["editable_persona"] == item["system_prompt"]
        assert item["default_persona"] == DEFAULT_PERSONAS[item["agent_role"]]
        assert item["program_protocol"] == PROGRAM_PROTOCOLS[item["agent_role"]]

    changed = client.patch(
        "/api/v1/agent-personas/writer",
        headers=auth_headers,
        json={"editable_persona": "我的自定义 Writer 人格"},
    )
    assert changed.status_code == 200
    assert changed.json()["editable_persona"] == "我的自定义 Writer 人格"
    assert changed.json()["program_protocol"] == PROGRAM_PROTOCOLS["writer"]

    forbidden = client.patch(
        "/api/v1/agent-personas/writer",
        headers=auth_headers,
        json={"editable_persona": "x", "program_protocol": "试图覆盖"},
    )
    assert forbidden.status_code == 422

    reset = client.post("/api/v1/agent-personas/writer/reset", headers=auth_headers)
    assert reset.status_code == 200
    assert reset.json()["editable_persona"] == DEFAULT_PERSONAS["writer"]


def test_settings_rejects_retired_reviser_everywhere(client: TestClient, auth_headers: dict[str, str]) -> None:
    assert client.patch(
        "/api/v1/agent-personas/reviser", headers=auth_headers, json={"editable_persona": "x"}
    ).status_code == 404
    assert client.post("/api/v1/agent-personas/reviser/reset", headers=auth_headers).status_code == 404
    assert client.patch(
        "/api/v1/agent-model-bindings/reviser", headers=auth_headers, json={}
    ).status_code == 404
    bindings = client.get("/api/v1/agent-model-bindings", headers=auth_headers)
    assert bindings.status_code == 200
    assert [item["agent_role"] for item in bindings.json()] == list(AGENT_ROLES)


def test_checker_factory_is_available() -> None:
    assert callable(get_checker_client)


def test_seed_defaults_migrates_only_exact_legacy_extractor_settings(tmp_path) -> None:
    engine = make_engine(f"sqlite:///{tmp_path / 'personas.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        db.add(AgentPersona(
            agent_role="extractor",
            system_prompt=next(iter(LEGACY_EXTRACTOR_PERSONAS)),
        ))
        db.add(AgentModelBinding(agent_role="extractor", temperature=0.3))
        db.commit()

        seed_defaults(db)
        assert db.get(AgentPersona, "extractor").system_prompt == DEFAULT_PERSONAS["extractor"]
        assert db.get(AgentModelBinding, "extractor").temperature == 0.1

        db.get(AgentPersona, "extractor").system_prompt = "用户自己的 Extractor 人格"
        db.get(AgentModelBinding, "extractor").temperature = 0.3
        db.commit()
        seed_defaults(db)
        assert db.get(AgentPersona, "extractor").system_prompt == "用户自己的 Extractor 人格"
        assert db.get(AgentModelBinding, "extractor").temperature == 0.3
