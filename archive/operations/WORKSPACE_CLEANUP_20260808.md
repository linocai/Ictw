# 2026-08-08 工作区清理记录

## 目标

将当前运行所需源码、配置、迁移和测试与已完成施工资料、旧发布产物、一次性脚本及本地运行残留分开。

## 仓库内归档

- 完整 v1.8.1 计划：`archive/plans/PROJECT_PLAN-v1.8.1-completed.md`
- 清理前完整 AGENTS：`archive/operations/AGENTS-through-2026-08-08.md`
- v1.0–v1.6 施工计划：`archive/plans/v1.0-v1.6/`
- iOS「纸与墨」设计交接：`archive/design/ios-paper-and-ink/`
- 已解决 learning/error：`archive/learnings/`
- v1.7 状态重建应用脚本：`archive/operations/v1.7/`
- v1.8 已确认章节重提脚本：`archive/operations/v1.8/`

## 仓库外安全档案

位置：`/Users/linotsai/Lino/ICTW-Local-Archive/20260808-workspace-cleanup`，目录权限为 `700`。

- `deploy-history/`：旧 Backend 发布包、旧 ExportOptions、旧 App Archive、dSYM 与导出包。
- `local-runtime/linoi.db`：清理前本地开发数据库，权限 `600`，SHA-256 为 `da522b7dc249700bad03e28aae8a4f9cc2ad89bedd800b1c2d05a24fe15928bf`。

仓库外档案不进入 Git。部署私钥、known_hosts 和最新宁波迁移包仍保留在被 Git 忽略的 `.deploy/` 中，其内容与秘密值未写入本记录。

## 保留的运行组件

- `App/` 与 `Backend/app/` 源码。
- 完整 Alembic migration 链。
- Backend 与客户端回归测试。
- 被测试或当前维护流程引用的 `Backend/scripts/` 工具。
- `Backend/.env` 与 `.venv`。
- 当前 Xcode 工程、共享 scheme 和资产。

## 验证

清理后验证结果：

- `git diff --check` 通过。
- 运行代码与现行文档未引用已移动的一次性脚本。
- 仓库内归档未发现私钥正文或 `APP_TOKEN` / `KEK_SECRET` 赋值。
- Backend：117 passed / 12 skipped；仅有既存依赖弃用警告。
- 客户端状态测试通过。
- Alembic：`20260805_0010 (head)`。
