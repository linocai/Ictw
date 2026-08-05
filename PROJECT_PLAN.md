# ICTW PROJECT_PLAN

> 唯一现行计划与状态来源；与 `archive/` 冲突时以本文为准。本轮仅立项规划，未实施、未调用 LLM、未读取生产正文或任何书籍正文。

## 当前状态

- 已批准目标：双端与 Backend `v1.8.0(30)`，以“可追溯事实账本”替换当前多份重叠的 Extractor 归档；需新的 Alembic migration。
- 现行 `v1.7.2(29)` 是已发布的收敛快修：Extractor 仍同时写 `headline`、摘要、三个松散归档数组、人物事件和状态更新；在线路径可逐项 salvage，Selector 会同时消费摘要、数组和人物事件。这是本版要消除的结构性重复，不再继续叠加提示词补丁。
- 当前代码事实：`chapters.status` 仍混合正文与 Extractor 阶段；`context.memory_candidates` 会叠加 legacy 摘要／数组／人物事件；`character_state_changes` 是可重放状态的 legacy 事实源。既有姓名白名单、候选稿隔离、Checker 门禁、真实上游错误分类与状态投影铁律继续适用。
- 用户工作树资产只读保护：`.learnings/ERRORS.md`、`.learnings/LEARNINGS.md`、`App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme`、`design_handoff_ios_visual_upgrade/`；不得覆盖、回退、暂存或纳入本版。

## 目标与不做事项

- 正文接受与记忆归档解耦：Checker／用户接受后正文即 `finalized`；归档独立为 `pending`、`extracting`、`complete`、`partial`、`failed`、`stale`。`partial`／`failed`／`stale` 的新归档绝不进入 Selector。
- Extractor 只保留一个 Agent、每次归档一次完整主模型调用：产出 `summary + canonical facts + end_state_delta`。取消事件定向二次调用、字段级 salvage 和让模型重复输出同一事实的多数组合同。
- 历史绝不全量重提。仅在用户审阅并确认只读候选报告后，对确认的“明显膨胀”章节作 shadow v2 重提；非候选章节不调用模型、不改现有归档，以 legacy adapter 继续使用。
- 不重跑 Writer／Checker，不改正文、Bible、章节标题、人物固定卡、旧 `headline`／摘要／事件的用户手改；不读取或记录生产正文、Prompt、token、密钥或候选全文。不改 target、Bundle ID、Keychain／UserDefaults 键、草稿目录或旧 wire 字段；不上传 App Store Connect。

## 稳定设计决定

### 1. 章节与归档生命周期

- `Chapter.status` 只表达正文写作状态；接受正文的事务把它置为 `finalized`，同时创建 v2 archive revision=`pending` 并提交。后台归档失败不得撤销接受、不得要求再次 Checker／Bible override。
- 新 revision 在 fingerprint 未变时依序 `pending → extracting → complete|partial|failed`；正文或本章人物白名单变更立即使不匹配的活跃 revision `stale`，停用其事实和状态。`reopen`／删除亦作相同失效／重放；标题或 legacy 展示字段编辑不伪造正文变更。
- revision 保存 `schema_version`、递增 revision、来源 `live|manual_retry|selective_reextract`、输入 fingerprint、模型／合约元数据、校验结果、失败原因和 `is_active`。只允许一个 `complete + is_active` revision，激活必须检查当前 fingerprint 后在同一事务完成；旧 revision 永久保留以回滚。
- 同稿手动重归档可在旧活跃 v2／legacy 继续服务时 shadow 运行；新 revision 完整通过才原子切换。正文变更后的 `stale` 不能回退到旧事实服务。UI 以 `archive_schema=legacy|v2` 区分“旧版兼容完成”和真正 v2 完整验证，避免把 legacy 误称为 v2 complete。

### 2. v2 Extractor 合同与确定性校验

- 后端先将最终正文按稳定段落／句序机械编号为连续 source span（如 `P0003-S02`）；模型仅返回连续 `start_id/end_id`，不复制 evidence。编号算法、分段上限和 fingerprint 都版本化并覆盖契约测试。
- `summary` 是唯一模型摘要；`facts` 最多 8 条，每项含稳定位置、类型（剧情／决定／关系／认知／未决／状态）、重要性、简洁事实文本、参与人物精确名及 source span。章节级事实可无参与人物；人物事实只可引用本章白名单。
- `end_state_delta` 不再写第二份事实文本，只以受控 `fact_ref` 引用一个状态类 fact，并提供主体、可选关系对方、既有 snapshot/persistent/relationship 槽、`set|clear` 与值。关系必须有恰好两位不同白名单参与者；一项 delta 不能创造 ledger 外事实。
- 后端验证 schema、span 存在／连续／长度、参与人物白名单、关系双参与、事实／槽重复、每类规模、空／占位值和事实与状态引用一致性。姓名出现与 span 位置独立判断，代词叙事不再被“证据逐字且含姓名”的矛盾规则误杀；无法可靠归属的事实只能章节级保存，不能投影为人物故事线或状态。
- 一次调用的结果整体校验：完整通过才 `complete`／可激活；可安全保留的审计结果标为 `partial`，任何 partial 都不派生 Selector、人物事件或状态；上游／截断／过滤错误如实为 `failed`。用户点击“重新归档”才启动下一次单调用，不自动补救或改写事实。

### 3. 事实源、兼容与 Selector

- 新表边界：`chapter_archive_revisions`（生命周期／fingerprint／provenance）、`chapter_archive_facts`、事实参与者关联表、`chapter_archive_state_deltas`（引用 fact）。`chapters` 增加 archive head/status 与 legacy eligibility 所需元数据；不删除 v1 列、`character_events` 或 `character_state_changes`。
- `headline`、`state_changes`、`unresolved_items`、`atomic_memories`、`character_events` 是 v2 的后端派生兼容视图：最高优先级事实→headline，类型／参与者→相应视图。新 API 优先返回 `archive` 对象（状态、schema、摘要、facts、delta、原因、可重试）；旧 wire 字段继续可解码。无法可靠证明旧字段是否用户手改时，绝不覆盖存量列或旧事件；v2 激活只改变新视图／事实选择。
- 状态投影按章节选择唯一事实源：该章活跃 v2 → v2 delta；无 v2 且 legacy eligibility 仍真 → 已有 `CharacterStateChange`；`stale/pending/partial/failed` 且无同 fingerprint 活跃 revision → 无该章状态。每次激活、失效、重开、删除后整书重放；legacy 记录不删除，回滚只切换来源。
- Selector 对每个既往章节只取一个来源：活跃 v2 的 `summary + canonical facts`，否则 eligible legacy adapter 的现行摘要／归档／人物事件；不再在 v2 章节叠加松散数组和人物事件。目标章节前当前状态与“上一章结尾”独立机制保留。

### 4. 选择性历史重提（强制门禁）

- 第一步只能在生产备份副本作只读元数据报告：仅 chapter ID／序号、各数组计数、人物事件计数及每人最大数、`future_memory_blocks`、状态／revision／哈希，不输出标题、摘要、事件或正文。定义为 `summary 存在则 1 + state_changes + unresolved_items + atomic_memories + character_events`。
- 建议硬候选（默认提交用户确认）：`future_memory_blocks >=24`，或章节人物事件 `>=12`，或单人物事件 `>=8`。当前 61 个 finalized 章节的元数据为最小 3、均值 10.5、最大 34；此规则仅产生 5 个硬候选，符合“明显膨胀”而非宽泛清洗。
- 观察候选只列报告、不自动重提：排除硬候选后，`future_memory_blocks >=17` 或事件 `>=9` 或单人 `>=5`（当前 11 个）。salvage／失败历史只作为观察列，单独绝不入选。空／格式异常值须单列数据质量而不能夸大计数；重复率仅作排序佐证，不以模型文本相似度猜测事实。
- 报告须按硬候选、观察候选、排除理由分组，给出阈值和汇总；**用户确认精确章节清单前零 LLM 调用**。对确认项逐章 shadow 生成、fingerprint 再核验、完整验证后原子激活；任章失败只留下非活跃 revision，不影响该书其它章节。无可靠存量 provenance 一律标“未知”，不猜测用户手改。

## 执行计划

### Phase 0 — 合同锁定与安全基线

状态：待施工。

- 负责人先记录干净／脏工作树、版本四处和 Alembic `20260804_0009`；不触碰受保护资产。以合成正文建立 v2 JSON、span、代词、章节级事实、关系、重复／上限、partial 隔离、fingerprint 失效、legacy/v2 混读和接受解耦的测试基线。
- 主要边界：`Backend/app/agents/extractor.py`、`services/extraction.py`、`services/write_jobs.py`、`services/context.py`、`services/character_state_projection.py`、`models/entities.py`、`routers/chapters.py`、`schemas/chapter.py`；不复用旧 event-repair 或 state-only rebuild 合同。

### Phase 1 — Backend v2 数据与生命周期

状态：待施工。

- 新增一份仅增量的 Alembic migration（head 接在 `20260804_0009`）：revision／fact／participant／state-delta 表、索引、唯一／检查约束和 chapter archive-head 元数据。生产只由 `alembic upgrade head` 建表，启动不 `create_all`，不迁移／清空 legacy 内容。
- 实现 archive repository、revision 激活／失效与全书投影来源选择；将接受路径拆成“正文 finalized 事务”与独立 extract Job，所有 Job 终态、ownership 和 fingerprint 失配都不可覆盖新正文。移除在线 salvage／二次事件 repair 的生产调用路径。
- 改造 Extractor schema、人格、编号器、validator、持久化与错误码；日志只记 revision、计数、哈希、规则和真实上游分类。为手动 retry 提供幂等入口，并拒绝 draft、非当前 fingerprint 或并发写作。

### Phase 2 — API、Selector 与双端体验

状态：待施工。

- 在 `ChapterRead`／Job 状态增加向后兼容的 `archive` 读模型与 retry 操作；保留所有旧字段和 `summary`/`chapter_style` 兼容，不返回候选全文。新增事实账本简览只显示已验证活跃 v2 内容，legacy 原接口行为保持。
- Selector 改为 per-chapter source adapter；导出与人物页明确区分“当前状态投影”与归档来源。确认旧字段手改不被 v2 激活覆盖，且 chapter PATCH／import／reopen／delete 正确置 stale／重放。
- 修改共享 Swift 模型、Store、iOS `ChapterEditorViews`／`LinoErrorPresenter` 与 macOS `MacChapterEditor` 等共用表现：正文“已接受”与归档状态分开、显示明确失败原因、提供重试、显示简洁账本；不拉取／渲染候选全文。四组客户端版本及 Backend health 同步为 `1.8.0(30)`，不修改用户编辑的 scheme。

### Phase 3 — 候选报告与用户确认

状态：待施工，且是生产重提的硬停点。

- 在备份副本运行只读审计命令，生成权限 0600、Git 忽略的报告；复核 5 个硬候选与观察项数量，不读／打印文本。将精确 ID／序号清单、计数、阈值和排除理由交用户确认。
- 未获得确认：部署可包含 v2 新写作路径，但不得运行历史 re-extract。确认后只处理清单中的章节，按章单事务切换；非候选、观察项和仅有 salvage 历史的章节保持 legacy。

### Phase 4 — 验收、部署、选择性重提与发布

状态：待施工。

- Backend 必跑完整 `pytest -q`、`compileall`、`alembic heads`、migration upgrade、`git diff --check`；覆盖 revision 并发／回滚、Selector 去重、投影混源、旧 client decode、API 状态和候选分类。跑 `App/Tests/run_client_state_tests.sh`、iOS 与 macOS Debug build；共享代码改动后双 target 均需通过，再做签名 Archive。
- 生产顺序：停止旧服务→备份数据库、`.env`、代码及 unit/nginx（600）→SQLite integrity／foreign key／旧 head→部署已提交 Backend→`alembic upgrade head`→验证新 head/integrity/FK/单实例/健康/无敏感日志→启动服务。先验收新章 accepted+archive failed/complete 不互相回退；再执行经用户确认的逐章 shadow／激活。
- 回滚：停服，恢复代码与数据库备份并复核后单实例启动；若只需撤销某章 v2，则事务停用该 revision、恢复同 fingerprint 旧活跃 revision 或 legacy eligibility，并整书重放。绝不以手改 legacy 字段掩盖问题。
- 发布顺序：全测→commit→生产门禁与（如已确认）选择性重提验收→双端签名 Archive→iOS 开发签名 IPA（仅本机）→macOS universal ZIP、验签、换装→产物 `/Users/linotsai/Downloads/ICTW-v1.8.0-build30`→push main→tag／GitHub Release。公开资产仅 macOS ZIP；App Store Connect：无。

## 验收与风险

- 必测结果：接受后正文立即可读；archive `failed/partial` 不撤销正文且 Selector 不见其事实；v2 每章最多一套 summary+facts；代词 span 可通过而虚构 span／未选人物／单方关系被拒；编辑正文立即 stale；mixed legacy/v2 的状态和 Selector 无重复；partial revision、shadow 失败和回滚不污染活跃数据。
- 最大风险是新旧混源时错误选择旧状态或把用户手改当 Extractor 输出；以 fingerprint、active revision、legacy eligibility、全书投影重放、保守不覆盖和逐章原子切换控制。第二风险是阈值选得过宽；硬候选固定为 5 个报告样本且用户逐项确认，观察项不自动执行。
- 不做事项：不全量 re-extract、不自动重新处理 salvage、不上线后批量后台清洗、不删除 v1 archive／state 记录、不改变 v1.6 写作链、候选稿安全边界或云迁移计划。

## 里程碑索引

- `v1.7.2(29)`：Extractor 截断、人物事件／状态保守降级快修已发布，生产备份 `/opt/linoi/backups/20260805-150015`；它是 v1.8 的 legacy 基线，不再扩展。
- `v1.7.2(25)`：`20260804_0009` 状态投影及三书安全重建已发布；v1.8 保留其 legacy 状态来源并以 revision adapter 渐进替换。
- `v1.7.1(24)` 及更早发布、纸墨视觉、云迁移暂停条件详见历史里程碑／`archive/`；不属于本版施工范围。
