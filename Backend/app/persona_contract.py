"""Pure editable-persona text and capacity contract, shared by API and maintenance."""

BIBLE_FOCUS_PERSONAS = {
    "writer": (
        "写作前先在内部确认作者原始 Bible 中明确要求发生的核心事件、参与人物、因果关系，以及指定的顺序和结尾。"
        "正文应完整实现这些要求，不得以相似事件替换，不得把核心事件弱化为背景或一笔带过。"
        "细节描写、互动和局部波折应展开这些事件；历史资料用于衔接和保持事实一致，不得据此另选本章主线。"
        "未明确指定的过程允许自然展开，不额外强制场景数、段落结构或描写配额；只输出正文，不输出内部核对过程。"
    ),
    "checker": (
        "检查时对照作者原始 Bible，核对明确要求的核心事件是否真正发生、明确指定的顺序和结果是否实现、"
        "明确禁止事项是否被违背，以及新增内容是否挤掉或改变本章主线。"
        "只报告有具体原文依据的核心遗漏或偏离，不因表达方式不同判违规，不把未指定的细节补成硬要求。"
        "正常对话、细节、情绪变化和已有关系的渐进发展不需要 Bible 逐项授权。"
        "Bible 为空时跳过本章剧情要求检查，不补造要求；其他事实一致性和人物授权检查照常。"
        "沿用现有检查结果格式，不输出额外清单或文风评价。"
    ),
}


def with_bible_focus(role: str, persona: str) -> str:
    """Editable text upgrade; only invoked for defaults or explicit maintenance."""
    addition = BIBLE_FOCUS_PERSONAS.get(role)
    if addition is None or addition in persona:
        return persona
    return persona + "\n\n" + addition


# Preserve the original author allowance plus the longest explicit upgrade.
BASE_EDITABLE_PERSONA_MAX_LENGTH = 8000
EDITABLE_PERSONA_MAX_LENGTH = BASE_EDITABLE_PERSONA_MAX_LENGTH + max(
    len("\n\n" + addition) for addition in BIBLE_FOCUS_PERSONAS.values()
)
