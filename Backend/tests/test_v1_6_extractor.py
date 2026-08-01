from __future__ import annotations

from app.agents.extractor import ExtractorAgent, extractor_schema
from app.llm.factory import get_extractor_client
from app.services.context import memory_candidates
from app.services.personas import PROGRAM_PROTOCOLS


class RecordingExtractor:
    def __init__(self, payload: dict) -> None:
        self.payload = payload
        self.system = ""
        self.user = ""
        self.schema: dict = {}

    def complete_json(self, *, system: str, user: str, schema: dict, **_kwargs):
        self.system, self.user, self.schema = system, user, schema
        return self.payload


def _archive_payload(character_id: str) -> dict:
    return {
        "summary": "旧客户端可见的短梗概。",
        "headline": "关键落点。",
        "long_summary": "正文中主角在渡口交出了钥匙，并决定等候回信。",
        "state_changes": [{"text": "主角不再持有钥匙。", "kind": "possession", "character_id": character_id}],
        "unresolved_items": [{"text": "回信尚未抵达。", "kind": "pending"}],
        "atomic_memories": [{"text": "钥匙已交给渡口守人。", "kind": "event", "character_id": character_id}],
        "character_events": [{"character_id": character_id, "event_text": "在渡口交出钥匙"}],
        "dynamic_fields_patch": [{"character_id": character_id, "fields": {"钥匙": "已交出"}}],
    }


def test_extractor_appends_fixed_protocol_and_schema_has_v16_archive_fields():
    llm = RecordingExtractor(_archive_payload("character"))
    ExtractorAgent(llm, "可编辑 Extractor 人格").extract("最终正文", ["character"])
    assert llm.system == f"可编辑 Extractor 人格\n\n{PROGRAM_PROTOCOLS['extractor']}"
    assert {"long_summary", "state_changes", "unresolved_items", "atomic_memories"} <= set(llm.schema["properties"])
    assert extractor_schema([])["properties"]["character_events"].get("maxItems") == 0


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
    llm = RecordingExtractor(_archive_payload(character["id"]))
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
    assert recalled[f"chapter:{chapter['id']}:long_summary"].memory_type == "long_summary"
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


def test_extractor_discards_unselected_archive_character_and_rolls_back_on_bad_archive(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    selected = client.post(f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "甲"}).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "character_links": [{"character_id": selected["id"]}]},
    ).json()
    client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=auth_headers, json={"draft_text": "甲完成行动。"})
    output = _archive_payload(selected["id"])
    output["atomic_memories"].append({"text": "未知人物的事实", "character_id": "unknown"})
    client.app.dependency_overrides[get_extractor_client] = lambda: RecordingExtractor(output)
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    archived = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert [item["text"] for item in archived["atomic_memories"]] == ["钥匙已交给渡口守人。"]

    client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers).raise_for_status()
    bad_output = _archive_payload(selected["id"])
    bad_output["state_changes"] = [{"text": 3}]
    client.app.dependency_overrides[get_extractor_client] = lambda: RecordingExtractor(bad_output)
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    failed = wait_for_terminal(client, chapter["id"], auth_headers)
    assert failed["phase"] == "failed"
    after_failure = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert after_failure["status"] == "draft_ready"
    assert after_failure["atomic_memories"] == archived["atomic_memories"]
