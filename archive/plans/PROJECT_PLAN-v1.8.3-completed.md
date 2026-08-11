# ICTW v1.8.3（34）完成记录

> 归档于 2026-08-11。本文件只保留已完成版本的结论；现行施工以根目录 `PROJECT_PLAN.md` 为准。

## 交付结论

- 宁波 Backend 已部署 `v1.8.3`，Alembic head 为 `20260809_0011`；生产入口、单实例、鉴权健康、SQLite integrity 与 foreign keys 门禁均通过。
- Extractor v2 relationship delta 快修完成：关系由双参与者 Fact 机械推导；每个 revision 仍只调用一次，只有完整 `summary + canonical facts + end_state_delta` 可原子激活。
- Writer 采用 chapter `write_generation` 与数据库 CAS：所有真实输入变化使受影响写作失效；成功、失败、取消与 baseline 恢复均不能覆盖较新的章节输入，且恢复与 JobRun 终态同事务。
- Extractor 的 reopen／activation／重启恢复已统一生命周期门禁：撤销的 extract revision 只能 stale／cancelled，不能反向激活，也不撤销已接受正文。
- 配置错误、上游诊断脱敏、宁波默认连接迁移、章节并发编号重试、历史 correction 死代码清理以及客户端状态回归已完成；独立 Reviewer 无 P0–P3 finding。
- 本机 macOS `v1.8.3(34)` 已签名、换装并真实启动；iOS Build 34 与公开发布由用户另行处理。公开发布的双端客户端仍是 `v1.8.1(32)`。

## 生产记录与回滚

- 2026-08-09 14:39–14:43 CST 按 `/Users/linotsai/Lino/NB_info.md` 部署。停服备份位于 `/opt/linoi/backups/20260809-143950-v1.8.3-build34`；发布包为 `/opt/linoi/releases/ictw-backend-v1.8.3-build34.tar.gz`，SHA-256 为 `9d132445aab87fc083ed78a8a9dade69ce9e0a8365a95bb08dc8e545040cee72`。
- 部署前后为 3 books／68 chapters／26 characters；非终态 Writer／Extractor、pending/extracting revision 与 writing chapter 均为 0。公网 TLS、未鉴权 401、鉴权 health `1.8.3`、单 uvicorn、`NRestarts=0` 与启动 warning 门禁均通过。
- macOS 通用 ZIP 位于 `/Users/linotsai/Downloads/ICTW-v1.8.3-build34`，SHA-256 为 `2965c0992dd58dd7911f9a91dec09f7aa2741972765788a63e498d009a17d525`。旧 App 的本机临时备份位置记录于当时交付日志。
- 代码回退优先保留 `0011` 的兼容列；不得启动香港旧服务，除非先停宁波且用户明确要求回退。不得自动重跑 production JobRun、重写正文、激活 partial/stale revision 或历史重提。

## 历史索引

- v1.8.1 完整施工、历史重提与生产验收：`archive/plans/PROJECT_PLAN-v1.8.1-completed.md`。
- 清理前的完整规则与发布流水：`archive/operations/AGENTS-through-2026-08-08.md`。
- 现行后续目标：根目录 `PROJECT_PLAN.md`，v1.9.0（35）“灵感创造师”。
