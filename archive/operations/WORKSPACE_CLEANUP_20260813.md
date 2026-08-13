# 2026-08-13 工作区清理记录

## 目标

进一步分离现行版本记录、可运行工程、仓库内历史材料与仓库外本地运行档案，降低根目录和 Agent 上下文噪音。

## 文档收口

- 删除重复兼容入口 `CLAUDE.md`；其中唯一未重复的“发布必须经用户明确授权”规则已提升到根目录 `AGENTS.md`。
- 根目录 `PROJECT_PLAN.md` 改为精简版本记录，只保留当前基线、各版本完成内容、Backlog 与历史索引。
- v1.9.2 完整计划保存为 `archive/plans/PROJECT_PLAN-v1.9.2-completed.md`。
- 已解决 error、已完成 feature request 和旧 learning 分别转入 `archive/learnings/`；根目录 `.learnings/` 只保留现行入口与本次已提升规则。

## 本地档案与部署材料

- 原仓库内未跟踪的 `archive/ICTW-Local-Archive/` 已迁回仓库外 `/Users/linotsai/Lino/ICTW-Local-Archive/`，目录权限为 `700`。
- `.gitignore` 定向忽略 `/archive/ICTW-Local-Archive/`，防止本地运行档案再次误入仓库；仓库内经过筛选的 `archive/plans`、`design`、`operations` 与 `learnings` 继续由 Git 跟踪。
- Build 39 之前的五个本地 Backend 发布包移入仓库外 `20260813-workspace-cleanup/deploy-packages/`；`.deploy/` 保留当前 Build 39 包和现役连接材料。

## 可重建残留

- 清除仓库与本地档案中的 `.DS_Store`。
- 清除项目源码范围内的 Python bytecode、pytest cache、Xcode 用户状态与可重建 workspace。
- `Backend/.venv` 保留，避免破坏当前本地测试环境。

## 边界

- 未修改运行源码、Alembic migration、回归测试或 Xcode scheme。
- 未读取、复制或记录 `.env`、私钥、Token、数据库正文或业务内容。
- 仓库外档案与旧发布包可从上述路径恢复；可重建缓存不保留。
