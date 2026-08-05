# ICTW 项目操作规范

本文件是 Codex 的仓库级入口；`PROJECT_PLAN.md` 是唯一权威计划与状态来源，历史施工计划只查 `archive/`。

## 项目事实

- 仓库目录名是 `Ictw`；产品内部历史标识仍使用 `LinoI`，不要因仓库改名批量替换。
- 客户端为 SwiftUI iOS App（target `LinoI`，Bundle ID `com.lino.linoi`）和 macOS App（target `LinoIMac`，产品名 `ICTW`，Bundle ID `com.lino.linoi.mac`）。
- 后端位于 `Backend/`，使用 Python 3.12、FastAPI、SQLAlchemy、Alembic 与 SQLite。
- v1.6 写作链为 Memory Selector → Writer → Checker → 用户接受 → Extractor；Reviser 已移除。
- 云端拓扑、发版、回滚和运维命令记录在仓库外的 `/Users/linotsai/Lino/hk_info.md`；运维动作后同步更新。
- `Backend/.env`、生产数据库和 `.deploy/` 内的部署凭证不进 Git；真实数据只在云端生产库。

## 不可破坏的兼容标识

- 不要因仓库改名而改 Xcode 工程名、target 名、Bundle ID、Keychain/UserDefaults 键、`LinoI/ChapterDrafts` 本地草稿目录或后端 wire 字段。
- `chapter_style` 仍处于兼容窗口，内部统一为 `author_note`；收口时必须同步删除 `_AuthorNoteCompat` 与 ChapterRead 镜像字段。

## 铁律

- 生产表结构只允许通过 `alembic upgrade head` 变更；应用启动不得 `create_all`。
- 任何部署或迁移前先备份生产 `linoi.db`，随后验证 SQLite integrity、foreign keys 和 Alembic head。
- v1.6 字数按去空白字符数计算，正文只要求不少于 4000 字且正常结束，不设产品上限；首次长度／截断失败最多从同一输入完整重写一次，常量在 `Backend/app/services/context.py`。
- 人物选择是本章允许出现人物集合的上限；历史记忆与 Extractor 输出不会自动授权未选人物。
- Writer 候选仅在后端留档；公开 API 不提供候选列表、选择或真实候选正文。只有确定性校验和 Checker 均通过、且任务仍持有本章所有权时才能提升当前正文；提升与 JobRun 终态必须同一事务提交。
- 双端不得拉取或渲染候选全文，也不得用旧正文的 Checker 结果表示新一轮生成已通过；失败重生成保留旧正文时，旧正文仍可按它自己的 Checker 状态接受或重新检查。
- 能程序校验的约束必须程序复检，不能依赖模型自报“已修好”。
- `thinking`/`effort` 是否发送由 `model_capabilities.py` 决定；实际非思考请求统一发送 `top_p=0.95`（包括未知模型），思考请求不发送 `top_p`。
- 上游错误必须保留 `blockReason`/`finishReason` 的真实分类；不得把内容过滤伪装成普通失败，日志不得泄露 API Key、Prompt 或正文。
- v1.8 接受正文与归档独立：接受后章节立即 `finalized`；Extractor 每个 revision 只调用一次，只有完整通过确定性校验的 `summary + canonical facts + end_state_delta` 才能激活。`partial`／`failed`／`stale` 不得进入 Selector、人物故事线或状态投影，重试不得重新跑 Checker。
- v1.8 每个历史章节只能选择一个记忆来源：活跃 v2 ledger 优先，否则仅在 `legacy_archive_eligible` 时使用旧归档。历史重提必须来自 0600 只读报告、逐章正文哈希复核和用户精确 ID 确认；不得全量或按观察项自动调用模型。
- 生产迁移必须先停旧服务再切换，禁止两台服务器同时接受写入。

## 验证命令

```bash
cd Backend
.venv/bin/python -m pytest -q
.venv/bin/python -m alembic heads

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoI \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoIMac \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

SwiftUI View 或共享客户端代码改动必须验证受影响的 App target；共享层改动默认双 target 都跑。

## 当前运维门禁

- Backend `v1.8.1(32)` 于 2026-08-05 快修章节 PATCH 重建人物关联后计算归档指纹时的空引用：`_replace_links` 必须同时绑定已校验 Character 对象，不能只写 `character_id`；回归测试覆盖从空列表新增和重发同一非空列表。生产备份 `/opt/linoi/backups/20260805-200901`，部署包 SHA-256 `b14197f5bc3bb1b400435d155ee05c0d2efe1300ff3d5c6a4abafac06b0978b1`；事务烟测、内外网健康、integrity／foreign keys、零活动任务、`NRestarts=0` 及部署后零 error 均通过。无 migration，不改版本／Build、双端 App、tag 或 Release。
- 双端／Backend `v1.8.1(32)` 已于 2026-08-05 完成宽松 Extractor 状态合同快修：保持 v1.8 ledger、Selector、fingerprint 与整体原子激活；delta 可引用任何有正文证据且人物归属匹配的 fact，scope 由 slot 机械推导，snapshot 只更新实际变化的槽且未输出项保持原值。人物白名单、owner 参与、关系双方、source ID、未知占位、重复与整体激活门禁不放松。Backend 部署备份 `/opt/linoi/backups/20260805-180502`；用户确认重提前备份 `/opt/linoi/backups/20260805-181311`，只对第三轮失败的 4 章各调用一次，《骁扬》第 14 章以 8 facts／8 deltas 激活，其余 3 章被关系目标、重复槽、owner 参与事实门禁拒绝并继续使用 legacy。生产现为 `59 legacy eligible / 17 partial / 2 active v2 / 16 facts / 18 deltas`；正文、人物、legacy 数据未变，投影重放一致。不得自动追加第五轮，11 个观察项不得执行。双端签名 Archive、iOS 本机 IPA、macOS 通用 ZIP／换装已完成；后续已以 iOS 1024 图标机械重生 macOS 全套 AppIcon，不变更 `1.8.1(32)`、iOS 二进制、Backend 或既有 tag，重做并换装 macOS 签名包。Release 同名 ZIP 已替换，SHA-256 为 `0975e9e51baf2b004db395a35384d2ddaa82f37aba84a3c0d8e4affb59039564`；tag／Release 仍为 `v1.8.1`，公开资产仅 macOS ZIP。
- 双端／Backend `v1.8.0(31)` 已于 2026-08-05 完成 Extractor 合同漂移快修：模型事实引用只需本次输出内唯一，后端按数组顺序归一化为 `F1..F8` 并同步映射 delta；长度／槽位限制同步进 Schema，4 句 source span 仅作精度建议，仍严格检查 source ID 存在、首尾顺序、连续区间、白名单、关系、状态槽、重复与整体激活。最终 Backend 部署备份 `/opt/linoi/backups/20260805-173736`；用户确认第三轮前备份 `/opt/linoi/backups/20260805-174557`，同一 5 章各调用一次后仅《蔡言柃》第 41 章以 8 facts／10 deltas 激活，其余 4 章因状态引用／快照形状门禁成为非活动 partial 并继续使用 legacy。现为 `60 legacy eligible / 14 partial / 1 active v2 revision`；正文、旧记忆、305 条人物事件、296 条 legacy 状态载荷和固定人物卡未变，混合来源投影重放一致。不得自动第四轮调用，11 个观察项不得执行。双端签名包、iOS 本机 IPA、macOS 换装完成；tag／Release 为 `v1.8.0-build31`。
- 双端／Backend `v1.8.0(30)` 已于 2026-08-05 完成事实账本架构升级与 Alembic `20260805_0010`：正文接受和归档解耦，Extractor 改为单次 `summary + canonical facts + end_state_delta`，Selector／人物页／状态投影按章单源消费，双端支持明确归档原因与独立重试。部署备份 `/opt/linoi/backups/20260805-165604`；用户确认的 5 个硬候选在重提前备份 `/opt/linoi/backups/20260805-170938` 后各调用一次，2 章因事实编号顺序、3 章因 source span 过长被确定性门禁拒绝，均保留 legacy；现为 `61 legacy eligible / 5 partial / 0 active v2 revisions`，不得自动重试，11 个观察项不得执行。正文、旧记忆、人物事件与状态哈希均未变化。双端签名 Archive、iOS 本机 IPA、macOS 双架构 ZIP／换装已完成；tag 与 GitHub Release 为 `v1.8.0`，公开资产仅含 macOS ZIP。
- `v1.7.2(29)` Backend Extractor 质量收敛补丁已于 2026-08-05 精确迁移旧版“200 字梗概／动态字段”人格并将生产温度从 0.3 降为 0.1；人物事件必须按重要性排序，每人最多 3 条、本章最多 8 条，同一人物的同一事件不得重复，超限／重复项逐条丢弃并随完成 Job 提示。不得增加模型调用或放松人物姓名、白名单与正文证据门禁。无 migration、客户端、版本或 Build 变化，生产备份 `/opt/linoi/backups/20260805-150015`；本补丁只推 main，不另建 tag／Release。
- `v1.7.2(29)` Backend 跟进补丁已于 2026-08-04 将人物事件改为逐条严格校验：合格事件保留，类型／人物姓名／白名单／原文证据任一不合格的事件直接丢弃并随完成 Job 提示，不能再阻塞其余归档；不得通过改写证据或猜测归属挽救事件。无 migration、客户端或 Build 变化，生产备份 `/opt/linoi/backups/20260804-225041`；本补丁只推 main，不另建 tag／Release。
- 双端／Backend `v1.7.2(29)` 已于 2026-08-04 完成 Extractor 截断／事件定向纠偏快修：完整归档输出预算提高到 8192 token，长度截断真实分类并在三次调用预算内自动压缩重试；取得完整归档后，人物事件校验失败只重提 `character_events`，不得改写其余归档，原有事件证据与人物白名单门禁不放松。Backend 无 migration，生产备份 `/opt/linoi/backups/20260804-222215`；tag 与 GitHub Release 为 `v1.7.2-build29`，公开资产仅含 macOS ZIP。
- 双端／Backend `v1.7.2(28)` 已于 2026-08-04 完成 Extractor 保守降级快修：仍先严格纠偏三次；只有摘要、章节归档和人物事件全部合格时，才逐组件丢弃不安全的可选人物状态，即时快照保持整组原子性，持续状态／关系逐项复检。不得改写证据、猜测归属或放松白名单；完成 Job 必须记录丢弃数量和中文原因供双端提示。Backend 无 migration，生产备份 `/opt/linoi/backups/20260804-183358`；tag 与 GitHub Release 为 `v1.7.2-build28`，公开资产仅含 macOS ZIP。
- 双端／Backend `v1.7.2(27)` 已于 2026-08-04 修复“忽略 Bible 并接受”在 Extractor 失败后丢失的问题：授权绑定完整写作输入指纹，同稿可直接重试 Extractor，任一输入变化即失效；兼容 Build 26 缺少指纹的现网 override 记录，但必须由当前不可变候选证明输入未变。Backend 无 migration，生产备份 `/opt/linoi/backups/20260804-181721`；双端签名归档、iOS 本机 IPA、macOS 通用架构 ZIP／换装均完成。tag 与 GitHub Release 为 `v1.7.2-build27`，公开资产仅含 macOS ZIP。
- 双端 `v1.7.2(26)` 已于 2026-08-04 修复手改正文后 Checker 仍检查服务器旧稿、导致无法接受本章的问题；市场版本不变，仅 Build 从 25 升至 26。Backend 与数据库未改、未部署；客户端状态测试、双端 Debug／签名 Release Archive、iOS 本机 IPA、macOS 通用架构 ZIP／换装均通过。tag 与 GitHub Release 为 `v1.7.2-build26`，公开资产仅含 macOS ZIP。
- 双端／Backend `v1.7.2(25)` 已于 2026-08-04 完成人物当前状态投影升级、Alembic `20260804_0009`、三本书 77 章安全重建、签名 Archive、本机 macOS 换装、`v1.7.2` tag 与 GitHub Release。生产为 `472 character_state_changes / 111 effective / 0 character_field_patches`，340 条人物事件及正文／Bible／摘要／人物固定卡与备份哈希一致；备份 `/opt/linoi/backups/20260804-153226`。
- v1.7.2 离线重建只请求／校验 `state_updates`；三次纠偏后逐组件保守丢弃不合格状态，冲突关系整对丢弃。0600 断点／完整 bundle 只存云端维护目录，不进 Git；线上 Extractor 仍保持整次严格校验，不使用离线 salvage。
- 双端 `v1.7.1(24)` 已于 2026-08-04 完成 Extractor 快修发版；市场版本不变，仅 Build 从 23 升至 24。客户端状态测试、双端 Debug、签名 Release Archive、版本／Bundle ID／架构／签名复核通过；iOS 开发签名 IPA 仅本机保留、未上传 App Store Connect，macOS 通用架构 App 已换装。tag 与 GitHub Release 为 `v1.7.1-build24`，公开资产仅含 macOS ZIP。
- Backend `v1.7.1` 当前在线 Extractor 对确定性合约／证据校验最多执行三次（首次加两次纠正），仍失败时整事务回滚并返回具体规则原因；上游错误不参与此重试。该快修无 migration，生产备份在 `/opt/linoi/backups/20260804-083059`，Alembic 保持 `20260801_0008`。
- macOS `v1.7.0(22)` 已于 2026-08-03 完成「纸与墨」视觉升级、双端回归、正式通用架构 Archive、本机正式 App 换装、`v1.7.0-macos-build22` tag 与 GitHub Release；Backend、Alembic 与 iOS 无发布动作。
- `v1.7.0(22)` 已于 2026-08-02 修复 iOS 书架“新建书”卡片在网格换行时被压缩的问题，完成独立 Review、正式 Archive、本机开发签名 IPA、`v1.7.0-build22` tag 与 GitHub Release；市场版本仍为 `1.7.0`，Backend、Alembic 与 macOS App 未变更；未上传 App Store Connect 或安装设备。
- `v1.7.0(21)` 已于 2026-08-02 完成 iOS「纸与墨」原生视觉升级、全新 App Icon、正式 Archive、本机开发签名 IPA、tag 与 GitHub Release；Backend、Alembic 与 macOS App 未变更，仍维持 `v1.6.5(20)`；未上传 App Store Connect 或安装设备。
- `v1.6.5(20)` 已于 2026-08-02 完成 Backend 部署、macOS 正式 App 换装、tag 与 GitHub Release；无新 migration，Alembic 保持 `20260801_0008`；iOS 未打包或安装。
- `v1.6.4(19)` 已于 2026-08-02 完成 Backend 部署、macOS 正式 App 换装、tag 与 GitHub Release；无新 migration，Alembic 保持 `20260801_0008`；iOS 未打包或安装。
- `v1.6.3(18)` 已于 2026-08-01 完成 Backend 部署、Alembic `20260801_0008` 摘要迁移、macOS 正式 App 换装、tag 与 GitHub Release；iOS 未打包或安装。
- `v1.6.2(17)` 已于 2026-08-01 完成 Backend 部署、macOS 正式 App 换装、tag 与 GitHub Release；按用户要求未打包或安装 iOS。
- `v1.6.1(16)` 已于 2026-08-01 完成 Backend 部署、macOS 正式 App 换装、tag 与 GitHub Release；按用户要求未打包或安装 iOS。
- `v1.6.0(15)` 已于 2026-08-01 完成香港现网 Backend 部署与 Alembic `20260801_0007` 迁移、macOS 正式 App 换装、tag 与 GitHub Release；iOS 由用户处理。
- `v1.5.0(14)` 已于 2026-07-28 完成 Backend 部署、macOS 换装、tag 与 GitHub Release；iOS 安装由用户处理。
- 香港云迁移宁波云已暂停，恢复条件、范围和顺序以 `PROJECT_PLAN.md` 的「暂停／待恢复」段落为准。
- ICP 备案、非标准 HTTPS 端口或已备案域名的路线未确定前，只能做本地计划、只读盘点和新机离线准备，不得切 DNS 或停生产。
- `KEK_SECRET` 与 `APP_TOKEN` 必须原样、安全迁移；不得在日志、计划文件或聊天回复中打印其值。
