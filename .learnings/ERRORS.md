# Errors

新错误按 self-improvement 规范追加在这里；解决并稳定后移入 `archive/learnings/`。

## [ERR-20260813-001] final-audit-template-backtick

**Logged**: 2026-08-13T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

最终只读巡检的 JavaScript 模板字符串包含 shell 正则中的反引号，命令在进入 shell 前解析失败。

### Error

```
SyntaxError: Unexpected token ')'
```

### Context

- 失败发生在执行器解析阶段，没有运行任何巡检子命令，也没有修改文件或外部状态。

### Suggested Fix

传入执行器的多行 shell 不使用反引号字符；复杂文档边界检查拆成普通字符串或独立调用。

### Metadata

- Reproducible: yes
- Related Files: `PROJECT_PLAN.md`

### Resolution

- **Resolved**: 2026-08-13T00:00:00+08:00
- **Notes**: 已移除正则中的反引号并重新执行完整巡检。
