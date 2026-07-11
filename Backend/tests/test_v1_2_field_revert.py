from __future__ import annotations

from app.llm.factory import get_extractor_client


class PatchExtractor:
    """Extractor stub emitting a controlled dynamic_fields_patch."""

    def __init__(self, character_id: str, fields: dict) -> None:
        self.character_id = character_id
        self.fields = fields

    def complete_json(self, **kwargs):
        return {
            "summary": "梗概。",
            "headline": "大事记。",
            "character_events": [],
            "dynamic_fields_patch": [{"character_id": self.character_id, "fields": self.fields}],
        }


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
    book, character = _setup_book(client, auth_headers, initial_fields={"心情": "平静"})
    chapter = _new_chapter(client, auth_headers, book["id"], character["id"])
    _accept_with_patch(
        client, auth_headers, wait_for_terminal, chapter["id"], character["id"], {"心情": "激动", "位置": "废城"}
    )
    assert _fields(client, auth_headers, character["id"]) == {"心情": "激动", "位置": "废城"}

    client.delete(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).raise_for_status()
    # Pre-existing key restored, chapter-introduced key removed.
    assert _fields(client, auth_headers, character["id"]) == {"心情": "平静"}


def test_delete_middle_chapter_keeps_later_override_then_later_delete_reverts(client, auth_headers, wait_for_terminal):
    book, character = _setup_book(client, auth_headers)
    first = _new_chapter(client, auth_headers, book["id"], character["id"])
    second = _new_chapter(client, auth_headers, book["id"], character["id"])
    _accept_with_patch(client, auth_headers, wait_for_terminal, first["id"], character["id"], {"位置": "北境"})
    _accept_with_patch(client, auth_headers, wait_for_terminal, second["id"], character["id"], {"位置": "南港"})

    client.delete(f"/api/v1/chapters/{first['id']}", headers=auth_headers).raise_for_status()
    # Later chapter also patched the key: its state wins and stays.
    assert _fields(client, auth_headers, character["id"]) == {"位置": "南港"}

    client.delete(f"/api/v1/chapters/{second['id']}", headers=auth_headers).raise_for_status()
    # Reverting the later chapter restores ITS pre-state (first chapter's value).
    assert _fields(client, auth_headers, character["id"]) == {"位置": "北境"}


def test_reaccept_keeps_original_pre_chapter_baseline(client, auth_headers, wait_for_terminal):
    book, character = _setup_book(client, auth_headers, initial_fields={"心情": "平静"})
    chapter = _new_chapter(client, auth_headers, book["id"], character["id"])
    _accept_with_patch(client, auth_headers, wait_for_terminal, chapter["id"], character["id"], {"心情": "激动"})
    client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers).raise_for_status()
    _accept_with_patch(client, auth_headers, wait_for_terminal, chapter["id"], character["id"], {"心情": "愤怒"})
    assert _fields(client, auth_headers, character["id"]) == {"心情": "愤怒"}

    client.delete(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).raise_for_status()
    # Not "激动" (the chapter's own earlier output) — the true pre-chapter value.
    assert _fields(client, auth_headers, character["id"]) == {"心情": "平静"}
