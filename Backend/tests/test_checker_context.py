from __future__ import annotations

import pytest

import app.db as db_module
from app.llm.factory import get_checker_client, get_memory_selector_client, get_writer_client
from app.models import Book, Chapter, ChapterCharacter, Character
from app.services.context import (
    draft_violations,
    manual_checker_reference_context,
    validate_character_preflight,
)


def make_story():
    with db_module.SessionLocal() as db:
        book = Book(title="上下文回归", world_setting="现代小镇，没有超自然力量。")
        db.add(book)
        db.flush()
        lin = Character(book_id=book.id, name="林夕", fixed_profile="林夕与江川是已交往多年的恋人。")
        jiang = Character(book_id=book.id, name="江川", fixed_profile="江川是林夕的男朋友。")
        other = Character(book_id=book.id, name="远客", fixed_profile="不应传入的未选人物卡")
        db.add_all([lin, jiang, other])
        db.flush()
        prior = Chapter(book_id=book.id, index=1, status="finalized", long_summary="林夕已经归还钥匙。",
                        draft_text="林夕与江川在屋檐下等雨停。")
        current = Chapter(book_id=book.id, index=2, title="等雨", user_prompt="林夕与江川在屋檐下等雨停，随后一起回家。")
        future = Chapter(book_id=book.id, index=3, status="finalized", long_summary="未来秘密不得泄露")
        db.add_all([prior, current, future])
        db.flush()
        current.character_links.extend([ChapterCharacter(character_id=lin.id), ChapterCharacter(character_id=jiang.id)])
        db.commit()
        return current.id


def _context_ack(client, chapter_id: str, auth_headers: dict[str, str]) -> dict[str, str]:
    readiness = client.get(f"/api/v1/chapters/{chapter_id}/production-readiness", headers=auth_headers).json()
    return {"acknowledged_context_token": readiness["context_token"]} if readiness["limitations"] else {}


class RecordingWriter:
    last_finish_reason = "stop"

    def __init__(self, text):
        self.text = text
        self.user = ""

    def complete_stream(self, *, user, **kwargs):
        self.user = user
        yield self.text


class SourcedSelector:
    def complete_json(self, *, user, **kwargs):
        start = user.index("[M") + 1
        source = user[start:user.index("]", start)]
        return {"briefs": [{"text": "林夕已经归还钥匙。", "source_ids": [source]}],
                "conflicts": [], "previous_ending_start_id": None}


class RecordingChecker:
    def __init__(self, verdict="passed"):
        self.verdict = verdict
        self.user = ""

    def complete_json(self, *, user, **kwargs):
        self.user = user
        # This fixture verifies transport and promotion gates, not model reasoning.
        return {"verdict": self.verdict, "issues": [] if self.verdict == "passed" else [{
            "kind": "new_plot", "draft_evidence": "两人当场订婚。",
            "bible_evidence": "随后一起回家", "reason": "已有恋爱关系不授权本章新增订婚事件",
            "source_kind": "bible", "source_id": "bible", "source_evidence": "随后一起回家",
        }], "name_uses": []}


@pytest.mark.parametrize("verdict", ["passed", "suspect", "violation"])
def test_generation_checker_receives_same_reference_snapshot_and_keeps_gate(
    client, auth_headers, wait_for_terminal, verdict,
):
    chapter_id = make_story()
    draft = "林夕望着男朋友江川，一起等雨停，随后回家。" + "雨滴落下。" * 1000
    if verdict != "passed":
        draft += "两人当场订婚。"
    writer, checker = RecordingWriter(draft), RecordingChecker(verdict)
    client.app.dependency_overrides[get_writer_client] = lambda: writer
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.app.dependency_overrides[get_memory_selector_client] = lambda: SourcedSelector()
    client.post(
        f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers,
        json=_context_ack(client, chapter_id, auth_headers),
    ).raise_for_status()
    status = wait_for_terminal(client, chapter_id, auth_headers)
    reference = writer.user.split("# 本章剧情 Bible", 1)[0]
    assert reference and checker.user.startswith(reference)
    assert "江川是林夕的男朋友" in reference
    assert "现代小镇" in reference
    assert "林夕已经归还钥匙" in reference
    assert "林夕与江川在屋檐下等雨停" in reference
    assert "不应传入的未选人物卡" not in reference
    assert "未来秘密" not in reference
    visible = client.get(f"/api/v1/chapters/{chapter_id}", headers=auth_headers).json()
    if verdict == "passed":
        assert status["phase"] == "done"
        assert visible["draft_text"] == draft
    else:
        assert status["phase"] == "failed" and status["error_code"] == "checker_rejected"
        assert visible["draft_text"] == ""
        assert status["checker_result"]["issues"] == [{
            "kind": "new_plot", "reason": "已有恋爱关系不授权本章新增订婚事件",
        }]


def test_manual_check_uses_current_cards_and_valid_prior_history_without_selector(client, auth_headers):
    chapter_id = make_story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.draft_text = "林夕与男朋友江川等雨停。" + "雨滴落下。" * 1000
        db.commit()
    checker = RecordingChecker()
    client.app.dependency_overrides[get_checker_client] = lambda: checker

    def unexpected_selector():
        raise AssertionError("manual checks must not invoke Selector")

    client.app.dependency_overrides[get_memory_selector_client] = unexpected_selector
    response = client.post(
        f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers,
        json=_context_ack(client, chapter_id, auth_headers),
    )
    assert response.status_code == 200
    reference = checker.user.split("# 本章剧情 Bible", 1)[0]
    assert "江川是林夕的男朋友" in reference and "林夕已经归还钥匙" in reference
    assert "未来秘密" not in reference and "不应传入的未选人物卡" not in reference
    assert "历史记忆中出现的人物不会因此获得本章出场权限" in reference


def test_manual_reference_excludes_failed_archive_and_current_or_future_states(client):
    chapter_id = make_story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        prior = next(item for item in chapter.book.chapters if item.index == 1)
        prior.archive_input_fingerprint = "attempted-v2"
        prior.legacy_archive_eligible = False
        prior.long_summary = "失败归档不应作为事实"
        for link in chapter.character_links:
            link.character.dynamic_fields = {"当前行动": "未来动态不得回灌"}
        db.commit()
        reference = manual_checker_reference_context(db, chapter)
        assert "失败归档不应作为事实" not in reference
        assert "未来动态不得回灌" not in reference
        assert "未来秘密" not in reference
        assert "江川是林夕的男朋友" in reference


@pytest.mark.parametrize("bible", ["", " \n\t\u3000"])
def test_empty_bible_skips_requirements_and_allows_normal_accept(client, auth_headers, wait_for_terminal, bible):
    chapter_id = make_story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.user_prompt = bible
        chapter.draft_text = "林夕与江川等雨停。" + "雨滴落下。" * 1000
        db.commit()

    class NoBibleChecker:
        def complete_json(self, *, system, user, **kwargs):
            assert "跳过是否符合本章写作要求的检查" in system
            assert "跳过“是否符合本章写作要求”这一项" in user
            assert "每个 issue 必须同时引用正文和 Bible 证据" not in user
            assert "Bible 决定本章必要事件" not in user
            assert "江川是林夕的男朋友" in user and "现代小镇" in user
            assert "林夕已经归还钥匙" in user
            assert "历史人物不会自动获得本章出场权限" in user
            return {"verdict": "passed", "issues": [], "name_uses": []}

    client.app.dependency_overrides[get_checker_client] = NoBibleChecker
    checked = client.post(
        f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers,
        json=_context_ack(client, chapter_id, auth_headers),
    )
    assert checked.status_code == 200
    assert checked.json()["checker_result"]["verdict"] == "passed"
    assert checked.json()["checker_result"]["issues"] == []
    accepted = client.post(f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers)
    assert accepted.status_code == 200, accepted.text
    wait_for_terminal(client, chapter_id, auth_headers)


def test_empty_bible_keeps_other_issues_and_acceptance_gate(client, auth_headers):
    chapter_id = make_story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.user_prompt = ""
        chapter.draft_text = "林夕施展超自然力量，让雨停下。" + "雨滴落下。" * 1000
        db.commit()
    issue = {
        "kind": "contradiction", "draft_evidence": "林夕施展超自然力量", "bible_evidence": "",
        "reason": "世界观明确为现代小镇、没有超自然力量，与正文冲突。",
        "source_kind": "world", "source_id": "world", "source_evidence": "没有超自然力量",
    }

    class ContradictionChecker:
        def complete_json(self, **kwargs):
            return {"verdict": "violation", "issues": [issue], "name_uses": []}

    client.app.dependency_overrides[get_checker_client] = ContradictionChecker
    checked = client.post(
        f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers,
        json=_context_ack(client, chapter_id, auth_headers),
    )
    assert checked.status_code == 200
    result = checked.json()["checker_result"]
    assert result["verdict"] == "violation"
    assert result["issues"][0]["kind"] == issue["kind"]
    assert result["issues"][0]["reason"] == issue["reason"]
    assert not result.get("invalid_evidence")
    refused = client.post(f"/api/v1/chapters/{chapter_id}/accept", headers=auth_headers)
    assert refused.status_code == 409
    assert refused.json()["detail"]["code"] == "checker_override_required"


def test_character_substrings_wait_for_checker_semantics(client, auth_headers):
    chapter_id = make_story()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        chapter.user_prompt = ""
        chapter.draft_text = "远客来到屋檐下。" + "雨滴落下。" * 1000
        db.commit()
    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_id)
        validate_character_preflight(db, chapter)
        violations = draft_violations(db, chapter, chapter.draft_text, "manual_edit")
    assert not [item for item in violations if item["code"] in {"unselected_character", "ambiguous_character"}]


def test_nonempty_bible_retains_requirements_and_evidence_contract():
    from app.services.context import checker_user_message
    message = checker_user_message(Chapter(title="等雨"), "正文", "两人一起回家。", reference_context="已有资料")
    assert "Bible 决定核心事件、明确禁止事项及明确指定的顺序和结尾" in message
    assert "每个 issue 必须引用正文和对应冻结来源" in message
    assert "# 程序提供的检查来源目录" in message
    assert "# 待辨别姓名局部片段" in message
    assert "跳过“是否符合本章写作要求”这一项" not in message
