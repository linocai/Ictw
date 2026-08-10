from __future__ import annotations

import hashlib
import re
from copy import deepcopy
from threading import Event
from types import SimpleNamespace

import pytest

from app.llm.factory import get_extractor_client
from app.agents.extractor import extractor_v2_schema
from app.models import Chapter, ChapterArchiveRevision, CharacterEvent, JobRun
from app.services.write_jobs import write_registry
from app.services.archive_v2 import (
    ArchiveFingerprintMismatch,
    ArchiveV2ValidationError,
    MAX_FACT_REF_CHARS,
    MAX_FACT_TEXT_CHARS,
    MAX_STATE_VALUE_CHARS,
    MAX_SUMMARY_CHARS,
    RECOMMENDED_FACT_SPAN_SENTENCES,
    archive_input_fingerprint,
    activate_archive_revision,
    build_archive_user_message,
    segment_source,
    validate_archive_output,
)
from app.services.context import memory_candidates
from app.services.character_state_projection import project_state_changes
from app.services.write_jobs import _log_archive_failure
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


class BlockingV2Extractor(V2Extractor):
    def __init__(self) -> None:
        super().__init__()
        self.started = Event()
        self.release = Event()

    def complete_json(self, **kwargs):
        self.started.set()
        assert self.release.wait(timeout=3)
        return super().complete_json(**kwargs)


class V2RelationshipExtractor:
    def __init__(self) -> None:
        self.calls = 0

    def complete_json(self, *, user: str, schema: dict, **_kwargs):
        self.calls += 1
        names = schema["properties"]["facts"]["items"]["properties"]["participant_names"]["items"].get("enum", [])
        match = re.search(r"\[(P\d{4}-S\d{2})\]", user)
        span_id = match.group(1) if match else "P0001-S01"
        return {
            "summary": "两人建立合作关系。",
            "facts": [{
                "fact_ref": "relation",
                "type": "关系",
                "importance": 3,
                "text": f"{names[0]}与{names[1]}建立合作关系。",
                "participant_names": names[:2],
                "start_id": span_id,
                "end_id": span_id,
            }],
            "end_state_delta": [{
                "fact_ref": "relation",
                "slot": "relationship",
                "operation": "set",
                "value": "合作",
            }],
        }


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


def _book_two_character_chapter(client, headers):
    book = client.post("/api/v1/books", headers=headers, json={"title": "书"}).json()
    first = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=headers, json={"name": "林夕"}
    ).json()
    second = client.post(
        f"/api/v1/books/{book['id']}/characters", headers=headers, json={"name": "周宁"}
    ).json()
    chapter = client.post(
        f"/api/v1/books/{book['id']}/chapters",
        headers=headers,
        json={
            "user_prompt": "合作",
            "character_links": [
                {"character_id": first["id"]},
                {"character_id": second["id"]},
            ],
        },
    ).json()
    client.post(
        f"/api/v1/chapters/{chapter['id']}/import",
        headers=headers,
        json={"draft_text": "林夕与周宁建立合作关系。"},
    ).raise_for_status()
    return book, first, second, chapter


def test_source_spans_are_stable_and_sentence_addressable():
    first = segment_source("甲停下。他回头！\n\n乙离开？")
    second = segment_source("甲停下。他回头！\n\n乙离开？")
    assert first == second
    assert [item.id for item in first] == ["P0001-S01", "P0001-S02", "P0002-S01"]


def test_v2_contract_exposes_the_span_recommendation_to_the_model():
    chapter = Chapter(book_id="book", index=1, draft_text="甲停下。乙回头。")
    prompt = build_archive_user_message(chapter, {})
    schema = extractor_v2_schema([])
    fact_schema = schema["properties"]["facts"]["items"]

    assert f"连续 {RECOMMENDED_FACT_SPAN_SENTENCES} 句以内" in prompt
    assert str(RECOMMENDED_FACT_SPAN_SENTENCES) in fact_schema["description"]
    assert "后端会机械归一化" in fact_schema["properties"]["fact_ref"]["description"]
    assert fact_schema["properties"]["fact_ref"]["maxLength"] == MAX_FACT_REF_CHARS
    assert fact_schema["properties"]["text"]["maxLength"] == MAX_FACT_TEXT_CHARS
    assert schema["properties"]["summary"]["maxLength"] == MAX_SUMMARY_CHARS
    delta_variants = schema["properties"]["end_state_delta"]["items"]["oneOf"]
    character_delta = next(
        item for item in delta_variants if "character_name" in item["properties"]
    )
    relationship_delta = next(
        item for item in delta_variants
        if item["properties"]["slot"]["enum"] == ["relationship"]
    )
    assert character_delta["properties"]["value"]["anyOf"][0]["maxLength"] == MAX_STATE_VALUE_CHARS
    assert "character_name" in character_delta["required"]
    assert "relationship" not in character_delta["properties"]["slot"]["enum"]
    assert "character_name" not in relationship_delta["properties"]
    assert "other_character_name" not in relationship_delta["properties"]
    assert "恰好两人" in relationship_delta["description"]
    assert "不要重复输出 character_name" in prompt


def test_validator_derives_relationship_pair_from_fact_and_checks_legacy_names():
    chapter = SimpleNamespace(
        draft_text="甲与乙建立合作，丙在旁见证。",
        character_links=[
            SimpleNamespace(character_id="a", character=SimpleNamespace(name="甲")),
            SimpleNamespace(character_id="b", character=SimpleNamespace(name="乙")),
            SimpleNamespace(character_id="c", character=SimpleNamespace(name="丙")),
        ],
    )
    output = {
        "summary": "甲与乙建立合作。",
        "facts": [{
            "fact_ref": "pair",
            "type": "剧情",
            "importance": 3,
            "text": "甲与乙建立合作。",
            "participant_names": ["甲", "乙"],
            "start_id": "P0001-S01",
            "end_id": "P0001-S01",
        }],
        "end_state_delta": [{
            "fact_ref": "pair",
            "slot": "relationship",
            "operation": "set",
            "value": "合作",
        }],
    }

    validated = validate_archive_output(chapter, output)
    assert {validated.deltas[0].character_id, validated.deltas[0].other_character_id} == {"a", "b"}

    legacy = deepcopy(output)
    legacy["end_state_delta"][0].update({"character_name": "乙", "other_character_name": "甲"})
    assert validate_archive_output(chapter, legacy).deltas[0] == validated.deltas[0]

    conflicting = deepcopy(output)
    conflicting["end_state_delta"][0].update({"character_name": "甲", "other_character_name": "丙"})
    with pytest.raises(ArchiveV2ValidationError, match="legacy relationship delta participants"):
        validate_archive_output(chapter, conflicting)

    ambiguous = deepcopy(output)
    ambiguous["facts"][0]["participant_names"] = ["甲", "乙", "丙"]
    with pytest.raises(ArchiveV2ValidationError, match="exactly two participants"):
        validate_archive_output(chapter, ambiguous)


def test_validator_canonicalizes_unique_model_fact_refs_and_delta_links(
    client, auth_headers
):
    _, _, chapter_data = _book_character_chapter(client, auth_headers)
    import app.routers.chapters as chapters_router

    with chapters_router.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_data["id"])
        spans = segment_source(chapter.draft_text)
        output = {
            "summary": "两件事先后发生。",
            "facts": [
                {
                    "fact_ref": "major-event",
                    "type": "剧情",
                    "importance": 3,
                    "text": "林夕停在门边。",
                    "participant_names": ["林夕"],
                    "start_id": spans[0].id,
                    "end_id": spans[0].id,
                },
                {
                    "fact_ref": "ending-state",
                    "type": "状态",
                    "importance": 2,
                    "text": "林夕章末继续等待。",
                    "participant_names": ["林夕"],
                    "start_id": spans[1].id,
                    "end_id": spans[1].id,
                },
            ],
            "end_state_delta": [{
                "fact_ref": "ending-state",
                "character_name": "林夕",
                "other_character_name": None,
                "scope": "persistent",
                "slot": "当前目标",
                "operation": "set",
                "value": "等待",
            }],
        }

        validated = validate_archive_output(chapter, output)
        assert [fact.fact_ref for fact in validated.facts] == ["F1", "F2"]
        assert validated.deltas[0].fact_ref == "F2"

        output["facts"][1]["fact_ref"] = "major-event"
        with pytest.raises(ArchiveV2ValidationError, match="duplicate fact_ref"):
            validate_archive_output(chapter, output)


def test_validator_accepts_sparse_state_from_any_fact_and_infers_scope(client, auth_headers):
    _, character, chapter_data = _book_character_chapter(client, auth_headers)
    import app.routers.chapters as chapters_router

    with chapters_router.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_data["id"])
        span = segment_source(chapter.draft_text)[0].id
        output = {
            "summary": "林夕完成决定并停下。",
            "facts": [{
                "fact_ref": "decision",
                "type": "决定",
                "importance": 3,
                "text": "林夕决定停在门边。",
                "participant_names": ["林夕"],
                "start_id": span,
                "end_id": span,
            }],
            "end_state_delta": [{
                "fact_ref": "decision",
                "character_name": "林夕",
                "slot": "当前位置",
                "operation": "set",
                "value": "门边",
            }],
        }

        validated = validate_archive_output(chapter, output)
        assert len(validated.deltas) == 1
        assert validated.deltas[0].character_id == character["id"]
        assert validated.deltas[0].scope == "snapshot"
        assert validated.deltas[0].slot == "当前位置"

        # Older/in-flight payloads may still contain a mismatched scope or a
        # redundant selected name.  Slot is authoritative and both are safely
        # ignored for non-relationship state.
        output["end_state_delta"][0]["scope"] = "relationship"
        output["end_state_delta"][0]["other_character_name"] = "林夕"
        assert validate_archive_output(chapter, output).deltas[0].scope == "snapshot"


def test_sparse_v2_snapshot_preserves_unchanged_volatile_slots():
    character = SimpleNamespace(id="character", name="林夕")

    def delta(row_id: str, batch_id: str, slot: str, value: str):
        return SimpleNamespace(
            id=row_id,
            character_id=character.id,
            other_character_id=None,
            scope="snapshot",
            slot=slot,
            operation="set",
            value=value,
            batch_id=batch_id,
        )

    changes = [
        delta("d1", "revision-1", "当前位置", "门边"),
        delta("d2", "revision-1", "当前行动", "等待"),
        delta("d3", "revision-1", "情绪状态", "平静"),
        delta("d4", "revision-2", "当前位置", "窗边"),
    ]

    fields, _ = project_state_changes(changes, [character])
    assert fields[character.id] == {
        "当前位置": "窗边",
        "当前行动": "等待",
        "情绪状态": "平静",
    }


def test_validator_accepts_long_continuous_span_but_rejects_reversed_span():
    chapter = Chapter(book_id="book", index=1, draft_text="甲。乙。丙。丁。戊。")
    output = {
        "summary": "连续事件。",
        "facts": [{
            "fact_ref": "local-ref",
            "type": "剧情",
            "importance": 3,
            "text": "连续事件发生。",
            "participant_names": [],
            "start_id": "P0001-S01",
            "end_id": "P0001-S04",
        }],
        "end_state_delta": [],
    }

    assert validate_archive_output(chapter, output).facts[0].fact_ref == "F1"
    output["facts"][0]["end_id"] = "P0001-S05"
    assert validate_archive_output(chapter, output).facts[0].end_id == "P0001-S05"
    output["facts"][0]["start_id"] = "P0001-S05"
    output["facts"][0]["end_id"] = "P0001-S01"
    with pytest.raises(ArchiveV2ValidationError, match="reversed"):
        validate_archive_output(chapter, output)


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


def test_reopen_cancels_live_extractor_and_late_result_cannot_activate(client, auth_headers):
    _, _, chapter = _book_character_chapter(client, auth_headers)
    extractor = BlockingV2Extractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: extractor

    accepted = client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).json()
    assert accepted["phase"] == "extracting"
    assert extractor.started.wait(timeout=3)

    reopened = client.post(f"/api/v1/chapters/{chapter['id']}/reopen", headers=auth_headers)
    assert reopened.status_code == 200
    assert reopened.json()["status"] == "draft_ready"
    extractor.release.set()
    job = write_registry.get(chapter["id"])
    if job is not None and job.thread is not None:
        job.thread.join(timeout=3)

    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    status = client.get(f"/api/v1/chapters/{chapter['id']}/job", headers=auth_headers).json()
    assert current["status"] == "draft_ready"
    assert current["archive"]["status"] == "stale"
    assert status["phase"] == "cancelled"
    assert status["error_code"] == "archive_reopened"
    with __import__("app.db", fromlist=["SessionLocal"]).SessionLocal() as db:
        run = db.get(JobRun, accepted["job_id"])
        revision = db.get(ChapterArchiveRevision, run.archive_revision_id)
        assert revision.status == "stale"
        assert not revision.is_active
        assert run.phase == "cancelled"


def test_activation_lifecycle_gate_stales_reopened_revision(client, auth_headers):
    _, _, chapter_data = _book_character_chapter(client, auth_headers)
    import app.db as db_module

    with db_module.SessionLocal() as db:
        chapter = db.get(Chapter, chapter_data["id"])
        revision = ChapterArchiveRevision(
            chapter_id=chapter.id,
            revision=1,
            provenance="live",
            input_fingerprint=archive_input_fingerprint(chapter),
            status="extracting",
        )
        db.add(revision)
        chapter.status = "draft_ready"
        db.commit()
        with pytest.raises(ArchiveFingerprintMismatch):
            activate_archive_revision(
                db, chapter, revision, SimpleNamespace(), model_name=None
            )
        db.commit()
        db.expire_all()
        stored = db.get(ChapterArchiveRevision, revision.id)
        assert stored.status == "stale"
        assert not stored.is_active


def test_archive_failure_log_is_structured_and_redacted(monkeypatch):
    job = SimpleNamespace(
        chapter_id="chapter-id",
        job_id="job-id",
        archive_revision_id="revision-id",
    )
    accepted_prose = "这段正文绝不能进入日志。"
    captured: list[str] = []
    monkeypatch.setattr(
        "app.services.write_jobs.logger.warning",
        lambda template, rendered: captured.append(template % rendered),
    )
    _log_archive_failure(
        job,
        stage="archive_validation",
        error_code="archive_validation_failed",
        reason="fact source span does not exist",
        client=SimpleNamespace(model_name="deepseek-v4-pro"),
    )

    failure_log = captured[0]
    assert '"error_code": "archive_validation_failed"' in failure_log
    assert '"stage": "archive_validation"' in failure_log
    assert '"model_name": "deepseek-v4-pro"' in failure_log
    assert accepted_prose not in failure_log


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


def test_relationship_delta_activates_with_pair_derived_from_fact(
    client, auth_headers, wait_for_terminal
):
    _, first, second, chapter = _book_two_character_chapter(client, auth_headers)
    extractor = V2RelationshipExtractor()
    client.app.dependency_overrides[get_extractor_client] = lambda: extractor

    client.post(f"/api/v1/chapters/{chapter['id']}/accept", headers=auth_headers).raise_for_status()
    terminal = wait_for_terminal(client, chapter["id"], auth_headers)
    assert terminal["phase"] == "done", {
        key: terminal.get(key)
        for key in ("phase", "error_code", "error_message", "error_context")
    }
    assert extractor.calls == 1
    assert set(terminal["updated_character_ids"]) == {first["id"], second["id"]}

    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert current["archive"]["status"] == "complete"
    assert current["archive"]["state_delta_count"] == 1


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
