"""v1 agent chain and chapter author notes

Revision ID: 20260710_0002
Revises: 20260709_0001
Create Date: 2026-07-10
"""

from __future__ import annotations

from datetime import datetime, timezone

from alembic import op
import sqlalchemy as sa


revision = "20260710_0002"
down_revision = "20260709_0001"
branch_labels = None
depends_on = None


MEMORY_SELECTOR_PROMPT = (
    "你是小说写作记忆选择助手。根据本章剧情 Bible、作者备注与允许人物，"
    "从候选历史记忆中选择真正有助于本章写作的条目。只返回有序记忆 ID，"
    "不得重写、概括或补造历史。"
)


def _assert_foreign_keys_clean(connection) -> None:
    if connection.dialect.name != "sqlite":
        return
    connection.exec_driver_sql("PRAGMA foreign_keys=ON")
    violations = connection.exec_driver_sql("PRAGMA foreign_key_check").fetchall()
    if violations:
        raise RuntimeError(f"foreign_key_check failed before migration: {violations!r}")


def _move_character_notes(connection) -> None:
    rows = connection.execute(
        sa.text(
            """
            SELECT cc.chapter_id, c.name, cc.chapter_note
            FROM chapter_characters AS cc
            JOIN characters AS c ON c.id = cc.character_id
            WHERE trim(cc.chapter_note) <> ''
            ORDER BY cc.chapter_id, cc.id
            """
        )
    ).mappings()
    notes_by_chapter: dict[str, list[str]] = {}
    for row in rows:
        notes_by_chapter.setdefault(row["chapter_id"], []).append(
            f"- {row['name']}：{row['chapter_note'].strip()}"
        )
    for chapter_id, notes in notes_by_chapter.items():
        old_note = connection.execute(
            sa.text("SELECT author_note FROM chapters WHERE id = :chapter_id"),
            {"chapter_id": chapter_id},
        ).scalar_one()
        legacy_section = "## 旧版人物本章备注\n" + "\n".join(notes)
        merged = f"{old_note.rstrip()}\n\n{legacy_section}" if old_note.strip() else legacy_section
        connection.execute(
            sa.text("UPDATE chapters SET author_note = :note WHERE id = :chapter_id"),
            {"note": merged, "chapter_id": chapter_id},
        )


def _rename_agent(connection, table: str, old_role: str, new_role: str) -> None:
    old_exists = connection.execute(
        sa.text(f"SELECT 1 FROM {table} WHERE agent_role = :role"), {"role": old_role}
    ).first()
    if old_exists is None:
        return
    connection.execute(sa.text(f"DELETE FROM {table} WHERE agent_role = :role"), {"role": new_role})
    connection.execute(
        sa.text(f"UPDATE {table} SET agent_role = :new_role WHERE agent_role = :old_role"),
        {"new_role": new_role, "old_role": old_role},
    )


def upgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)

    if connection.dialect.name == "sqlite":
        # Rebuilding the parent table while foreign keys are enabled makes SQLite
        # cascade-delete every chapter link/event. Native rename preserves them.
        connection.exec_driver_sql(
            "ALTER TABLE chapters RENAME COLUMN chapter_style TO author_note"
        )
    else:
        op.alter_column(
            "chapters",
            "chapter_style",
            new_column_name="author_note",
            existing_type=sa.Text(),
            existing_nullable=False,
        )

    _move_character_notes(connection)
    with op.batch_alter_table("chapter_characters") as batch_op:
        batch_op.drop_column("chapter_note")

    with op.batch_alter_table("agent_model_bindings") as batch_op:
        batch_op.add_column(sa.Column("thinking_enabled", sa.Boolean(), nullable=True))
        batch_op.add_column(sa.Column("reasoning_effort", sa.String(length=32), nullable=True))

    _rename_agent(connection, "agent_personas", "compressor", "reviser")
    _rename_agent(connection, "agent_model_bindings", "compressor", "reviser")

    now = datetime.now(timezone.utc)
    connection.execute(
        sa.text(
            """
            INSERT INTO agent_personas (agent_role, system_prompt, updated_at)
            VALUES (:role, :prompt, :updated_at)
            """
        ),
        {"role": "memory_selector", "prompt": MEMORY_SELECTOR_PROMPT, "updated_at": now},
    )
    writer_profile_id = connection.execute(
        sa.text("SELECT llm_profile_id FROM agent_model_bindings WHERE agent_role = 'writer'")
    ).scalar_one_or_none()
    connection.execute(
        sa.text(
            """
            INSERT INTO agent_model_bindings
                (agent_role, llm_profile_id, thinking_enabled, reasoning_effort, updated_at)
            VALUES (:role, :profile_id, NULL, NULL, :updated_at)
            """
        ),
        {"role": "memory_selector", "profile_id": writer_profile_id, "updated_at": now},
    )
    _assert_foreign_keys_clean(connection)


def downgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)
    connection.execute(sa.text("DELETE FROM agent_model_bindings WHERE agent_role = 'memory_selector'"))
    connection.execute(sa.text("DELETE FROM agent_personas WHERE agent_role = 'memory_selector'"))
    _rename_agent(connection, "agent_personas", "reviser", "compressor")
    _rename_agent(connection, "agent_model_bindings", "reviser", "compressor")

    with op.batch_alter_table("agent_model_bindings") as batch_op:
        batch_op.drop_column("reasoning_effort")
        batch_op.drop_column("thinking_enabled")
    with op.batch_alter_table("chapter_characters") as batch_op:
        batch_op.add_column(sa.Column("chapter_note", sa.Text(), nullable=False, server_default=""))
    if connection.dialect.name == "sqlite":
        connection.exec_driver_sql(
            "ALTER TABLE chapters RENAME COLUMN author_note TO chapter_style"
        )
    else:
        op.alter_column(
            "chapters",
            "author_note",
            new_column_name="chapter_style",
            existing_type=sa.Text(),
            existing_nullable=False,
        )
    _assert_foreign_keys_clean(connection)
