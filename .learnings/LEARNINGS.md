# Learnings

## [LRN-20260813-001] correction

**Logged**: 2026-08-13T00:00:00+08:00
**Priority**: high
**Status**: promoted
**Area**: docs
**Promoted**: `AGENTS.md`

### Summary

`PROJECT_PLAN.md` 只记录各版本完成了什么、当前状态和后续升级项，不得承载施工细节。

### Details

现行计划曾逐步堆入文件范围、接口字段、施工阶段、测试步骤和临时排障过程，虽然信息完整，却使唯一权威文档难以快速回答“每个版本做了什么”。这些细节已有代码、测试、Git 历史、完成计划档案和生产运维记录承载。

### Suggested Action

根计划保持版本摘要结构；实施方案留在施工期间的工作记录，完成后进入 `archive/plans/`。生产命令与回滚事实只进仓库外 `NB_info.md`。

### Metadata

- Source: user_feedback
- Related Files: `PROJECT_PLAN.md`, `AGENTS.md`, `archive/plans/`
- Tags: project-plan, context-hygiene, version-history

### Resolution

- **Resolved**: 2026-08-13T00:00:00+08:00
- **Notes**: 已提升为 `AGENTS.md` 永久规则，并将 v1.9.2 完整计划归档、根计划改为精简版本记录。
