from __future__ import annotations

from typing import Any

from sqlalchemy import func, select

import app.db as db_module
from app.llm.factory import get_inspiration_creator_client
from app.models import (
    Book,
    Chapter,
    ChapterArchiveRevision,
    ChapterDraftCandidate,
    Character,
    JobRun,
    LLMCallAudit,
)
from app.services.archive_v2 import archive_input_fingerprint


def _valid_cards() -> list[dict[str, Any]]:
    return [
        {
            "title": "先让灯熄灭",
            "body": "让环境先失去一种可靠信号，人物必须在信息不足时主动选择下一步。",
            "history_basis": None,
            "note": None,
            "source_ids": [],
        },
        {
            "title": "把答案推迟",
            "body": "本章先呈现答案造成的后果，却暂时不说明答案本身，让悬念来自因果倒置。",
            "history_basis": None,
            "note": "结尾可以停在人物意识到代价的瞬间。",
            "source_ids": [],
        },
        {
            "title": "一次克制的拒绝",
            "body": "让人物拒绝眼前最方便的道路，并通过这个拒绝暴露真正看重的东西。",
            "history_basis": None,
            "note": None,
            "source_ids": [],
        },
    ]


class RecordingInspirationLLM:
    model_name = "recording-inspiration"
    last_finish_reason = "stop"
    last_usage = {"prompt_tokens": 7, "completion_tokens": 11, "total_tokens": 18}

    def __init__(self, outputs: list[dict[str, Any]] | None = None) -> None:
        self.outputs = outputs or [{"cards": _valid_cards()}]
        self.users: list[str] = []
        self.systems: list[str] = []

    def complete_json(self, **kwargs):
        self.users.append(kwargs["user"])
        self.systems.append(kwargs["system"])
        index = min(len(self.users) - 1, len(self.outputs) - 1)
        return self.outputs[index]


def _create_book_and_chapter(client, auth_headers, *, title: str = "数据库旧标题", bible: str = "数据库旧 Bible"):
    book = client.post(
        "/api/v1/books",
        headers=auth_headers,
        json={"title": "书", "world_setting": "潮汐会改变城市道路。"},
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=auth_headers,
        json={"title": title, "user_prompt": bible},
    ).json()
    return book, chapter


def _table_counts() -> dict[str, int]:
    with db_module.SessionLocal() as db:
        return {
            "books": int(db.scalar(select(func.count()).select_from(Book)) or 0),
            "chapters": int(db.scalar(select(func.count()).select_from(Chapter)) or 0),
            "characters": int(db.scalar(select(func.count()).select_from(Character)) or 0),
            "jobs": int(db.scalar(select(func.count()).select_from(JobRun)) or 0),
            "candidates": int(db.scalar(select(func.count()).select_from(ChapterDraftCandidate)) or 0),
            "revisions": int(db.scalar(select(func.count()).select_from(ChapterArchiveRevision)) or 0),
        }


def test_empty_snapshot_and_no_characters_generate_without_business_writes(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    llm = RecordingInspirationLLM()
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm
    before = _table_counts()

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 200
    assert len(response.json()["cards"]) == 3
    assert _table_counts() == before
    assert "数据库旧标题" not in llm.users[0]
    assert "数据库旧 Bible" not in llm.users[0]
    assert "（空白）" in llm.users[0]
    with db_module.SessionLocal() as db:
        stored = db.get(Chapter, chapter["id"])
        assert stored is not None
        assert stored.title == "数据库旧标题"
        assert stored.user_prompt == "数据库旧 Bible"
        audits = list(db.scalars(select(LLMCallAudit)).all())
        assert len(audits) == 1
        assert audits[0].agent_role == "inspiration_creator"
        assert audits[0].chapter_id == chapter["id"]
        assert audits[0].job_id is None


def test_unsaved_snapshot_and_requested_character_selection_are_authoritative(client, auth_headers) -> None:
    book, chapter = _create_book_and_chapter(client, auth_headers)
    selected = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "林夕", "role": "主角", "fixed_profile": "只相信亲眼所见。"},
    ).json()
    unselected = client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "赵六", "role": "旧友", "fixed_profile": "从不说谎。"},
    ).json()
    client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"character_links": [{"character_id": unselected["id"]}]},
    ).raise_for_status()
    llm = RecordingInspirationLLM()
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={
            "title": "尚未保存的新标题",
            "bible": "林夕在潮水抵达前必须作出选择。",
            "selected_character_ids": [selected["id"]],
        },
    )

    assert response.status_code == 200
    user = llm.users[0]
    assert "尚未保存的新标题" in user
    assert "林夕在潮水抵达前必须作出选择" in user
    assert "只相信亲眼所见" in user
    assert "赵六" not in user
    assert "从不说谎" not in user


def test_inspiration_uses_one_valid_history_source_per_chapter_and_never_prose(client, auth_headers) -> None:
    book, _ = _create_book_and_chapter(client, auth_headers, title="第一章", bible="旧章")
    with db_module.SessionLocal() as db:
        first = db.scalar(select(Chapter).where(Chapter.book_id == book["id"], Chapter.index == 1))
        assert first is not None
        first.status = "finalized"
        first.legacy_archive_eligible = True
        first.long_summary = "LEGACY-FIRST-SUMMARY"
        first.draft_text = "RAW-FIRST-PROSE-MUST-NOT-APPEAR"
        second = Chapter(
            book_id=book["id"],
            index=2,
            title="第二章",
            user_prompt="旧章二",
            status="finalized",
            long_summary="LEGACY-SECOND-MUST-NOT-APPEAR",
            draft_text="RAW-SECOND-PROSE-MUST-NOT-APPEAR",
            archive_status="complete",
        )
        db.add(second)
        db.flush()
        revision = ChapterArchiveRevision(
            chapter_id=second.id,
            revision=1,
            provenance="live",
            input_fingerprint=archive_input_fingerprint(second),
            status="complete",
            is_active=True,
            summary="ACTIVE-V2-SECOND-SUMMARY",
        )
        db.add(revision)
        db.flush()
        second.active_archive_revision_id = revision.id
        current = Chapter(book_id=book["id"], index=3, title="第三章", user_prompt="")
        db.add(current)
        db.commit()
        current_id = current.id

    llm = RecordingInspirationLLM()
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm
    response = client.post(
        f"/api/v1/chapters/{current_id}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 200
    user = llm.users[0]
    assert "LEGACY-FIRST-SUMMARY" in user
    assert "ACTIVE-V2-SECOND-SUMMARY" in user
    assert "LEGACY-SECOND-MUST-NOT-APPEAR" not in user
    assert "RAW-FIRST-PROSE-MUST-NOT-APPEAR" not in user
    assert "RAW-SECOND-PROSE-MUST-NOT-APPEAR" not in user


def test_history_source_is_mapped_to_public_chapter_index(client, auth_headers) -> None:
    book, first = _create_book_and_chapter(client, auth_headers, title="第一章", bible="旧章")
    with db_module.SessionLocal() as db:
        stored = db.get(Chapter, first["id"])
        assert stored is not None
        stored.status = "finalized"
        stored.legacy_archive_eligible = True
        stored.long_summary = "海墙在第一章出现裂缝。"
        current = Chapter(book_id=book["id"], index=2, title="第二章", user_prompt="")
        db.add(current)
        db.commit()
        current_id = current.id
    cards = _valid_cards()
    cards[0] = {
        **cards[0],
        "history_basis": "海墙既有裂缝。",
        "source_ids": [f"chapter:{first['id']}:summary"],
    }
    llm = RecordingInspirationLLM([{"cards": cards}])
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{current_id}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 200
    first_card = response.json()["cards"][0]
    assert first_card["history_chapter_indexes"] == [1]
    assert "source_ids" not in first_card


def test_invalid_first_batch_is_repaired_once(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    duplicate = _valid_cards()[0]
    llm = RecordingInspirationLLM([
        {"cards": [duplicate, duplicate, duplicate]},
        {"cards": _valid_cards()},
    ])
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "新章", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 200
    assert len(llm.users) == 2
    assert "程序退回" in llm.users[1]
    with db_module.SessionLocal() as db:
        audits = list(db.scalars(select(LLMCallAudit).order_by(LLMCallAudit.created_at)).all())
        assert len(audits) == 2
        assert audits[0].error_code == "inspiration_invalid_response"
        assert audits[1].error_code is None


def test_unselected_known_character_is_rejected_without_text_leak(client, auth_headers) -> None:
    book, chapter = _create_book_and_chapter(client, auth_headers)
    client.post(
        f"/api/v1/books/{book['id']}/characters",
        headers=auth_headers,
        json={"name": "赵六"},
    ).raise_for_status()
    bad = _valid_cards()
    bad[0] = {**bad[0], "body": "赵六突然出现并交出关键证据。"}
    llm = RecordingInspirationLLM([{"cards": bad}, {"cards": bad}])
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm
    before = _table_counts()

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 502
    detail = response.json()["detail"]
    assert detail["code"] == "inspiration_invalid_response"
    assert "赵六" not in str(detail)
    assert _table_counts() == before


def test_overlong_cards_are_rejected_after_one_repair_without_business_writes(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    bad = _valid_cards()
    bad[0] = {**bad[0], "body": "潮" * 301}
    llm = RecordingInspirationLLM([{"cards": bad}, {"cards": bad}])
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm
    before = _table_counts()

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 502
    assert response.json()["detail"]["code"] == "inspiration_invalid_response"
    assert len(llm.users) == 2
    assert _table_counts() == before


def test_foreign_book_character_is_rejected_before_llm_call(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    other = client.post("/api/v1/books", headers=auth_headers, json={"title": "另一本"}).json()
    outsider = client.post(
        f"/api/v1/books/{other['id']}/characters",
        headers=auth_headers,
        json={"name": "外书人物"},
    ).json()
    llm = RecordingInspirationLLM()
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": [outsider["id"]]},
    )

    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "inspiration_character_invalid"
    assert llm.users == []


def test_missing_inspiration_profile_uses_safe_configuration_error(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    client.app.dependency_overrides.pop(get_inspiration_creator_client)

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 409
    assert response.json()["detail"] == {
        "code": "llm_profile_not_configured",
        "message": "该 Agent 尚未完成可用模型配置",
        "details": {"agent_role": "inspiration_creator"},
    }
