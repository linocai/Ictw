#!/usr/bin/env python3
"""Create a count-only v1.8 historical re-extraction candidate report.

This command is deliberately read-only and never invokes an LLM.  It emits no
chapter title, prose, summary, event text, prompt, token or secret.  Run it only
against a protected production backup copy; its output is chmod 0600.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def classify_candidate(*, future_blocks: int, event_count: int, max_per_character: int) -> str:
    if future_blocks >= 24 or event_count >= 12 or max_per_character >= 8:
        return "hard"
    if future_blocks >= 17 or event_count >= 9 or max_per_character >= 5:
        return "observe"
    return "excluded"


def _json_list(value: Any) -> tuple[list[Any], bool]:
    if value is None or value == "":
        return [], False
    try:
        parsed = json.loads(value) if isinstance(value, str) else value
    except (TypeError, json.JSONDecodeError):
        return [], True
    return (parsed, False) if isinstance(parsed, list) else ([], True)


def build_report(database_path: Path) -> dict[str, Any]:
    uri = f"file:{database_path.resolve()}?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    try:
        columns = {
            row["name"]
            for row in connection.execute("PRAGMA table_info(chapters)").fetchall()
        }
        archive_status_expr = "archive_status" if "archive_status" in columns else "'legacy'"
        active_revision_expr = (
            "active_archive_revision_id" if "active_archive_revision_id" in columns else "NULL"
        )
        rows = connection.execute(
            f"""
            SELECT id, book_id, "index" AS chapter_index, status, draft_text, long_summary,
                   state_changes, unresolved_items, atomic_memories,
                   {archive_status_expr} AS archive_status,
                   {active_revision_expr} AS active_archive_revision_id
            FROM chapters
            WHERE status = 'finalized'
            ORDER BY book_id, chapter_index, id
            """
        ).fetchall()
        event_rows = connection.execute(
            "SELECT chapter_id, character_id, COUNT(*) AS count FROM character_events "
            "GROUP BY chapter_id, character_id"
        ).fetchall()
        event_counts: dict[str, Counter[str]] = {}
        for row in event_rows:
            event_counts.setdefault(row["chapter_id"], Counter())[row["character_id"]] = row["count"]

        items: list[dict[str, Any]] = []
        malformed_total = 0
        for row in rows:
            state, bad_state = _json_list(row["state_changes"])
            unresolved, bad_unresolved = _json_list(row["unresolved_items"])
            atomic, bad_atomic = _json_list(row["atomic_memories"])
            malformed = bad_state or bad_unresolved or bad_atomic
            malformed_total += int(malformed)
            per_character = event_counts.get(row["id"], Counter())
            event_count = sum(per_character.values())
            max_per_character = max(per_character.values(), default=0)
            summary_count = int(bool((row["long_summary"] or "").strip()))
            future_blocks = summary_count + len(state) + len(unresolved) + len(atomic) + event_count
            category = classify_candidate(
                future_blocks=future_blocks,
                event_count=event_count,
                max_per_character=max_per_character,
            )
            items.append({
                "chapter_id": row["id"],
                "chapter_index": row["chapter_index"],
                "book_id": row["book_id"],
                "status": row["status"],
                "archive_status": row["archive_status"],
                "active_archive_revision_id": row["active_archive_revision_id"],
                "draft_sha256": hashlib.sha256((row["draft_text"] or "").encode()).hexdigest(),
                "summary_count": summary_count,
                "state_changes_count": len(state),
                "unresolved_items_count": len(unresolved),
                "atomic_memories_count": len(atomic),
                "character_event_count": event_count,
                "max_events_per_character": max_per_character,
                "future_memory_blocks": future_blocks,
                "malformed_legacy_arrays": malformed,
                "category": category,
            })
        groups = {
            name: [item for item in items if item["category"] == name]
            for name in ("hard", "observe", "excluded")
        }
        return {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "source": "read_only_sqlite_backup",
            "llm_calls": 0,
            "thresholds": {
                "hard": "future_memory_blocks >= 24 OR character_event_count >= 12 OR max_events_per_character >= 8",
                "observe": "future_memory_blocks >= 17 OR character_event_count >= 9 OR max_events_per_character >= 5",
            },
            "summary": {
                "finalized_chapters": len(items),
                "hard_candidates": len(groups["hard"]),
                "observation_candidates": len(groups["observe"]),
                "excluded": len(groups["excluded"]),
                "malformed_legacy_arrays": malformed_total,
            },
            "hard_candidates": groups["hard"],
            "observation_candidates": groups["observe"],
            "excluded": groups["excluded"],
            "execution_gate": "No historical LLM call is allowed until the user confirms exact chapter IDs.",
        }
    finally:
        connection.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("database", type=Path, help="Path to a production backup copy of linoi.db")
    parser.add_argument("output", type=Path, help="0600 JSON report path outside Git")
    args = parser.parse_args()
    if not args.database.is_file():
        raise SystemExit("database backup copy not found")
    report = build_report(args.database)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(args.output, 0o600)


if __name__ == "__main__":
    main()
