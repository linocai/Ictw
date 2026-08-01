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

- `v1.6.3(18)` 已于 2026-08-01 完成 Backend 部署、Alembic `20260801_0008` 摘要迁移、macOS 正式 App 换装、tag 与 GitHub Release；iOS 未打包或安装。
- `v1.6.2(17)` 已于 2026-08-01 完成 Backend 部署、macOS 正式 App 换装、tag 与 GitHub Release；按用户要求未打包或安装 iOS。
- `v1.6.1(16)` 已于 2026-08-01 完成 Backend 部署、macOS 正式 App 换装、tag 与 GitHub Release；按用户要求未打包或安装 iOS。
- `v1.6.0(15)` 已于 2026-08-01 完成香港现网 Backend 部署与 Alembic `20260801_0007` 迁移、macOS 正式 App 换装、tag 与 GitHub Release；iOS 由用户处理。
- `v1.5.0(14)` 已于 2026-07-28 完成 Backend 部署、macOS 换装、tag 与 GitHub Release；iOS 安装由用户处理。
- 香港云迁移宁波云已暂停，恢复条件、范围和顺序以 `PROJECT_PLAN.md` 的「暂停／待恢复」段落为准。
- ICP 备案、非标准 HTTPS 端口或已备案域名的路线未确定前，只能做本地计划、只读盘点和新机离线准备，不得切 DNS 或停生产。
- `KEK_SECRET` 与 `APP_TOKEN` 必须原样、安全迁移；不得在日志、计划文件或聊天回复中打印其值。
