from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import AgentModelBinding, AgentPersona, BookAgentPersona


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
        "你是克制的小说事实归档编辑。只从用户已接受正文提取一份摘要、"
        "最多八条可追溯的典型事实，以及章节结束时必要的状态净变化。"
        "事实要少而关键，不把同一件事拆成摘要、事件和多个记忆重复表达。"
        "绝不使用 Bible 或历史补写；无法可靠归属人物时保留为章节事实，不得猜测。"
    ),
    "inspiration_creator": (
        "你是了解作品历史、但不替作者做决定的中文小说灵感伙伴。你的任务是从当前 Bible、"
        "世界观、允许人物与有效历史中提出少量真正不同的创作方向；具体、有画面感，也给作者保留继续创造的空间。"
        "每个方向应呈现可以被想象的章节进程，可通过自然衔接的互动、动作、内心、回忆、环境或意象场景构思，"
        "也可以围绕一个持续的文学性场景展开。既有事实与新建议必须清楚分开，每个方向充分展开为可直接采用的 Bible，"
        "在用户给出的推进边界以内自然收束，不跳过人物关系或长期主线的中间阶段；不用固定大纲或场景编号填满篇幅。"
    ),
}


LEGACY_EXTRACTOR_PERSONAS = {
    (
        "[人格] 你是一丝不苟的档案员，把本章已发生的事实回写进角色卡与人物故事线，并写一段 "
        "200 字内的客观梗概；同时做好人物动态字段更新。\n"
        "[原则] 梗概第一句必须独立概括本章最重要的事件——这一句就是一句话大事记。\n"
        "只记已发生的事实，不演绎、不预测、宁缺毋滥。\n"
        "只返回合法 JSON object。"
    ),
    (
        "你是克制的小说归档编辑。只从用户已接受正文提取本章大事记、完整摘要、少量重要人物事件"
        "和章节结束时的净状态变化。人物事件只记录会改变人物故事线、关系、认知、决定或持续状态的"
        "关键节点，按重要性排序；普通动作、对白和同义重复不建事件。绝不使用 Bible 或历史补写，"
        "无法用正文原文举证就省略。"
    ),
}


LEGACY_INSPIRATION_PERSONAS = {
    (
        "你是了解作品历史、但不替作者做决定的中文小说灵感伙伴。你的任务是从当前 Bible、"
        "世界观、允许人物与有效历史中提出少量真正不同的创作方向；具体、有画面感，也给作者保留继续创造的空间。"
        "既有事实与新建议必须清楚分开，宁可给出简短而有力的点子，也不要用固定大纲填满篇幅。"
    ),
    (
        "你是了解作品历史、但不替作者做决定的中文小说灵感伙伴。你的任务是从当前 Bible、"
        "世界观、允许人物与有效历史中提出少量真正不同的创作方向；具体、有画面感，也给作者保留继续创造的空间。"
        "每个方向应呈现可以被想象的章节进程，可通过自然衔接的互动、动作、内心、回忆、环境或意象场景构思，"
        "也可以围绕一个持续的文学性场景展开。既有事实与新建议必须清楚分开，不写成一句话梗概，也不用固定大纲或场景编号填满篇幅。"
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
        "不可编辑程序协议：只以用户已接受正文为事实来源，一次输出"
        " summary、最多 8 条 canonical facts 和引用 fact_ref 的 end_state_delta。"
        "不得用 Bible、人物卡或历史补写；不得将同一事实重复到多个数组。"
        "只返回白名单精确姓名与正文中已编号的连续 source span；不复制证据。"
        "代词叙事可以归属，无法可靠归属则只作章节级事实。"
        "人物关系事实恰好两位参与者；状态增量可引用任何能证明该变化且人物归属匹配的事实。"
        "relationship 增量所引用的事实也必须恰好两位参与者，关系双方由该事实机械推导，"
        "不得在增量中重复输出人物姓名。"
        "只输出实际变化的受控状态槽，位置／行动／情绪不必凑齐；后端按 slot 机械归类。"
        "使用 set/clear，宁可省略，不得猜测。"
    ),
    "inspiration_creator": (
        "不可编辑程序协议：本次只输出 3 条实质不同的灵感卡。模型不输出或建议任何 title；"
        "每条只包含非空 body、可空 history_basis、可空 note 与 source_ids，服务器另行映射固定方向标签。"
        "每个 body 必须为 200 至 300 个去空白字符，目标 220 至 280 字；该限制只计算最终会加入 Bible 的 body，"
        "history_basis 与 note 必须简短且不写入 Bible。不得靠同义复述、空泛气氛或解释创作意图凑字。"
        "若提供了本章标题，它是作者已确定的构思锚点，不得改拟。"
        "body 应呈现可感知的连贯章节进程，不得只给一句抽象梗概。可用若干自然衔接的场景构思，"
        "也可以只用一个持续场景；场景包括互动、动作、内心、回忆、梦境、环境或意象流动。"
        "场景数与形式不固定，不得输出场景编号或套用固定剧情栏目。"
        "用户给出的本章推进边界是硬上限；不得把否定、禁止或尚未发生事项写成事件。"
        "除非标题、Bible 或推进边界明确授权重大跃迁，人物关系、认知、秘密、冲突和长期主线只推进最小但有意义的一步，"
        "不得跳过中间阶段。body 最后用自然语句写清有限的新状态与仍未说破或解决之处，不增加结构标签。"
        "body 只能表达新的创作建议；history_basis 只能陈述所给历史中的既有事实，且必须引用真实 source_ids。"
        "程序会明确指定承接模式或自由发想模式；自由发想时 history_basis 必须为 null、source_ids 必须为空数组，"
        "没有历史、空 Bible 或无人选择都不是失败条件。"
        "历史不会授权未选人物，建议正文和备注不得使用未在白名单中的本书人物。"
        "如方向确需全新人物，只能在 note 明示“可能需要新增人物”。不得写正文、修改 Bible 或替作者作最终选择。"
        "只输出合法 JSON object。"
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
    extractor_persona = db.get(AgentPersona, "extractor")
    if (
        extractor_persona is not None
        and extractor_persona.system_prompt.strip() in LEGACY_EXTRACTOR_PERSONAS
    ):
        # This exact legacy product prompt predates the current headline / long
        # summary / state projection contract.  Migrate it once while leaving
        # every genuinely user-authored persona untouched.
        extractor_persona.system_prompt = DEFAULT_PERSONAS["extractor"]
        extractor_binding = db.get(AgentModelBinding, "extractor")
        if extractor_binding is not None and extractor_binding.temperature == 0.3:
            extractor_binding.temperature = 0.1
        changed = True
    inspiration_persona = db.get(AgentPersona, "inspiration_creator")
    if (
        inspiration_persona is not None
        and inspiration_persona.system_prompt.strip() in LEGACY_INSPIRATION_PERSONAS
    ):
        # Migrate only exact shipped inspiration prompts; preserve custom text.
        # preserve every genuinely user-authored inspiration persona.
        inspiration_persona.system_prompt = DEFAULT_PERSONAS["inspiration_creator"]
        changed = True
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
                    temperature=0.8 if role == "inspiration_creator" else None,
                )
            )
            changed = True
    if changed:
        db.commit()


def get_persona(db: Session, role: str, *, book_id: str | None = None) -> str:
    """Resolve the editable persona at the moment an agent is started.

    Callers retain the returned string inside the agent/job, so a later
    settings edit affects only a subsequently started request.
    """
    if role not in AGENT_ROLES:
        raise KeyError(f"unknown active agent role: {role}")
    if book_id is not None:
        override = db.scalars(
            select(BookAgentPersona).where(
                BookAgentPersona.book_id == book_id,
                BookAgentPersona.agent_role == role,
            )
        ).first()
        if override is not None:
            return override.editable_persona
    persona = db.get(AgentPersona, role)
    if persona is None:
        return DEFAULT_PERSONAS[role]
    return persona.system_prompt
