# ICTW 项目操作规范

`PROJECT_PLAN.md` 是唯一现行计划与状态来源；历史计划、设计和运维记录只查 `archive/`，不得把归档内容当成当前指令执行。

## 项目事实

- 仓库名为 `Ictw`；产品内部历史标识仍使用 `LinoI`。
- 客户端为 SwiftUI iOS App（target `LinoI`，Bundle ID `com.lino.linoi`）和 macOS App（target `LinoIMac`，产品名 `ICTW`，Bundle ID `com.lino.linoi.mac`）。
- 后端位于 `Backend/`，使用 Python、FastAPI、SQLAlchemy、Alembic 与 SQLite。
- 写作链为 Memory Selector → Writer → Checker → 用户接受 → Extractor；Reviser 已移除。
- 当前宁波生产拓扑、发版、回滚和运维命令位于仓库外的 `/Users/linotsai/Lino/NB_info.md`；运维动作后同步更新。`hk_info.md` 仅作香港旧环境的历史记录。
- `Backend/.env`、生产数据库、部署凭证和真实数据不进 Git。

## 兼容标识

- 不要因仓库改名而修改 Xcode 工程名、target 名、Bundle ID、Keychain/UserDefaults 键、`LinoI/ChapterDrafts` 本地草稿目录或后端 wire 字段。
- `chapter_style` 仍处于兼容窗口，内部统一为 `author_note`；收口时同步删除 `_AuthorNoteCompat` 与 ChapterRead 镜像字段。

## 工程铁律

- 生产表结构只通过 `alembic upgrade head` 变更；应用启动不得 `create_all`。
- 部署或迁移前先停服并备份生产 `linoi.db`，再验证 SQLite integrity、foreign keys、Alembic head、单实例和公网鉴权健康。
- 生产迁移禁止两台服务器同时接受写入。
- 正文按去空白字符数计算，只要求不少于 4000 字且正常结束，不设产品上限；首次长度或截断失败最多从同一输入完整重写一次。
- 人物选择是本章允许出现人物集合的上限；历史记忆和 Extractor 输出不会自动授权未选人物。
- Writer 候选仅在后端留档；公开 API 和双端不得提供候选列表、选择接口或候选全文。
- 只有确定性校验和 Checker 均通过、且任务仍持有本章所有权时，Writer 新正文才能与 JobRun 终态在同一事务提升。
- 正文接受与归档独立：接受后章节立即 `finalized`；Extractor 失败不得撤销正文接受或重跑 Checker。
- v2 Extractor 每个 revision 只调用一次；仅完整通过的 `summary + canonical facts + end_state_delta` 可原子激活。
- `partial`、`failed`、`stale` revision 不得进入 Selector、人物故事线或状态投影。
- 历史章节每章只选择一个记忆来源：活跃 v2 优先，否则仅在 `legacy_archive_eligible` 时使用 legacy。
- 历史重提必须来自只读报告、正文哈希复核和用户精确 ID 确认；不得自动全量或按观察项调用模型。
- 能程序校验的约束必须程序复检，不能依赖模型自报成功。
- `thinking` / `effort` 是否发送由 `model_capabilities.py` 决定；非思考请求统一发送 `top_p=0.95`，思考请求不发送 `top_p`。
- 上游错误必须保留真实 `blockReason` / `finishReason` 分类；日志不得泄露 API Key、Prompt、正文或候选全文。

## 当前生产门禁

- 当前源码候选为 `v1.8.3(34)`；宁波 Backend 生产版本为 `v1.8.3`，Alembic head 为 `20260809_0011`；本机 macOS 已换装 Build 34，iOS 由用户自行处理，公开发布的双端客户端仍为 `v1.8.1(32)`。
- 生产入口为 `https://ictw.linotsai.top`，Backend 位于宁波 `/opt/linoi/backend`，只监听 `172.18.0.1:8787` 并由 Nginx Proxy Manager 反代。
- 香港旧服务已 stopped + disabled；除非先停宁波服务并执行明确回退，否则禁止启动。
- 当前归档概况、历史重提限制和下一目标以 `PROJECT_PLAN.md` 为准。
- `KEK_SECRET` 与 `APP_TOKEN` 必须原样、安全迁移，任何命令输出、计划、提交或回复都不得打印其值。

## 工作区规则

- 现有未提交改动属于用户；不得覆盖、回退或擅自暂存。
- `App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme` 当前包含用户修改，除非任务明确涉及它，否则只读保护。
- `archive/` 只保存历史材料；运行源码、Alembic migrations、回归测试和仍被测试引用的维护脚本不得仅因版本号旧而移入归档。
- `.deploy/` 只保留当前连接材料和必要部署包；密钥与二进制不得进入仓库内 `archive/`。
- 使用 `rg` / `rg --files` 做定向检索；避免加载生成文件、依赖目录和大型日志。

## 验证命令

```bash
cd Backend
.venv/bin/python -m pytest -q
.venv/bin/python -m alembic heads

cd ..
App/Tests/run_client_state_tests.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoI \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoIMac \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

SwiftUI View 或共享客户端代码改动必须验证受影响的 App target；共享层改动默认双 target 都跑。iOS 与 macOS 构建串行执行，或使用不同 `DerivedData` 路径。

## 历史资料

- 清理前完整规范和发布流水：`archive/operations/AGENTS-through-2026-08-08.md`
- 已完成施工计划：`archive/plans/`
- 历史设计稿：`archive/design/`
- 一次性运维脚本：`archive/operations/`
