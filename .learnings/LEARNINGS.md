# Learnings

## [LRN-20260801-002] correction

**Logged**: 2026-08-01T13:05:00+08:00
**Priority**: high
**Status**: resolved
**Area**: frontend

### Summary

失败候选不应在章节编辑器渲染；输入变更也不能让旧正文的 Checker 通过状态看起来像新一轮已经通过。

### Details

用户实测发现 Writer 因未获准人物失败后，点击人物会清除失败态，同时旧草稿的 Checker 结果与 `draft_ready` 的机械完成映射把界面画成全通过。失败后的异步章节刷新还可能覆盖点击后尚未同步的人物选择。候选全文嵌入 DisclosureGroup 会造成长文 SwiftUI 布局和重绘卡顿，并混淆“后台留档候选”与“当前可交付正文”。

### Suggested Action

生成开始和写作失败时清除旧 Checker 展示；`draft_ready` 只有在当前 Checker 明确 passed 时才能把 Bible 检查画成完成。所有服务器刷新必须在本地编辑 revision 未变化且无未同步输入时才覆盖编辑器。候选稿继续保留在后端，但双端不再拉取、发布或渲染候选列表与全文。

### Metadata

- Source: user_feedback
- Related Files: App/LinoI/LinoStores.swift, App/LinoI/LinoModels.swift, App/LinoI/ChapterEditorViews.swift, App/LinoIMac/MacChapterEditor.swift
- Tags: checker, stale-state, race-condition, candidates, swiftui-performance

### Resolution

- **Resolved**: 2026-08-01T13:12:00+08:00
- **Notes**: 双端移除候选全文状态与 UI；后端改为 Checker passed 后才提升当前正文；旧结果失效、刷新 revision 门禁和真实链路回归已完成。

---

## [LRN-20260728-001] correction

**Logged**: 2026-07-28T15:30:00+08:00
**Priority**: high
**Status**: pending
**Area**: infra

### Summary

中国大陆服务器使用非标准 HTTPS 端口不能作为规避 ICP 备案的合规迁移路线。

### Details

工信部现行规则按“在境内通过域名或 IP 提供互联网信息服务”判断，并不以 80/443 端口为边界。非标准端口可能暂时避开个别接入商的端口级技术拦截，但不免除备案义务，且仍可能被接入商阻断。已备案域名迁入新的境内接入商时，也应核对并完成相应接入备案。

### Suggested Action

从宁波云迁移计划中删除“非标准 HTTPS 端口可作为 ICP 替代路线”的表述。合规路线应为完成 ICP/接入备案，或将服务部署在中国大陆以外节点。

### Metadata

- Source: conversation
- Related Files: PROJECT_PLAN.md
- Tags: icp, migration, compliance, mainland-china

---
