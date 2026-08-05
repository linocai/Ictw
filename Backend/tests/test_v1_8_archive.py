from __future__ import annotations

import hashlib
import re

import pytest

from app.llm.factory import get_extractor_client
from app.models import Chapter, ChapterArchiveRevision, CharacterEvent
from app.services.archive_v2 import (
    ArchiveV2ValidationError,
    archive_input_fingerprint,
    segment_source,
    validate_archive_output,
)
from app.services.context import memory_candidates
from scripts.report_archive_reextract_candidates import classify_candidate


class V2Extractor:
    def __init__(
        self,
        *,
        invalid_span: bool = False,
        with_state: bool = False,
        state_location: str = "门边",
    ) -> None:
        self.invalid_span = invalid_span
        self.with_state = with_state
        self.state_location = state_location
        self.calls = 0

    def complete_json(self, *, user: str, schema: dict, **_kwargs):
        self.calls += 1
        names = schema["properties"]["facts"]["items"]["properties"]["participant_names"]["items"].get("enum", [])
        name = names[0] if names else ""
        match = re.search(r"\[(P\d{4}-S\d{2})\]", user)
        span_id = "P9999-S99" if self.invalid_span else (match.group(1) if match else "P0001-S01")
        fact_type = "状态" if self.with_state else "剧情"
        output = {
            "summary": "主角完成了本章的关键行动。",
            "facts": [{
                "fact_ref": "F1",
                "type": fact_type,
                "importance": 3,
                "text": f"{name}完成行动并停在门边。" if name else "关键行动已完成。",
                "participant_names": [name] if name else [],
                "start_id": span_id,
                "end_id": span_id,
            }],
            "end_state_delta": [],
        }
        if self.with_state and name:
            output["end_state_delta"] = [
                {"fact_ref": "F1", "character_name": name, "other_character_name": None, "scope": "snapshot", "slot": "当前位置", "operation": "set", "value": self.state_location},
                {"fact_ref": "F1", "character_name": name, "other_character_name": None, "scope": "snapshot", "slot": "当前行动", "operation": "set", "value": "等待"},
                {"fact_ref": "F1", "character_name": name, "other_character_name": None, "scope": "snapshot", "slot": "情绪状态", "operation": "set", "value": "平静"},
            ]
        return output


def _book_character_chapter(client, headers):
    book = client.post("/api/v1/books", headers=headers, json={"title": "书"}).json()
    character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=headers, json={"name": "林夕"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=headers,
        json={"user_prompt": "等待", "character_links": [{"character_id": character["id"]}]},
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=headers,
        json={"draft_text": "林夕在门边停下。随后，他安静等待。"},
    ).raise_for_status()
    return book, character, chapter


def test_source_spans_are_stable_and_sentence_addressable():
    first = segment_source("甲停下。他回头！\n\n乙离开？")
    second = segment_source("甲停下。他回头！\n\n乙离开？")
    assert first == second
    assert [item.id for item in first] == ["P0001-S01", "P0001-S02", "P0002-S01"]


def test_historical_candidate_thresholds_keep_observation_separate():
    assert classify_candidate(future_blocks=24, event_count=0, max_per_character=0) == "hard"
    assert classify_candidate(future_blocks=16, event_count=9, max_per_character=0) == "observe"
    assert classify_candidate(future_blocks=16, event_count=8, max_per_character=4) == "excluded"


def test_validator_accepts_pronoun_span_without_requiring_name_in_quote(client, auth_headers):
    _, character, chapter_data = _book_character_chapter(client, auth_headers)
    import app.routers.chapters as chapters_router

    with chapters_router.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_data["id"])
        spans = segment_source(chapter.draft_text)
        output = {
            "summary": "林夕停下后等待。",
            "facts": [{
                "fact_ref": "F1", "type": "状态", "importance": 2, "text": "林夕转为安静等待。",
                "participant_names": ["林夕"], "start_id": spans[1].id, "end_id": spans[1].id,
            }],
            "end_state_delta": [{
                "fact_ref": "F1", "character_name": "林夕", "other_character_name": None,
                "scope": "persistent", "slot": "当前目标", "operation": "set", "value": "等待",
            }],
        }
        validated = validate_archive_output(chapter, output)
        assert validated.facts[0].participant_ids == (character["id"],)

        output["facts"][0]["start_id"] = "P9999-S99"
        with pytest.raises(ArchiveV2ValidationError, match="does not exist"):
            validate_archive_output(chapter, output)


def test_invalid_v2_archive_does_not_revoke_accepted_prose_or_feed_selector(
    client, auth_headers, wait_for_terminal
):
    _, _, chapter = _book_character_chapter(client, auth_headers)
    bad = V2Extractor(invalid_span=True)
    client.app.dependency_overrides[get_extractor_client] = lambda: bad

    started = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers)
    assert started.status_code == 200
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["status"] == "finalized"
    terminal = wait_for_terminal(client, chapter["id"], auth_headers)
    assert terminal["phase"] == "failed"
    assert terminal["attempt"] == 1
    assert terminal["outcome_current"] is True
    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert current["status"] == "finalized"
    assert current["archive"]["status"] == "partial"
    assert "source span" in current["archive"]["error_message"]
    assert bad.calls == 1

    import app.routers.chapters as chapters_router

    with chapters_router.SessionLocal() as db:
        later = Chapter(book_id=current["book_id"], index=2, title="", user_prompt="", archive_status="stale")
        db.add(later)
        db.flush()
        assert {block.memory_type for block in memory_candidates(db, later)} == {"previous_ending"}


def test_complete_v2_archive_activates_once_projects_state_and_selector_uses_only_ledger(
    client, auth_headers, wait_for_terminal
):
    book, character, chapter = _book_character_chapter(client, auth_headers)
    extractor = V2Extractor(with_state=True)
    client.app.dependency_overrides[get_extractor_client] = lambda: extractor
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert current["archive"]["schema"] == "v2"
    assert current["archive"]["status"] == "complete"
    assert len(current["archive"]["facts"]) == 1
    character_read = client.get(f"/api/v1/characters/{character['id']}", headers=auth_headers).json()
    assert character_read["dynamic_fields"] == {"当前位置": "门边", "当前行动": "等待", "情绪状态": "平静"}
    assert character_read["events"][0]["source"] == "archive_v2"
    assert character_read["events"][0]["editable"] is False

    # Even if legacy compatibility columns/rows exist, a v2 chapter contributes
    # only its v2 summary and facts to Memory Selector.
    import app.routers.chapters as chapters_router

    with chapters_router.SessionLocal() as db:
        stored = db.get(Chapter, chapter["id"])
        stored.long_summary = "legacy duplicate"
        stored.atomic_memories = [{"text": "legacy duplicate fact"}]
        db.add(
            CharacterEvent(
                book_id=book["id"], character_id=character["id"], chapter_id=chapter["id"],
                event_type="行动", event_text="legacy duplicate event",
            )
        )
        later = Chapter(book_id=book["id"], index=2, title="", user_prompt="", archive_status="stale")
        db.add(later)
        db.flush()
        blocks = memory_candidates(db, later)
        assert {block.memory_type for block in blocks} == {"summary", "canonical_fact", "previous_ending"}
        assert all("legacy duplicate" not in block.text for block in blocks)


def test_editing_accepted_body_stales_v2_and_manual_retry_creates_new_revision(
    client, auth_headers, wait_for_terminal
):
    _, _, chapter = _book_character_chapter(client, auth_headers)
    extractor = V2Extractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: extractor
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    before = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    first_revision = before["archive"]["revision_id"]
    patched = client.patch(
        f"/api/v1/chapters/{chapter['id']}",
        headers=auth_headers,
        json={"draft_text": before["draft_text"] + "他继续等待。"},
    ).json()
    assert patched["status"] == "finalized"
    assert patched["archive"]["status"] == "stale"
    assert patched["archive"]["schema"] == "none"

    retried = client.post(f"/api/v1/chapters/{chapter['id']}/archive/retry", headers=auth_headers)
    assert retried.status_code == 200
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"
    after = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert after["archive"]["revision_id"] != first_revision
    assert after["archive"]["revision"] == 2

    import app.routers.chapters as chapters_router

    with chapters_router.SessionLocal() as db:
        revisions = db.query(ChapterArchiveRevision).filter_by(chapter_id=chapter["id"]).all()
        assert sum(item.is_active for item in revisions) == 1
        assert {item.status for item in revisions} == {"stale", "complete"}
        active = db.get(ChapterArchiveRevision, after["archive"]["revision_id"])
        assert archive_input_fingerprint(db.get(Chapter, chapter["id"])) == active.input_fingerprint


def test_unselected_character_state_change_does_not_stale_independent_later_archive(
    client, auth_headers, wait_for_terminal
):
    book = client.post("/api/v1/books", headers=auth_headers, json={"title": "书"}).json()
    first_character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "甲"}
    ).json()
    second_character = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=auth_headers, json={"name": "乙"}
    ).json()

    def create_and_import(character: dict, text: str) -> dict:
        chapter = client.post(
            f"/api/v1/books/{book['id']}/chapters",
            headers=auth_headers,
            json={"user_prompt": "行动", "character_links": [{"character_id": character["id"]}]},
        ).json()
        client.post(
            f"/api/v1/chapters/{chapter['id']}/import",
            headers=auth_headers,
            json={"draft_text": text},
        ).raise_for_status()
        return chapter

    first = create_and_import(first_character, "甲在北境停下。")
    client.app.dependency_overrides[get_extractor_client] = lambda: V2Extractor(
        with_state=True, state_location="北境"
    )
    client.post(f"/api/v1/chapters/{first['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, first["id"], auth_headers)["phase"] == "done"

    second = create_and_import(second_character, "乙完成自己的行动。")
    client.app.dependency_overrides[get_extractor_client] = lambda: V2Extractor()
    client.post(f"/api/v1/chapters/{second['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, second["id"], auth_headers)["phase"] == "done"
    second_revision = client.get(
        f"/api/v1/chapters/{second['id']}", headers=auth_headers
    ).json()["archive"]["revision_id"]

    client.app.dependency_overrides[get_extractor_client] = lambda: V2Extractor(
        with_state=True, state_location="南港"
    )
    client.post(f"/api/v1/chapters/{first['id']}/archive/retry", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, first["id"], auth_headers)["phase"] == "done"

    second_after = client.get(
        f"/api/v1/chapters/{second['id']}", headers=auth_headers
    ).json()
    assert second_after["archive"]["status"] == "complete"
    assert second_after["archive"]["revision_id"] == second_revision


def test_selective_reextract_requires_confirmed_report_hash_and_records_provenance(
    client, auth_headers, wait_for_terminal
):
    _, _, chapter = _book_character_chapter(client, auth_headers)
    extractor = V2Extractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: extractor
    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    mismatch = client.post(
        f"/api/v1/chapters/{chapter['id']}/archive/retry",
        headers=auth_headers,
        json={"provenance": "selective_reextract", "expected_draft_sha256": "0" * 64},
    )
    assert mismatch.status_code == 409
    assert mismatch.json()["detail"]["code"] == "archive_report_mismatch"
    assert extractor.calls == 1

    draft_hash = hashlib.sha256("林夕在门边停下。随后，他安静等待。".encode()).hexdigest()
    accepted = client.post(
        f"/api/v1/chapters/{chapter['id']}/archive/retry",
        headers=auth_headers,
        json={"provenance": "selective_reextract", "expected_draft_sha256": draft_hash},
    )
    accepted.raise_for_status()
    assert wait_for_terminal(client, chapter["id"], auth_headers)["phase"] == "done"

    import app.routers.chapters as chapters_router

    with chapters_router.SessionLocal() as db:
        latest = (
            db.query(ChapterArchiveRevision)
            .filter_by(chapter_id=chapter["id"])
            .order_by(ChapterArchiveRevision.revision.desc())
            .first()
        )
        assert latest is not None
        assert latest.provenance == "selective_reextract"
