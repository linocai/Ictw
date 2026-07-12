# LinoI v1.3.1

LinoI 是一个个人小说写作工作台，由 SwiftUI iOS App 和 FastAPI 后端组成。写作流程为：

```text
Memory Selector → Writer（初稿/扩写）→ Reviser（压缩与其他违规修订）→ 用户接受 → Extractor
```

## 项目结构

- `App/`：SwiftUI iOS App，Bundle ID `com.lino.linoi`。
- `Backend/`：FastAPI、SQLAlchemy、Alembic 和 SQLite 后端。
- `Backend/alembic/`：生产数据库迁移；生产启动不会自动修改表结构。
- `PROJECT_PLAN.md`：项目唯一权威计划入口。
- `archive/v1发版施工plan.md`：v1.0.0 的设计、迁移和验收契约（历史存档）。

## 当前能力

- 写作与提取均为后台任务：`POST /write`、`POST /accept` 立即返回 `WriteJobStatus`，通过 `GET /chapters/{id}/job` 轮询到终态；任务状态持久化到 `job_runs`，重启后非终态任务标记 failed。
- 字数按去空白字符计，合格区间为目标的 80%~120%；记忆预算固定为 1800 去空白字符，章节梗概装箱最多 2 条。
- Memory Selector 从同书、已完成、早于当前章的历史块中选择工作记忆。
- Writer 使用人物白名单，历史记忆不会自动授予人物本章出场权限；短名校验对单字名走左边界启发式（“森林”不再误命中“林”），并支持章级豁免。
- 字数不足或输出截断只由 Writer 扩写；超长、人物白名单和其他程序违规由 Reviser 修订，二者各最多两次，失败恢复生成前草稿。
- Extractor 仅更新本章已选人物，章节结果和人物事件事务化提交；单条人物事件可改/删，事件文本上限 60 去空白字符。
- 每次 LLM 调用写入 `llm_call_audits`（role/model/耗时/usage/finish_reason/error_code），绝不记录 API Key、prompt 或正文。
- 四个 Agent 可独立绑定模型、人格、思考开关与思考强度。
- 支持 DeepSeek V4 Pro/Flash、GLM 5/5.1/5.2、Gemini 3.5 Flash 的显式推理能力。
- Writer 会在固定 1800 字历史预算内读取由 Memory Selector 选择起点的紧邻上一章结尾原文，作为低于本章 Bible 的开场衔接参考。
- Reviser 工作时双端实时展示程序校验未通过的具体原因，并可接管其他客户端已经启动的章节任务。
- 支持章节删除、人物事件级联和章节序号收拢。
- 旧 `chapter_style` wire 字段在兼容期继续可读写，内部统一为 `author_note`。

## 后端本地启动

```bash
cd Backend
python3.12 -m venv .venv
.venv/bin/pip install -e '.[dev]'
cp .env.example .env
.venv/bin/alembic upgrade head
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8787 --reload
```

必须在 `.env` 中设置高强度的 `APP_TOKEN` 与 `KEK_SECRET`。`.env`、SQLite 数据库和部署密钥均被 `.gitignore` 排除。

## iOS 构建

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj \
  -scheme LinoI \
  -configuration Debug \
  -sdk iphonesimulator \
  CODE_SIGNING_ALLOWED=NO \
  build
```

App 首次启动需要填写后端 HTTPS 地址和 Bearer Token，Token 保存在 Keychain。Debug 构建也可通过 Scheme 环境变量 `LINOI_DEBUG_TOKEN` 注入本地 Token；仓库不包含任何真实凭证。

## 测试

```bash
cd Backend
.venv/bin/python -m pytest -q
```

测试覆盖数据库迁移、SQLite 外键、模型 capability、记忆筛选、人物预检、Writer/Reviser 路由与次数上限、失败恢复、任务接管、Extractor 事务和章节删除等场景。

## 生产部署

推荐顺序：

1. 确认没有运行中的写作任务。
2. 停止后端并备份数据库与代码。
3. 部署兼容后端。
4. 执行 `.venv/bin/alembic upgrade head`。
5. 启动服务并检查 `/api/v1/health`。
6. 完成 Memory Selector、Writer、Reviser、Extractor 烟测。

生产服务器配置、`.env`、SQLite 数据和 SSH 凭证不进入仓库。
