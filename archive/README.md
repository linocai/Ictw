# ICTW 历史档案

本目录保存已完成版本的计划、设计交接、一次性运维脚本和历史 learning。内容只用于追溯，不是当前施工指令；现行状态与规则以根目录 `PROJECT_PLAN.md` 和 `AGENTS.md` 为准。

## 目录

- `plans/`：已完成版本的施工计划与验收记录。
- `design/`：已落地或停止使用的设计交接资产。
- `operations/`：历史运维记录和一次性维护脚本。
- `learnings/`：已解决的 Agent error / learning 完整记录。

运行源码、Alembic migrations、回归测试、秘密、数据库和发布二进制不得存放在这里。包含秘密或二进制的历史运行资产应进入仓库外、权限受控的本机档案。
