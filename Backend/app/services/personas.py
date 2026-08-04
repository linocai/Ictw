from __future__ import annotations

from sqlalchemy.orm import Session

from app.models import AgentModelBinding, AgentPersona


DEFAULT_PERSONAS: dict[str, str] = {
    "memory_selector": (
        "你是严谨的小说记忆编辑。只压缩有明确来源的既有历史事实，为本章写作提供"
        "短而密集、可追溯的记忆简报。绝不推断人物动机、补足因果、续写事件或预测未来。"
    ),
    "writer": (
        "你是服从 Bible 的中文小说创作者。Bible 决定剧情；你的文学自由只用于动作、"
        "对话、心理、环境与自然衔接等表达层，不创造新的剧情状态。"
    ),
    "checker": (
        "你是克制的剧情边界审计员。只举证 Bible 的遗漏、矛盾与剧情越界，"
        "区分合理文学延展和会改变后续事实的新剧情；不评价文风，也不修改正文。"
    ),
    "extractor": (
        "你是忠实的小说档案管理员。只归档用户已接受正文中实际发生的内容，"
        "区分确定事实、人物认知和未解决事项；不使用 Bible 补写正文没有发生的事实。"
    ),
}


AGENT_ROLES = tuple(DEFAULT_PERSONAS.keys())

# These rules are deliberately separate from DEFAULT_PERSONAS.  The latter is
# user-editable product copy; this is the program-owned contract appended by
# each v1.6 agent implementation and exposed read-only by Settings.
PROGRAM_PROTOCOLS: dict[str, str] = {
    "memory_selector": (
        "不可编辑程序协议：只可使用提供的候选来源；每条记忆简报事实必须包含 text 和"
        "非空 source_ids。可报告 Bible 与记忆的冲突，但不得调和、推断或创造事实。"
        "仅输出约定的 JSON 结构。"
    ),
    "writer": (
        "不可编辑程序协议：原始 Bible 是最高剧情来源，必须按原文约束完成整章。"
        "不得新增会改变后续事实的人物、线索、秘密、冲突或关系变化；只输出完整正文纯文本。"
    ),
    "checker": (
        "不可编辑程序协议：只输出 JSON 检查结论 passed、suspect 或 violation，以及逐项"
        "kind、draft_evidence、bible_evidence、reason。必须基于证据；不得修改、续写正文"
        "或作任何文风评价。"
    ),
    "extractor": (
        "不可编辑程序协议：只以用户已接受的正文为事实来源，输出约定 JSON 归档结构；"
        "不得用 Bible 或推测补写事实，并保留章节来源。人物归属只输出白名单中的精确姓名，"
        "由程序映射内部 ID；人物事件和动态字段必须附正文原文证据并明确写出所属人物。"
        "state_updates 是可回放的当前状态：即时快照必须完整替换位置、行动、情绪三槽；持续状态和唯一人物关系"
        "只能 set/clear。同一无向人物对整份输出只能写一次，归到人物白名单顺序更靠前的一方，"
        "关系值必须是双方共同状态而非各自视角。掌握信息归入 atomic_memories，禁止其他状态、未知或过程式快照；宁缺毋滥。"
    ),
}

def compose_system_prompt(role: str, editable_persona: str) -> str:
    """Append a non-overridable protocol to the user-editable persona."""
    return f"{editable_persona.strip()}\n\n{PROGRAM_PROTOCOLS[role]}"


def seed_defaults(db: Session) -> None:
    changed = False
    # Fresh/test databases may be initialized straight from ORM metadata.  Keep
    # that path consistent with the Alembic migration without touching audits.
    for retired_role in ("reviser", "compressor"):
        persona = db.get(AgentPersona, retired_role)
        binding = db.get(AgentModelBinding, retired_role)
        if persona is not None:
            db.delete(persona)
            changed = True
        if binding is not None:
            db.delete(binding)
            changed = True
    if changed:
        db.flush()
    for role, prompt in DEFAULT_PERSONAS.items():
        if db.get(AgentPersona, role) is None:
            db.add(AgentPersona(agent_role=role, system_prompt=prompt))
            changed = True
        if db.get(AgentModelBinding, role) is None:
            writer_binding = db.get(AgentModelBinding, "writer") if role in {"memory_selector", "checker"} else None
            db.add(
                AgentModelBinding(
                    agent_role=role,
                    llm_profile_id=writer_binding.llm_profile_id if writer_binding else None,
                    thinking_enabled=None,
                    reasoning_effort=None,
                )
            )
            changed = True
    if changed:
        db.commit()


def get_persona(db: Session, role: str) -> str:
    if role not in AGENT_ROLES:
        raise KeyError(f"unknown active agent role: {role}")
    persona = db.get(AgentPersona, role)
    if persona is None:
        return DEFAULT_PERSONAS[role]
    return persona.system_prompt
