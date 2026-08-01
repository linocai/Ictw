"""v1.6 agent foundation and draft candidates

Revision ID: 20260801_0007
Revises: 20260711_0006
Create Date: 2026-08-01
"""

from __future__ import annotations

from datetime import datetime, timezone

from alembic import op
import sqlalchemy as sa


revision = "20260801_0007"
down_revision = "20260711_0006"
branch_labels = None
depends_on = None


V1_6_DEFAULT_PERSONAS = {
    "memory_selector": "你是严谨的小说记忆编辑。只压缩有明确来源的既有历史事实，为本章写作提供短而密集、可追溯的记忆简报。绝不推断人物动机、补足因果、续写事件或预测未来。",
    "writer": "你是服从 Bible 的中文小说创作者。Bible 决定剧情；你的文学自由只用于动作、对话、心理、环境与自然衔接等表达层，不创造新的剧情状态。",
    "checker": "你是克制的剧情边界审计员。只举证 Bible 的遗漏、矛盾与剧情越界，区分合理文学延展和会改变后续事实的新剧情；不评价文风，也不修改正文。",
    "extractor": "你是忠实的小说档案管理员。只归档用户已接受正文中实际发生的内容，区分确定事实、人物认知和未解决事项；不使用 Bible 补写正文没有发生的事实。",
}

OLD_DEFAULT_PERSONAS = {
    "memory_selector": (
        "你是小说写作记忆选择助手。根据本章剧情 Bible、作者备注与允许人物，从候选历史记忆中选择真正有助于本章写作的条目。只返回有序记忆 ID，不得重写、概括或补造历史。",
        "你是小说写作记忆选择助手。根据本章剧情 Bible、作者备注与允许人物，从候选历史记忆中选择真正有助于本章写作的条目，并从紧邻上一章结尾候选中选择满足开场衔接所需的最短原文片段起点。只返回有序记忆 ID 和结尾起点 ID，不得重写、概括或补造历史，也不得扩大摘取范围。",
    ),
    "writer": ("你是中文小说写作者。严格以作者的本章剧情为情节最高权威，以世界观为设定最高权威。只输出正文纯文本。",),
    "extractor": ("你是中文小说章节归档助手。从最终正文中提取本章梗概、一句话大事记、人物故事线事件和人物动态字段更新。只返回合法 JSON object。",),
}


def _assert_foreign_keys_clean(connection) -> None:
    if connection.dialect.name != "sqlite":
        return
    connection.exec_driver_sql("PRAGMA foreign_keys=ON")
    violations = connection.exec_driver_sql("PRAGMA foreign_key_check").fetchall()
    if violations:
        raise RuntimeError(f"foreign_key_check failed before migration: {violations!r}")


def upgrade() -> None:
    connection = op.get_bind()
    _assert_foreign_keys_clean(connection)

    # These columns deliberately contain only structured task metadata.  Raw
    # prompts stay out of LLM audit rows and draft text belongs in candidates.
    op.add_column("job_runs", sa.Column("memory_context", sa.JSON(), nullable=True))
    op.add_column("job_runs", sa.Column("checker_result", sa.JSON(), nullable=True))
    op.add_column("job_runs", sa.Column("bible_sha256", sa.String(length=64), nullable=True))
    op.add_column("job_runs", sa.Column("draft_fingerprint", sa.String(length=64), nullable=True))
    # Archive data is additive.  Existing summary/headline stay untouched so
    # pre-v1.6 clients can continue decoding finalized chapters.
    op.add_column("chapters", sa.Column("long_summary", sa.Text(), nullable=False, server_default=""))
    op.add_column("chapters", sa.Column("state_changes", sa.JSON(), nullable=False, server_default="[]"))
    op.add_column("chapters", sa.Column("unresolved_items", sa.JSON(), nullable=False, server_default="[]"))
    op.add_column("chapters", sa.Column("atomic_memories", sa.JSON(), nullable=False, server_default="[]"))
    op.create_table(
        "chapter_draft_candidates",
        sa.Column("id", sa.String(length=36), primary_key=True),
        sa.Column("chapter_id", sa.String(length=36), nullable=False),
        sa.Column("job_id", sa.String(length=36), nullable=True),
        sa.Column("attempt", sa.Integer(), nullable=False),
        sa.Column("draft_text", sa.Text(), nullable=False),
        sa.Column("non_whitespace_count", sa.Integer(), nullable=False),
        sa.Column("finish_reason", sa.String(length=64), nullable=True),
        sa.Column("deterministic_violations", sa.JSON(), nullable=True),
        sa.Column("checker_result", sa.JSON(), nullable=True),
        sa.Column("bible_sha256", sa.String(length=64), nullable=True),
        sa.Column("draft_fingerprint", sa.String(length=64), nullable=True),
        sa.Column("is_current", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["chapter_id"], ["chapters.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["job_id"], ["job_runs.id"], ondelete="SET NULL"),
    )
    op.create_index("ix_chapter_draft_candidates_chapter_id", "chapter_draft_candidates", ["chapter_id"])
    op.create_index("ix_chapter_draft_candidates_job_id", "chapter_draft_candidates", ["job_id"])

    # Reviser configuration is retired; historical job/audit records retain
    # their literal role strings for read-only traceability.
    connection.execute(sa.text("DELETE FROM agent_personas WHERE agent_role IN ('reviser', 'compressor')"))
    connection.execute(sa.text("DELETE FROM agent_model_bindings WHERE agent_role IN ('reviser', 'compressor')"))
    now = datetime.now(timezone.utc)
    for role, default in V1_6_DEFAULT_PERSONAS.items():
        for old_default in OLD_DEFAULT_PERSONAS.get(role, ()):
            connection.execute(
                sa.text("UPDATE agent_personas SET system_prompt=:new, updated_at=:now WHERE agent_role=:role AND system_prompt=:old"),
                {"new": default, "now": now, "role": role, "old": old_default},
            )
        exists = connection.execute(
            sa.text("SELECT 1 FROM agent_personas WHERE agent_role=:role"), {"role": role}
        ).first()
        if exists is None:
            connection.execute(
                sa.text("INSERT INTO agent_personas (agent_role, system_prompt, updated_at) VALUES (:role, :prompt, :now)"),
                {"role": role, "prompt": default, "now": now},
            )

    checker_binding = connection.execute(
        sa.text("SELECT 1 FROM agent_model_bindings WHERE agent_role='checker'")
    ).first()
    if checker_binding is None:
        writer_profile_id = connection.execute(
            sa.text("SELECT llm_profile_id FROM agent_model_bindings WHERE agent_role='writer'")
        ).scalar_one_or_none()
        connection.execute(
            sa.text("INSERT INTO agent_model_bindings (agent_role, llm_profile_id, thinking_enabled, reasoning_effort, temperature, updated_at) VALUES ('checker', :profile_id, NULL, NULL, NULL, :now)"),
            {"profile_id": writer_profile_id, "now": now},
        )
    _assert_foreign_keys_clean(connection)


def downgrade() -> None:
    op.drop_index("ix_chapter_draft_candidates_job_id", table_name="chapter_draft_candidates")
    op.drop_index("ix_chapter_draft_candidates_chapter_id", table_name="chapter_draft_candidates")
    op.drop_table("chapter_draft_candidates")
    with op.batch_alter_table("job_runs") as batch_op:
        batch_op.drop_column("draft_fingerprint")
        batch_op.drop_column("bible_sha256")
        batch_op.drop_column("checker_result")
        batch_op.drop_column("memory_context")
    with op.batch_alter_table("chapters") as batch_op:
        batch_op.drop_column("atomic_memories")
        batch_op.drop_column("unresolved_items")
        batch_op.drop_column("state_changes")
        batch_op.drop_column("long_summary")
