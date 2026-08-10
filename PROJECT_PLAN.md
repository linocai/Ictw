# ICTW PROJECT_PLAN

> 本文件是唯一现行控制面：只保留当前状态、已定决策与可施工计划。已完成版本的过程记录在 `archive/plans/`；历史运维与设计资料仅供查阅，不是现行指令。

## 当前状态

- 当前源码候选为 `v1.8.3(34)`；宁波 Backend 已部署 `v1.8.3`，Alembic head `20260809_0011`。本机 macOS 已换装 Build 34，签名 Archive 与通用 ZIP 已生成；iOS 由用户自行打包。公开发布的双端客户端仍为 `v1.8.1(32)`。
- 生产入口为 `https://ictw.linotsai.top`；宁波 Backend 在 `/opt/linoi/backend`，仅监听 `172.18.0.1:8787`，由同机 Nginx Proxy Manager 反代。香港旧服务保持 stopped + disabled。
- v1.8 Extractor 关系 delta 快修已随 Backend `v1.8.3` 上线：relationship 由双参与者 Fact 推导，revision 仍只调用一次、完整结果才可原子激活。
- 最终复审的三项上线阻断整改已完成：reopen／重启不会让已撤销的 Extractor 激活；Writer generation 覆盖实际读取的 Book／选中 Character 输入；Writer 失败恢复与 JobRun 终态同事务提交。独立 Reviewer 复验 P0/P1/P2/P3 均无 finding，宁波 Backend 生产部署与门禁验收已完成。
- 工作树已有用户与前序施工的未提交改动；只按本计划增量施工，绝不回退、覆盖或擅自暂存。受保护的 `App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme` 不在范围内。

## 架构与不可破坏规则

- 写作链固定为 Memory Selector → Writer → Checker → 用户接受 → Extractor；候选正文只留后端，公开 API 与双端不得暴露候选列表或全文。
- 正文接受与归档独立；Extractor 失败不得撤销接受或重跑 Checker。v2 每 revision 只调用一次，`partial`、`failed`、`stale` 一律不进入 Selector、人物故事线或状态投影。
- 人物选择是本章允许出现人物的上限；所有可程序校验的约束必须复检。`chapter_style`、工程/target/Bundle ID、Keychain/UserDefaults 键和本地草稿目录保持兼容。
- 生产表结构只经 Alembic；启动不得 `create_all`。迁移/部署前先停服和备份，再验证 SQLite integrity、foreign keys、head、单实例和公网鉴权。
- `thinking` / `effort` 继续由 capability registry 决定；非思考请求发送 `top_p=0.95`，思考请求不发送它。日志、审计、API 返回不得含 API Key、Prompt、正文或候选全文。
- 历史重提必须以只读报告、正文哈希和用户精确章节 ID 确认；本轮绝不自动重提、重跑 Extractor 或重新生成历史章节。

## 本轮目标与非目标

**目标**：Writer 的终态提升和所有失败恢复均以数据库章节版本作最终授权，并覆盖所有实际 Writer 输入；reopen、Extractor 激活与重启恢复维持同一生命周期门禁；配置错误可预测且可被客户端展示；上游诊断仅存安全分类；新装与仍保留旧默认地址的客户端连到宁波入口；并发章节创建不再泄露 `IntegrityError/500`；删除 v1 Extractor 纠偏遗留路径并补齐可在本地运行的回归测试。

**非目标**：不改公开候选策略、人物/Archive v2 的单次调用语义、生产数据、Keychain/Token、真实 Profile 内容或香港服务；不把进程内锁升级成分布式任务系统；不做自动历史修复或自动重提；不在本轮改变用户自定义后端地址；不新增 schema／Alembic（现有 generation 字段足够）。

## 已定技术决策

### 1. P1 Writer 章节所有权：generation + CAS（`20260809_0011` 已存在）

- 根因：`WriteJobRegistry` 只在当前进程判定任务是否 current；`_run_job` 提交 `draft_text/status`、拒绝分支和 `_restore_baseline` 都没有数据库条件。另一客户端在任务期间 PATCH/IMPORT 后，旧任务仍可能提升候选或把旧 baseline 写回。
- `chapters.write_generation` 与 `job_runs.chapter_write_generation` 已由 `20260809_0011` 建立；本整改不再创建 migration、不改 head。新 Writer Job 在 JobRun 与 `WriteJob` 记录当前 generation，旧 JobRun 的 `NULL` 继续使用时间戳兼容逻辑。
- 建立共享的 Writer-input invalidation service，供 chapters、books、characters router 调用，禁止复制章节 router 私有逻辑。它在调用方事务内递增**受影响章节**的 generation、将 `writing` 恢复为与当前正文一致的 `draft/draft_ready`，并条件化终止这些章节的非终态 `kind=write` JobRun 为 `cancelled/chapter_changed`；commit 后仅作 best-effort 本进程 registry cancel，正确性不依赖它。
- 精确影响范围：Chapter PATCH／IMPORT／人物链接替换等既有 chapter 输入变更仍作用于本章；`Book.world_setting` 变更作用于该书所有章节；`Character.name`、`role`、`fixed_profile`、`dynamic_fields` 的变更和删除只作用于仍链接该人物的章节。Book 标题、未被链接人物的创建/导入、人物事件和 Archive-only 状态不取消 Writer。服务只终止受影响的非终态 Writer，不终止 Extractor；Extractor 有独立的章节生命周期门禁。
- worker 在构造 Writer prompt 前及每个可见终态前复核 generation；Writer 成功提升、Checker 拒绝、确定性失败、LLM/异常失败和 baseline 恢复均以 `UPDATE chapters ... WHERE id=:id AND write_generation=:expected` 或等价 CAS 为最终授权。CAS 未命中时绝不改章节文本/状态、绝不回写 baseline，只保留 `chapter_changed` 终态并结束本地线程。
- baseline CAS 与对应 JobRun terminal（`failed`/`cancelled`、error code/context、finished_at）必须在**同一 Session transaction**提交。删除“`_restore_baseline()` 先 commit、再 `record_job_phase()`”的窗口；若 JobRun 更新不能写入则连同 baseline 回滚，不能留下无终态的可见恢复。
- `/job` 对带 generation 的 write 终态以 `job_runs.chapter_write_generation == chapters.write_generation` 计算 `outcome_current`；旧历史 JobRun 继续兼容原有时间戳规则。API 不暴露 generation，旧客户端 wire 不变。
- `cancel_write`、replace、重开、接受与 Archive 路径须复核：用户编辑不能遗留 `writing`，但 Archive 接受后的 `finalized` 和 v2 原子激活语义不变。

### 2. P1 Extractor 生命周期：reopen、激活和重启同一门禁（无 migration）

- 根因：`reopen_chapter()` 仅使 active archive 失效，没有取消 live extract、终态化其 JobRun 或使 pending/extract revision 失效；`activate_archive_revision()` 只核对 fingerprint；启动恢复会把任意 interrupted extract 的章节改回 `finalized`。因此同 fingerprint 的旧 Extractor 可在 reopen 后写入 facts/deltas 并重新 active。
- 增加 archive lifecycle helper（由 chapters router、worker 和恢复逻辑共享）：reopen 在同一事务条件化取消本章所有非终态 `kind=extract` JobRun，令其关联且仍为 `pending/extracting` 的 revision 为 `stale`（非 active、静态 `archive_reopened` 原因），清理 chapter archive head/status，再在 commit 后 best-effort cancel 本进程 extractor。任何旧 worker 释放后只能观察到 cancelled/stale，不得重写正文接受状态。
- `activate_archive_revision()` 将 chapter 仍为 `finalized`、revision 仍为本 job 的 `extracting`、input fingerprint 仍匹配作为同一事务的条件化最终激活门禁。若任一条件不符，回滚待写 facts/deltas，revision 保持/转换为 `stale`，不激活、不重放投影；这不增加第二次模型调用，也不撤销已接受正文。
- `recover_interrupted_chapters()` 按 job kind 分支：Writer 沿 generation 兼容的恢复路径处理；v2 extract 只在章节仍为 `finalized` 时将未完成 revision 标为 `failed/interrupted` 并保留 finalized 正文，章节已 reopen/非 finalized 时将 run/revision 标为 `cancelled`/`stale` 并保持当前用户状态。历史无 revision 的旧 `extracting` 记录按旧安全恢复到 draft 状态，绝不无条件“恢复 finalized”。

### 3. P2 配置、上游错误与客户端入口

- `build_llm_client` 改抛带固定 `code`、`agent_role` 的 `LLMConfigurationError`，覆盖未绑定 profile、外键清空后的 profile 缺失、Extractor 不支持关闭 thinking 与 capability 不兼容。FastAPI 统一转换为 HTTP `409`：`detail={code,message,details:{agent_role}}`；不把 `RuntimeError` 或配置细节发给客户端。现有 `APIClient.structuredError` 可兼容该形状。
- 上游响应正文一律不进入 `LLMError`、JobRun、`LLMCallAudit`、日志或 API 返回。删除对 provider `error.message` 的读取；`upstream_reason` 只允许固定映射出的机器分类，未知为 `None`。`http_status`、本地 `error_code`、可信的白名单 `finish_reason` / `block_reason` 继续保留，且同样先规范化为安全枚举。
- `AppSession.bootstrap` 使用宁波 URL 作为新默认值；若 UserDefaults 缺失或值**精确等于**旧产品默认地址，迁移并持久化为宁波 URL。任何其他已保存地址、Token、Keychain 键和 DEBUG 环境变量优先级均不改。将端点迁移规则抽成 Foundation-only、可测试的纯逻辑，避免用 UI 测试验证持久化分支。
- `CLAUDE.md` 收敛为兼容入口：明确以 `AGENTS.md`、`PROJECT_PLAN.md` 和仓库外 `/Users/linotsai/Lino/NB_info.md` 为准，不再指向香港资料或旧部署私钥路径，不复制密钥/运维命令。

### 4. P3 并发、死代码与测试缺口

- 章节编号不新增 schema：保留现有 `uq_chapters_book_index` 作为最终唯一性。创建路由对短事务中的唯一冲突/SQLite busy 做有界重试；每次 rollback 后重新计算 `max(index)+1` 和重建待插入对象。耗尽后返回安全的结构化 `409 chapter_index_busy`，不能泄露 `IntegrityError/500`，不影响已有章节。不得为此 batch rebuild 或删除唯一约束。
- 删除 `write_jobs.py` 不可达的 `_run_extractor_with_correction`、三次 correction 常量/提示及其唯一调用的 legacy agent/service helper；保留 v2 单次 `extract_v2` 路径、Archive v2 验证和现有历史只读工具。删除前后用 `rg` 确认没有生产调用。
- 轻量客户端测试扩展为可编译的 Foundation 级测试：端点默认/精确旧值迁移/自定义地址保留，API URL、Bearer 与结构化配置错误解码，以及从临时轮询失败恢复、终态停止和陈旧终态不覆盖本地编辑。必要时把 Store 的轮询决策提炼为无 SwiftUI 副作用的协作者，`LinoStores` 只调用该协作者。

## 施工阶段、文件范围与验收

1. **复审 P1：先封住 Extractor 生命周期（已完成本地验收）**
   - 文件：`Backend/app/routers/chapters.py`、`Backend/app/services/archive_v2.py`、`Backend/app/services/write_jobs.py`、`Backend/app/main.py`、`Backend/tests/test_api.py`、`Backend/tests/test_v1_1_features.py`、`Backend/tests/test_v1_8_archive.py`。
   - 实现 reopen 对 live/跨进程 extract 的条件化取消、revision stale、activation 的 finalized+extracting+fingerprint CAS，以及不改写用户状态的按-kind 启动恢复。不得修改 Extractor Prompt、次数或事实账本表。
   - 测试：accept→阻塞 Extractor→reopen→释放后，chapter 仍 `draft_ready`、JobRun/revision 为 cancelled/stale、零 active facts/deltas；激活与 reopen 两种提交先后都不留下 active revision；模拟重启时 finalized 章保留 finalized 且 revision failed，reopen 章保持 draft_ready 且 revision stale；旧无 revision 的 extracting run 仍安全恢复。

2. **复审 P1/P3：共享 Writer 输入失效与单事务失败终态（已完成本地验收）**
   - 文件：新增 `Backend/app/services/write_ownership.py`，以及 `Backend/app/routers/chapters.py`、`Backend/app/routers/books.py`、`Backend/app/routers/characters.py`、`Backend/app/services/write_jobs.py`、`Backend/tests/test_api.py`、`Backend/tests/test_v1_pipeline.py`。`Backend/app/models/entities.py`、`Backend/alembic/versions/20260809_0011_writer_generation.py` 仅只读验证，禁止为本项重做 migration。
   - 将现有 `_cancel_stale_write_jobs` 收口到 shared service，按本计划定义的 Book/Character 精确影响集合终止非终态 write；在 worker 的输入边界与最终提升均查 generation。将 `_restore_baseline` 改为内部 transaction helper，CAS baseline 和 `_apply_job_phase` 一次提交，涵盖确定性失败、`LLMError`、一般异常、cancel/generation mismatch。
   - 测试：阻塞 Writer/Checker 时分别 PATCH `world_setting`、已选角色的 name/role/fixed_profile/dynamic_fields、删除已选角色；旧 job 必须 `chapter_changed`、`outcome_current=false`、不得提升，未关联章节 job 不受影响。注入 JobRun terminal 写入失败，断言 baseline 也回滚；所有失败类型若成功恢复，则必有同事务 terminal row。既有 Chapter PATCH/IMPORT/links/cancel 正常回归。

3. **既有完成项回归与版本一致性（已完成本地验收）**
   - 重新验证已完成的配置脱敏、默认 URL 迁移、编号重试和 dead correction 删除；不扩大客户端/公开 API 范围。`v1.8.3(34)`、Alembic head `20260809_0011` 保持不变。

4. **全量门禁与交付准备（本地验收与独立复验均已完成）**
   - 依次运行 `cd Backend && .venv/bin/python -m pytest -q`、`.venv/bin/python -m alembic heads`、`App/Tests/run_client_state_tests.sh`、`git diff --check`，并对源码/测试/计划做密钥与旧域名定向扫描。
   - 共享客户端改动后串行构建 iOS `LinoI` 与 macOS `LinoIMac` Debug（不同 DerivedData 或串行）；不得改受保护 scheme。记录实际通过数、head 与版本一致性。

## 生产部署、回滚与历史任务限制

- 2026-08-09 14:39–14:43 CST 已按 `NB_info.md` 完成宁波部署：部署前非终态 Writer/Extractor、pending/extracting revision 与 writing chapter 均为 0；停服备份位于 `/opt/linoi/backups/20260809-143950-v1.8.3-build34`，发布包位于 `/opt/linoi/releases/ictw-backend-v1.8.3-build34.tar.gz`，SHA-256 为 `9d132445aab87fc083ed78a8a9dade69ce9e0a8365a95bb08dc8e545040cee72`。单实例迁移到 `20260809_0011` 后，SQLite integrity 正常、foreign keys 为空、对象计数仍为 3 books／68 chapters／26 characters；内外网鉴权健康均返回 `1.8.3`，公网未鉴权为 401，TLS 验证通过，单 uvicorn 且 `NRestarts=0`、启动 warning 为空。
- macOS `v1.8.3(34)` Apple Development 签名 Release Archive、Hardened Runtime 与 `x86_64 + arm64` 通用 ZIP 已验收；本机 `/Applications/ICTW.app` 已换装并真实启动。产物位于 `/Users/linotsai/Downloads/ICTW-v1.8.3-build34`，ZIP SHA-256 为 `2965c0992dd58dd7911f9a91dec09f7aa2741972765788a63e498d009a17d525`；旧 App 备份为 `/tmp/ictw-app-backup-v183-build34.MXBOA1/ICTW-v1.8.1-build32.app`。iOS 由用户自行处理，本轮未打包、安装或上传。
- 本整改不新增 migration；既有 `0011` 是向后兼容加列。若应用回滚，优先回退代码并保留列；只有在无新写入且已验证备份时才讨论 DB 回滚/恢复，绝不让两台服务器同时写入。
- 不自动重跑 production JobRun、重写正文、激活 partial/stale revision 或重提历史章节。部署时若发现旧 `writing`/非终态任务，先人工记录精确 ID 和状态并由用户决定，不将其视为可重试队列；reopen 后的 extract 一律只能保持取消/失效，不能由恢复逻辑重新接受正文。

## 完成定义与历史索引

- 完成 = reopen/重启/激活三方竞态不能让撤销的 Extractor active，且正文接受与归档独立；所有 Writer 实际输入变更与所有失败恢复均有 generation/CAS、同事务 JobRun terminal 证明；P2 配置/错误/默认地址保持固定、无敏感回显；P3 无 500 编号竞态、无不可达 correction 路径、客户端关键状态可在本地回归；全量后端、客户端脚本、双端构建、Alembic `0011`、diff 检查、独立复审、宁波 Backend 生产门禁和 macOS Build 34 换装／ZIP 均已通过。iOS Build 34 与公开发布由用户另行处理。
- v1.8.1 完整施工、历史重提和生产验收：`archive/plans/PROJECT_PLAN-v1.8.1-completed.md`；清理前规范与发布流水：`archive/operations/AGENTS-through-2026-08-08.md`；其他历史计划、设计、运维与已解决 learning 位于 `archive/`。
