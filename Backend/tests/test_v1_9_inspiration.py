from __future__ import annotations

from typing import Any

from sqlalchemy import func, select

import app.db as db_module
from app.llm.factory import get_inspiration_creator_client
from app.models import (
    Book,
    AgentPersona,
    Chapter,
    ChapterArchiveRevision,
    ChapterDraftCandidate,
    Character,
    JobRun,
    LLMCallAudit,
)
from app.services.archive_v2 import archive_input_fingerprint
from app.services.personas import DEFAULT_PERSONAS, LEGACY_INSPIRATION_PERSONAS, seed_defaults


def _valid_cards() -> list[dict[str, Any]]:
    return [
        {
            "body": (
                "潮水切断旧路后，人物没有立刻冒险穿越，而是先在废弃候船室观察水位与远处灯号。"
                "他从散落的值班记录里发现涨潮时间被人改过，却无法判断这是疏忽还是刻意误导。"
                "为了不让同伴陷入危险，他试着用手边材料恢复一盏信号灯，并借短暂亮光确认另一条通道仍有人活动。"
                "这个过程中，原本彼此戒备的两人因为必须配合而开始交换有限的信息，但都没有交出最重要的秘密。"
                "临近退潮，通道入口露出一角，他们决定先共同走到能够回头的位置。"
                "本章停在两人愿意暂时同行，关系只从疏离推进到初步信任，真正的动机与去向仍留待后续。"
            ),
            "history_basis": None,
            "note": None,
            "source_ids": [],
        },
        {
            "body": (
                "人物带着一个自以为正确的判断进入空置档案室，准备寻找能够证明猜测的记录，却先看见几份日期互相矛盾的值班表。"
                "她没有马上推翻旧结论，而是逐页比对墨迹、折痕和被撕掉的编号，让行动在安静的搜寻中逐渐积累压力。"
                "同行者偶尔提出不同解释，她起初敷衍，后来因一次险些触发警报的失误才认真听完。"
                "两人由此发现问题并不在某一个答案，而在有人希望他们只看见单一答案。"
                "离开前，她把最关键的缺页留在原处，只带走能继续核验的线索。"
                "本章收束在她承认自己的判断可能有误，却尚未查明幕后者，也没有因此与同行者建立超出当前阶段的亲密关系。"
            ),
            "history_basis": None,
            "note": "结尾可以停在人物意识到代价的瞬间。",
            "source_ids": [],
        },
        {
            "body": (
                "夜里的旧屋没有出现突发袭击，人物却在整理遗物时发现每件物品都被刻意放回日常位置，唯独餐桌旁少了一把椅子。"
                "她先沿着房间的使用痕迹还原缺席者最后一天的行动，又在窗台灰尘里看见反复擦拭留下的浅痕。"
                "外面的风声、楼梯上的回响和停顿许久的自言自语，把这次寻找变成对自身记忆的审问。"
                "她最终意识到，自己一直回避的不是失踪原因，而是曾经做出的某个选择。"
                "她没有立刻追出去，也没有得到完整答案，只把那把藏在储物间的椅子重新搬回桌边。"
                "本章停在她愿意面对过去的第一步，缺席者的去向与两人的旧关系仍保持未解。"
            ),
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
        self.schemas: list[dict[str, Any]] = []
        self.max_tokens: list[int | None] = []

    def complete_json(self, **kwargs):
        self.users.append(kwargs["user"])
        self.systems.append(kwargs["system"])
        self.schemas.append(kwargs["schema"])
        self.max_tokens.append(kwargs.get("max_tokens"))
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
    assert [card["title"] for card in response.json()["cards"]] == ["方向一", "方向二", "方向三"]
    assert _table_counts() == before
    assert "数据库旧标题" not in llm.users[0]
    assert "数据库旧 Bible" not in llm.users[0]
    assert "（空白）" in llm.users[0]
    assert "自由发想模式" in llm.users[0]
    assert "history_basis 必须为 null" in llm.users[0]
    assert "场景化只是构思方法，不是输出模板" in llm.users[0]
    assert "允许一个持续的文学性场景" in llm.users[0]
    assert "每个 body 必须为 200–300 个去空白字符" in llm.users[0]
    assert "不得跳过人物关系、认知、冲突或长期主线的中间阶段" in llm.users[0]
    card_schema = llm.schemas[0]["properties"]["cards"]["items"]
    assert "title" not in card_schema["properties"]
    assert "title" not in card_schema["required"]
    assert card_schema["properties"]["body"]["minLength"] == 200
    assert card_schema["properties"]["body"]["maxLength"] == 300
    assert llm.max_tokens == [8192]
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
            "pacing_boundary": "林夕与同伴只推进到愿意主动交谈，不表白、不确认关系。",
        },
    )

    assert response.status_code == 200
    user = llm.users[0]
    assert "尚未保存的新标题" in user
    assert "作者已确定，不可改拟" in user
    assert "不得另拟、替换或建议新标题" in user
    assert "林夕在潮水抵达前必须作出选择" in user
    assert "林夕与同伴只推进到愿意主动交谈，不表白、不确认关系" in user
    assert "限定本章最多推进到哪里" in user
    assert "不得把其中的否定、禁止或尚未发生事项误写成实际事件" in user
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
    assert "承接模式" in user


def test_single_history_chapter_uses_free_ideation_and_discards_history_metadata(client, auth_headers) -> None:
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
    assert "自由发想模式" in llm.users[0]
    assert "海墙在第一章出现裂缝" in llm.users[0]
    first_card = response.json()["cards"][0]
    assert first_card["history_basis"] is None
    assert first_card["history_chapter_indexes"] == []


def test_history_source_is_mapped_to_public_chapter_index(client, auth_headers) -> None:
    book, first = _create_book_and_chapter(client, auth_headers, title="第一章", bible="旧章")
    with db_module.SessionLocal() as db:
        stored = db.get(Chapter, first["id"])
        assert stored is not None
        stored.status = "finalized"
        stored.legacy_archive_eligible = True
        stored.long_summary = "海墙在第一章出现裂缝。"
        second = Chapter(
            book_id=book["id"],
            index=2,
            title="第二章",
            user_prompt="",
            status="finalized",
            legacy_archive_eligible=True,
            long_summary="第二章确认潮水正在退去。",
        )
        db.add(second)
        current = Chapter(book_id=book["id"], index=3, title="第三章", user_prompt="")
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
    assert "承接模式" in llm.users[0]


def test_three_valid_cards_survive_invalid_extras_without_repair(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    cards = _valid_cards()
    cards.extend(
        [
            {**_valid_cards()[0], "body": "潮" * 301},
            _valid_cards()[0],
        ]
    )
    llm = RecordingInspirationLLM([{"cards": cards}])
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 200
    assert len(response.json()["cards"]) == 3
    assert len(llm.users) == 1


def test_model_supplied_titles_are_ignored_and_server_labels_stay_stable(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    cards = _valid_cards()
    cards[0] = {**cards[0], "title": "模型擅自拟的章节标题"}
    llm = RecordingInspirationLLM([{"cards": cards}])
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "作者已定标题", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 200
    assert [card["title"] for card in response.json()["cards"]] == ["方向一", "方向二", "方向三"]
    assert "模型擅自拟的章节标题" not in str(response.json())


def test_body_length_boundary_excludes_server_label_and_optional_metadata(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    at_limit = _valid_cards()
    at_limit[0] = {**at_limit[0], "body": "潮" * 200, "note": "注" * 120}
    at_limit[1] = {**at_limit[1], "body": "雨" * 300, "note": "记" * 120}
    llm = RecordingInspirationLLM([{"cards": at_limit}])
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 200
    cards = response.json()["cards"]
    assert len(cards[0]["body"]) == 200
    assert len(cards[1]["body"]) == 300
    assert cards[0]["title"] == "方向一"
    assert cards[0]["note"] == "注" * 120


def test_overlong_body_is_clipped_only_at_a_natural_sentence_end(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    cards = _valid_cards()
    expected = cards[0]["body"]
    cards[0] = {**cards[0], "body": expected + "补充内容没有新的句号" * 20}
    llm = RecordingInspirationLLM([{"cards": cards}])
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={"title": "", "bible": "", "selected_character_ids": []},
    )

    assert response.status_code == 200
    assert response.json()["cards"][0]["body"] == expected
    assert len(llm.users) == 1


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
    bad[0] = {**bad[0], "body": "赵六突然出现并交出关键证据。" + "潮" * 200}
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


def test_underlong_cards_are_rejected_after_one_repair_without_business_writes(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    bad = _valid_cards()
    bad[0] = {**bad[0], "body": "潮" * 199}
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
    assert "body_too_short" in llm.users[1]
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


def test_overlong_pacing_boundary_is_rejected_before_llm_call(client, auth_headers) -> None:
    _, chapter = _create_book_and_chapter(client, auth_headers)
    llm = RecordingInspirationLLM()
    client.app.dependency_overrides[get_inspiration_creator_client] = lambda: llm

    response = client.post(
        f"/api/v1/chapters/{chapter['id']}/inspirations",
        headers=auth_headers,
        json={
            "title": "",
            "bible": "",
            "selected_character_ids": [],
            "pacing_boundary": "界" * 501,
        },
    )

    assert response.status_code == 422
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


def test_exact_shipped_short_idea_persona_migrates_but_custom_persona_is_preserved(client) -> None:
    with db_module.SessionLocal() as db:
        persona = db.get(AgentPersona, "inspiration_creator")
        assert persona is not None
        for legacy_prompt in LEGACY_INSPIRATION_PERSONAS:
            persona.system_prompt = legacy_prompt
            db.commit()
            seed_defaults(db)
            db.refresh(persona)
            assert persona.system_prompt == DEFAULT_PERSONAS["inspiration_creator"]

        persona.system_prompt = "用户自定义的灵感人格"
        db.commit()
        seed_defaults(db)
        db.refresh(persona)
        assert persona.system_prompt == "用户自定义的灵感人格"
