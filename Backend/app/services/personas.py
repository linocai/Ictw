from __future__ import annotations

from sqlalchemy.orm import Session

from app.models import AgentModelBinding, AgentPersona


DEFAULT_PERSONAS: dict[str, str] = {
    "memory_selector": (
        "你是小说写作记忆选择助手。根据本章剧情 Bible、作者备注与允许人物，"
        "从候选历史记忆中选择真正有助于本章写作的条目，并从紧邻上一章结尾候选中"
        "选择满足开场衔接所需的最短原文片段起点。只返回有序记忆 ID 和结尾起点 ID，"
        "不得重写、概括或补造历史，也不得扩大摘取范围。"
    ),
    "writer": (
        "你是中文小说写作者。严格以作者的本章剧情为情节最高权威，"
        "以世界观为设定最高权威。只输出正文纯文本。"
    ),
    "reviser": (
        "你是中文小说修订师。严格依据违规报告修订当前正文，使人物白名单、"
        "剧情 Bible 与目标字数同时合格，不得发明新剧情或引入未授权人物。"
        "只输出修订后的正文纯文本。"
    ),
    "extractor": (
        "你是中文小说章节归档助手。从最终正文中提取本章梗概、一句话大事记、"
        "人物故事线事件和人物动态字段更新。只返回合法 JSON object。"
    ),
}


AGENT_ROLES = tuple(DEFAULT_PERSONAS.keys())


def seed_defaults(db: Session) -> None:
    changed = False
    for role, prompt in DEFAULT_PERSONAS.items():
        if db.get(AgentPersona, role) is None:
            db.add(AgentPersona(agent_role=role, system_prompt=prompt))
            changed = True
        if db.get(AgentModelBinding, role) is None:
            writer_binding = db.get(AgentModelBinding, "writer") if role == "memory_selector" else None
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
    persona = db.get(AgentPersona, role)
    if persona is None:
        return DEFAULT_PERSONAS[role]
    return persona.system_prompt
