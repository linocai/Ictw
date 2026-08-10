from __future__ import annotations

import pytest

from app.agents.extractor import (
    CHARACTER_EVENT_MAX_PER_CHARACTER,
    CHARACTER_EVENT_MAX_TOTAL,
    ExtractorAgent,
    bind_extractor_character_names,
    extractor_schema,
)
from app.llm.base import LLMError
from app.llm.factory import get_extractor_client
from app.services.character_memory_rebuild import rebuild_book_character_memory
from app.services.context import memory_candidates
from app.services.personas import PROGRAM_PROTOCOLS
from scripts.rebuild_book_character_memory import (
    load_rebuild_checkpoint,
    load_validated_bundle,
    state_rebuild_fingerprint,
    write_rebuild_checkpoint,
    write_validated_bundle,
)


class RecordingExtractor:
    def __init__(self, payload: dict) -> None:
        self.payload = payload
        self.system = ""
        self.user = ""
        self.users: list[str] = []
        self.schemas: list[dict] = []
        self.max_tokens: list[int | None] = []
        self.temperatures: list[float | None] = []
        self.schema: dict = {}
        self.calls = 0

    def complete_json(self, *, system: str, user: str, schema: dict, **_kwargs):
        self.calls += 1
        self.system, self.user, self.schema = system, user, schema
        self.users.append(user)
        self.schemas.append(schema)
        self.max_tokens.append(_kwargs.get("max_tokens"))
        self.temperatures.append(_kwargs.get("temperature"))
        return self.payload


class TruncatedThenExtractor(RecordingExtractor):
    def complete_json(self, *, system: str, user: str, schema: dict, **_kwargs):
        if self.calls == 0:
            self.calls += 1
            self.system, self.user, self.schema = system, user, schema
            self.users.append(user)
            self.schemas.append(schema)
            self.max_tokens.append(_kwargs.get("max_tokens"))
            self.temperatures.append(_kwargs.get("temperature"))
            raise LLMError(
                "LLM JSON output was truncated",
                code="llm_output_truncated",
                retryable=True,
                finish_reason="length",
            )
        return super().complete_json(system=system, user=user, schema=schema, **_kwargs)


def _archive_payload(character_name: str) -> dict:
    return {
        "headline": "关键落点。",
        "long_summary": "正文中主角在渡口交出了钥匙，并决定等候回信。",
        "state_changes": [{"text": f"{character_name}不再持有钥匙。", "kind": "possession", "character_name": character_name}],
        "unresolved_items": [{"text": "回信尚未抵达。", "kind": "pending", "character_name": None}],
        "atomic_memories": [{"text": f"{character_name}已把钥匙交给渡口守人。", "kind": "event", "character_name": character_name}],
        "character_events": [{
            "character_name": character_name,
            "event_type": "行动",
            "event_text": f"{character_name}在渡口交出钥匙。",
            "evidence": f"原文：{character_name}在渡口交出了钥匙，决定等候回信。",
        }],
        "dynamic_fields_patch": [{
            "character_name": character_name,
            "evidence": f"原文：{character_name}在渡口交出了钥匙，决定等候回信。",
            "fields": {"当前行动": "已交出钥匙"},
            "relationships": [],
        }],
    }


legacy_online_contract = pytest.mark.skip(
    reason="v1.8 replaces the v1.6 online multi-array/salvage contract with the atomic fact ledger"
)


@legacy_online_contract
def test_extractor_uses_accepted_draft_only_archives_and_recalls_new_memory(
    client, auth_headers, wait_for_terminal
):
    book = client.post(
        "/api/v1/books", headers=auth_headers, json={"title": "书", "world_setting": "世界观密语：月门"}
    ).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕", "fixed_profile": "人物卡密语"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "Bible密语：焚毁月门", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers,
        json={"draft_text": "林夕在渡口交出了钥匙，决定等候回信。"},
    ).raise_for_status()
    llm = RecordingExtractor(_archive_payload("林夕"))
    client.app.dependency_overrides[get_extractor_client] = lambda: llm

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, chapter["id"], auth_headers)
    assert result["phase"] == "done"
    assert "Bible密语" not in llm.user
    assert "月门" not in llm.user
    assert "人物卡密语" not in llm.user
    assert "最终接受正文" in llm.user

    archived = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert archived["long_summary"] == _archive_payload(character["id"])["long_summary"]
    assert archived["state_changes"][0]["character_id"] == character["id"]
    assert archived["unresolved_items"][0]["text"] == "回信尚未抵达。"

    next_chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=auth_headers, json={"user_prompt": "继续"}).json()
    from app.db import SessionLocal
    from app.models import Chapter

    db = SessionLocal()
    try:
        blocks = memory_candidates(db, db.get(Chapter, next_chapter["id"]))
    finally:
        db.close()
    recalled = {block.id: block for block in blocks}
    summary_block = recalled[f"chapter:{chapter['id']}:summary"]
    assert summary_block.memory_type == "summary"
    assert summary_block.text.endswith(_archive_payload("林夕")["long_summary"])
    assert f"chapter:{chapter['id']}:long_summary" not in recalled
    assert recalled[f"chapter:{chapter['id']}:state_change:1"].chapter_index == 1
    assert recalled[f"chapter:{chapter['id']}:unresolved_item:1"].memory_type == "unresolved_item"
    assert recalled[f"chapter:{chapter['id']}:atomic_memory:1"].character_id == character["id"]

    client.patch(
        f"/api/v1/chapters/{chapter['id']}", headers=auth_headers,
        json={"atomic_memories": [{"text": "用户更正：钥匙已沉入河底。", "kind": "event"}]},
    ).raise_for_status()
    db = SessionLocal()
    try:
        edited_blocks = memory_candidates(db, db.get(Chapter, next_chapter["id"]))
    finally:
        db.close()
    assert any(block.text.endswith("钥匙已沉入河底。") for block in edited_blocks)


@legacy_online_contract
def test_online_extractor_drops_only_invalid_event_without_another_model_call(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "交钥匙", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "林夕在渡口交出了钥匙，决定等候回信。"},
    ).raise_for_status()
    output = _archive_payload("林夕")
    output["character_events"].append({
        "character_name": "林夕",
        "event_type": "推进",
        "event_text": "林夕继续等待回信。",
        "evidence": "林夕在渡口交出了钥匙，决定等候回信。",
    })
    llm = RecordingExtractor(output)
    client.app.dependency_overrides[get_extractor_client] = lambda: llm

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, chapter["id"], auth_headers)
    assert result["phase"] == "done"
    assert result["attempt"] == 1
    assert llm.calls == 1
    assert result["error_context"] == {
        "stage": "optional_salvage",
        "completion_warning": "本章已接受；1 条人物事件未归档：人物事件类型不在固定分类中。正文、摘要及其余合格记忆已保存。",
        "dropped_event_count": 1,
        "dropped_event_reasons": ["人物事件类型不在固定分类中"],
        "dropped_state_components": 0,
        "dropped_state_reasons": [],
    }
    archived = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert archived["status"] == "finalized"
    assert archived["headline"] == output["headline"]
    assert archived["long_summary"] == output["long_summary"]
    events = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"]
    assert [event["event_text"] for event in events] == ["林夕在渡口交出钥匙。"]


@legacy_online_contract
def test_online_extractor_deduplicates_and_caps_each_character_without_retry(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "交钥匙", "character_links": [{"character_id": character["id"]}]},
    ).json()
    draft = "林夕在渡口交出了钥匙，决定留下等待回信。"
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": draft},
    ).raise_for_status()
    output = _archive_payload("林夕")
    output["character_events"] = [
        {"character_name": "林夕", "event_type": "行动", "event_text": "林夕交出钥匙。", "evidence": draft},
        {"character_name": "林夕", "event_type": "行动", "event_text": "林夕交出钥匙！", "evidence": draft},
        {"character_name": "林夕", "event_type": "决定", "event_text": "林夕决定留下。", "evidence": draft},
        {"character_name": "林夕", "event_type": "状态", "event_text": "林夕等待回信。", "evidence": draft},
        {"character_name": "林夕", "event_type": "行动", "event_text": "林夕结束当日行动。", "evidence": draft},
    ]
    llm = RecordingExtractor(output)
    client.app.dependency_overrides[get_extractor_client] = lambda: llm

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, chapter["id"], auth_headers)

    assert result["phase"] == "done"
    assert result["attempt"] == 1
    assert llm.calls == 1
    assert result["error_context"]["dropped_event_count"] == 2
    assert result["error_context"]["dropped_event_reasons"] == [
        "人物事件内容重复",
        "单个人物的事件超过每章 3 条上限",
    ]
    events = client.get(
        f"/api/v1/characters/{character['id']}", headers=auth_headers
    ).json()["events"]
    assert [event["event_text"] for event in events] == [
        "林夕交出钥匙。",
        "林夕决定留下。",
        "林夕等待回信。",
    ]


@legacy_online_contract
def test_online_extractor_caps_chapter_event_total_without_retry(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    characters = [
        client.post(
            f"/api/v1/books/{book['id']}/characters",
            headers=auth_headers,
            json={"name": name},
        ).json()
        for name in ("甲", "乙", "丙")
    ]
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={
            "user_prompt": "三人行动",
            "character_links": [{"character_id": character["id"]} for character in characters],
        },
    ).json()
    evidence = {
        name: f"{name}在渡口交出钥匙并决定留下等待回信。" for name in ("甲", "乙", "丙")
    }
    draft = "".join(evidence.values())
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": draft},
    ).raise_for_status()
    output = {
        "headline": "三人在渡口作出决定。",
        "long_summary": "甲、乙、丙先后在渡口完成关键行动。",
        "state_changes": [],
        "unresolved_items": [],
        "atomic_memories": [],
        "character_events": [
            {
                "character_name": name,
                "event_type": event_type,
                "event_text": f"{name}{label}。",
                "evidence": evidence[name],
            }
            for name in ("甲", "乙", "丙")
            for event_type, label in (("行动", "交出钥匙"), ("决定", "决定留下"), ("状态", "等待回信"))
        ],
        "state_updates": [],
    }
    llm = RecordingExtractor(output)
    client.app.dependency_overrides[get_extractor_client] = lambda: llm

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, chapter["id"], auth_headers)

    assert result["phase"] == "done"
    assert result["attempt"] == 1
    assert llm.calls == 1
    assert result["error_context"]["dropped_event_count"] == 1
    assert result["error_context"]["dropped_event_reasons"] == ["本章人物事件超过 8 条上限"]
    saved_count = sum(
        len(client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"])
        for character in characters
    )
    assert saved_count == CHARACTER_EVENT_MAX_TOTAL


@legacy_online_contract
def test_online_extractor_can_finish_when_all_character_events_lack_owner_evidence(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "开门", "character_links": [{"character_id": character["id"]}]},
    ).json()
    draft = "林夕" + "风" * 120 + "推开门。"
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": draft},
    ).raise_for_status()
    output = {
        "headline": "林夕推开门。",
        "long_summary": "林夕最终推开了门。",
        "state_changes": [],
        "unresolved_items": [],
        "atomic_memories": [],
        "character_events": [{
            "character_name": "林夕",
            "event_type": "行动",
            "event_text": "林夕推开门。",
            "evidence": "推开门。",
        }],
        "state_updates": [],
    }
    llm = RecordingExtractor(output)
    client.app.dependency_overrides[get_extractor_client] = lambda: llm

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, chapter["id"], auth_headers)
    assert result["phase"] == "done"
    assert result["attempt"] == 1
    assert llm.calls == 1
    assert result["error_context"]["dropped_event_count"] == 1
    assert result["error_context"]["dropped_event_reasons"] == [
        "人物事件的原文证据及近邻语境无法确认所属人物"
    ]
    archived = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert archived["status"] == "finalized"
    assert archived["headline"] == output["headline"]
    assert client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"] == []


@legacy_online_contract
def test_online_extractor_retries_length_truncation_with_compact_full_archive(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "交钥匙", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "林夕在渡口交出了钥匙，决定等候回信。"},
    ).raise_for_status()
    llm = TruncatedThenExtractor(_archive_payload("林夕"))
    client.app.dependency_overrides[get_extractor_client] = lambda: llm

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, chapter["id"], auth_headers)
    assert result["phase"] == "done"
    assert result["attempt"] == 2
    assert llm.calls == 2
    assert "输出截断自动重试 1/2" in llm.users[1]
    assert all(tokens == 8192 for tokens in llm.max_tokens)
    assert all(set(schema["properties"]) != {"character_events"} for schema in llm.schemas)


@legacy_online_contract
def test_online_extractor_salvages_only_unsafe_optional_state_after_three_attempts(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "负伤后停留", "character_links": [{"character_id": character["id"]}]},
    ).json()
    draft = "林夕受了伤。" + "风" * 120 + "随后，他留在门边。"
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": draft}
    ).raise_for_status()
    output = {
        "headline": "林夕负伤后停留。",
        "long_summary": "林夕受伤并留在门边。",
        "state_changes": [], "unresolved_items": [], "atomic_memories": [],
        "character_events": [{
            "character_name": "林夕", "event_type": "状态", "event_text": "林夕受了伤。", "evidence": "林夕受了伤。",
        }],
        "state_updates": [{
            "character_name": "林夕",
            "snapshot": {
                "presence_evidence": "林夕受了伤。",
                "当前位置": {"operation": "clear", "value": None, "evidence": "林夕受了伤。"},
                "当前行动": {"operation": "set", "value": "留在门边", "evidence": "随后，他留在门边。"},
                "情绪状态": {"operation": "clear", "value": None, "evidence": "林夕受了伤。"},
            },
            "persistent_ops": [{"slot": "身体状态", "operation": "set", "value": "受伤", "evidence": "林夕受了伤。"}],
            "relationship_ops": [],
        }],
    }
    llm = RecordingExtractor(output)
    client.app.dependency_overrides[get_extractor_client] = lambda: llm

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, chapter["id"], auth_headers)
    assert result["phase"] == "done"
    assert result["attempt"] == 3
    assert result["error_context"] == {
        "stage": "state_salvage",
        "completion_warning": "本章已接受；1 项人物当前状态未归档：即时快照“当前行动”的原文证据及近邻语境无法确认所属人物。正文、摘要及其余合格记忆已保存。",
        "dropped_state_components": 1,
        "dropped_state_reasons": ["即时快照“当前行动”的原文证据及近邻语境无法确认所属人物"],
    }
    assert llm.calls == 3
    archived = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert archived["status"] == "finalized"
    after = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert after["dynamic_fields"] == {"身体状态": "受伤"}
    assert [event["event_text"] for event in after["events"]] == ["林夕受了伤。"]


@legacy_online_contract
def test_extractor_keeps_chapter_level_archive_and_rolls_back_on_bad_archive(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    selected = client.post(f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "甲"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "character_links": [{"character_id": selected["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "甲在渡口交出了钥匙，决定等候回信。"},
    )
    output = _archive_payload("甲")
    output["atomic_memories"].append({"text": "回信仍未抵达。", "character_name": None})
    client.app.dependency_overrides[get_extractor_client] = lambda: RecordingExtractor(output)
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    archived = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert [item["text"] for item in archived["atomic_memories"]] == [
        "甲已把钥匙交给渡口守人。",
        "回信仍未抵达。",
    ]

    client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers).raise_for_status()
    bad_output = _archive_payload("甲")
    bad_output["state_changes"] = [{"text": 3}]
    client.app.dependency_overrides[get_extractor_client] = lambda: RecordingExtractor(bad_output)
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    failed = wait_for_terminal(client, chapter["id"], auth_headers)
    assert failed["phase"] == "failed"
    after_failure = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert after_failure["status"] == "draft_ready"
    assert after_failure["atomic_memories"] == archived["atomic_memories"]


@legacy_online_contract
def test_extractor_maps_multi_character_names_without_exposing_ids_to_model(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    lin = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林骁扬"}
    ).json()
    zhou = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "周蕴文"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={
            "user_prompt": "递伞",
            "character_links": [{"character_id": lin["id"]}, {"character_id": zhou["id"]}],
        },
    ).json()
    draft = "林骁扬把伞递给周蕴文。周蕴文接过伞并向林骁扬道谢。"
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": draft}
    ).raise_for_status()
    payload = {
        "headline": "林骁扬递伞。",
        "long_summary": draft,
        "state_changes": [
            {"text": "林骁扬主动帮助周蕴文。", "kind": "关系", "character_name": "林骁扬"}
        ],
        "unresolved_items": [],
        "atomic_memories": [
            {"text": "周蕴文接受林骁扬递来的伞。", "kind": "事件", "character_name": "周蕴文"}
        ],
        "character_events": [
            {
                "character_name": "林骁扬",
                "event_type": "行动",
                "event_text": "林骁扬把伞递给周蕴文。",
                "evidence": "林骁扬把伞递给周蕴文。",
            },
            {
                "character_name": "周蕴文",
                "event_type": "行动",
                "event_text": "周蕴文接过伞并向林骁扬道谢。",
                "evidence": "周蕴文接过伞并向林骁扬道谢。",
            },
        ],
        "dynamic_fields_patch": [
            {
                "character_name": "林骁扬",
                "evidence": "林骁扬把伞递给周蕴文。",
                "fields": {"当前行动": "给周蕴文递伞"},
                "relationships": [{"other_character_name": "周蕴文", "status": "主动帮助"}],
            },
            {
                "character_name": "周蕴文",
                "evidence": "周蕴文接过伞并向林骁扬道谢。",
                "fields": {"情绪状态": "感谢"},
                "relationships": [{"other_character_name": "林骁扬", "status": "接受帮助"}],
            },
        ],
    }
    llm = RecordingExtractor(payload)
    client.app.dependency_overrides[get_extractor_client] = lambda: llm
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    lin_after = client.get(f"/api/v1/characters/{lin['id']}", headers=auth_headers).json()
    zhou_after = client.get(f"/api/v1/characters/{zhou['id']}", headers=auth_headers).json()
    assert [event["event_text"] for event in lin_after["events"]] == ["林骁扬把伞递给周蕴文。"]
    assert [event["event_text"] for event in zhou_after["events"]] == ["周蕴文接过伞并向林骁扬道谢。"]
    assert lin_after["dynamic_fields"] == {"当前行动": "给周蕴文递伞", "与周蕴文关系": "主动帮助"}
    assert zhou_after["dynamic_fields"] == {"情绪状态": "感谢", "与林骁扬关系": "主动帮助"}
    name_schema = llm.schema["properties"]["character_events"]["items"]["properties"]["character_name"]
    assert set(name_schema["enum"]) == {"林骁扬", "周蕴文"}
    assert lin["id"] not in llm.user and zhou["id"] not in llm.user
    assert "林骁扬" in llm.user and "周蕴文" in llm.user


@legacy_online_contract
def test_extractor_drops_event_evidence_assigned_to_the_wrong_character(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    lin = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林骁扬"}
    ).json()
    zhou = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "周蕴文"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "离开", "character_links": [{"character_id": lin["id"]}, {"character_id": zhou["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "周蕴文独自离开。林骁扬留在原地。"},
    ).raise_for_status()
    payload = {
        "headline": "离开。",
        "long_summary": "周蕴文离开，林骁扬留下。",
        "state_changes": [],
        "unresolved_items": [],
        "atomic_memories": [],
        "character_events": [{
            "character_name": "林骁扬",
            "event_type": "行动",
            "event_text": "林骁扬留在原地。",
            "evidence": "周蕴文独自离开。",
        }],
        "dynamic_fields_patch": [],
    }
    llm = RecordingExtractor(payload)
    client.app.dependency_overrides[get_extractor_client] = lambda: llm
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    done = wait_for_terminal(client, chapter["id"], auth_headers)
    assert done["phase"] == "done"
    assert done["attempt"] == 1
    assert done["error_context"]["dropped_event_count"] == 1
    assert done["error_context"]["dropped_event_reasons"] == [
        "人物事件的原文证据及近邻语境无法确认所属人物"
    ]
    assert llm.calls == 1
    archived = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert archived["status"] == "finalized"
    assert archived["headline"] == payload["headline"]
    assert archived["long_summary"] == payload["long_summary"]
    assert client.get(f"/api/v1/characters/{lin['id']}", headers=auth_headers).json()["events"] == []


@legacy_online_contract
def test_extractor_accepts_pronoun_evidence_when_preceding_context_names_owner(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林骁扬"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "折返", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=auth_headers,
        json={"draft_text": "林骁扬在门边停住脚步。随后，他转身返回。"},
    ).raise_for_status()
    payload = {
        "headline": "林骁扬折返。",
        "long_summary": "林骁扬在门边停步后折返。",
        "state_changes": [],
        "unresolved_items": [],
        "atomic_memories": [],
        "character_events": [{
            "character_name": "林骁扬",
            "event_type": "行动",
            "event_text": "林骁扬停步后转身返回。",
            "evidence": "随后，他转身返回。",
        }],
        "dynamic_fields_patch": [{
            "character_name": "林骁扬",
            "evidence": "随后，他转身返回。",
            "fields": {"当前行动": "转身返回"},
            "relationships": [],
        }],
    }
    client.app.dependency_overrides[get_extractor_client] = lambda: RecordingExtractor(payload)
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    after = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert [event["event_text"] for event in after["events"]] == ["林骁扬停步后转身返回。"]
    assert after["dynamic_fields"] == {"当前行动": "转身返回"}


@legacy_online_contract
def test_character_memory_rebuild_replaces_only_extractor_owned_character_state(
    client, auth_headers, wait_for_terminal, tmp_path
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "交钥匙", "character_links": [{"character_id": character["id"]}]},
    ).json()
    draft = "林夕在渡口交出了钥匙，决定等候回信。"
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": draft}
    ).raise_for_status()
    client.app.dependency_overrides[get_extractor_client] = lambda: RecordingExtractor(_archive_payload("林夕"))
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"headline": "用户大事记", "long_summary": "用户保留摘要"},
    ).raise_for_status()
    client.patch(
        f"/api/v1/characters/{character['id']}",
        headers=auth_headers,
        json={"dynamic_fields": {"坏字段": "污染"}},
    ).raise_for_status()

    from app import db as db_module
    from app.models import Book, Chapter

    db = db_module.SessionLocal()
    try:
        full_output = bind_extractor_character_names(_archive_payload("林夕"), [(character["id"], "林夕")])
        output = {"state_updates": full_output["state_updates"]}
        orm_book = db.get(Book, book["id"])
        orm_chapter = db.get(Chapter, chapter["id"])
        fingerprint = state_rebuild_fingerprint(orm_chapter)
        orm_chapter.character_links[0].character.dynamic_fields = {"临时投影": "不属于输入身份"}
        assert state_rebuild_fingerprint(orm_chapter) == fingerprint
        checkpoint_path = tmp_path / "validated-rebuild.json.partial"
        write_rebuild_checkpoint(
            checkpoint_path, orm_book, [orm_chapter], [orm_chapter], {chapter["id"]: output}
        )
        assert load_rebuild_checkpoint(checkpoint_path, orm_book, [orm_chapter]) == {chapter["id"]: output}
        bundle_path = tmp_path / "validated-rebuild.json"
        write_validated_bundle(str(bundle_path), orm_book, [orm_chapter], {chapter["id"]: output})
        assert bundle_path.stat().st_mode & 0o777 == 0o600
        loaded_outputs = load_validated_bundle(str(bundle_path), orm_book, [orm_chapter])
        assert loaded_outputs == {chapter["id"]: output}
        stats = rebuild_book_character_memory(db, orm_book, loaded_outputs)
        db.commit()
    finally:
        db.close()
    assert stats == {"chapters": 1, "characters": 1, "updated_characters": 1, "events": 1, "patches": 0, "state_changes": 3, "effective_states": 3}
    rebuilt_character = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    rebuilt_chapter = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert rebuilt_character["dynamic_fields"] == {"当前行动": "已交出钥匙"}
    assert rebuilt_character["events"][0]["event_text"] == "林夕在渡口交出钥匙。"
    assert rebuilt_chapter["headline"] == "用户大事记"
    assert rebuilt_chapter["long_summary"] == "用户保留摘要"
    assert rebuilt_chapter["draft_text"] == draft
