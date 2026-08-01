# ICTW PROJECT_PLAN

> 本文件是唯一权威计划与状态来源。详细版本执行记录见 [`archive/v1.6.0施工plan.md`](archive/v1.6.0施工plan.md)，v1.5 完结索引见 [`archive/v1.5.0施工plan.md`](archive/v1.5.0施工plan.md)。归档与本文冲突时，以本文为准。

## 项目与现状

- SwiftUI iOS（`LinoI`）/macOS（`LinoIMac`）客户端，FastAPI + SQLAlchemy + Alembic + SQLite 后端；产品历史标识 `LinoI` 与 Bundle/Keychain/草稿目录兼容标识不改。
- `v1.5.0(14)` 于 2026-07-28 已完成 Backend 部署、macOS 换装、tag 与 GitHub Release；iOS 安装由用户处理。
- 当前工作树有用户未提交的 `App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme` 改动；v1.6 施工不得覆盖、回滚或纳入无关提交。
- 香港现网 Backend 已运行 `v1.6.0` 新链，生产库已升级至 `20260801_0007`；本机正式 macOS App 已换装并运行 `v1.6.0(15)`。tag 与 GitHub Release 正在执行。

## 当前版本：v1.6.0(15) 写作架构升级（发布收尾中）

### 版本目标

让 DeepSeek 保持一次完成整章的文学性，同时把剧情控制、历史记忆和失败解释收回系统。Bible 是唯一不可改写的剧情来源；系统不自动把候选正文反复扩写、压缩或修订。

### 已确认决定

1. 工作流为 **Memory Selector → Writer → Checker → 用户接受 → Extractor**；Reviser 完全删除。
2. 用户在章节页只填写 Bible（以及标题、允许人物）。删除目标字数和本章备注输入；旧 `target_word_count`、`author_note`、`chapter_style` 仅做存储/wire 兼容，不参与 v1.6 写作。
3. Bible 原文由程序从章节快照直接传给 Selector/Writer/Checker，不被任何 Agent 改写；以 hash 与输入版本保护。当前 Bible 与历史记忆冲突时，Bible 优先。
4. Selector 机械扩大召回后低温压缩为带来源的“本章记忆简报”；上一章尾段独立承担开场承接。无来源或无效来源的记忆不进入 Writer，实际 Writer 上下文可查看。
5. Writer 一次生成整章，不分场景、不扩写旧稿。只要求去空白字符 `>=4000` 且正常结束；无产品字数上限。首稿不足/截断仅可从同一输入完整重写一次，第二次失败即停止；人物白名单等既有可程序验证约束仍保留。
6. Checker 只对 Bible 的遗漏、矛盾和新增剧情举证，结论为通过/存疑/明确越界；不修改正文、不评价文风。用户可重生、编辑并复查，或明确忽略后接受。
7. Extractor 只从已接受正文提取长摘要、状态变化、未决事项和带来源原子记忆；既有人物白名单和字段回滚约束不变。
8. 所有候选稿保留且互不覆盖；四个现役 Agent 的默认人格词重做，双端可编辑、可恢复默认。人格词与始终生效的不可编辑程序协议分离。

### 非范围与兼容

- 不改 Xcode target/Bundle ID/Keychain/UserDefaults/`LinoI/ChapterDrafts`；不提前收口 `chapter_style` 兼容。
- 不改变生产写入的 Alembic 门禁、LLM 错误真实分类、日志不存 API Key/Prompt/正文的安全规则。
- v1.6 的固定4000下限和无上限决定，取代旧版的80%–120%规则；实施同时更新相关仓库约束、测试和文案，不能新旧逻辑并存。

## 施工计划

| 阶段 | 责任范围 | 完成门槛 |
| --- | --- | --- |
| 1. 数据/角色底座 | Alembic、四角色 persona/binding、Checker、旧 Reviser 配置删除、API 模型 | 单一 head；旧数据/自定义 persona 兼容；没有可配置或 Settings/API 可达的 Reviser |
| 2. 写作闭环 | Selector 压缩、Bible快照、一次整写、4000门禁、候选持久化、Checker | 自动测试证明不扩写、最多一次整写、正文不被 Checker 改写 |
| 3. 归档闭环 | 新 Extractor schema、记忆召回与来源链 | 仅接受稿产生可检索的新记忆，人物约束/回滚回归通过 |
| 4. 双端体验 | 共享模型/API/状态、章节页、透明抽屉、候选与检查决策、Agent设置 | iOS/macOS 无旧字数/备注/Reviser入口；冷启动/断网/取消可解释 |
| 5. 验收发版 | 全量测试、双端构建、隔离手测、版本/部署/Release | 详见版本执行记录；用户授权后才部署和发版 |

**推荐首个施工切片**：阶段1的 migration、Persona/Binding 角色替换与 Settings API；它先建立四角色的事实来源和可见配置，再接入写作闭环，避免 UI 和后端同时猜测 Checker/Reviser 状态。

**2026-08-01 阶段1–3完成**：`20260801_0007` 建立任务／候选元数据和 Extractor 归档字段；后端已实现 Bible SHA-256 快照、带来源记忆简报、一次整章与单次同输入重写、不可覆盖候选、Checker 三档举证及候选／复查／显式覆盖 API。Extractor 以接受稿为唯一事实输入，落库长摘要、状态变化、未决事项和原子记忆，并以稳定章节／类型来源回召；人物白名单、动态字段回滚和失败回滚保持。Reviser/Compressor 运行时、factory、DI、调用和替身已物理删除。Backend `pytest -q`、唯一 Alembic head、隔离库升级与 diff check 通过；当前下一步为阶段4 双端体验。

**2026-08-01 阶段4完成**：共享客户端接入记忆上下文、候选、Checker 与新 Extractor 字段；iOS/macOS 均移除目标字数、本章备注和 Reviser 入口，新增可展开的实际写作上下文、候选正文、Bible 证据检查及覆盖接受确认。四个 Agent 的可编辑人格词、只读程序协议与恢复默认已双端落地；旧字段和旧任务仍可兼容解码。阶段5复核补齐手动编辑后复查与完整上下文指纹后，主会话最终复验 Backend 86 项、客户端状态测试、iOS Debug、macOS Debug、唯一 Alembic head 与 diff check 全绿。下一步为隔离库端到端手测与发版准备；部署、换装、版本号、tag 和 Release 尚未授权执行。

**2026-08-01 阶段5隔离体验验收完成**：以全新临时 SQLite 和替代 Bundle ID 的调试包验证 4988 字长正文、两份候选（通过首稿／明确越界的当前手动稿）、实际记忆简报／上一章尾段／两条来源／冲突提示、Checker 正文与 Bible 双证据、显式覆盖入口及四角色人格卡。iOS 发现 Checker 未通过时“接受本章”虽不可点击却仍显示绿色，已在共享按钮样式中补齐清晰灰色禁用态并复核双端；临时自动导航钩子已移除，本地服务与测试 App 已停止。撤钩后的最终回归为 Backend 86 项、客户端状态测试、iOS Debug、macOS Debug、唯一 Alembic head 与 diff check 全绿。下一步进入发版准备；版本号、生产迁移、部署、换装、tag 和 Release 仍须用户另行授权。

**2026-08-01 发版授权与候选完成**：用户明确授权一口气完成版本号、香港现网 Backend 部署与迁移、macOS 正式 App 换装、tag 和 GitHub Release，iOS 由用户处理。双 target 已更新为 `1.6.0(15)`，Backend health 版本为 `1.6.0`；带正式版本号的 Backend 86 项、客户端状态测试、iOS/macOS Debug、唯一 Alembic head 与 diff check 全绿，macOS Release 使用 Apple Development 签名构建成功，待生产前置检查与执行。

**2026-08-01 生产部署与 macOS 换装完成**：部署前备份位于 `/opt/linoi/backups/20260801-121924`，数据库完整性与外键检查通过；停服后代码同步并由 Alembic 升级至唯一 head `20260801_0007`。服务启动后内外网健康检查均为 `1.6.0`，实体数量保持 `3 books / 59 chapters / 28 characters / 222 character_events / 4 personas / 4 bindings`，角色为 Checker、Extractor、Memory Selector、Writer，systemd `NRestarts=0`。本机正式 App 已换装、验签并启动 `1.6.0(15)`，旧版备份位于 `/tmp/ictw-app-backup-v160.zyCPpJ`；发布包解压复验通过，SHA-256 为 `9b57c7c4ad6714bca5f241b2ef067c8cfb5b9f54a042bd0d5ec42c2bbcb4fca2`。iOS 未安装，由用户处理；下一步只剩 tag、推送和 GitHub Release。

## 验收基线

- 迁移前备份生产库；迁移后 `integrity_check`、`foreign_key_check`、`alembic heads` 全通过。任何生产 schema 改动只走 `alembic upgrade head`。
- Backend pytest、Alembic heads、iOS Debug、macOS Debug 按 `AGENTS.md` 命令通过；共享客户端改动默认双端构建。
- 固定测试覆盖：候选不足后的单次整写、截断、无上限正常长文、人物白名单、Selector 来源、Bible hash、Checker三结论/失败、手动编辑后的复查、明确覆盖接受及 Extractor 只读接受稿。
- 发布前以隔离数据完成 iOS/macOS 手测；真实文本和密钥不进入日志/截图。部署、tag、Release 必须另获用户明确授权。

## 暂停／待恢复：宁波云迁移

香港现网服务器到期与宁波迁移仍暂停。恢复前用户须基于当时官方 ICP/接入规则明确合规路线；在此之前仅允许本地计划、只读盘点和离线准备，不切 DNS、不停生产、不传送生产库或秘密。恢复时另写替换式执行计划，先备份并确保旧服务停止后再切换，避免双写。

## Backlog

- v1.6 完成后，基于真实使用记录评估记忆简报预算、Selector temperature 与 DeepSeek 模型配置；不将评估结果预设为产品规则。
- 阅读器书签、朗读、翻页动效等增强不纳入 v1.6。
- 云迁移路线待用户恢复并提供合规决策后再立项。

## 里程碑索引

- `v1.5.0(14)`：已发布，索引见 `archive/v1.5.0施工plan.md`。
- `v1.6.0`：已立项，详细施工契约见 `archive/v1.6.0施工plan.md`。
