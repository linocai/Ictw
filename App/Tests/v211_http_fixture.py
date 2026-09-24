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


def reset(options):
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
    STATE.update(book=book, character=character, chapters=chapters, requests=[], options=options,
                 checker={}, job_calls={})


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
    result = dict(chapter_id=chapter["id"], job_id=chapter["id"] + "-job",
        outcome_current=True, phase=phase, kind=kind,
        chapter=copy.deepcopy(chapter) if phase == "done" else None,
        visible_checker_result=STATE["checker"].get(chapter["id"]),
        can_retry_checker=bool(STATE["options"].get("can_retry_checker")),
        checker_source_job_id=chapter["id"] + "-source" if STATE["options"].get("can_retry_checker") else None)
    if phase == "failed":
        if kind == "check":
            result.update(error_code="checker_failed", error_message="手动检查暂时不可用",
                          error_context=dict(agent_role="checker", model_name="test-checker"))
        else:
            result.update(error_code="llm_timeout", error_message="整理记忆请求超时",
                          error_context=dict(agent_role="extractor", model_name="test-extractor"))
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, status, value):
        data = json.dumps(value, ensure_ascii=False).encode()
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
                return self.send(200, STATE)
            if path == "/_test/state":
                return self.send(200, STATE)
            STATE["requests"].append(dict(method=self.command, path=path,
                bodyText=body.decode(), ifMatch=self.headers.get("If-Match")))
            options = copy.deepcopy(STATE["options"])
            if self.headers.get("Authorization") != "Bearer synthetic-test-token":
                return self.send(401, {"detail": "unauthorized"})
            if path == "/books":
                status = options.get("books_status", 200)
                return self.send(status, [] if status == 200 else {"detail": "unauthorized"})
            parts = path.strip("/").split("/")
            cid = parts[1] if len(parts) > 1 else ""
            chapter = STATE["chapters"].get(cid)
            if parts[0] == "books" and cid == STATE["book"]["id"]:
                chapter = STATE["book"]
            elif parts[0] == "characters" and cid == STATE["character"]["id"]:
                chapter = STATE["character"]
            if not chapter:
                return self.send(404, {"detail": "not found"})
            action = "/".join(parts[2:])
            if self.command == "GET" and not action:
                status = options.get("get_status", 200)
                if status != 200:
                    return self.send(status, {"detail": "follow-up read failed"})
                if options.get("get_malformed"):
                    return self.send(200, "invalid resource shape")
                if options.get("get_blocked"):
                    return self.send(503, {"detail": "temporarily unavailable"})
                return self.send(200, chapter)
            if self.command == "PATCH":
                if options.get("patch_lost"):
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                status = options.get("patch_status", 200)
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
                return self.send(200, chapter)
            if action == "job":
                STATE["job_calls"][cid] = STATE["job_calls"].get(cid, 0) + 1
                captured = job(chapter, options.get("job_phase"))
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
                if options.get("checker_retry_reject"):
                    return self.send(409, {"detail": {"code": options.get("checker_retry_reject_code", "checker_retry_unavailable"), "message": "生成稿已不能安全复查"}})
                if options.get("checker_retry_failure"):
                    response = job(chapter, "failed", "check")
                    options["checker_retry_count"] = options.get("checker_retry_count", 0) + 1
                    response["job_id"] = chapter["id"] + "-retry-" + str(options["checker_retry_count"])
                    response.update(error_code="checker_invalid_response", error_message="检查结果未通过校验：Checker 未逐项处理程序提供的姓名分组",
                                    checker_result={"status": "unavailable", "error_code": "checker_invalid_response"})
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
                return self.send(503, {"detail": {"code": "llm_timeout", "message": "灵感生成超时"}})
            return self.send(404, {"detail": "unknown synthetic route"})

    do_GET = do_POST = do_PATCH = handle_request


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    reset({"prefix": "initial"})
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    Path(args.port_file).write_text(str(server.server_address[1]))
    server.serve_forever()
