"""Build70 actual SSE/Writer and committed input-invalidation regressions."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
from threading import Event

import httpx
import pytest
from sqlalchemy import select

import app.db as db_module
import app.routers.books as books_routes
import app.routers.characters as characters_routes
import app.routers.chapters as chapters_routes
from app.llm.base import LLMError, LLMStreamIncompleteError
from app.llm.factory import get_checker_client, get_writer_client
from app.llm.openai_compatible import OpenAICompatibleClient
from app.models import Chapter, ChapterDraftCandidate, JobRun
from app.services.write_jobs import WriteJob, write_registry
from app.services.write_ownership import InvalidatedWriterJob, cancel_local_writer_jobs, invalidate_writer_inputs
from conftest import FakeChecker, FakeWriter


HALF_SENTENCE = "雨" * 4211 + "她正要"
COMPLETE_DRAFT = "新" * 4213 + "。"


def _stream_lines(text=COMPLETE_DRAFT, finish=None, done=False, usage=True):
    yield "data: " + json.dumps({"choices": [{"delta": {"content": text}, "finish_reason": None}]})
    if finish is not None:
        yield "data: " + json.dumps({"choices": [{"delta": {}, "finish_reason": finish}]})
    if usage:
        yield "data: " + json.dumps({"choices": [], "usage": {"total_tokens": 17}})
    if done:
        yield "data: [DONE]"


def _install_streams(monkeypatch, replies):
    calls = []

    class Response:
        status_code = 200

        def __init__(self, reply):
            self.reply = reply

        def iter_lines(self):
            if isinstance(self.reply, Exception):
                raise self.reply
            yield from self.reply() if callable(self.reply) else self.reply

    @contextmanager
    def stream(_method, _url, **kwargs):
        calls.append(kwargs["json"])
        reply = replies[min(len(calls) - 1, len(replies) - 1)]
        yield Response(reply)

    monkeypatch.setattr(httpx, "stream", stream)
    return calls


def _llm():
    return OpenAICompatibleClient(base_url="https://synthetic.invalid/v1",
                                  api_key="synthetic-memory-only", model_name="synthetic-writer")


@pytest.mark.parametrize("finish,done", [("stop", False), ("end_turn", False),
                                        ("completed", False), ("complete", False), (None, True)])
def test_stream_accepts_only_real_completion_proofs(monkeypatch, finish, done):
    _install_streams(monkeypatch, [lambda: _stream_lines(finish=finish, done=done)])
    llm = _llm()
    assert "".join(llm.complete_stream(system="合成", user="输入")) == COMPLETE_DRAFT
    assert llm.last_finish_reason == finish  # DONE never invents a stop reason.
    assert llm.last_usage["total_tokens"] == 17


def test_stream_unmarked_eof_has_no_invented_finish_reason(monkeypatch):
    _install_streams(monkeypatch, [lambda: _stream_lines(HALF_SENTENCE)])
    llm = _llm()
    with pytest.raises(LLMStreamIncompleteError) as caught:
        list(llm.complete_stream(system="合成", user="输入"))
    assert caught.value.code == "llm_output_truncated" and caught.value.retryable
    assert llm.last_finish_reason is None and caught.value.finish_reason is None


@pytest.mark.parametrize("tail_stop", [False, True])
def test_length_cannot_be_washed_by_stop_or_done(monkeypatch, tail_stop):
    def lines():
        yield from _stream_lines(HALF_SENTENCE, finish="length", usage=False)
        if tail_stop:
            yield 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}'
        yield 'data: {"choices":[],"usage":{"total_tokens":19}}'
        yield "data: [DONE]"

    _install_streams(monkeypatch, [lines])
    llm = _llm()
    assert "".join(llm.complete_stream(system="合成", user="输入")) == HALF_SENTENCE
    assert llm.last_finish_reason == "length" and llm.last_usage["total_tokens"] == 19


@pytest.mark.parametrize("finish,code", [("content_filter", "llm_content_blocked"),
                                        ("safety", "llm_content_blocked"),
                                        ("tool_calls", "llm_invalid_finish"),
                                        ("function_call", "llm_invalid_finish")])
def test_non_prose_terminal_reason_is_not_success(monkeypatch, finish, code):
    _install_streams(monkeypatch, [lambda: _stream_lines(finish=finish, done=True)])
    llm = _llm()
    with pytest.raises(LLMError) as caught:
        list(llm.complete_stream(system="合成", user="输入"))
    assert caught.value.code == code and caught.value.finish_reason == finish
    assert not caught.value.retryable and llm.last_finish_reason == finish


def test_stream_prompt_block_transport_and_cancel_keep_distinct_classification(monkeypatch):
    _install_streams(monkeypatch, [[
        'data: {"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"},"choices":[]}',
        "data: [DONE]",
    ]])
    with pytest.raises(LLMError) as blocked:
        list(_llm().complete_stream(system="合成", user="输入"))
    assert blocked.value.code == "llm_content_blocked" and blocked.value.block_reason == "PROHIBITED_CONTENT"
    _install_streams(monkeypatch, [httpx.ReadError("synthetic transport failure")])
    with pytest.raises(LLMError) as transport:
        list(_llm().complete_stream(system="合成", user="输入"))
    assert transport.value.code == "llm_transport" and not isinstance(transport.value, LLMStreamIncompleteError)
    cancelled = Event()

    def cancelling_lines():
        yield from _stream_lines(HALF_SENTENCE, usage=False)
        cancelled.set()

    _install_streams(monkeypatch, [cancelling_lines])
    llm = _llm()
    assert "".join(llm.complete_stream(system="合成", user="输入", cancel_event=cancelled)) == HALF_SENTENCE
    assert cancelled.is_set() and llm.last_finish_reason is None


@pytest.mark.parametrize("reason,blocked", [("STOP", False), ("MAX_TOKENS", False), ("SAFETY", True)])
def test_provider_candidate_tail_reason_is_checked_before_empty_choices(monkeypatch, reason, blocked):
    def lines():
        yield from _stream_lines(usage=False)
        yield "data: " + json.dumps({"choices": [], "candidates": [{"finishReason": reason}]})
        yield "data: [DONE]"

    _install_streams(monkeypatch, [lines])
    llm = _llm()
    if blocked:
        with pytest.raises(LLMError) as caught:
            list(llm.complete_stream(system="合成", user="输入"))
        assert caught.value.code == "llm_content_blocked" and caught.value.finish_reason == "safety"
    else:
        assert "".join(llm.complete_stream(system="合成", user="输入")) == COMPLETE_DRAFT
        assert llm.last_finish_reason == ("stop" if reason == "STOP" else "length")


@pytest.mark.parametrize("value", ["RECITATION", "NON_NORMAL_TERMINAL", "", 17, False])
@pytest.mark.parametrize("native", [False, True])
def test_explicit_unmapped_finish_is_not_equivalent_to_absent_finish(monkeypatch, value, native):
    def lines():
        yield from _stream_lines(HALF_SENTENCE, usage=False)
        tail = {"choices": [], "candidates": [{"finishReason": value}]} if native else {
            "choices": [{"delta": {}, "finish_reason": value}]}
        yield "data: " + json.dumps(tail)
        yield "data: [DONE]"

    _install_streams(monkeypatch, [lines])
    with pytest.raises(LLMError) as caught:
        list(_llm().complete_stream(system="合成", user="输入"))
    assert caught.value.code == "llm_invalid_finish" and not caught.value.retryable
    assert caught.value.finish_reason == "other"


@pytest.mark.parametrize("field", [None, "finish_reason", "finishReason"])
def test_done_accepts_absent_or_null_pending_finish(monkeypatch, field):
    choice = {"delta": {"content": COMPLETE_DRAFT}}
    if field is not None:
        choice[field] = None
    _install_streams(monkeypatch, [["data: " + json.dumps({"choices": [choice]}), "data: [DONE]"]])
    llm = _llm()
    assert "".join(llm.complete_stream(system="合成", user="输入")) == COMPLETE_DRAFT
    assert llm.last_finish_reason is None


@pytest.mark.parametrize("field", ["tool_calls", "function_call"])
def test_done_after_non_text_tool_delta_is_not_legal_completion(monkeypatch, field):
    def lines():
        yield from _stream_lines(usage=False)
        yield "data: " + json.dumps({"choices": [{"delta": {field: {"name": "synthetic_tool"}}}]})
        yield "data: [DONE]"

    _install_streams(monkeypatch, [lines])
    with pytest.raises(LLMError) as caught:
        list(_llm().complete_stream(system="合成", user="输入"))
    assert caught.value.code == "llm_invalid_finish" and caught.value.finish_reason is None


class CountingChecker(FakeChecker):
    def __init__(self):
        self.calls = 0

    def complete_json(self, **kwargs):
        self.calls += 1
        return super().complete_json(**kwargs)


def _manuscript(client, headers, *, selected=False):
    book = client.post("/api/v1/books", headers=headers, json={"title": "合成书", "world_setting": "虚构世界"}).json()
    character = client.post(f"/api/v1/books/{book['id']}/characters", headers=headers, json={"name": "合成人物"}).json()
    chapter = client.post(f"/api/v1/books/{book['id']}/chapters", headers=headers,
                          json={"character_links": [{"character_id": character["id"]}]} if selected else {}).json()
    imported = client.post(f"/api/v1/chapters/{chapter['id']}/import", headers=headers,
                           json={"draft_text": "合成原稿。"})
    imported.raise_for_status()
    return book, character, imported.json()


@pytest.mark.parametrize("first,second,expected,calls,checks,error", [
    ("eof", "eof", "failed", 2, 0, "llm_output_truncated"),
    ("eof", "stop", "done", 2, 1, None),
    ("length", "length", "failed", 2, 0, "writer_minimum_failed"),
    ("length", "eof", "failed", 2, 0, "llm_output_truncated"),
    ("eof", "length", "failed", 2, 0, "writer_minimum_failed"),
    ("stop", None, "done", 1, 1, None),
    ("done", None, "done", 1, 1, None),
    ("content_filter", None, "failed", 1, 0, "llm_content_blocked"),
    ("tool_calls", None, "failed", 1, 0, "llm_invalid_finish"),
    ("transport", None, "failed", 1, 0, "llm_transport"),
    ("native-other", None, "failed", 1, 0, "llm_invalid_finish"),
    ("unknown-choice", None, "failed", 1, 0, "llm_invalid_finish"),
    ("unknown-camel", None, "failed", 1, 0, "llm_invalid_finish"),
])
def test_actual_sse_writer_shares_exact_two_attempt_budget(
    client, auth_headers, wait_for_terminal, monkeypatch, first, second, expected, calls, checks, error,
):
    _, _, chapter = _manuscript(client, auth_headers)

    def reply(kind):
        if kind == "transport":
            return httpx.ReadError("synthetic transport failure")
        if kind in {"native-other", "unknown-choice", "unknown-camel"}:
            def unknown_terminal():
                yield from _stream_lines(HALF_SENTENCE, usage=False)
                if kind == "native-other":
                    tail = {"choices": [], "candidates": [{"finishReason": "RECITATION"}]}
                else:
                    key = "finish_reason" if kind == "unknown-choice" else "finishReason"
                    tail = {"choices": [{"delta": {}, key: "NON_NORMAL_TERMINAL"}]}
                yield "data: " + json.dumps(tail)
                yield "data: [DONE]"
            return unknown_terminal
        return lambda: _stream_lines(HALF_SENTENCE if kind in {"eof", "length"} else COMPLETE_DRAFT,
                                     finish=None if kind in {"eof", "done"} else kind,
                                     done=kind in {"done", "length", "content_filter", "tool_calls"})

    requests = _install_streams(monkeypatch, [reply(first)] + ([reply(second)] if second else []))
    llm, checker = _llm(), CountingChecker()
    client.app.dependency_overrides[get_writer_client] = lambda: llm
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    start = client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers)
    start.raise_for_status()
    status = wait_for_terminal(client, chapter["id"], auth_headers)
    job = write_registry.get(chapter["id"])
    job.thread.join(5)
    assert not job.thread.is_alive()
    assert status["phase"] == expected and len(requests) == calls and checker.calls == checks
    if calls == 2:
        assert requests[0]["messages"] == requests[1]["messages"]
    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert current["draft_text"] == (COMPLETE_DRAFT if expected == "done" else chapter["draft_text"])
    with db_module.SessionLocal() as db:
        run = db.get(JobRun, start.json()["job_id"])
        assert run.attempt == calls and run.error_code == error
        if first in {"native-other", "unknown-choice", "unknown-camel"}:
            assert run.error_context["finish_reason"] == "other"
        candidates = db.scalars(select(ChapterDraftCandidate).where(ChapterDraftCandidate.job_id == run.id)).all()
        assert sum(item.is_current for item in candidates) == (1 if expected == "done" else 0)
        if expected == "done" and first == "eof":
            assert [(item.attempt, item.draft_text) for item in candidates] == [(2, COMPLETE_DRAFT)]


def test_cancelled_sse_eof_does_not_rewrite_or_check(client, auth_headers, monkeypatch):
    _, _, chapter = _manuscript(client, auth_headers)
    entered = Event()

    def lines():
        yield from _stream_lines(HALF_SENTENCE, usage=False)
        entered.set()
        assert write_registry.get(chapter["id"]).cancel_event.wait(5)

    requests = _install_streams(monkeypatch, [lines])
    checker = CountingChecker()
    client.app.dependency_overrides[get_writer_client] = _llm
    client.app.dependency_overrides[get_checker_client] = lambda: checker
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert entered.wait(5)
    result = client.post(f"/api/v1/chapters/{chapter['id']}/write/cancel", headers=auth_headers)
    result.raise_for_status()
    job = write_registry.get(chapter["id"])
    job.thread.join(5)
    assert not job.thread.is_alive() and job.cancel_event.is_set()
    assert len(requests) == 1 and checker.calls == 0 and result.json()["draft_text"] == chapter["draft_text"]
    with db_module.SessionLocal() as db:
        assert db.get(JobRun, job.job_id).phase == "cancelled"


class BlockedWriter(FakeWriter):
    def __init__(self, text):
        super().__init__(text)
        self.entered, self.release = Event(), Event()
        self.calls = 0

    def complete_stream(self, **kwargs):
        self.calls += 1
        self.entered.set()
        assert self.release.wait(8)
        kwargs["cancel_event"] = None  # A provider may return despite cancellation.
        yield from super().complete_stream(**kwargs)


@pytest.mark.parametrize("route", ["book", "character", "delete-character", "patch-chapter", "import-chapter", "reopen"])
@pytest.mark.parametrize("has_old_writer", [False, True])
def test_actual_input_edit_postcommit_cancels_only_frozen_writer(
    client, auth_headers, wait_for_terminal, monkeypatch, route, has_old_writer,
):
    book, character, chapter = _manuscript(client, auth_headers, selected=True)
    cid = chapter["id"]
    old_llm, new_llm = BlockedWriter("旧" * 4000), BlockedWriter("新" * 4000)
    old = new = None
    entered, release = Event(), Event()
    frozen = []
    if has_old_writer:
        client.app.dependency_overrides[get_writer_client] = lambda: old_llm
        client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers).raise_for_status()
        assert old_llm.entered.wait(5)
        old = write_registry.get(cid)

    def blocked_cancel(proofs):
        frozen.extend(proofs)
        entered.set()
        assert release.wait(8)
        cancel_local_writer_jobs(proofs)

    def blocked_chapter_cancel(chapter_id, job_ids):
        blocked_cancel([InvalidatedWriterJob(chapter_id, job_id) for job_id in job_ids])

    module = books_routes if route == "book" else characters_routes if route in {"character", "delete-character"} else chapters_routes
    monkeypatch.setattr(module, "_cancel_local_job_ids" if module is chapters_routes else "cancel_local_writer_jobs",
                        blocked_chapter_cancel if module is chapters_routes else blocked_cancel)

    def mutate():
        if route == "book":
            return client.patch(f"/api/v1/books/{book['id']}", headers=auth_headers, json={"world_setting": "新虚构世界"})
        if route == "character":
            return client.patch(f"/api/v1/characters/{character['id']}", headers=auth_headers, json={"fixed_profile": "新的虚构经历"})
        if route == "delete-character":
            return client.delete(f"/api/v1/characters/{character['id']}", headers=auth_headers)
        if route == "patch-chapter":
            return client.patch(f"/api/v1/chapters/{cid}", headers=auth_headers, json={"title": "新章节名"})
        if route == "import-chapter":
            return client.post(f"/api/v1/chapters/{cid}/import", headers=auth_headers, json={"draft_text": "新导入原稿。"})
        return client.post(f"/api/v1/chapters/{cid}/reopen", headers=auth_headers)

    try:
        with ThreadPoolExecutor(max_workers=1) as pool:
            editing = pool.submit(mutate)
            try:
                assert entered.wait(5)
                assert [item.job_id for item in frozen] == ([old.job_id] if old else [])
                with db_module.SessionLocal() as db:
                    if old:
                        assert db.get(JobRun, old.job_id).phase == "cancelled"
                    committed_generation = db.get(Chapter, cid).write_generation
                client.app.dependency_overrides[get_writer_client] = lambda: new_llm
                started = client.post(f"/api/v1/chapters/{cid}/write", headers=auth_headers,
                                      json={"replace_draft": True})
                started.raise_for_status()
                assert new_llm.entered.wait(5)
                new = write_registry.get(cid)
                assert new.job_id not in {item.job_id for item in frozen}
                assert new.chapter_write_generation >= committed_generation
            finally:
                release.set()
            editing.result(5).raise_for_status()
        assert not new.cancel_event.is_set() and write_registry.get_live(cid) is new
        with db_module.SessionLocal() as db:
            assert db.get(JobRun, new.job_id).phase == "writing"
        if old:
            assert old.cancel_event.is_set()
            old_llm.release.set()
            old.thread.join(5)
            assert not old.thread.is_alive()
        new_llm.release.set()
        assert wait_for_terminal(client, cid, auth_headers)["phase"] == "done"
    finally:
        release.set()
        old_llm.release.set()
        new_llm.release.set()
        for job in (old, new):
            if job and job.thread:
                job.thread.join(5)


@pytest.mark.parametrize("kind", ["check", "extract"])
def test_input_invalidation_does_not_mark_or_cancel_other_task_kinds(client, auth_headers, kind):
    _, _, chapter = _manuscript(client, auth_headers)
    with db_module.SessionLocal() as db:
        row = db.get(Chapter, chapter["id"])
        run = JobRun(chapter_id=row.id, kind=kind, phase="checking" if kind == "check" else "extracting")
        db.add(run)
        db.commit()
        job = WriteJob(row.id, job_id=run.id, kind=kind)
        write_registry.reserve(job)
        proofs = invalidate_writer_inputs(db, [row])
        db.commit()
        cancel_local_writer_jobs(proofs)
        assert proofs == [] and not job.cancel_event.is_set()
        db.refresh(run)
        assert run.phase == ("checking" if kind == "check" else "extracting")
        job.mark_terminal("done")


@pytest.mark.parametrize("late_registration", [False, True])
@pytest.mark.parametrize("inputs_changed", [False, True])
def test_committed_writer_deferred_registration_respects_exact_invalidation(
    client, auth_headers, monkeypatch, late_registration, inputs_changed,
):
    book, _, chapter = _manuscript(client, auth_headers)
    llm = BlockedWriter("旧" * 4000)
    llm.release.set()
    client.app.dependency_overrides[get_writer_client] = lambda: llm
    delayed = []
    original_launch = write_registry.launch
    monkeypatch.setattr(write_registry, "launch", lambda job, sf: delayed.append((job, sf)))
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    job, session_factory = delayed[0]
    if late_registration:
        write_registry.clear()  # Its durable row exists before this process registers it.
    if inputs_changed:
        client.patch(f"/api/v1/books/{book['id']}", headers=auth_headers,
                     json={"world_setting": "新虚构世界"}).raise_for_status()
    if late_registration:
        write_registry.reserve(job)
    original_launch(job, session_factory)
    job.thread.join(5)
    assert not job.thread.is_alive() and llm.calls == (0 if inputs_changed else 1)
    current = client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()
    assert current["draft_text"] == (chapter["draft_text"] if inputs_changed else "旧" * 4000)
    assert current["status"] == "draft_ready"
    with db_module.SessionLocal() as db:
        assert db.get(JobRun, job.job_id).phase == ("cancelled" if inputs_changed else "done")


def test_frozen_writer_is_cancelled_when_no_replacement_is_started(client, auth_headers):
    book, _, chapter = _manuscript(client, auth_headers)
    llm = BlockedWriter("旧" * 4000)
    client.app.dependency_overrides[get_writer_client] = lambda: llm
    client.post(f"/api/v1/chapters/{chapter['id']}/write", headers=auth_headers).raise_for_status()
    assert llm.entered.wait(5)
    job = write_registry.get(chapter["id"])
    try:
        client.patch(f"/api/v1/books/{book['id']}", headers=auth_headers,
                     json={"world_setting": "新虚构世界"}).raise_for_status()
        assert job.cancel_event.is_set() and job.discard_on_cancel
    finally:
        llm.release.set()
        job.thread.join(5)
    assert not job.thread.is_alive()
    assert client.get(f"/api/v1/chapters/{chapter['id']}", headers=auth_headers).json()["draft_text"] == chapter["draft_text"]
