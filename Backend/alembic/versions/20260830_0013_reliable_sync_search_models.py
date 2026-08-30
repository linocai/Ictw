"""add content revisions, book model overrides, and safe search projection

Revision ID: 20260830_0013
Revises: 20260814_0012
Create Date: 2026-08-30
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "20260830_0013"
down_revision = "20260814_0012"
branch_labels = None
depends_on = None


_REVISION_TABLES = (
    "books",
    "chapters",
    "characters",
    "character_events",
    "agent_personas",
    "book_agent_personas",
    "llm_profiles",
    "agent_model_bindings",
)


def _assert_foreign_keys_clean(connection) -> None:
    if connection.dialect.name != "sqlite":
        return
    connection.exec_driver_sql("PRAGMA foreign_keys=ON")
    violations = connection.exec_driver_sql("PRAGMA foreign_key_check").fetchall()
    if violations:
        raise RuntimeError(f"foreign_key_check failed before migration: {violations!r}")


def _backfill_search_documents(connection) -> None:
    """Index only material the author can already read through public APIs."""
    rows: list[dict[str, object]] = []
    for row in connection.execute(sa.text("SELECT id, title, world_setting FROM books")).mappings():
        rows.append({
            "id": f"book:{row['id']}", "book_id": row["id"], "chapter_id": None,
            "character_id": None, "result_type": "book", "title": row["title"] or "",
            "body": row["world_setting"] or "",
        })
    for row in connection.execute(sa.text("SELECT id, book_id, title, user_prompt, author_note, draft_text FROM chapters")).mappings():
        rows.append({
            "id": f"chapter:{row['id']}", "book_id": row["book_id"], "chapter_id": row["id"],
            "character_id": None, "result_type": "chapter", "title": row["title"] or "",
            "body": "\n".join((row["user_prompt"] or "", row["author_note"] or "", row["draft_text"] or "")),
        })
    for row in connection.execute(sa.text("SELECT id, book_id, name, role, fixed_profile FROM characters")).mappings():
        rows.append({
            "id": f"character:{row['id']}", "book_id": row["book_id"], "chapter_id": None,
            "character_id": row["id"], "result_type": "character", "title": row["name"] or "",
            "body": "\n".join((row["role"] or "", row["fixed_profile"] or "")),
        })
    for row in connection.execute(sa.text("""
        SELECT e.id, e.book_id, e.chapter_id, e.character_id, e.event_text, c.name
        FROM character_events AS e
        JOIN characters AS c ON c.id = e.character_id
        JOIN chapters AS chapter ON chapter.id = e.chapter_id
        WHERE NOT EXISTS (
            SELECT 1
            FROM chapter_archive_revisions AS r
            WHERE r.chapter_id = e.chapter_id
              AND r.is_active = 1
              AND r.status = 'complete'
              AND chapter.active_archive_revision_id = r.id
        )
    """)).mappings():
        rows.append({
            "id": f"character-event:{row['id']}", "book_id": row["book_id"],
            "chapter_id": row["chapter_id"], "character_id": row["character_id"],
            "result_type": "character", "title": row["name"] or "人物记录",
            "body": row["event_text"] or "",
        })
    for row in connection.execute(sa.text("""
        SELECT r.id AS revision_id, r.chapter_id, c.book_id, r.summary
        FROM chapter_archive_revisions AS r
        JOIN chapters AS c ON c.id = r.chapter_id
        WHERE r.is_active = 1 AND r.status = 'complete' AND c.active_archive_revision_id = r.id
    """)).mappings():
        rows.append({
            "id": f"archive-summary:{row['revision_id']}", "book_id": row["book_id"], "chapter_id": row["chapter_id"],
            "character_id": None, "result_type": "archive", "title": "归档摘要", "body": row["summary"] or "",
        })
    for row in connection.execute(sa.text("""
        SELECT f.id, r.chapter_id, c.book_id, f.fact_type, f.fact_text
        FROM chapter_archive_facts AS f
        JOIN chapter_archive_revisions AS r ON r.id = f.revision_id
        JOIN chapters AS c ON c.id = r.chapter_id
        WHERE r.is_active = 1 AND r.status = 'complete' AND c.active_archive_revision_id = r.id
    """)).mappings():
        rows.append({
            "id": f"archive-fact:{row['id']}", "book_id": row["book_id"], "chapter_id": row["chapter_id"],
            "character_id": None, "result_type": "archive", "title": row["fact_type"] or "归档事实", "body": row["fact_text"] or "",
        })
    if rows:
        connection.execute(sa.text("""
            INSERT INTO search_documents
                (id, book_id, chapter_id, character_id, result_type, title, body, updated_at)
            VALUES (:id, :book_id, :chapter_id, :character_id, :result_type, :title, :body, CURRENT_TIMESTAMP)
        """), rows)


def _create_search_fts(connection) -> None:
    if connection.dialect.name != "sqlite":
        raise RuntimeError("ICTW full-text search requires SQLite FTS5")
    connection.exec_driver_sql("""
        CREATE VIRTUAL TABLE search_documents_fts USING fts5(
            title,
            body,
            content='search_documents',
            content_rowid='rowid',
            tokenize='trigram'
        )
    """)
    connection.exec_driver_sql("""
        CREATE TRIGGER search_documents_fts_ai AFTER INSERT ON search_documents BEGIN
            INSERT INTO search_documents_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END
    """)
    connection.exec_driver_sql("""
        CREATE TRIGGER search_documents_fts_ad AFTER DELETE ON search_documents BEGIN
            INSERT INTO search_documents_fts(search_documents_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
        END
    """)
    connection.exec_driver_sql("""
        CREATE TRIGGER search_documents_fts_au AFTER UPDATE ON search_documents BEGIN
            INSERT INTO search_documents_fts(search_documents_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
            INSERT INTO search_documents_fts(rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
        END
    """)
    connection.exec_driver_sql(
        "INSERT INTO search_documents_fts(search_documents_fts) VALUES ('rebuild')"
    )


def upgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)
    for table in _REVISION_TABLES:
        op.add_column(table, sa.Column("content_revision", sa.Integer(), nullable=False, server_default="1"))
    op.add_column("job_runs", sa.Column("model_binding_snapshot", sa.JSON(), nullable=True))
    op.create_table(
        "book_agent_model_bindings",
        sa.Column("id", sa.String(length=36), nullable=False),
        sa.Column("book_id", sa.String(length=36), nullable=False),
        sa.Column("agent_role", sa.String(length=32), nullable=False),
        sa.Column("llm_profile_id", sa.String(length=36), nullable=True),
        sa.Column("thinking_enabled", sa.Boolean(), nullable=True),
        sa.Column("reasoning_effort", sa.String(length=32), nullable=True),
        sa.Column("temperature", sa.Float(), nullable=True),
        sa.Column("content_revision", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["book_id"], ["books.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["llm_profile_id"], ["llm_profiles.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("book_id", "agent_role", name="uq_book_agent_model_binding_role"),
    )
    op.create_index("ix_book_agent_model_bindings_book_id", "book_agent_model_bindings", ["book_id"], unique=False)
    op.create_table(
        "search_documents",
        sa.Column("id", sa.String(length=160), nullable=False),
        sa.Column("book_id", sa.String(length=36), nullable=False),
        sa.Column("chapter_id", sa.String(length=36), nullable=True),
        sa.Column("character_id", sa.String(length=36), nullable=True),
        sa.Column("result_type", sa.String(length=24), nullable=False),
        sa.Column("title", sa.Text(), nullable=False, server_default=""),
        sa.Column("body", sa.Text(), nullable=False, server_default=""),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["book_id"], ["books.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["chapter_id"], ["chapters.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["character_id"], ["characters.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_search_documents_book_type", "search_documents", ["book_id", "result_type"], unique=False)
    op.create_index("ix_search_documents_chapter", "search_documents", ["chapter_id"], unique=False)
    op.create_index("ix_search_documents_character", "search_documents", ["character_id"], unique=False)
    _backfill_search_documents(connection)
    _create_search_fts(connection)
    _assert_foreign_keys_clean(connection)


def downgrade() -> None:
    # This is only for an explicitly authorised, isolated recovery rehearsal.
    # Normal production rollback restores the verified pre-deploy database and
    # old code; dropping these records is never a routine rollback path.
    from app.migration_safety import require_destructive_downgrade_authorization

    connection = op.get_bind()
    require_destructive_downgrade_authorization(connection, revision=revision)
    connection.exec_driver_sql("DROP TRIGGER IF EXISTS search_documents_fts_au")
    connection.exec_driver_sql("DROP TRIGGER IF EXISTS search_documents_fts_ad")
    connection.exec_driver_sql("DROP TRIGGER IF EXISTS search_documents_fts_ai")
    connection.exec_driver_sql("DROP TABLE IF EXISTS search_documents_fts")
    op.drop_index("ix_search_documents_character", table_name="search_documents")
    op.drop_index("ix_search_documents_chapter", table_name="search_documents")
    op.drop_index("ix_search_documents_book_type", table_name="search_documents")
    op.drop_table("search_documents")
    op.drop_index("ix_book_agent_model_bindings_book_id", table_name="book_agent_model_bindings")
    op.drop_table("book_agent_model_bindings")
    with op.batch_alter_table("job_runs") as batch_op:
        batch_op.drop_column("model_binding_snapshot")
    for table in reversed(_REVISION_TABLES):
        with op.batch_alter_table(table) as batch_op:
            batch_op.drop_column("content_revision")
