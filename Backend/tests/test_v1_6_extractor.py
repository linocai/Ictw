from __future__ import annotations

from app.agents.extractor import ExtractorAgent, bind_extractor_character_names, extractor_schema
from app.llm.factory import get_extractor_client
from app.services.character_memory_rebuild import rebuild_book_character_memory
from app.services.context import memory_candidates
from app.services.personas import PROGRAM_PROTOCOLS
from scripts.rebuild_book_character_memory import load_validated_bundle, write_validated_bundle


class RecordingExtractor:
    def __init__(self, payload: dict) -> None:
        self.payload = payload
        self.system = ""
        self.user = ""
        self.users: list[str] = []
        self.schema: dict = {}
        self.calls = 0

    def complete_json(self, *, system: str, user: str, schema: dict, **_kwargs):
        self.calls += 1
        self.system, self.user, self.schema = system, user, schema
        self.users.append(user)
        return self.payload


class SequencedExtractor(RecordingExtractor):
    def __init__(self, payloads: list[dict]) -> None:
        super().__init__(payloads[-1])
        self.payloads = payloads

    def complete_json(self, *, system: str, user: str, schema: dict, **_kwargs):
        payload = self.payloads[min(self.calls, len(self.payloads) - 1)]
        self.payload = payload
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


def test_extractor_appends_fixed_protocol_and_schema_has_v16_archive_fields():
    llm = RecordingExtractor(_archive_payload("林夕"))
    output = ExtractorAgent(llm, "可编辑 Extractor 人格").extract("最终正文", [("character", "林夕")])
    assert llm.system == f"可编辑 Extractor 人格\n\n{PROGRAM_PROTOCOLS['extractor']}"
    assert {"long_summary", "state_changes", "unresolved_items", "atomic_memories"} <= set(llm.schema["properties"])
    assert "summary" not in llm.schema["properties"]
    assert extractor_schema([])["properties"]["character_events"].get("maxItems") == 0
    assert output["character_events"][0]["character_id"] == "character"
    assert "character_name" not in output["character_events"][0]


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


def test_online_extractor_corrects_a_validation_failure_before_committing(
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
    invalid = _archive_payload("林夕")
    invalid["character_events"][0]["event_type"] = "推进"
    llm = SequencedExtractor([invalid, _archive_payload("林夕")])
    client.app.dependency_overrides[get_extractor_client] = lambda: llm

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    result = wait_for_terminal(client, chapter["id"], auth_headers)
    assert result["phase"] == "done"
    assert result["attempt"] == 2
    assert llm.calls == 2
    assert "自动纠偏 1/2" in llm.users[1]
    assert "event_type must use the canonical taxonomy" in llm.users[1]
    archived = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert archived["status"] == "finalized"
    assert client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()["events"]


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
    assert zhou_after["dynamic_fields"] == {"情绪状态": "感谢", "与林骁扬关系": "接受帮助"}
    name_schema = llm.schema["properties"]["character_events"]["items"]["properties"]["character_name"]
    assert set(name_schema["enum"]) == {"林骁扬", "周蕴文"}
    assert lin["id"] not in llm.user and zhou["id"] not in llm.user
    assert "林骁扬" in llm.user and "周蕴文" in llm.user


def test_extractor_rejects_evidence_that_does_not_name_the_assigned_character(
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
    failed = wait_for_terminal(client, chapter["id"], auth_headers)
    assert failed["phase"] == "failed"
    assert failed["attempt"] == 3
    assert failed["error_message"].startswith("Extractor 连续 3 次未通过确定性校验：")
    assert failed["error_context"] == {
        "stage": "validation",
        "attempts": 3,
        "reason": "人物事件的原文证据及近邻语境无法确认所属人物",
    }
    assert llm.calls == 3
    assert client.get(f"/api/v1/characters/{lin['id']}", headers=auth_headers).json()["events"] == []


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
        output = bind_extractor_character_names(_archive_payload("林夕"), [(character["id"], "林夕")])
        orm_book = db.get(Book, book["id"])
        orm_chapter = db.get(Chapter, chapter["id"])
        bundle_path = tmp_path / "validated-rebuild.json"
        write_validated_bundle(str(bundle_path), orm_book, [orm_chapter], {chapter["id"]: output})
        assert bundle_path.stat().st_mode & 0o777 == 0o600
        loaded_outputs = load_validated_bundle(str(bundle_path), orm_book, [orm_chapter])
        assert loaded_outputs == {chapter["id"]: output}
        stats = rebuild_book_character_memory(db, orm_book, loaded_outputs)
        db.commit()
    finally:
        db.close()
    assert stats == {"chapters": 1, "characters": 1, "updated_characters": 1, "events": 1, "patches": 1}
    rebuilt_character = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    rebuilt_chapter = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert rebuilt_character["dynamic_fields"] == {"当前行动": "已交出钥匙"}
    assert rebuilt_character["events"][0]["event_text"] == "林夕在渡口交出钥匙。"
    assert rebuilt_chapter["headline"] == "用户大事记"
    assert rebuilt_chapter["long_summary"] == "用户保留摘要"
    assert rebuilt_chapter["draft_text"] == draft
