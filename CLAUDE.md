# LinoI 项目规范

## 项目事实

- SwiftUI iOS App（`App/`，Bundle ID `com.lino.linoi`）+ FastAPI 后端（`Backend/`，Python 3.12 + SQLAlchemy + Alembic + SQLite）。
- 写作链四 Agent：Memory Selector → Writer → Reviser（按需 ≤2 次）→ Extractor。语义契约见 PROJECT_PLAN.md。
- 云端信息（服务器拓扑、发版/回滚/运维命令、安全整改清单）在仓库外的 `/Users/linotsai/Lino/hk_info.md`，运维动作后同步更新它。
- SSH 部署私钥应放在 `.deploy/linoi_cloud_ed25519`（被 gitignore）；本机没有就向用户要。
- `Backend/.env`（APP_TOKEN / KEK_SECRET / DATABASE_URL）不进 Git；真实数据只在云端生产库。

## 铁律

- 生产表结构只走 `alembic upgrade head`，应用启动不 create_all；发版前必须先备份云端 `linoi.db`（命令见 hk_info.md §13）。
- 字数一律按「去空白字符数」计算，合格区间为目标的 95%~105%，常量定义在 `Backend/app/services/context.py`。
- 人物选择 = 本章允许出现集合的**上限**（被提及也算出现）；未选人物不因历史记忆或 Extractor 输出获得授权。
- 能程序校验的约束不只写在 Prompt 里；模型自报「已修好」不作数，以程序复检为准。
- 推理参数（thinking/effort）由 capability registry（`model_capabilities.py`）决定能不能发，未知模型一律不发额外参数。
- 上游错误必须分类保留 blockReason/finishReason，不得把内容过滤伪装成普通失败；日志不得泄露 API Key 与正文。

## 常用命令

```bash
# 后端测试（本地 venv：Backend/.venv，没有就按 README 重建）
cd Backend && .venv/bin/python -m pytest -q

# iOS 构建验证（SwiftUI View 改动必须跑 App target，不能只跑 SwiftPM）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoI \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

## 兼容窗口

- `chapter_style` 旧 wire 字段仍可读写（内部统一 `author_note`），新 App 全量验证后收口，收口时同步删 `_AuthorNoteCompat` 与 ChapterRead 镜像字段。
