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

## [LRN-20260814-001] best_practice

**Logged**: 2026-08-14T16:20:00+08:00
**Priority**: high
**Status**: resolved
**Area**: config

### Summary

Developer ID Release 构建必须显式关闭 Xcode base-entitlement 注入，并复核最终签名不含 `get-task-allow`。

### Details

macOS Release 使用 Developer ID Application 与 Hardened Runtime 构建时，首次产物虽通过 `codesign --verify`，但 Xcode 注入了源码 entitlements 中不存在的 `com.apple.security.get-task-allow=true`。这会让公开交付包保留调试附加能力。重新隔离构建并传入 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` 后，最终签名只保留 App Sandbox、网络客户端和用户选择文件读写权限。

### Suggested Action

后续 Developer ID 打包命令固定加入 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`；交付前同时执行深度严格验签，并用 `codesign -d --entitlements :-` 明确拒绝 `get-task-allow`。

### Metadata

- Source: error
- Related Files: `App/LinoIMac/LinoIMac.entitlements`, `App/LinoI.xcodeproj/project.pbxproj`
- Tags: macos, developer-id, entitlements, release-gate

### Resolution

- **Resolved**: 2026-08-14T16:21:00+08:00
- **Notes**: Build 42 已用新隔离目录重建，通用架构、严格签名和无调试权限门禁均通过。
