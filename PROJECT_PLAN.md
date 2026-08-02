# ICTW PROJECT_PLAN

> 本文件是唯一权威计划与状态来源。详细版本执行记录见 [`archive/v1.6.0施工plan.md`](archive/v1.6.0施工plan.md)，v1.5 完结索引见 [`archive/v1.5.0施工plan.md`](archive/v1.5.0施工plan.md)。归档与本文冲突时，以本文为准。

## 项目与现状

- SwiftUI iOS（`LinoI`）/macOS（`LinoIMac`）客户端，FastAPI + SQLAlchemy + Alembic + SQLite 后端；产品历史标识 `LinoI` 与 Bundle/Keychain/草稿目录兼容标识不改。
- `v1.5.0(14)` 于 2026-07-28 已完成 Backend 部署、macOS 换装、tag 与 GitHub Release；iOS 安装由用户处理。
- 当前工作树有用户未提交的 `App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme` 改动；v1.6 施工不得覆盖、回滚或纳入无关提交。
- `v1.6.3(18)` 已完成 Backend 部署、Alembic 摘要合并迁移、macOS 正式 App 换装、tag 与 GitHub Release；iOS 未打包或安装。`v1.6.4(19)` 已完成 Backend 部署和 macOS 换装，待 tag 与 GitHub Release。

## 当前版本：v1.6.4(19) Selector／Checker 解释性快修（已部署，待发布，iOS 不发包）

### 版本目标

让 DeepSeek 保持一次完成整章的文学性，同时把剧情控制、历史记忆和失败解释收回系统。Bible 是唯一不可改写的剧情来源；系统不自动把候选正文反复扩写、压缩或修订。

### 已确认决定

1. 工作流为 **Memory Selector → Writer → Checker → 用户接受 → Extractor**；Reviser 完全删除。
2. 用户在章节页只填写 Bible（以及标题、允许人物）。删除目标字数和本章备注输入；旧 `target_word_count`、`author_note`、`chapter_style` 仅做存储/wire 兼容，不参与 v1.6 写作。
3. Bible 原文由程序从章节快照直接传给 Selector/Writer/Checker，不被任何 Agent 改写；以 hash 与输入版本保护。当前 Bible 与历史记忆冲突时，Bible 优先。
4. Selector 机械扩大召回后低温压缩为带来源的“本章记忆简报”；上一章尾段独立承担开场承接。无来源或无效来源的记忆不进入 Writer，实际 Writer 上下文可查看。
5. Writer 一次生成整章，不分场景、不扩写旧稿。只要求去空白字符 `>=4000` 且正常结束；无产品字数上限。首稿不足/截断仅可从同一输入完整重写一次，第二次失败即停止；人物白名单等既有可程序验证约束仍保留。
6. Checker 只对 Bible 的遗漏、矛盾和新增剧情举证，结论为通过/存疑/明确越界；不修改正文、不评价文风。Writer 新稿只有 Checker 明确通过后才提升为当前正文；存疑、越界或检查不可用的稿件仅在后端留档，前端显示原因和必要证据但不渲染全文。
7. Extractor 只从已接受正文提取唯一章节摘要、状态变化、未决事项和带来源原子记忆；既有人物白名单和字段回滚约束不变。
8. 所有候选稿在后端保留且互不覆盖，但双端不拉取、不展示、不切换候选全文；当前正文是唯一前端正文。四个现役 Agent 的默认人格词重做，双端可编辑、可恢复默认。人格词与始终生效的不可编辑程序协议分离。

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

**2026-08-01 v1.6.0 发布完成**：实现提交 `011457d`、生产落账提交 `1051650`；annotated tag `v1.6.0` 指向 `1051650` 并已推送。GitHub Release `ICTW / LinoI v1.6.0` 已发布，附带 `ICTW-1.6.0.zip`（3,166,379 B；GitHub digest 与本地 SHA-256 一致）。Release 地址：<https://github.com/linocai/Ictw/releases/tag/v1.6.0>。iOS 未安装，由用户自行处理。

**2026-08-01 发布后缺陷修复完成（尚未部署）**：实测发现 Writer 因未获准人物失败后，点击人物会清除失败态，而旧正文的 Checker 结果与 `draft_ready` 机械映射使界面误画为全通过；失败后的异步刷新还可能覆盖刚选择的人物。现已在生成开始／写作失败时失效旧 Checker 状态，`draft_ready` 仅在当前 Checker 明确 passed 时完成检查步骤，并以本地编辑 revision 阻止迟到刷新覆盖输入。设计同步收口为“候选仅后端留档”：双端删除候选全文、切换和刷新入口，Writer 新稿经确定性校验与 Checker passed 后才提升为当前正文；其它稿件不进入正文区。回归覆盖未获准人物、Checker violation、可见基线保持和刷新竞态；Backend 87 项、客户端状态测试、iOS/macOS Debug、唯一 Alembic head 与 diff check 全部通过。生产 Backend 与正式 App 仍是已发布的原 `v1.6.0(15)`，本补丁未部署、未换装。

**2026-08-01 v1.6.1 发版授权**：用户授权将上述修复作为补丁版发布，并要求在 iOS 发包前停止。版本更新为 `1.6.1(16)`；范围为全量验证、生产 Backend 备份与部署、macOS 正式 App 换装、tag、推送和 GitHub Release，不打包或安装 iOS。

**2026-08-01 v1.6.1 生产部署与 macOS 换装完成**：带正式版本号的 Backend 87 项、客户端状态测试、iOS/macOS Debug 与签名 macOS Release 构建均通过；唯一 Alembic head 保持 `20260801_0007`，本补丁无新迁移。部署前全量备份位于 `/opt/linoi/backups/20260801-130105`，备份库与生产库完整性、外键检查均通过；服务内外网健康检查为 `1.6.1`，`NRestarts=0`，实体数量保持 `3 books / 59 chapters / 28 characters / 222 character_events / 4 personas / 4 bindings`。本机正式 App 已换装、验签并启动 `1.6.1(16)`，旧版备份位于 `/tmp/ictw-app-backup-v161.q1AFVw/ICTW-v1.6.0-build15.app`。发布包 `ICTW-1.6.1.zip` 为 3,129,059 B，SHA-256 `955322bd257aa9aeaa34d28dafe5177e66f99fa9700396e9440c45d5dc5607d9`。iOS 未打包或安装；下一步只剩 tag、推送和 GitHub Release。

**2026-08-01 v1.6.1 发布完成**：实现提交 `3fce69f`、版本提交 `89437c0`、生产落账提交 `5cf238c`；annotated tag `v1.6.1` 指向 `5cf238c` 并已推送。GitHub Release `ICTW / LinoI v1.6.1` 已发布，资产 `ICTW-1.6.1.zip` 为 3,129,059 B，GitHub digest 与本地 SHA-256 一致。Release 地址：<https://github.com/linocai/Ictw/releases/tag/v1.6.1>。本次按用户要求在 iOS 发包前停止，未打包或安装 iOS。

**2026-08-01 v1.6.2 Review 修复与发版授权**：独立 Review 确认旧 Checker 在取消／替换任务后仍可能提升旧候选、旧客户端候选 API 可提升未通过稿、失败重生成会锁住旧正文、`/job` 仍下发候选全文，以及正文提升与 JobRun 终态不原子。现已将取消／完成纳入同一任务所有权临界区，正文／候选／JobRun 在同一事务完成；候选列表和选择端点退出公开 API，`/job` 不再返回候选，复查仅返回空正文兼容壳与 Checker 元数据。双端恢复旧可见正文自己的 Checker 状态，允许失败后复查／接受，并以本地 revision 拒绝迟到复查结果。版本更新为 `1.6.2(17)`；Backend 88 项、客户端状态测试、iOS/macOS Debug、签名 macOS Release 和唯一 Alembic head `20260801_0007` 已通过，本补丁无新 migration。用户授权直接发布 Backend、macOS、tag 与 GitHub Release；按上一版边界不打包或安装 iOS。

**2026-08-01 v1.6.2 生产部署与 macOS 换装完成**：部署前全量备份位于 `/opt/linoi/backups/20260801-150522`，备份库与生产库 integrity／foreign keys 均通过；本补丁无新 migration，Alembic 保持 `20260801_0007`。内外网健康检查均为 `1.6.2`，服务 active、`NRestarts=0`、发布后错误标记为 0；实体数量保持 `3 books / 59 chapters / 28 characters / 215 character_events / 4 personas / 4 bindings`，无运行中章节。本机正式 App 已换装、验签并启动 `1.6.2(17)`，旧版备份位于 `/tmp/ictw-app-backup-v162.nnlPUl/ICTW-v1.6.1-build16.app`。发布包 `ICTW-1.6.2.zip` 为 3,119,531 B，SHA-256 `6c0e6d64bfea806879cd3f61e581185fd527684f332507ff7b1587462ec8a5cf`。iOS 未打包或安装；下一步只剩 tag、推送和 GitHub Release。

**2026-08-01 v1.6.2 发布完成**：实现提交 `59395cd`、生产落账提交 `59a6381`；annotated tag `v1.6.2` 指向 `59a6381` 并已推送。GitHub Release `ICTW / LinoI v1.6.2` 已发布，资产 `ICTW-1.6.2.zip` 为 3,119,531 B，GitHub digest 与本地 SHA-256 一致。Release 地址：<https://github.com/linocai/Ictw/releases/tag/v1.6.2>。本次按用户要求在 iOS 发包前停止，未打包或安装 iOS。

**2026-08-01 v1.6.3 快修施工**：用户决定合并 Extractor 重复的「梗概／长摘要」，不进入正式 Planner 工作流。`long_summary` 成为唯一章节摘要且不设机械字数；Alembic 将历史 `summary` 原文回填至空摘要后物理删除旧列，已有新摘要不覆盖。Extractor 不再生成旧梗概，Selector 每章只提供一份稳定摘要来源；API 继续动态提供旧 `summary` wire 别名兼容 v1.6.2 客户端，双端只展示「章节摘要」。版本更新为 `1.6.3(18)`；Backend 89 项、客户端状态测试、iOS/macOS Debug、签名 macOS Release、唯一 Alembic head `20260801_0008` 与迁移子表保全测试均通过。生产部署、macOS 换装、tag 与 Release 尚未执行。

**2026-08-01 v1.6.3 生产部署与 macOS 换装完成**：迁移前确认 59 章中 58 章仅有旧梗概、1 章已有新摘要；停服全量备份位于 `/opt/linoi/backups/20260801-160612`。Alembic 升级至唯一 head `20260801_0008`，旧 `summary` 列已删除且 59 章 `long_summary` 均非空；数据库 integrity／foreign keys、旧 App `summary` wire 别名、零活动任务和实体数量 `3 books / 59 chapters / 27 characters / 214 chapter links / 215 character events / 4 personas / 4 bindings` 全部复核通过。内外网健康检查均为 `1.6.3`，服务 active、`NRestarts=0`、错误标记为 0。本机正式 App 已换装、验签并运行 `1.6.3(18)`，旧版备份位于 `/tmp/ictw-app-backup-v163.HdZKmc`；发布包 `ICTW-1.6.3.zip` 为 3,117,944 B，SHA-256 `12c4bbcae75b580bf29fe55fa5387c54b80cee2d8322430be8aebe8f8886fc17`。iOS 未打包或安装；下一步只剩 tag、推送和 GitHub Release。

**2026-08-01 v1.6.3 发布完成**：实现提交 `0b62f13`、生产落账提交 `c9b3ebf`；annotated tag `v1.6.3` 指向 `c9b3ebf` 并已推送。GitHub Release `ICTW / LinoI v1.6.3` 已发布，资产 `ICTW-1.6.3.zip` 为 3,117,944 B，GitHub digest 与本地 SHA-256 一致。Release 地址：<https://github.com/linocai/Ictw/releases/tag/v1.6.3>。iOS 未打包或安装，由用户自行处理。

**2026-08-02 v1.6.4 快修授权与施工**：生产只读核查确认 Selector 虽正常调用，却在真实多章数据上出现“35 个摘要来源几乎全选”与“0 条记忆”两个极端；Checker 具体 issues 与 reason 已由后端保存，但客户端固定文案和旧正文状态隔离共同吞掉了失败候选解释。快修将每章大事记／摘要收口为单一历史来源，候选按相关性排序，Selector 固定协议限制最多 8 条简报、4 条冲突、16 个来源并对逐章复述规模自动退回一次；Writer 实际简报和审计来源分层展示并修正字符统计。Checker 失败候选元数据与旧可见正文状态分离，前端展示具体原因和必要证据但不返回候选全文。版本更新为 `1.6.4(19)`；Backend 93 项、客户端状态测试、iOS/macOS Debug、签名 macOS Release、唯一 Alembic head `20260801_0008` 与 diff check 全绿，发布 ZIP 为 3,140,891 B、SHA-256 `f8258b0c96af7740ca736abc7795dd105ea6fd3aa674eaa59ee67ebe39602842`。用户授权完成香港 Backend 部署、macOS 换装、tag、推送与 GitHub Release，延续约定不打包或安装 iOS。

**2026-08-02 v1.6.4 生产部署与 macOS 换装完成**：停服前确认现网 `1.6.3`、零活动任务／章节、数据库 integrity／foreign keys 与 Alembic `20260801_0008` 正常；停服全量备份位于 `/opt/linoi/backups/20260802-095737`。本补丁无新 migration，部署后内外网健康检查均为 `1.6.4`，服务 active、`NRestarts=0`、发布后错误标记为 0；数据库大小保持 2,170,880 B，实体数量保持 `3 books / 61 chapters / 27 characters / 222 chapter links / 221 character events / 4 personas / 4 bindings`。本机正式 App 已验签、换装并运行 `1.6.4(19)`，旧版备份位于 `/tmp/ictw-app-backup-v164.IQYjZ1/ICTW-v1.6.3-build18.app`。发布 ZIP 为 3,140,891 B，SHA-256 `f8258b0c96af7740ca736abc7795dd105ea6fd3aa674eaa59ee67ebe39602842`。iOS 未打包或安装；下一步只剩 tag、推送和 GitHub Release。

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
- `v1.6.0(15)`：已发布，详细执行记录见 `archive/v1.6.0施工plan.md`。
- `v1.6.1(16)`：已发布，iOS 未发包；补丁记录见 `archive/v1.6.0施工plan.md`。
- `v1.6.2(17)`：已发布，iOS 未发包；记录见 `archive/v1.6.0施工plan.md`。
- `v1.6.3(18)`：已发布，iOS 未发包；记录见 `archive/v1.6.0施工plan.md`。
- `v1.6.4(19)`：已部署，待 tag／Release，iOS 不发包；记录见 `archive/v1.6.0施工plan.md`。
