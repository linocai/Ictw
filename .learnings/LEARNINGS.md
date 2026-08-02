# Learnings

## [LRN-20260802-004] correction

**Logged**: 2026-08-02T17:34:56+08:00
**Priority**: high
**Status**: resolved
**Area**: frontend

### Summary

SwiftUI 网格中的固定比例操作卡必须把稳定尺寸约束施加在整个网格项上，不能只给 Button 的固有尺寸 label 设置比例。

### Details

v1.7.0 书架的“新建书”按钮把 `aspectRatio(3 / 4)` 放在按钮 label 内。`LazyVGrid` 测量 Button 时，label 以加号和短文案的固有尺寸参与布局，导致虚线卡片缩成窄胶囊，没有占满两列网格中的一个完整书封宽度。此前构建和流程型 UI 测试均通过，但未在“恰好两本书、第三项为新建卡”的真实网格换行状态检查几何尺寸。

### Suggested Action

把比例与 `maxWidth` 约束放到 Button／网格项本身，label 只负责在可用空间内居中；视觉回归必须覆盖 0、1、2、3 本书，尤其检查操作卡换行后的宽高比与可点击区域。

### Metadata

- Source: user_feedback
- Related Files: App/LinoI/ShelfViews.swift
- Tags: swiftui, lazyvgrid, button, intrinsic-size, visual-regression

### Resolution

- **Resolved**: 2026-08-02T17:38:41+08:00
- **Notes**: 将 3:4 比例和整列宽度约束移到 Button 网格项；iPhone 17 Pro 截图确认新建卡恢复完整书封尺寸，1／2／3 本书场景均通过临时 UI 回归，断言宽度、高度、0.75 比例和点击打开 sheet 全部通过。0 本书继续使用独立空态卡，不经过本次网格分支。

---

## [LRN-20260802-003] correction

**Logged**: 2026-08-02T09:41:25+08:00
**Priority**: high
**Status**: resolved
**Area**: writing-pipeline

### Summary

“Selector 已调用”和“Checker 已保存结构化结果”不等于用户实际获得了有效选择与可见失败解释，必须用生产产物分布和最终 UI 状态验证端到端语义。

### Details

用户实测指出“本次写作上下文”总在展示大量历史章节信息，Checker 失败也只显示泛化的“未通过”。只读核查确认：生产 Selector 调用本身成功，但部分任务把 35 章的全部摘要来源压成 32–33 条简报，另一些任务又选择 0 条，说明当前协议只校验来源和总预算，没有约束相关性、选择规模或整合粒度；双端还逐条展开所有原始来源，使“精炼简报”和“审计依据”混成一块。Checker 失败时后端已保存 issues 和带具体 reason 的 error_message，但客户端错误表优先覆盖原始消息，失败状态又只保留旧可见正文的 Checker 结果，导致被拒候选的原因和证据无处显示。

### Suggested Action

为 Selector 增加可程序验收的相关性／选择规模／合并粒度协议与真实多章回归样本，并把审计来源默认折叠、与 Writer 实际输入分区展示；修正实际简报字符统计。Checker 失败需单独保存并展示“本次失败候选检查结果”，只展示原因和必要证据、不返回候选全文；错误呈现必须保留后端具体 reason，通用建议只能追加而不能覆盖。

### Metadata

- Source: user_feedback
- Related Files: Backend/app/agents/memory_selector.py, Backend/app/services/context.py, Backend/app/services/write_jobs.py, App/LinoI/LinoErrorPresenter.swift, App/LinoI/LinoStores.swift, App/LinoI/ChapterEditorViews.swift, App/LinoIMac/MacChapterEditor.swift
- Tags: memory-selector, checker, explainability, production-evidence, ui-state

### Resolution

- **Resolved**: 2026-08-02T10:00:34+08:00
- **Notes**: v1.6.4 已用单章单一历史来源、相关性排序、8／4／16 规模门禁和一次纠偏重试收口 Selector；双端分层展示 Writer 简报与审计来源并修正统计。Checker 失败候选结果与旧正文状态分离，具体原因和必要证据可见且候选全文仍只留后端。Backend、双端构建、生产部署、macOS 换装、tag 与 Release 全部完成。

---

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

生成开始时分离新候选与旧可见正文的 Checker 状态；`draft_ready` 只有在当前可见正文的 Checker 明确 passed 时才能把 Bible 检查画成完成。所有服务器刷新和异步复查必须在本地编辑 revision 未变化且无未同步输入时才覆盖编辑器。候选稿继续保留在后端，但公开 API 不得列出、选择或返回真实候选全文；任务取消／替换与通过候选提升必须共用所有权临界区，正文提升和 JobRun 终态同一事务提交。

### Metadata

- Source: user_feedback
- Related Files: App/LinoI/LinoStores.swift, App/LinoI/LinoModels.swift, App/LinoI/ChapterEditorViews.swift, App/LinoIMac/MacChapterEditor.swift
- Tags: checker, stale-state, race-condition, candidates, swiftui-performance

### Resolution

- **Resolved**: 2026-08-01T15:05:00+08:00
- **Notes**: v1.6.1 完成首轮 UI 与提升闸门；v1.6.2 Review 进一步关闭公开候选 API、`/job` 正文泄漏、取消竞态和非原子终态，并恢复失败后旧正文自己的复查／接受能力与异步复查 revision 门禁。

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
