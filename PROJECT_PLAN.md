# ICTW PROJECT_PLAN

> 本文件是唯一现行计划与状态来源；与归档冲突时以本文为准。历史实施记录仅在 `archive/` 查询。

## 当前状态

- `v1.7.2(28)` Extractor 保守降级快修施工中：在线 Extractor 仍先执行三次完整严格校验；纠偏耗尽后，仅当 headline、摘要、章节归档和人物事件全部严格合格时，才复用离线重建的逐组件校验器丢弃不安全的可选人物状态。即时快照任一槽失败则整组丢弃，持续状态／关系逐项验证；不改写证据、不猜测归属、不放松白名单。章节完成时通过现有 JobRun 安全上下文向双端显示中文降级警告。Backend 无 migration，市场版本保持 `1.7.2`，Build 从 27 升至 28。
- `v1.7.2(27)` 强制接受快修已完成：让“忽略 Bible 并接受”按完整写作输入指纹持久记录；Extractor 失败不再抹掉用户决定，同一正文可直接重试 Extractor，正文／Bible／世界观／人物选择变化后授权自动失效。兼容 Build 26 已产生但缺少指纹的 override 记录，仅在当前不可变候选能证明所有输入未变时继承。Backend 无 migration，生产备份为 `/opt/linoi/backups/20260804-181721`；106 项后端测试、客户端状态测试、双端 Debug／签名 Release Archive、iOS 本机 IPA、macOS 通用架构 ZIP／换装均通过。双端市场版本保持 `1.7.2`，Build 从 26 升至 27；tag 与 GitHub Release 为 `v1.7.2-build27`。
- `v1.7.2(26)` 客户端快修已完成：市场版本保持 `1.7.2`，仅将 iOS／macOS Build 从 25 升至 26；修正双端手改正文后 Checker 仍检查服务器旧稿的问题。“重新检查”现先保存当前正文再检查，“编辑后检查”在编辑态明确变为“保存并检查”。Backend 与数据库未改、未部署。双端正式 Archive、iOS 本机 IPA、macOS ZIP／换装、`v1.7.2-build26` tag 与 GitHub Release 均已完成。
- 双端／Backend `v1.7.2(25)` 已完成施工、生产迁移、三书状态重建、签名 Archive、本机 macOS 换装、tag 与 GitHub Release；生产 Alembic 为 `20260804_0009`，发布前备份为 `/opt/linoi/backups/20260804-153226`。
- 已确认故障在整体数据语义而非单一前端：`characters.dynamic_fields` 被 Extractor 逐键增量合并；`character_field_patches` 只保存逆向补丁。未再次写到的旧字段不会退出，删除／重开中间章也不能可靠重算全部后续状态。双端和 Writer 原样读取该混合字典。
- 现行 Extractor 已有姓名白名单、正文原文证据与三次确定性纠偏；这些安全门禁必须保留。`thinking`/`top_p`、候选稿隔离、Checker 与 v1.6 写作链均不随本项目改变。
- 用户工作树资产：`.learnings/ERRORS.md`、`App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme`、`design_handoff_ios_visual_upgrade/`；只读保护，不暂存、覆盖、回退或纳入提交／产物。

## 目标与边界

- 根治人物动态字段的累积与矛盾：人物事件继续累积；动态字段成为章节顺序可重放的“当前有效状态投影”。前端只展示最新有效状态，Writer 只获得目标章节开始前的有效状态；历史仅留在事件／状态变更记录中。
- 仅改 Backend、共享 Swift 客户端与版本配置。保持已有 API 的 `dynamic_fields` 响应字段、所有 target／Bundle ID／Keychain／草稿目录与既有正文、Bible、摘要、事件编辑接口兼容；不读取或在日志／计划中呈现任何书籍正文。
- 三本现存书必须用已接受正文安全重建状态，不改正文、Bible、章节标题、`headline`、`long_summary`、章节摘要、用户人物固定设定或用户手工事件。重建会调用 Extractor，输入和验证包均不得输出到日志或 Git。

## 稳定设计决定

### 1. 字段语义

| 分类 | 字段／存储 | 更新规则 |
| --- | --- | --- |
| 即时快照 | `当前位置`、`当前行动`、`情绪状态` | 人物在本章实际在场且有合法快照时整组替换；未明确的槽写 `clear`，不继承旧地点、动作或情绪。值只能描述章节结束时状态，禁止过程串与“未知／未明确／暂无”。 |
| 持续状态 | `身体状态`、`当前目标`、`秘密状态` | 只有正文明确设定、变化或结束时才 `set`／`clear`；未触及则保留上一次有效值。 |
| 人物关系 | 无向人物对的唯一关系槽 | 新状态替换同一人物对的旧状态，结束时 `clear`；投影时才镜像为双方的 `与某人关系`，不得双向各自累积。 |
| 掌握信息 | 归属人物的 `atomic_memories`；叙事事件可另用 `CharacterEvent(event_type=认知)` | 可累积，不再属于动态字段。 |
| 其他状态 | 删除 | 禁止 Extractor 输出、禁止投影、旧值在重建时清除。 |

### 2. 状态变更数据模型与兼容

- 新增迁移和 `CharacterStateChange`（`character_state_changes`）：`book_id`、`chapter_id`、主体人物、可空对方人物、`scope`（snapshot/persistent/relationship）、固定 `slot`、`operation`（set/clear）、可空 JSON `value`、原文 `evidence`、即时快照 `batch_id`、`is_effective`、时间戳及防重复唯一约束／索引。人物对按稳定 ID 排序后唯一化。
- 即时快照一批恰有三个槽；投影器遇到该批先清空三个即时槽、再应用其中 `set`。持续／关系按章节序与稳定次序回放，最后有效记录标记 `is_effective=true`。`characters.dynamic_fields` 保留为唯一公开的物化当前投影，不再是事实源。
- 保留表和 wire 字段 `character_field_patches`／`dynamic_fields` 以兼容旧安装，但 v1.7.2 不再写、读或用旧补丁回滚；三本书重建事务清除旧补丁与旧投影。`CharacterCreate/Patch.dynamic_fields` 继续接受以免旧 App 保存人物卡失败，但服务端忽略该输入；新双端保存人物卡不再回传动态字段。
- 新状态 API 不公开历史正文或候选稿；人物卡、导出和 Writer 使用投影。历史状态只供后端重算、审计与后续受控工具使用。

### 3. Extractor 输入、输出与确定性门禁

- `extractor_user_message` 为每位本章白名单人物提供“本章开始前有效状态”，只作为更新基线，绝非可归档事实。它按目标章节之前的已定稿章节投影，不能误带后续章节状态。
- 将 `dynamic_fields_patch` 替换为 `state_updates`：每项以精确人物名绑定，含可选完整 `snapshot`（在场证据 + 三个即时槽及每个 set 的正文证据）、`persistent_ops`（字段、set/clear、值、证据）和 `relationship_ops`（对方精确名、set/clear、值、证据）。未在正文中实际在场的人物不得输出操作。
- 所有 set／clear 均须有可定位且能识别所属人物的正文原文；即时槽的 clear 使用同一人物在场证据。关系对方必须在本章白名单，主体／对方不能相同。空、未知、未明确、过程式快照、非法字段、重复槽／关系对、非完整即时批、未获准人物、无证据或不匹配证据一律整次失败。
- 保留 JSON schema、姓名→UUID 后端机械映射、固定事件分类、白名单与三次自动纠偏。每轮输出先完整校验再事务落库；上游／内容过滤错误不伪装成校验失败。

### 4. 确定性投影与章节生命周期

- 实现单一纯投影服务：按 `Chapter.index` 回放所有 `finalized` 章节的 `CharacterStateChange`，重建 `dynamic_fields` 与 `is_effective`；任何写入后不得原地 merge。状态、关系和投影在同一事务提交。
- 接受章节：替换该章 Extractor 产物并重投影整本书。重开章节：撤销该章状态变更、使其不再作为定稿事实，重投影；既有人物事件仍按现有兼容行为保留至重新接受或删除。删除任意章节：删除后重排索引并重投影整本书。重新接受：以原始章节前基线重提取／重投影，绝不读取自己的旧输出或未来状态。
- Memory Selector／Writer 的人物卡改为目标章节前投影；人物卡、TXT 导出和双端 UI 仅展示当前投影。双端动态区域改名“当前状态 · Extractor”，空态说明无当前有效状态，不增加历史全文页面。

## 执行计划

### Phase 0 — 保护基线与契约测试

状态：完成。合成契约覆盖快照替换、持续状态清除、关系唯一镜像、旧客户端动态字段忽略与非法状态拒绝；未读取任何生产正文。

- 复读本计划，记录 `git status --short`、四组版本和生产 Alembic；确认无活动写作任务后再触碰状态数据。创建状态操作契约的 fixture，先锁定快照替换、持续保留／清除、关系唯一、认知记忆、非法值与旧客户端保存的预期。
- Builder 不查看书籍正文；测试仅用合成文本。所有日志只记录章节索引、计数、哈希和规则错误，不记录 Prompt、正文、token 或密钥。

### Phase 1 — Backend 状态源与迁移

状态：完成。本地 head 为 `20260804_0009`；状态变更表、纯投影、接受／重开／删除／重接受重放及 v2 bundle 重建路径已实现。

- 新建不可破坏旧数据的 Alembic migration：只增加状态变更表、索引与约束；不在启动时建表，不拷贝不可信旧动态值，不删除旧表。migration 前后执行 SQLite integrity、foreign key check、Alembic head。
- 用投影服务取代 `CharacterFieldPatch` 的写入／`_revert_dynamic_fields`；修改 Extractor 应用、重开、删除、重接受、人物读取、导出和上下文，使所有动态状态路径只读重放结果。确保失败、取消或验证异常完全回滚。
- 更新 v2 离线验证包与重建脚本：指纹覆盖书、章节顺序、正文与新输出；0600 文件；先干跑验证所有章节，再仅凭已验证 bundle 写入，严禁二次调用模型。

### Phase 2 — Extractor 合同与运行时

状态：完成。`state_updates` 已替代生产写入的旧 patch，包含前态基线、确定性校验、中文错误原因、Extractor 关闭 thinking、120 秒总时限和 4096 token 输出预算。

- 实现 `state_updates` schema、人格／固定协议、姓名绑定、输入基线和确定性验证；移除 `掌握信息`、`其他状态` 与旧 patch 合同的生产写路径。不得放松已有事件、证据和白名单验证。
- 保持最多三次格式纠偏；纠偏提示涵盖快照完整性、set/clear 及精确证据。把具体状态规则映射为双端可见中文失败原因，保留真正的上游分类。
- 处理 Extractor 长耗时：此版本关闭 Extractor thinking，并为单次请求增加严格总时限与 JSON 输出预算；超时如实标记为上游超时，不自动转为状态校验重试。为 timeout、三次纠偏和事务回滚增加测试。

### Phase 3 — 双端兼容与体验

状态：完成。共享客户端保存人物卡不再回传动态字段；双端改为“当前状态 · Extractor”展示和空态；版本均更新为 `1.7.2(25)`。

- iOS 与 macOS 共用模型／Store 调整为保存人物固定卡时不发送 `dynamic_fields`；后端仍容忍旧 App 带来的该字段并不污染投影。动态区仅读当前字段，保留现有人物事件编辑／删除功能。
- 更新当前状态标签、空态与长关系文本布局；不拉取状态历史、候选稿或正文。共享 Swift 改动必须两 target 构建与客户端状态测试。

### Phase 4 — 三本书安全重建

状态：完成。三本书 77 个已定稿章节已生成并复检 0600 v2 bundle；单一事务应用 472 条状态变更、111 条当前有效来源，旧 `character_field_patches` 清零。

- 先用生产库备份副本或维护锁确认三本书精确 ID／标题、已定稿章节数和人物数，仅输出元数据。停止写入并确认无活动 Job；对三本书逐章生成 v2 0600 验证 bundle，所有输出通过确定性校验、章节／正文指纹和覆盖率检查后才允许继续。
- 一次性校验三份 bundle 后，在**单一数据库事务**中清除三书旧字段补丁与旧物化动态状态，按章节顺序写入状态变更并投影；既有 `CharacterEvent`、章节归档和用户不可变内容不改。任一本／任一章失败即 rollback，绝不产生半书或半套状态。
- 应用后只产出每书章节数、状态变更数、有效状态数、既有人物事件数前后一致性、非法字段数和 fingerprint 摘要；人工核对这些元数据与重建前清单。验证不通过立即从备份完整回滚，不尝试在线手修字段。

### Phase 5 — 验证、部署与发布

状态：完成。Backend 105 项测试、compileall、迁移、客户端状态测试、双端 Debug／签名 Release Archive、iOS 开发签名 IPA、macOS universal ZIP／换装、生产内外网健康与发布门禁均通过。

- Backend：新增／更新迁移、投影、生命周期、Extractor、bundle、旧客户端兼容、导出与错误路径测试；完整 `pytest -q`、`compileall`、`alembic heads`、`git diff --check` 必须通过。客户端运行 `App/Tests/run_client_state_tests.sh`、iOS／macOS Debug build。
- 生产：先停旧服务并备份 `linoi.db`、`.env`、当前代码与 unit/nginx 配置；备份权限 600，并验证 integrity／FK／head。上传已提交 Backend，先 `alembic upgrade head`，执行三书干跑与一次性 apply，再启动单一服务实例。验收内外 HTTPS health=`1.7.2`、head、integrity、FK、零活动任务、`NRestarts=0`、无敏感日志和三书投影统计；失败按停服、还原代码与数据库备份、复核后启动的顺序回滚。
- 版本：`LinoI` 与 `LinoIMac` 的 Debug／Release 四组同时设 `MARKETING_VERSION=1.7.2`、`CURRENT_PROJECT_VERSION=25`；Backend health 版本同步。不得改 target、Bundle ID、scheme 或用户修改的 scheme。
- 发布顺序：全部测试 → commit → 生产备份／部署／重建验收 → 双端签名 Release Archive → iOS 开发签名 IPA（仅本机）→ macOS universal ZIP、验签与换装 `/Applications/ICTW.app` → 将产物存至 `/Users/linotsai/Downloads/ICTW-v1.7.2-build25` → push main → annotated tag `v1.7.2` 与 GitHub Release。公开资产仅 macOS ZIP；不上传 iOS App Store Connect。

## 验收、风险与回滚

- 必测事实：地点 A→B 只显示 B；睡觉→起床不保留睡觉；受伤→痊愈清除身体状态；敌对→合作只显示合作；认知只进记忆／事件；`未明确`／`其他状态` 为零；未出场人物状态不变；删除／重开／重接受中间章节能重放后续；Writer 得到的仅是该章开始前状态。
- 最大风险是三书重建的 LLM 输出质量与长耗时；以停写、严格总时限、验证 bundle、一次性 apply、生产备份和完整回滚控制。不得通过放松证据门禁或保留旧字段掩盖失败。
- 次要风险是旧客户端保存人物卡回传动态字段；服务端兼容忽略、新客户端停止发送并以双端回归覆盖。`character_field_patches` 暂留作数据库兼容壳，待所有旧版本淘汰后另立项删除。
- 外部网页操作清单：GitHub Release 由现有 CLI 发布；App Store Connect：无。宁波云迁移、视觉功能、写作 SOP 和其它 Backend 功能不随本计划推进。

## 里程碑索引

- `v1.7.2(26)` 修复手改正文后的 Checker／接受链路；仅发双端客户端 Build，Backend、Alembic 与生产数据不变。产物位于 `/Users/linotsai/Downloads/ICTW-v1.7.2-build26`，macOS Build 25 回滚副本位于 `/tmp/ictw-app-backup-v172-build26.L1Ft7O/ICTW-v1.7.2-build25.app`。
- `v1.7.2(25)` 将人物动态字段升级为可重放当前状态投影；生产 `3 books / 77 chapters / 31 characters / 340 events / 472 state changes / 111 effective states`，不可变内容与备份哈希一致，非法键／占位值为零；备份 `/opt/linoi/backups/20260804-153226`。
- `v1.7.1(24)` Extractor 错误可见性与三次纠偏已发布；备份 `/opt/linoi/backups/20260804-083059`。
- `v1.7.0(21/22)` iOS／macOS 纸墨视觉、Archive、tag 与 GitHub Release 已完成；`v1.6.0–v1.6.5` 写作链／摘要迁移已完成。详细记录在 `archive/` 与 Git tag。
