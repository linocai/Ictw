from __future__ import annotations

import pytest

import app.db as db_module
from app.llm.factory import get_checker_client, get_memory_selector_client, get_writer_client
from app.models import Book, Chapter, ChapterCharacter, Character
from app.services.context import manual_checker_reference_context


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
        start = user.index("[chapter:") + 1
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
        }]}


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
    client.post(f"/api/v1/chapters/{chapter_id}/write", headers=auth_headers).raise_for_status()
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
    response = client.post(f"/api/v1/chapters/{chapter_id}/check", headers=auth_headers)
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
