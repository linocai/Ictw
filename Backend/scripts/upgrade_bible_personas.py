"""Explicit Build67 editable-persona upgrade; dry-run by default, never logs text.

Run against the stopped, backed-up deployment database with --apply at release.
No automatic startup rewrite: later author edits remain authoritative.
"""
import argparse
import json
from pathlib import Path
import sqlite3
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.persona_contract import EDITABLE_PERSONA_MAX_LENGTH, with_bible_focus


def upgrade(database: Path, *, apply: bool = False) -> dict[str, int]:
    uri = database.resolve().as_uri() + ("?mode=rw" if apply else "?mode=ro")
    with sqlite3.connect(uri, uri=True) as db:
        if apply:
            db.execute("BEGIN IMMEDIATE")
        else:
            db.execute("PRAGMA query_only=ON")
        counts = {}
        updates = []
        invalid = []
        for table, text_field, identity in (
            ("agent_personas", "system_prompt", "agent_role"),
            ("book_agent_personas", "editable_persona", "id"),
        ):
            changed = 0
            rows = db.execute(f"SELECT {identity}, agent_role, {text_field} FROM {table} WHERE agent_role IN ('writer', 'checker')").fetchall()
            for row_id, role, original in rows:
                updated = with_bible_focus(role, original)
                if len(updated) > EDITABLE_PERSONA_MAX_LENGTH:
                    invalid.append({"table": table, "id": row_id, "role": role,
                                    "length": len(updated), "maximum": EDITABLE_PERSONA_MAX_LENGTH})
                if updated == original:
                    continue
                changed += 1
                updates.append((table, text_field, identity, updated, row_id))
            counts[table] = changed
        # Validate every target before writing either table. No author text is
        # included in the error or the CLI output.
        if invalid:
            raise ValueError("persona_upgrade_capacity_exceeded: " + json.dumps(invalid))
        if apply:
            for table, text_field, identity, updated, row_id in updates:
                db.execute(f"UPDATE {table} SET {text_field}=?, content_revision=content_revision+1, updated_at=CURRENT_TIMESTAMP WHERE {identity}=?", (updated, row_id))
        return counts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        changed = upgrade(args.database, apply=args.apply)
    except ValueError as exc:
        print(json.dumps({"applied": False, "error": str(exc)}))
        sys.exit(1)
    print(json.dumps({"applied": args.apply, "changed": changed}))
