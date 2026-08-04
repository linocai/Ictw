from __future__ import annotations

from app.models import CharacterStateChange
from app.services.character_state_projection import project_state_changes, rebuild_book_projection


def _change(character_id: str, *, scope: str, slot: str, operation: str, value: str | None, batch_id: str = "", other: str | None = None) -> CharacterStateChange:
    return CharacterStateChange(
        id=f"{character_id}-{scope}-{slot}-{batch_id or operation}-{value or 'clear'}",
        book_id="book", chapter_id="chapter", character_id=character_id, other_character_id=other,
        scope=scope, slot=slot, operation=operation, value=value, evidence="合成证据", batch_id=batch_id,
    )


def test_projection_replaces_snapshot_preserves_persistent_and_mirrors_one_relationship():
    from app.models import Character

    left = Character(id="a", book_id="book", name="甲")
    right = Character(id="b", book_id="book", name="乙")
    changes = [
        _change("a", scope="snapshot", slot="当前位置", operation="set", value="地点 A", batch_id="one"),
        _change("a", scope="snapshot", slot="当前行动", operation="set", value="睡觉", batch_id="one"),
        _change("a", scope="snapshot", slot="情绪状态", operation="clear", value=None, batch_id="one"),
        _change("a", scope="persistent", slot="身体状态", operation="set", value="受伤"),
        _change("a", scope="relationship", slot="relationship", operation="set", value="敌对", other="b"),
        _change("a", scope="snapshot", slot="当前位置", operation="set", value="地点 B", batch_id="two"),
        _change("a", scope="snapshot", slot="当前行动", operation="set", value="起床", batch_id="two"),
        _change("a", scope="snapshot", slot="情绪状态", operation="set", value="警觉", batch_id="two"),
        _change("a", scope="persistent", slot="身体状态", operation="clear", value=None),
        _change("a", scope="relationship", slot="relationship", operation="set", value="合作", other="b"),
    ]
    projected, effective = project_state_changes(changes, [left, right])
    assert projected["a"] == {"当前位置": "地点 B", "当前行动": "起床", "情绪状态": "警觉", "与乙关系": "合作"}
    assert projected["b"] == {"与甲关系": "合作"}
    assert len(effective) == 5


def test_character_rename_and_delete_reprojects_relationship(client, auth_headers):
    import app.db as db_module
    from app.models import Chapter

    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "关系投影"}).json()
    left = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers,
        json={"name": "甲", "dynamic_fields": {"污染": "不会写入"}},
    ).json()
    right = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers,
        json={"name": "乙", "dynamic_fields": {}},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters", headers=auth_headers,
        json={"user_prompt": "关系变化", "character_links": []},
    ).json()
    db = db_module.SessionLocal()
    try:
        orm_chapter = db.get(Chapter, chapter["id"])
        orm_chapter.status = "finalized"
        left_id, right_id = sorted((left["id"], right["id"]))
        db.add(CharacterStateChange(
            book_id=book["id"], chapter_id=chapter["id"], character_id=left_id,
            other_character_id=right_id, scope="relationship", slot="relationship",
            operation="set", value="合作", evidence="甲与乙开始合作。", batch_id="",
        ))
        db.flush()
        rebuild_book_projection(db, book["id"])
        db.commit()
    finally:
        db.close()

    assert client.get(f"/api/v1/characters/{left['id']}", headers=auth_headers).json()["dynamic_fields"] == {"与乙关系": "合作"}
    renamed = client.patch(
        f"/api/v1/characters/{right['id']}", headers=auth_headers,
        json={"name": "乙改名"},
    )
    renamed.raise_for_status()
    assert client.get(f"/api/v1/characters/{left['id']}", headers=auth_headers).json()["dynamic_fields"] == {"与乙改名关系": "合作"}

    client.delete(f"/api/v1/characters/{right['id']}", headers=auth_headers).raise_for_status()
    assert client.get(f"/api/v1/characters/{left['id']}", headers=auth_headers).json()["dynamic_fields"] == {}
