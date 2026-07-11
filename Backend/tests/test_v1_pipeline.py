from __future__ import annotations

import pytest
from sqlalchemy.orm import Session

from app.agents.extractor import extractor_schema
from app.agents.memory_selector import MemorySelectorAgent
from app.db import Base, make_engine
from app.llm.base import LLMError
from app.llm.openai_compatible import OpenAICompatibleClient, _extract_content, _http_error
from app.models import Book, Chapter
from app.services.context import MemoryBlock, pack_selected_memories, prefilter_memory_candidates
from app.services.write_jobs import WriteJob, _restore_baseline, write_registry


def test_memory_selection_skips_unknown_id_and_accepts_empty():
    blocks = [MemoryBlock("known", "记忆", 1)]
    assert pack_selected_memories(blocks, [], 600) == []
    # Unknown / empty-text selections degrade to "fewer memories", never a failure.
    assert pack_selected_memories(blocks, ["future-or-other-book", "known"], 600) == blocks
    assert pack_selected_memories([MemoryBlock("empty", "  \n", 1)], ["empty"], 600) == []


def test_memory_selection_salvages_unambiguous_truncated_chapter_id():
    summary_only = MemoryBlock("chapter:abc:summary", "第 3 章梗概：内容", 3, memory_type="summary")
    both_a = MemoryBlock("chapter:xyz:summary", "第 5 章梗概：内容", 5, memory_type="summary")
    both_b = MemoryBlock("chapter:xyz:headline", "第 5 章大事记：内容", 5, memory_type="headline")
    blocks = [summary_only, both_a, both_b]
    # Unique prefix match is recovered; whitespace is tolerated.
    assert pack_selected_memories(blocks, [" chapter:abc "], 600) == [summary_only]
    # Ambiguous prefix (both summary and headline exist) is dropped, not guessed.
    assert pack_selected_memories(blocks, ["chapter:xyz"], 600) == []
    # A salvaged id must not double-pack with its explicit form.
    assert pack_selected_memories(blocks, ["chapter:abc", "chapter:abc:summary"], 600) == [summary_only]


def test_extractor_schema_for_no_characters_forces_empty_arrays():
    schema = extractor_schema([])
    assert schema["properties"]["character_events"]["maxItems"] == 0
    assert schema["properties"]["dynamic_fields_patch"]["maxItems"] == 0


def test_thinking_request_snapshots_and_unknown_sends_nothing():
    deepseek = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="deepseek-v4-pro",
        thinking_enabled=True,
        reasoning_effort="high",
        capability_family="deepseek_v4",
    )
    payload = deepseek._payload(system="s", user="u", stream=False, temperature=0.7)
    assert payload["thinking"] == {"type": "enabled"}
    assert payload["reasoning_effort"] == "high"
    assert "temperature" not in payload

    gemini = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="gemini-3.5-flash",
        thinking_enabled=True,
        reasoning_effort="minimal",
        capability_family="gemini_3_5_flash",
    )
    gemini_payload = gemini._payload(system="s", user="u", stream=False, temperature=0.7)
    assert gemini_payload["reasoning_effort"] == "minimal"
    assert "temperature" not in gemini_payload

    unknown = OpenAICompatibleClient(
        base_url="https://example.invalid/v1",
        api_key="secret",
        model_name="custom",
        thinking_enabled=True,
        reasoning_effort="high",
        capability_family="unknown",
    )
    unknown_payload = unknown._payload(system="s", user="u", stream=False)
    assert "thinking" not in unknown_payload and "reasoning_effort" not in unknown_payload


def test_gemini_200_block_and_empty_candidate_are_classified():
    with pytest.raises(LLMError) as blocked:
        _extract_content({"promptFeedback": {"blockReason": "PROHIBITED_CONTENT"}, "choices": []})
    assert blocked.value.code == "llm_content_blocked"
    assert blocked.value.block_reason == "PROHIBITED_CONTENT"

    with pytest.raises(LLMError) as empty:
        _extract_content({"choices": [], "candidates": []})
    assert empty.value.code == "llm_empty_candidate"


def test_rate_limit_preserves_retry_after():
    error = _http_error(429, {"Retry-After": "17"})
    assert error.code == "llm_rate_limited"
    assert error.retryable is True
    assert error.status_code == 429
    assert error.retry_after == "17"


def test_provider_reasons_are_preserved_without_exposing_body():
    error = _http_error(
        503,
        {},
        b'{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"},'
        b'"candidates":[{"finishReason":"SAFETY"}]}',
    )
    assert error.finish_reason == "SAFETY"
    assert error.block_reason == "PROHIBITED_CONTENT"
    assert "PROHIBITED_CONTENT" not in str(error)


def test_stale_cancelled_job_cannot_restore_over_replacement(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'stale-job.db'}")
    Base.metadata.create_all(engine)
    with Session(engine) as db:
        book = Book(id="book", title="书")
        chapter = Chapter(id="chapter", book_id="book", index=1, draft_text="新任务最终稿")
        db.add_all([book, chapter])
        db.commit()

        stale = WriteJob(
            "chapter",
            writer=None,  # type: ignore[arg-type]
            baseline_text="旧草稿",
            baseline_status="draft_ready",
        )
        replacement = WriteJob("chapter", writer=None)  # type: ignore[arg-type]
        write_registry.clear()
        write_registry.reserve(stale)
        stale.phase = "cancelled"
        write_registry.reserve(replacement)

        _restore_baseline(db, stale)
        db.expire_all()
        assert db.get(Chapter, "chapter").draft_text == "新任务最终稿"
    write_registry.clear()


def test_memory_prefilter_is_deterministic_and_prioritizes_selected_character():
    chapter = Chapter(title="城门行动", user_prompt="进入城门", author_note="保持安静")
    blocks = [MemoryBlock(f"block-{index:03d}", f"普通记忆 {index}", index) for index in range(301)]
    selected = MemoryBlock("selected", "人物关键记忆", 1, character_id="character")
    blocks.append(selected)
    first = prefilter_memory_candidates(blocks, chapter=chapter, selected_character_ids={"character"})
    second = prefilter_memory_candidates(blocks, chapter=chapter, selected_character_ids={"character"})
    assert [item.id for item in first] == [item.id for item in second]
    assert first[0].id == "selected"
    assert len(first) <= 300


def test_memory_selector_retries_one_retryable_failure_only():
    class RetryOnceLLM:
        def __init__(self):
            self.calls = 0

        def complete_json(self, **kwargs):
            self.calls += 1
            if self.calls == 1:
                raise LLMError("rate limited", code="llm_rate_limited", retryable=True, status_code=429)
            return {"memory_ids": []}

    llm = RetryOnceLLM()
    assert MemorySelectorAgent(llm, "selector").select("input") == []  # type: ignore[arg-type]
    assert llm.calls == 2


def test_memory_selector_tolerates_malformed_id_payload_shapes():
    class ShapedLLM:
        def __init__(self, payload):
            self.payload = payload

        def complete_json(self, **kwargs):
            return self.payload

    # Mixed non-string items are filtered, not fatal.
    agent = MemorySelectorAgent(ShapedLLM({"memory_ids": ["chapter:x:headline", 123, None]}), "selector")  # type: ignore[arg-type]
    assert agent.select("input") == ["chapter:x:headline"]
    # A bare string is salvaged as a single-item selection.
    agent = MemorySelectorAgent(ShapedLLM({"memory_ids": "chapter:x:headline"}), "selector")  # type: ignore[arg-type]
    assert agent.select("input") == ["chapter:x:headline"]
    # Anything else degrades to the legal empty selection.
    agent = MemorySelectorAgent(ShapedLLM({"memory_ids": {"a": 1}}), "selector")  # type: ignore[arg-type]
    assert agent.select("input") == []
    agent = MemorySelectorAgent(ShapedLLM({}), "selector")  # type: ignore[arg-type]
    assert agent.select("input") == []
