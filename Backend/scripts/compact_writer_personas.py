"""Explicit Build77 Writer persona update; dry-run by default, never logs text.

Apply at release against the stopped, backed-up database together with Build77
code. Only the two exact Writer texts reviewed by the author on 2026-10-09 are
eligible. Later edits, all other roles and model bindings remain untouched.
This is not a schema migration and is never called by application startup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.persona_contract import COMPACT_WRITER_PERSONA


# Preserve the reviewed personas' existing genre designation, separately from
# the generic default used for new databases and an explicit settings reset.
REVIEWED_WRITER_PERSONA = COMPACT_WRITER_PERSONA.replace("中文小说创作者", "中文R18小说创作者")
REVIEWED_SOURCE_SHA256 = {
    "agent_personas": "645e3c7aaac24e1b39fb5bf924bd8da3509fae510fcbb44bf6991bd9e46f7f16",
    "book_agent_personas": "6f6b0620a2b4788d71eb7f9e840ffc0e90022d65abbaf737521d58778b0af0a7",
}


def compact(database: Path, *, apply: bool = False) -> dict[str, dict[str, int]]:
    uri = database.resolve().as_uri() + ("?mode=rw" if apply else "?mode=ro")
    with sqlite3.connect(uri, uri=True) as db:
        if apply:
            db.execute("BEGIN IMMEDIATE")
        else:
            db.execute("PRAGMA query_only=ON")
            db.execute("BEGIN")
        result = {}
        for table, text_field, identity in (
            ("agent_personas", "system_prompt", "agent_role"),
            ("book_agent_personas", "editable_persona", "id"),
        ):
            counts = {"eligible": 0, "updated": 0, "already_current": 0, "preserved_custom": 0}
            rows = db.execute(
                f"SELECT {identity}, {text_field} FROM {table} WHERE agent_role='writer'"
            ).fetchall()
            for row_id, original in rows:
                if original == REVIEWED_WRITER_PERSONA:
                    counts["already_current"] += 1
                    continue
                if hashlib.sha256(original.encode()).hexdigest() != REVIEWED_SOURCE_SHA256[table]:
                    counts["preserved_custom"] += 1
                    continue
                counts["eligible"] += 1
                if apply:
                    db.execute(
                        f"UPDATE {table} SET {text_field}=?, content_revision=content_revision+1, "
                        f"updated_at=CURRENT_TIMESTAMP WHERE {identity}=?",
                        (REVIEWED_WRITER_PERSONA, row_id),
                    )
                    counts["updated"] += 1
            result[table] = counts
        return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print(json.dumps({"applied": args.apply, "counts": compact(args.database, apply=args.apply)}))
