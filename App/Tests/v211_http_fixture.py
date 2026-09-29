#!/usr/bin/env python3
"""Local-only synthetic API for the real Swift stores; no production imports."""
import argparse
import copy
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOCK = threading.RLock()
STATE = {}
GATES = {}


def pause_at(name):
    """Freeze a captured response until the test explicitly releases it."""
    if not name:
        return
    gate = GATES.setdefault(name, threading.Event())
    LOCK.release()
    try:
        if not gate.wait(8):
            raise TimeoutError("synthetic response gate was not released")
    finally:
        LOCK.acquire()


def reset(options):
    for gate in GATES.values():
        gate.set()
    GATES.clear()
    prefix = options.pop("prefix")
    book = dict(id=prefix + "-book", title="隔离回归书", world_setting="虚构世界",
                updated_at="2026-09-20T00:00:00", content_revision=7)
    chapters = {}
    for index in (1, 2):
        cid = f"{prefix}-c{index}"
        chapters[cid] = dict(id=cid, book_id=book["id"], index=index, title="",
            user_prompt="", author_note="", draft_text="虚构的雨落在屋檐。" * 500,
            summary="", headline="", status="draft_ready", source="agent",
            updated_at="2026-09-20T00:00:00", content_revision=7,
            character_links=[], exempted_character_names=[])
    if options.get("archive_failure"):
        chapter = chapters[prefix + "-c1"]
        chapter["status"] = "finalized"
        chapter["archive"] = archive("failed")
    if options.get("archive_complete"):
        chapter = chapters[prefix + "-c1"]
        chapter["status"] = "finalized"
        chapter["archive"] = archive("complete")
    if options.get("finalized"):
        chapters[prefix + "-c1"]["status"] = "finalized"
    if options.get("writing"):
        chapters[prefix + "-c1"]["status"] = "writing"
    if options.get("writing_second"):
        chapters[prefix + "-c2"]["status"] = "writing"
    if options.get("accept_preflight") == "minimum_length" or options.get("check_mode") == "minimum_length":
        chapters[prefix + "-c1"]["draft_text"] = "短稿。"
    STATE.clear()
    character = dict(id=prefix + "-character", book_id=book["id"], name="虚构人物",
                     role="", fixed_profile="", content_revision=7)
    other_book = dict(book, id=prefix + "-other-book", title="另一隔离书")
    other_character = dict(character, id=prefix + "-other-character", book_id=other_book["id"], name="另一人物")
    other_chapters = {prefix + "-other-c1": dict(chapters[prefix + "-c1"],
        id=prefix + "-other-c1", book_id=other_book["id"], title="另一书章节")}
    STATE.update(book=book, character=character, chapters=chapters, requests=[], options=options,
                 other_book=other_book, other_character=other_character, other_chapters=other_chapters,
                 added_books=[], deleted_book_ids=[], added_characters=[], deleted_character_ids=[],
                 personas=[dict(agent_role="writer", editable_persona="原人格", content_revision=7)],
                 profiles=[dict(id=prefix + "-profile", name="隔离配置", provider="openai-compatible",
                    base_url="https://synthetic.invalid", model_name="synthetic-model", content_revision=7)],
                 bindings=[dict(agent_role="writer", llm_profile_id=prefix + "-profile", content_revision=7)],
                 book_personas={item["id"]: [dict(agent_role="writer", source="global", book_persona=None,
                     global_persona="原人格", effective_persona="原人格", default_persona="默认人格",
                     program_protocol="", content_revision=None)] for item in (book, other_book)},
                 book_bindings={item["id"]: [dict(agent_role="writer", source="global", book_binding=None,
                     global_binding=dict(llm_profile_id=prefix + "-profile"), effective_binding=dict(llm_profile_id=prefix + "-profile"),
                     content_revision=None)] for item in (book, other_book)},
                 checker={}, job_calls={}, deleted_event_ids=[])
    if options.get("with_event"):
        character["events"] = [dict(id=prefix + "-event", book_id=book["id"], character_id=character["id"],
            chapter_id=prefix + "-c1", event_type="行动", event_text="旧事件", content_revision=7,
            created_at="2026-09-20T00:00:00", updated_at="2026-09-20T00:00:00")]



def archive(status):
    return dict(status=status, schema="v2", revision_id="test-revision", revision=1,
        summary="虚构归档" if status == "complete" else "", facts=[], state_delta_count=0,
        error_code="llm_timeout" if status == "failed" else None,
        error_message="整理记忆请求超时" if status == "failed" else None,
        can_retry=status == "failed", latest_attempt_status=status,
        effective_status="full" if status == "complete" else "none",
        state_status="complete" if status == "complete" else "none",
        state_uncertainties=[], diagnostics=[], latest_attempt=None)


def job(chapter, phase=None, kind=None):
    archived = chapter.get("archive", {}).get("status")
    phase = phase or ("failed" if archived == "failed" else
                      "done" if archived == "complete" else
                      "writing" if chapter["status"] == "writing" else "idle")
    kind = kind or STATE["options"].get("job_kind") or ("extract" if archived else "write")
    if phase == "done" and kind == "write" and chapter["status"] == "writing":
        chapter["status"] = "draft_ready"
        if STATE["options"].get("job_advances_revision"):
            chapter["content_revision"] += 1
    result = dict(chapter_id=chapter["id"], job_id=chapter["id"] + "-job",
        outcome_current=STATE["options"].get("job_outcome_current", True), phase=phase, kind=kind,
        chapter=copy.deepcopy(chapter) if phase == "done" else None,
        visible_checker_result=None if STATE["options"].get("job_without_visible_checker") else STATE["checker"].get(chapter["id"]),
        can_retry_checker=bool(STATE["options"].get("can_retry_checker")),
        checker_source_job_id=chapter["id"] + "-source" if STATE["options"].get("can_retry_checker") else None)
    if STATE["options"].get("job_id_suffix"):
        result["job_id"] = chapter["id"] + STATE["options"]["job_id_suffix"]
    if kind == "check":
        result["checker_target"] = STATE["options"].get("checker_target", "visible_draft")
    if phase == "failed":
        if kind == "check":
            result.update(error_code="checker_failed", error_message="手动检查暂时不可用",
                          error_context=dict(agent_role="checker", model_name="test-checker"))
        else:
            result.update(error_code="llm_timeout", error_message="整理记忆请求超时",
                          error_context=dict(agent_role="extractor", model_name="test-extractor"))
        if role := STATE["options"].get("job_failure_role"):
            result.update(error_code="llm_timeout", error_message="虚构任务超时",
                          error_context=dict(agent_role=role, model_name="test-role"))
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, status, value):
        data = b"" if status == 204 else json.dumps(value, ensure_ascii=False).encode()
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Explicit client cancellation is one of the regression cases.

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        payload = json.loads(body) if body else {}
        path = self.path.removeprefix("/api/v1")
        with LOCK:
            if path == "/_test/reset":
                reset(payload)
                return self.send(200, STATE)
            if path == "/_test/config":
                STATE["options"].update(payload)
                if "archive_message" in payload:
                    for item in STATE["chapters"].values():
                        if "archive" in item:
                            item["archive"]["error_message"] = payload["archive_message"]
                            item["archive"]["revision_id"] = "new-server-revision"
                if "remote_draft_text" in payload:
                    chapter = STATE["chapters"][next(iter(STATE["chapters"]))]
                    chapter["draft_text"] = payload["remote_draft_text"]
                    chapter["content_revision"] += 1
                if "remote_character_profile" in payload:
                    STATE["character"]["fixed_profile"] = payload["remote_character_profile"]
                    STATE["character"]["content_revision"] += 1
                return self.send(200, STATE)
            if path == "/_test/state":
                return self.send(200, STATE)
            if path == "/_test/release":
                GATES.setdefault(payload["gate"], threading.Event()).set()
                return self.send(200, STATE)
            STATE["requests"].append(dict(method=self.command, path=path,
                bodyText=body.decode(), ifMatch=self.headers.get("If-Match")))
            options = copy.deepcopy(STATE["options"])
            if self.headers.get("Authorization") != "Bearer synthetic-test-token":
                return self.send(401, {"detail": "unauthorized"})
            if path == "/books":
                if self.command == "GET":
                    status = options.get("books_status", 200)
                    values = [item for item in [STATE["book"], STATE["other_book"]] + STATE["added_books"]
                              if item["id"] not in STATE["deleted_book_ids"]]
                    captured = copy.deepcopy(values) if options.get("books_with_rows") else []
                    pause_at(options.get("books_read_gate"))
                    return self.send(status, captured if status == 200 else {"detail": "unauthorized"})
                if self.command == "POST":
                    value = dict(STATE["book"], id=STATE["book"]["id"] + "-new-book-" + str(len(STATE["added_books"])), **payload)
                    STATE["added_books"].append(value)
                    captured = copy.deepcopy(value)
                    pause_at(options.get("books_create_gate"))
                    return self.send(200, captured)
            parts = path.strip("/").split("/")
            cid = parts[1] if len(parts) > 1 else ""
            action = "/".join(parts[2:])
            if parts[0] in ("agent-personas", "llm_profiles", "agent-model-bindings"):
                key = {"agent-personas": "personas", "llm_profiles": "profiles", "agent-model-bindings": "bindings"}[parts[0]]
                values = STATE[key]
                identity = "id" if key == "profiles" else "agent_role"
                if self.command == "GET":
                    return self.send(200, values if not cid else next(item for item in values if item[identity] == cid))
                status = options.get("settings_status", 200)
                pause_at(options.get("settings_gate"))
                if status != 200:
                    if status == 409:
                        return self.send(409, {"detail": {"code": "write_conflict", "details": {
                            "resource_type": key, "resource_id": cid,
                            "submitted_revision": 7, "current_revision": 8}}})
                    return self.send(status, {"detail": "synthetic settings refused"})
                if not cid:
                    # The synthetic key is memory-only and never part of a public resource.
                    value = {k: v for k, v in payload.items() if k != "api_key"}
                    value.update(id=STATE["book"]["id"] + "-new-profile", content_revision=1)
                    values.append(value)
                    return self.send(200, value)
                value = next(item for item in values if item[identity] == cid)
                if options.get("strict_settings_revisions") and self.headers.get("If-Match") != f'"{value["content_revision"]}"':
                    return self.send(409, {"detail": {"code": "write_conflict", "details": {
                        "resource_type": key, "resource_id": cid,
                        "submitted_revision": int((self.headers.get("If-Match") or '"0"').strip('"')),
                        "current_revision": value["content_revision"]}}})
                if action == "reset":
                    value["editable_persona"] = "默认人格"
                else:
                    value.update({k: v for k, v in payload.items() if k != "api_key"})
                value["content_revision"] += 1
                returned = copy.deepcopy(value)
                if options.get("settings_response") == "wrong_id":
                    returned[identity] = "wrong-resource"
                if options.get("settings_response") == "malformed":
                    returned = {"agent_role": cid}
                return self.send(200, returned)
            if parts[0] == "character-events":
                event = next((e for e in STATE["character"].get("events", []) if e["id"] == cid), None)
                if event is None or cid in STATE["deleted_event_ids"]:
                    return self.send(404, {"detail": "deleted event"})
                if self.command == "GET":
                    return self.send(200, event)
                if self.command == "DELETE":
                    STATE["deleted_event_ids"].append(cid)
                    return self.send(204, None)
                status = options.get("event_patch_status", 200)
                if status != 200: return self.send(status, {"detail": "event unavailable"})
                event.update(payload)
                event["content_revision"] += 1
                return self.send(200, event)
            book = next((item for item in [STATE["book"], STATE["other_book"]] + STATE["added_books"]
                         if item["id"] == cid and cid not in STATE["deleted_book_ids"]), None)
            if parts[0] == "books" and book and action.startswith("agent-personas"):
                values = STATE["book_personas"][cid]
                if self.command == "GET":
                    captured = copy.deepcopy(values if len(parts) == 3 else values[0])
                    pause_at(options.get("book_personas_read_gate"))
                    return self.send(200, captured)
                pause_at(options.get("book_personas_write_gate"))
                status = options.get("settings_status", 200)
                if status != 200:
                    if status == 409:
                        return self.send(409, {"detail": {"code": "write_conflict", "details": {
                            "resource_type": "agent_persona", "resource_id": parts[-1],
                            "submitted_revision": 0, "current_revision": 0}}})
                    return self.send(status, {"detail": "synthetic book persona refused"})
                value = values[0]
                if options.get("strict_settings_revisions") and self.command == "PUT" and self.headers.get("If-Match") != f'"{value["content_revision"] or 0}"':
                    return self.send(409, {"detail": {"code": "write_conflict", "details": {
                        "resource_type": "book_setting", "resource_id": parts[-1],
                        "submitted_revision": int((self.headers.get("If-Match") or '"0"').strip('"')),
                        "current_revision": value["content_revision"] or 0}}})
                if self.command == "DELETE":
                    value.update(source="global", book_persona=None, effective_persona=value["global_persona"], content_revision=None)
                    return self.send(204, None)
                value.update(source="book", book_persona=payload["editable_persona"], effective_persona=payload["editable_persona"],
                             content_revision=(value["content_revision"] or 0) + 1)
                return self.send(200, value)
            if parts[0] == "books" and book and action.startswith("agent-model-bindings"):
                values = STATE["book_bindings"][cid]
                if self.command == "GET":
                    captured = copy.deepcopy(values if len(parts) == 3 else values[0])
                    pause_at(options.get("book_bindings_read_gate"))
                    return self.send(200, captured)
                status = options.get("settings_status", 200)
                if status == 409:
                    return self.send(409, {"detail": {"code": "write_conflict", "details": {
                        "resource_type": "model_binding", "resource_id": parts[-1],
                        "submitted_revision": 0, "current_revision": 0}}})
                if status != 200:
                    return self.send(status, {"detail": "synthetic book binding refused"})
                value = values[0]
                if options.get("strict_settings_revisions") and self.command == "PUT" and self.headers.get("If-Match") != f'"{value["content_revision"] or 0}"':
                    return self.send(409, {"detail": {"code": "write_conflict", "details": {
                        "resource_type": "book_setting", "resource_id": parts[-1],
                        "submitted_revision": int((self.headers.get("If-Match") or '"0"').strip('"')),
                        "current_revision": value["content_revision"] or 0}}})
                if self.command == "DELETE":
                    value.update(source="global", book_binding=None, content_revision=None)
                    return self.send(204, None)
                value.update(source="book", book_binding=payload, effective_binding=payload,
                             content_revision=(value["content_revision"] or 0) + 1)
                returned = copy.deepcopy(value)
                if options.get("settings_response") == "wrong_scope":
                    returned = dict(STATE["bindings"][0])
                if options.get("settings_response") == "wrong_id":
                    returned["agent_role"] = "wrong-resource"
                return self.send(200, returned)
            if parts[0] == "books" and book and action in ("export-data", "project-export"):
                chapters = list((STATE["chapters"] if book == STATE["book"] else STATE["other_chapters"]).values())
                data = dict(book_id=book["id"], title=book["title"], world_setting=book["world_setting"],
                            chapters=chapters, characters=[STATE["character"]] if book == STATE["book"] else [STATE["other_character"]])
                captured = copy.deepcopy(data)
                pause_at(options.get("export_gate"))
                # Project's wire payload is opaque to the client. Synthetic
                # JSON permits checking the exact snapshot without real data.
                return self.send(200, captured)
            if parts[0] == "books" and book and action in ("chapters", "characters"):
                if action == "chapters":
                    collection = STATE["chapters"] if book == STATE["book"] else STATE["other_chapters"]
                    values = list(collection.values())
                    if book == STATE["other_book"] and options.get("other_book_empty"):
                        values = []
                else:
                    values = [item for item in [STATE["character"], STATE["other_character"]] + STATE["added_characters"]
                              if item["book_id"] == book["id"] and item["id"] not in STATE["deleted_character_ids"]]
                if self.command == "GET":
                    captured = copy.deepcopy(values)
                    status = options.get(action + "_list_status", 200)
                    pause_at(options.get(action + "_list_gate"))
                    return self.send(status, captured if status == 200 else {"detail": "list unavailable"})
                if self.command == "POST":
                    if action == "chapters":
                        value = dict(next(iter(STATE["chapters"].values())), id=book["id"] + "-new-chapter",
                                     book_id=book["id"], index=len(values) + 1, **payload)
                        collection[value["id"]] = value
                    else:
                        value = dict(STATE["character"], id=book["id"] + "-new-character-" + str(len(STATE["added_characters"])),
                                     book_id=book["id"], **payload)
                        STATE["added_characters"].append(value)
                    captured = copy.deepcopy(value)
                    pause_at(options.get(action + "_create_gate"))
                    return self.send(200, captured)
            chapter = STATE["chapters"].get(cid) or STATE["other_chapters"].get(cid)
            if parts[0] == "books" and book:
                chapter = book
            elif parts[0] == "characters":
                chapter = next((item for item in [STATE["character"], STATE["other_character"]] + STATE["added_characters"]
                                if item["id"] == cid and cid not in STATE["deleted_character_ids"]), None)
            if not chapter:
                return self.send(404, {"detail": "not found"})
            if self.command == "DELETE":
                status = options.get("delete_status", 204)
                pause_at(options.get("delete_gate"))
                if status != 204:
                    return self.send(status, {"detail": "synthetic delete refused"})
                if parts[0] == "chapters":
                    STATE["chapters"].pop(cid, None)
                    STATE["other_chapters"].pop(cid, None)
                elif parts[0] == "characters":
                    STATE["deleted_character_ids"].append(cid)
                elif parts[0] == "books":
                    STATE["deleted_book_ids"].append(cid)
                return self.send(204, None)
            if self.command == "GET" and not action:
                status = options.get("get_status", 200)
                captured_chapter = copy.deepcopy(chapter)
                pause_at(options.get("get_gate"))
                chapter_get_delay = options.get("chapter_get_delay", 0)
                if chapter_get_delay:
                    LOCK.release()
                    try:
                        time.sleep(chapter_get_delay)
                    finally:
                        LOCK.acquire()
                if status != 200:
                    return self.send(status, {"detail": "follow-up read failed"})
                if options.get("get_malformed"):
                    return self.send(200, "invalid resource shape")
                if options.get("get_blocked"):
                    return self.send(503, {"detail": "temporarily unavailable"})
                return self.send(200, captured_chapter)
            if self.command == "PATCH":
                pause_at(options.get("patch_failure_gate"))
                if options.get("patch_failure_delay"):
                    LOCK.release()
                    try:
                        time.sleep(options["patch_failure_delay"])
                    finally:
                        LOCK.acquire()
                if options.get("patch_lost"):
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                status = options.get("patch_status", 200)
                if (options.get("job_advances_revision") or options.get("strict_revisions")) and self.headers.get("If-Match") != f'"{chapter["content_revision"]}"':
                    status = 409
                if options.get("patch_only_first") and cid.endswith("-c2"):
                    status = 200
                if status != 200:
                    if status == 409:
                        return self.send(409, {"detail": {"code": "write_conflict", "details": {
                            "resource_type": parts[0].removesuffix("s"), "resource_id": cid,
                            "submitted_revision": 7, "current_revision": 8}}})
                    return self.send(status, {"detail": {"code": "validation_failed",
                        "message": "虚构校验拒绝了本次修改"}})
                chapter.update(payload)
                chapter["content_revision"] += 1
                if options.get("patch_response") == "malformed":
                    return self.send(200, "invalid success shape")
                if options.get("patch_response") == "wrong_id":
                    return self.send(200, dict(chapter, id="another-synthetic-resource"))
                saved = copy.deepcopy(chapter)
                pause_at(options.get("patch_response_gate"))
                if options.get("patch_delay"):
                    LOCK.release()
                    try:
                        time.sleep(options["patch_delay"])
                    finally:
                        LOCK.acquire()
                return self.send(200, saved)
            if action == "job":
                STATE["job_calls"][cid] = STATE["job_calls"].get(cid, 0) + 1
                captured = copy.deepcopy(job(chapter, options.get("job_phase")))
                if options.get("job_checker_rejected"):
                    captured.update(phase="failed", error_code="checker_rejected",
                        error_message="候选未通过检查，当前正文保持不变",
                        checker_result={"verdict": "violation", "issues": [
                            {"kind": "relation_changed", "reason": "既有关系出现矛盾"}]},
                        error_context={"agent_role": "checker", "model_name": "test-checker"})
            else:
                captured = copy.deepcopy(chapter)

        # Delay outside the lock so tests can navigate or change conditions
        # while the real URLSession request is in flight.
        delay = options.get(action.replace("/", "_") + "_delay", 0)
        if action == "check/start":
            delay = options.get("check_delay", delay)
        time.sleep(delay)
        with LOCK:
            if action == "job":
                if options.get("job_malformed"):
                    return self.send(200, {"unexpected": "shape"})
                status = options.get("job_status", 200)
                failure = {"detail": {"code": "upstream_unavailable", "message": "暂时无法读取任务"}} if options.get("structured_status") else {"detail": "unauthorized"}
                return self.send(status, captured if status == 200 else failure)
            if action == "production-readiness":
                limitations = options.get("readiness_limitations", [])
                recovery = options.get("readiness_recovery")
                return self.send(200, {
                    "context_token": options.get("readiness_token", "synthetic-context-token"),
                    "limitations": limitations,
                    "recommended_recovery": recovery,
                })
            if action == "check/start":
                if options.get("check_start_lost"):
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                if options.get("check_start_reject"):
                    return self.send(409, {"detail": {
                        "code": options.get("check_start_reject_code", "not_configured"),
                        "message": "Checker 模型配置不可用",
                    }})
                mode = options.get("check_mode", "passed")
                if mode in ("minimum_length", "unselected_character", "ambiguous_character"):
                    return self.send(409, {"detail": {"code": "checker_preflight_failed",
                        "message": "当前正文未通过确定性校验", "violations": [{"code": mode,
                        "message": "正文3字，少于最低要求4000字" if mode == "minimum_length" else "人物选择需要修正",
                        "current_chars": 3, "names": [] if mode == "minimum_length" else ["虚构人物"]}]}})
                result = dict(verdict=mode if mode in ("suspect", "violation") else "passed",
                              issues=[], draft_fingerprint="test-fingerprint")
                if options.get("check_context_limitations"):
                    result["context_limitations"] = options["check_context_limitations"]
                if options.get("check_identity_issues"):
                    result["identity_issues"] = options["check_identity_issues"]
                if mode in ("unavailable", "timeout", "invalid", "legacy"):
                    code, message = {
                        "unavailable": ("llm_content_blocked", "上游模型拦截了本次检查请求"),
                        "timeout": ("llm_timeout", "检查请求超时"),
                        "invalid": ("checker_failed", "检查模型返回格式无效"),
                        "legacy": ("checker_failed", "")}[mode]
                    result = dict(status="unavailable", error_code=code,
                        error_message=message,
                        error_context=dict(agent_role="checker", model_name="test-checker",
                                           block_reason="PROHIBITED_CONTENT", http_status=403))
                    if mode == "legacy":
                        result = {"status": "unavailable", "error_code": "checker_failed"}
                    elif mode != "unavailable":
                        result["error_context"].pop("block_reason")
                        result["error_context"].pop("http_status")
                STATE["checker"][cid] = result
                if mode in ("unavailable", "timeout", "invalid", "legacy"):
                    failed = job(chapter, "failed", "check")
                    failed.update(error_code=result.get("error_code"),
                                  error_message=result.get("error_message"),
                                  visible_checker_result=result)
                    return self.send(200, failed)
                return self.send(200, job(chapter, "done", "check"))
            if action == "check":
                mode = options.get("check_mode", "passed")
                if mode in ("minimum_length", "unselected_character", "ambiguous_character"):
                    return self.send(409, {"detail": {"code": "checker_preflight_failed",
                        "message": "当前正文未通过确定性校验", "violations": [{"code": mode,
                        "message": "正文3字，少于最低要求4000字" if mode == "minimum_length" else "人物选择需要修正",
                        "current_chars": 3, "names": [] if mode == "minimum_length" else ["虚构人物"]}]}})
                result = dict(verdict="passed", issues=[], draft_fingerprint="test-fingerprint")
                if options.get("check_context_limitations"):
                    result["context_limitations"] = options["check_context_limitations"]
                if options.get("check_identity_issues"):
                    result["identity_issues"] = options["check_identity_issues"]
                if mode in ("unavailable", "timeout", "invalid", "legacy"):
                    code, message = {
                        "unavailable": ("llm_content_blocked", "上游模型拦截了本次检查请求"),
                        "timeout": ("llm_timeout", "检查请求超时"),
                        "invalid": ("checker_failed", "检查模型返回格式无效"),
                        "legacy": ("checker_failed", "")}[mode]
                    result = dict(status="unavailable", error_code=code,
                        error_message=message,
                        error_context=dict(agent_role="checker", model_name="test-checker",
                                           block_reason="PROHIBITED_CONTENT", http_status=403))
                    if mode == "legacy":
                        result = {"status": "unavailable", "error_code": "checker_failed"}
                    elif mode != "unavailable":
                        result["error_context"].pop("block_reason")
                        result["error_context"].pop("http_status")
                STATE["checker"][cid] = result
                return self.send(200, {"checker_result": result})
            if action == "checker/retry":
                if options.get("checker_retry_lost"):
                    if options.get("checker_retry_admitted"):
                        terminal = options.get("checker_retry_terminal", False)
                        STATE["options"].update(job_kind="check", job_phase="done" if terminal else "checking",
                                                checker_target="generated_candidate", job_outcome_current=True if terminal else None,
                                                job_id_suffix="-new-check")
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                if options.get("checker_retry_reject"):
                    return self.send(409, {"detail": {"code": options.get("checker_retry_reject_code", "checker_retry_unavailable"), "message": "生成稿已不能安全复查"}})
                if options.get("checker_retry_failure"):
                    response = job(chapter, "failed", "check")
                    response["checker_target"] = "generated_candidate"
                    options["checker_retry_count"] = options.get("checker_retry_count", 0) + 1
                    response["job_id"] = chapter["id"] + "-retry-" + str(options["checker_retry_count"])
                    response.update(error_code=options.get("checker_retry_error_code", "checker_invalid_response"), error_message="检查结果未通过校验：Checker 未逐项处理程序提供的姓名分组",
                                    checker_result={"status": "unavailable", "error_code": options.get("checker_retry_error_code", "checker_invalid_response")})
                    return self.send(200, response)
                return self.send(200, job(chapter, "done", "write"))
            if action == "accept":
                preflight = options.get("accept_preflight")
                if preflight and (preflight != "minimum_length" or not (payload.get("override_checker") or payload.get("allow_short_draft"))):
                    code = "accept_override_required" if preflight == "minimum_length" else "accept_preflight_failed"
                    return self.send(409, {"detail": {"code": code,
                        "message": "正文未通过确定性校验", "violations": [{"code": preflight,
                        "message": "正文3字，少于最低要求4000字" if preflight == "minimum_length" else "人物选择需要修正",
                        "current_chars": 3, "names": [] if preflight == "minimum_length" else ["虚构人物"]}]}})
                if options.get("accept_short_confirmation") and not payload.get("allow_short_draft"):
                    return self.send(409, {"detail": {
                        "code": "short_draft_confirmation_required",
                        "message": "正文少于4000字，请明确确认后继续",
                    }})
                if options.get("accept_status"):
                    status = options["accept_status"]
                    failure = {"detail": {"code": "upstream_unavailable", "message": "接受状态暂时无法读取"}} if options.get("structured_status") else {"detail": "unavailable"}
                    STATE["options"]["get_blocked"] = True
                    return self.send(status, failure)
                mode = options.get("accept_mode", "success")
                if mode == "reject":
                    return self.send(409, {"detail": {"code": "checker_override_required",
                        "message": "设定已更新，请重新检查"}})
                chapter["status"] = "finalized"
                chapter["archive"] = archive("complete")
                if mode in ("lost", "lost_and_blocked"):
                    STATE["options"]["get_blocked"] = mode == "lost_and_blocked"
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                return self.send(200, job(chapter, "done", "extract"))
            if action == "archive/retry":
                if options.get("archive_reject"):
                    return self.send(409, {"detail": {"code": "archive_unavailable", "message": "当前归档不能开始"}})
                chapter["archive"] = archive("complete")
                return self.send(200, job(chapter, "done", "extract"))
            if action == "write":
                if options.get("write_reject"):
                    return self.send(409, {"detail": {"code": "bible_empty", "message": "本章意图为空"}})
                chapter["status"] = "writing"
                return self.send(200, job(chapter, "writing", "write"))
            if action == "inspirations":
                if options.get("inspiration_success"):
                    return self.send(200, {"cards": [dict(title="方向一", body="虚构的文学构思。", history_basis=None, note=None, history_chapter_indexes=[])]})
                return self.send(503, {"detail": {"code": "llm_timeout", "message": "灵感生成超时"}})
            return self.send(404, {"detail": "unknown synthetic route"})

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = handle_request


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    reset({"prefix": "initial"})
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    Path(args.port_file).write_text(str(server.server_address[1]))
    server.serve_forever()
