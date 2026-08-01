# ICTW / LinoI

ICTW / LinoI 是一个个人小说写作工作台，由 SwiftUI iOS、macOS App 和 FastAPI 后端组成。当前版本为 [`1.6.0(15)`](https://github.com/linocai/Ictw/releases/tag/v1.6.0)；iOS 安装由用户处理。写作流程为：

```text
Memory Selector → Writer → Checker → 用户接受 → Extractor
```

## 项目结构

- `App/LinoI/`：iOS App 与双端共享源码，target `LinoI`，Bundle ID `com.lino.linoi`。
- `App/LinoIMac/`：macOS App，target `LinoIMac`，产品名 `ICTW`，Bundle ID `com.lino.linoi.mac`。
- `Backend/`：FastAPI、SQLAlchemy、Alembic 和 SQLite 后端。
- `Backend/alembic/`：生产数据库迁移；生产启动不会自动修改表结构。
- `AGENTS.md`：Codex 的项目级操作规范。
- `PROJECT_PLAN.md`：项目唯一权威计划入口。
- `archive/`：历次版本的设计、迁移和验收记录。

仓库目录已从 `LinoI` 改名为 `Ictw`。工程名、target、Bundle ID、Keychain/UserDefaults 键和本地草稿目录仍保留历史标识，不应批量改名。

## 当前能力

- 写作与提取均为后台任务：`POST /write`、`POST /accept` 立即返回 `WriteJobStatus`，通过 `GET /chapters/{id}/job` 轮询到终态；任务状态持久化到 `job_runs`，重启后非终态任务标记 failed。客户端加载章节时会主动对账最新任务，后端用 `job_id` / `outcome_current` 区分当前终态与已失效旧结果。
- 字数按去空白字符计，只要求正文不少于 4000 字且正常结束，不设产品上限；首次长度或截断失败最多从同一输入完整重写一次。
- Memory Selector 从同书已完成历史中召回较多候选，再压缩成短而密集、逐条带来源的记忆简报；上一章尾段独立提供开场衔接。
- Writer 使用人物白名单，历史记忆不会自动授予人物本章出场权限；短名校验对单字名走左边界启发式（“森林”不再误命中“林”），并支持章级豁免。
- Writer 每次从同一份 Bible 与记忆上下文完整生成整章，不扩写旧稿；所有候选完整保留，可在双端查看、比较和切换。
- Checker 只举证 Bible 遗漏、矛盾和剧情越界，不修改正文或评价文风；用户可编辑后复查，或明确忽略结果后接受。
- Extractor 只从用户接受的正文提取长摘要、状态变化、未决事项、原子记忆和已选人物更新，事务化提交并为后续记忆提供来源。
- 每次 LLM 调用写入 `llm_call_audits`（role/model/耗时/usage/finish_reason/error_code），绝不记录 API Key、prompt 或正文。
- 四个现役 Agent 可独立绑定模型、可编辑人格、思考开关与思考强度；不可编辑程序协议始终生效。
- 支持 DeepSeek V4 Pro/Flash、GLM 5/5.1/5.2、Gemini 3.5 Flash 的显式推理能力。
- 双端可展开查看实际记忆简报、上一章尾段、来源、冲突提示、候选全文和 Checker 双侧证据。
- 支持章节删除、人物事件级联和章节序号收拢。
- 旧 `chapter_style` wire 字段在兼容期继续可读写，内部统一为 `author_note`。

## 后端本地启动

```bash
cd Backend
python3.12 -m venv .venv
.venv/bin/python -m pip install -e '.[dev]'
cp .env.example .env
.venv/bin/python -m alembic upgrade head
.venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8787 --reload
```

必须在 `.env` 中设置高强度的 `APP_TOKEN` 与 `KEK_SECRET`。`.env`、SQLite 数据库和部署密钥均被 `.gitignore` 排除。

## App 构建

```bash
# iOS
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj \
  -scheme LinoI \
  -configuration Debug \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO \
  build

# macOS
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj \
  -scheme LinoIMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

App 首次启动需要填写后端 HTTPS 地址和 Bearer Token，Token 保存在 Keychain。Debug 构建也可通过 Scheme 环境变量 `LINOI_DEBUG_TOKEN` 注入本地 Token；仓库不包含任何真实凭证。

## 测试

```bash
cd Backend
.venv/bin/python -m pytest -q

cd ..
App/Tests/run_client_state_tests.sh
```

测试覆盖数据库迁移、SQLite 外键、模型 capability、记忆压缩与来源、人物预检、Writer 单次完整重写上限、候选保留、Checker 三档结论与显式覆盖、Extractor 归档事务、章节删除，以及客户端冷启动/跨设备终态对账与失败缓存失效等场景。

## 生产部署

推荐顺序：

1. 确认没有运行中的写作任务。
2. 停止后端并备份数据库与代码。
3. 部署兼容后端。
4. 执行 `.venv/bin/python -m alembic upgrade head`。
5. 启动服务并检查 `/api/v1/health`。
6. 完成 Memory Selector、Writer、Checker、Extractor 烟测。

生产服务器配置、`.env`、SQLite 数据和 SSH 凭证不进入仓库。
