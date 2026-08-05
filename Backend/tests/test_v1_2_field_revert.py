from __future__ import annotations

from app.llm.factory import get_extractor_client


class PatchExtractor:
    """v2 Extractor stub emitting a controlled ending snapshot."""

    def __init__(self, character_id: str, fields: dict) -> None:
        self.character_id = character_id
        self.fields = fields

    def complete_json(self, *, user: str, **kwargs):
        import re
        span_id = re.search(r"\[(P\d{4}-S\d{2})\]", user).group(1)
        fact = {
            "fact_ref": "F1", "type": "状态", "importance": 3,
            "text": "林夕的章末状态发生变化。", "participant_names": ["林夕"],
            "start_id": span_id, "end_id": span_id,
        }
        deltas = []
        for slot in ("当前位置", "当前行动", "情绪状态"):
            value = self.fields.get(slot)
            deltas.append({
                "fact_ref": "F1", "character_name": "林夕", "other_character_name": None,
                "scope": "snapshot", "slot": slot,
                "operation": "set" if value else "clear", "value": value,
            })
        return {"summary": "梗概。", "facts": [fact], "end_state_delta": deltas}


def _setup_book(client, auth_headers, initial_fields: dict | None = None):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "dynamic_fields": initial_fields or {}},
    ).json()
    return book, character


def _new_chapter(client, auth_headers, book_id: str, character_id: str) -> dict:
    return client.post(
        f"/api/v1/books/{book_id}/chapters",
        headers=auth_headers,
        json={"user_prompt": "行动", "character_links": [{"character_id": character_id}]},
    ).json()


def _accept_with_patch(client, auth_headers, wait_for_terminal, chapter_id: str, character_id: str, fields: dict):
    client.app.dependency_overrides[get_extractor_client] = lambda: PatchExtractor(character_id, fields)
    client.post(f"/api/v1/chapters/{chapter_id}/import", headers=auth_headers, json={"draft_text": "林夕行动"})
    client.post(f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter_id, auth_headers)["phase"] == "done"


def _fields(client, auth_headers, character_id: str) -> dict:
    return client.get(f"/api/v1/characters/{character_id}", headers=auth_headers).json()["dynamic_fields"]


def test_delete_reverts_preexisting_and_introduced_keys(client, auth_headers, wait_for_terminal):
    book, character = _setup_book(client, auth_headers, initial_fields={"情绪状态": "平静"})
    chapter = _new_chapter(client, auth_headers, book["id"], character["id"])
    _accept_with_patch(
        client, auth_headers, wait_for_terminal, chapter["id"], character["id"], {"情绪状态": "激动", "当前位置": "废城"}
    )
    assert _fields(client, auth_headers, character["id"]) == {"情绪状态": "激动", "当前位置": "废城"}

    client.delete(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).raise_for_status()
    # Client-owned dynamic fields are ignored; deleting the only finalized
    # state source leaves no stale value behind.
    assert _fields(client, auth_headers, character["id"]) == {}


def test_delete_middle_chapter_stales_dependent_archive_until_retry(client, auth_headers, wait_for_terminal):
    book, character = _setup_book(client, auth_headers)
    first = _new_chapter(client, auth_headers, book["id"], character["id"])
    second = _new_chapter(client, auth_headers, book["id"], character["id"])
    _accept_with_patch(client, auth_headers, wait_for_terminal, first["id"], character["id"], {"当前位置": "北境"})
    _accept_with_patch(client, auth_headers, wait_for_terminal, second["id"], character["id"], {"当前位置": "南港"})

    client.delete(f"/api/v1/chapters/{first['id']}", headers=auth_headers).raise_for_status()
    # The later v2 archive was extracted with the deleted chapter's projected
    # state in its input fingerprint. It must stop contributing until a fresh
    # one-call retry validates the same accepted prose against the new prior
    # state; silently keeping its old delta would mix incompatible ledgers.
    second_read = client.get(f"/api/v1/chapters/{second['id']}", headers=auth_headers).json()
    assert second_read["status"] == "finalized"
    assert second_read["archive"]["status"] == "stale"
    assert second_read["archive"]["can_retry"] is True
    assert _fields(client, auth_headers, character["id"]) == {}

    client.app.dependency_overrides[get_extractor_client] = lambda: PatchExtractor(
        character["id"], {"当前位置": "南港"}
    )
    client.post(f"/api/v1/chapters/{second['id']}/archive/retry", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, second["id"], auth_headers)["phase"] == "done"
    assert _fields(client, auth_headers, character["id"]) == {"当前位置": "南港"}

    client.delete(f"/api/v1/chapters/{second['id']}", headers=auth_headers).raise_for_status()
    assert _fields(client, auth_headers, character["id"]) == {}


def test_reaccept_keeps_original_pre_chapter_baseline(client, auth_headers, wait_for_terminal):
    book, character = _setup_book(client, auth_headers, initial_fields={"情绪状态": "平静"})
    chapter = _new_chapter(client, auth_headers, book["id"], character["id"])
    _accept_with_patch(client, auth_headers, wait_for_terminal, chapter["id"], character["id"], {"情绪状态": "激动"})
    client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers).raise_for_status()
    _accept_with_patch(client, auth_headers, wait_for_terminal, chapter["id"], character["id"], {"情绪状态": "愤怒"})
    assert _fields(client, auth_headers, character["id"]) == {"情绪状态": "愤怒"}

    client.delete(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).raise_for_status()
    assert _fields(client, auth_headers, character["id"]) == {}
