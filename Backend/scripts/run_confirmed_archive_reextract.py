#!/usr/bin/env python3
"""Run only user-confirmed hard candidates through the deployed v2 API.

The input report contains counts, IDs and hashes only.  This script never reads
or prints prose and never takes a token on the command line.  It makes exactly
one archive request per explicitly listed chapter and continues after an
isolated failure so no other chapter is rolled back.
"""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


CONFIRMATION = "I_CONFIRM_THE_EXACT_CHAPTER_IDS"
TERMINAL_PHASES = {"done", "failed", "cancelled"}


def _request(url: str, token: str, *, method: str = "GET", payload: dict[str, Any] | None = None) -> dict:
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        url,
        data=body,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {detail[:500]}") from exc


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--chapter-id", action="append", required=True, dest="chapter_ids")
    parser.add_argument("--base-url", required=True, help="API root ending in /api/v1")
    parser.add_argument("--token-env", default="ICTW_APP_TOKEN")
    parser.add_argument("--confirm", required=True)
    parser.add_argument("--timeout", type=int, default=240)
    args = parser.parse_args()
    if args.confirm != CONFIRMATION:
        raise SystemExit("explicit confirmation phrase is required")
    token = os.environ.get(args.token_env, "")
    if not token:
        raise SystemExit(f"token environment variable {args.token_env} is empty")
    report = json.loads(args.report.read_text(encoding="utf-8"))
    hard_by_id = {item["chapter_id"]: item for item in report.get("hard_candidates", [])}
    requested = list(dict.fromkeys(args.chapter_ids))
    unknown = [chapter_id for chapter_id in requested if chapter_id not in hard_by_id]
    if unknown:
        raise SystemExit(f"chapter IDs are not hard candidates in this report: {unknown}")

    root = args.base_url.rstrip("/")
    results: list[dict[str, Any]] = []
    for chapter_id in requested:
        item = hard_by_id[chapter_id]
        try:
            started = _request(
                f"{root}/chapters/{chapter_id}/archive/retry",
                token,
                method="POST",
                payload={
                    "provenance": "selective_reextract",
                    "expected_draft_sha256": item["draft_sha256"],
                },
            )
            deadline = time.monotonic() + args.timeout
            status = started
            while status.get("phase") not in TERMINAL_PHASES:
                if time.monotonic() >= deadline:
                    raise RuntimeError("archive job polling timed out")
                time.sleep(2)
                status = _request(f"{root}/chapters/{chapter_id}/job", token)
            results.append({
                "chapter_id": chapter_id,
                "phase": status.get("phase"),
                "error_code": status.get("error_code"),
            })
        except Exception as exc:
            results.append({"chapter_id": chapter_id, "phase": "request_failed", "error": str(exc)[:500]})
    print(json.dumps({"llm_requests_started": len(requested), "results": results}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
