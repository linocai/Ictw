# LinoI PROJECT_PLAN

> 本文件是项目唯一权威计划入口。历史 plan 全文在 `archive/`。

## 概述

LinoI 是单人小说写作工作台：SwiftUI iOS App + FastAPI 后端。核心是四 Agent 写作链——Memory Selector（按本章 Bible 从大事记/梗概/人物事件中选记忆 ID）→ Writer（白名单约束下流式写初稿）→ Reviser(仅程序校验不合格时修订，最多两次)→ 用户接受 → Extractor（只归档已选人物）。数据库负责记得全，Writer Prompt 只保留当前工作集。

## 技术选型

- **App**：SwiftUI（iOS），无第三方依赖；Token 存 Keychain，本地草稿缓存在 Application Support。
- **后端**：FastAPI + SQLAlchemy 2 + Alembic + SQLite，单 worker uvicorn；LLM 走 OpenAI-compatible 协议，capability registry 管推理参数（DeepSeek V4 Pro/Flash、Gemini 3.5 Flash、未知模型）。
- **部署**：HK 云服务器，Nginx HTTPS 反代 → 127.0.0.1:8787，systemd `linoi-backend.service`。详情见 `~/Lino/hk_info.md`。

## 当前状态（2026-07-10）

- v1.0.0 已发版上线，云端健康检查正常；Alembic head `20260710_0002`。
- 线上数据：2 本书、23 章、11 个人物；仓库从 https://github.com/linocai/Ictw 克隆。
- 后端 31 个测试全绿（本地新克隆验证过）；`chapter_style` 兼容窗口仍开着（本轮不收口）。
- v1.1.0 施工完成：后端 45 测试全绿、iOS 构建通过、契约交叉检查与本地冒烟通过；Alembic head `20260710_0003`。

## 当前 Plan

（暂无。v1.1.0 已完成施工，全文见 archive/v1.1.0施工plan.md。）

## Backlog

**产品/功能（v1 明确延后项）**
- 向量数据库 / embedding 记忆检索（预筛接口已预留）
- 用户手动 pin/强制选择某条历史记忆
- 人物别名字段及别名级未授权人物扫描
- 跨供应商模型 fallback
- 对后续章节自动重新提取 / 重建记忆
- 每本书单独配置记忆预算公式
- PostgreSQL 迁移、多 worker 分布式写作任务

**技术债**
- `chapter_style` 兼容字段收口（新 App 验证后）
- capability registry 扩充（Qwen、Claude、Kimi 等）
- 短名整词匹配的可选轻量分词方案（提升 2 字名精度，替代当前 1 字左边界启发式）
- LLM 审计表的查询/统计入口（当前仅落库，靠直连 DB 查看）
- 阅读模式增强（书签、朗读、翻页动画等）

**运维/安全（hk_info.md §12 有排序清单）**
- 云端安全整改：关 root 密码登录、UFW、Fail2ban、服务降权、systemd 加固
- 每日自动备份 + 异地副本（当前仅一份人工备份且同盘）
- 安全更新 + 重启、NTP 修复、加 swap、Nginx 限流与 /docs 收口

## 变更日志

- 2026-07-10 v1.0.0 发版：四 Agent 链、记忆选择、Reviser 两次上限、Extractor 权限收口、推理参数配置、删除章节。（施工全文见 archive/v1发版施工plan.md）
- 2026-07-10 仓库从 GitHub 克隆重建本地工作区；恢复 Backend/.env；建立 PROJECT_PLAN.md 与项目 CLAUDE.md，v1 施工 plan 移入 archive/。
- 2026-07-10 v1.1.0 立项：去流式 + 任务持久化（job_runs）、accept 异步化、字数放宽 80%~120%、记忆预算固定常量 + summary≤2、短名校验修复 + 章级豁免、LLM 审计表、单条人物事件接口、ChapterPatch 放开 summary/headline、事件 60 字上限；iOS 去流式轮询、阅读模式、新建直进、章节行简化、故事线增删改、梗概可编辑、导出全书、删书。（施工全文见 archive/v1.1.0施工plan.md）
- 2026-07-10 v1.1.0 施工完成并验证：后端 45 测试全绿、iOS xcodebuild 通过、前后端契约交叉检查通过、本地全新建库迁移链 + API 冒烟通过；iOS 版本抬到 1.1.0(2)。本机新生成部署密钥并完成服务器授权与主机键核验（见 hk_info.md）。
- 2026-07-11 快修上线：Memory Selector 返回非法/截断记忆 ID 不再导致整次写作失败（跳过 + 唯一前缀救回 + Prompt 加固，commit 5ff703b）；真机实报 bug，当日修复部署。
