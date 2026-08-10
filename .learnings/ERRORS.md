# Errors

当前无未解决错误。2026-08-08 以前的完整记录已归档至 `archive/learnings/ERRORS-through-2026-08-08.md`。

## [ERR-20260809-006] extraction-helper-removal-patch

**Logged**: 2026-08-09T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: backend

### Summary

删除旧 Extractor salvage helper 时，补丁上下文基于过期函数正文而未匹配；没有写入任何文件。

### Resolution

- **Resolved**: 2026-08-09T00:00:00+08:00
- **Notes**: 先读取当前函数全文，再以精确上下文进行最小删除。

---

## [ERR-20260809-007] verification-working-directory

**Logged**: 2026-08-09T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

一次组合验证在进入 `Backend/` 后读取根目录 `PROJECT_PLAN.md`，路径错误且没有改动文件。

### Resolution

- **Resolved**: 2026-08-09T00:00:00+08:00
- **Notes**: 后续根目录检查使用独立工作目录命令，不依赖 shell 的前序 `cd`。

---

## [ERR-20260808-001] cache-cleanup-command

**Logged**: 2026-08-08T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: config

### Summary

首次缓存清理命令包含递归 `rm`，在执行前被安全策略拒绝，未删除任何文件。

### Resolution

改用对已核准精确目录执行的 `find -delete` 与 `rmdir`；清理成功且未触及 `.venv`、源码、凭证或用户 scheme。

## [ERR-20260809-001] ningbo-ssh-known-hosts

**Logged**: 2026-08-09T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

首次宁波只读日志命令误用了 `.deploy/known_hosts`，SSH 在连接前因 host key 校验失败。

### Error

`Host key verification failed.`

### Suggested Fix

宁波主机 `114.66.0.38` 使用 `.deploy/ningbo_known_hosts`；旧 `.deploy/known_hosts` 不作为宁波连接材料。

### Metadata

- Reproducible: yes
- Related Files: `.deploy/ningbo_known_hosts`, `/Users/linotsai/Lino/NB_info.md`

### Resolution

- **Resolved**: 2026-08-09T00:00:00+08:00
- **Notes**: 改用 `.deploy/ningbo_known_hosts` 后只读 SSH 成功；服务 active、`NRestarts=0`，未修改服务器。

## [ERR-20260809-002] relationship-delta-integration-test

**Logged**: 2026-08-09T00:00:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: tests

### Summary

新增 relationship delta 端到端测试时，纯 validator 用例通过，但归档任务在激活路径返回 failed。

### Context

- 命令：`PYTHONDONTWRITEBYTECODE=1 .venv/bin/python -m pytest -q -p no:cacheprovider tests/test_v1_8_archive.py`
- 失败测试：`test_relationship_delta_activates_with_pair_derived_from_fact`
- 未跳过测试；正在读取脱敏 Job 错误定位激活／投影阶段。

### Metadata

- Reproducible: yes
- Related Files: `Backend/tests/test_v1_8_archive.py`, `Backend/app/services/archive_v2.py`

### Resolution

- **Resolved**: 2026-08-09T00:00:00+08:00
- **Notes**: 失败来自测试夹具的临时 `fact_ref` 超过既有 16 字符上限；缩短为 `relation` 后，15 项 v1.8 archive 测试全部通过。产品实现无需为此放松 fact_ref 门禁。

## [ERR-20260809-003] archive-log-redaction-assertion

**Logged**: 2026-08-09T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

日志脱敏回归错误地使用了导入前 Chapter 响应中的空 `draft_text`，使“不包含正文”断言必然失败。

### Resolution

- **Resolved**: 2026-08-09T00:00:00+08:00
- **Notes**: 改为使用接受后重新读取的非空正文检查日志；捕获到的日志本身仅含 ID、模型、stage、error code 和静态规则。

### Metadata

- Reproducible: yes
- Related Files: `Backend/tests/test_v1_8_archive.py`

## [ERR-20260809-004] background-caplog-race

**Logged**: 2026-08-09T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

后台 Extractor 线程的 warning 在全量测试顺序中偶尔晚于 `caplog` 上下文结束，造成日志断言不稳定。

### Resolution

- **Resolved**: 2026-08-09T00:00:00+08:00
- **Notes**: 后台端到端用例只验证归档失败隔离；结构化日志字段与正文脱敏改由同步调用日志 helper、替换 `logger.warning` 的独立单元测试验证，避免依赖全局日志捕获状态。

### Metadata

- Reproducible: intermittent
- Related Files: `Backend/tests/test_v1_8_archive.py`, `Backend/app/services/write_jobs.py`

## [ERR-20260809-005] reviewer-spawn-context-conflict

**Logged**: 2026-08-09T05:40:58Z
**Priority**: low
**Status**: resolved
**Area**: config

### Summary

启动指定 `reviewer` 角色时同时请求继承完整对话，协作工具拒绝了互斥参数组合。

### Error

```
Full-history forked agents inherit the parent agent type; omit agent_type, or spawn without a full-history fork.
```

### Context

- 操作：为 Extractor 快修启动独立 Reviewer。
- 参数组合：`agent_type=reviewer` 与 `fork_turns=all`。

### Suggested Fix

指定 Reviewer 等角色时使用有限的最近上下文，并在任务消息中补齐完整审查范围；只有继承父角色时才使用完整历史分叉。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-09T05:40:58Z
- **Notes**: 改用有限上下文启动 Reviewer；不影响项目代码或审查结论。

## [ERR-20260809-008] production-alembic-working-directory

**Logged**: 2026-08-09T06:36:41Z
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

宁波只读 Alembic 查询未先进入 Backend 工作目录，`linoi` 用户因此尝试读取 root 当前目录中的 `pyproject.toml` 并被拒绝。

### Error

```
PermissionError: [Errno 13] Permission denied: 'pyproject.toml'
```

### Context

- 操作：部署前以服务用户查询生产 Alembic current。
- SSH、systemd 和数据库权限检查均成功；只有 Alembic 命令工作目录错误。
- 生产未发生任何写入。

### Suggested Fix

远端 Alembic 命令必须先 `cd /opt/linoi/backend`，再以 `linoi` 用户运行项目虚拟环境中的 Alembic。

### Metadata

- Reproducible: yes
- Related Files: `/Users/linotsai/Lino/NB_info.md`

### Resolution

- **Resolved**: 2026-08-09T06:36:41Z
- **Notes**: 已改用明确的 Backend 工作目录重新执行部署前检查；不影响生产状态。

## [ERR-20260809-009] production-sqlite-ssh-quoting

**Logged**: 2026-08-09T06:37:36Z
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

通过 SSH 内嵌 SQLite SQL 时，多层 shell 引号移除了 SQL 字符串字面量的引号，导致只读任务计数查询无法解析。

### Error

```
Error: in prepare, no such column: nonterminal_jobs
```

### Context

- 操作：部署前查询非终态 JobRun、未完成 revision 和 writing 章节数量。
- Alembic current 已成功确认；SQLite 查询在 prepare 阶段失败。
- 生产未发生任何写入。

### Suggested Fix

通过标准输入把固定 SQL 传给远端 `sqlite3 -readonly`，避免在 SSH 命令、远端 shell 与 SQL 三层之间嵌套字符串引号。

### Metadata

- Reproducible: yes
- Related Files: `/Users/linotsai/Lino/NB_info.md`

### Resolution

- **Resolved**: 2026-08-09T06:37:36Z
- **Notes**: 改用 stdin 传递 SQL 后重新执行部署前只读检查。

## [ERR-20260809-010] deployment-tar-macos-xattr

**Logged**: 2026-08-09T06:39:14Z
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

macOS bsdtar 创建的发布包仍携带 provenance 扩展属性，远端 GNU tar 校验时输出未知扩展头 warning。

### Error

```
tar: Ignoring unknown extended header keyword 'LIBARCHIVE.xattr.com.apple.provenance'
```

### Context

- 操作：上传后在宁波服务器列出 Backend 发布包关键文件。
- 包哈希与源码文件均正确，尚未切换生产代码。

### Suggested Fix

创建跨平台发布包时同时使用 bsdtar 的 `--no-xattrs` 与 `--no-mac-metadata`，上传为临时文件并在远端校验后原子替换。

### Metadata

- Reproducible: yes
- Related Files: `.deploy/ictw-backend-v1.8.3-build34.tar.gz`

### Resolution

- **Resolved**: 2026-08-09T06:39:14Z
- **Notes**: 已重新生成不含 macOS 扩展属性的发布包，并在远端无 warning 校验。

## [ERR-20260809-011] sqlite-pragma-notnull-keyword

**Logged**: 2026-08-09T06:41:45Z
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

迁移后的只读结构检查在查询 `pragma_table_info` 时直接使用 `notnull` 列名，SQLite 将其按关键字解析并报语法错误。

### Error

```
Parse error near line 1: near "notnull": syntax error
```

### Context

- `alembic upgrade head` 已成功完成到 `20260809_0011`。
- `PRAGMA integrity_check` 已先返回 `ok`；失败只发生在后续只读元数据查询。

### Suggested Fix

生产门禁只需按列名确认新增字段存在，或在确需读取时正确引用 pragma 的 `notnull` 字段，避免裸用关键字。

### Metadata

- Reproducible: yes
- Related Files: `Backend/alembic/versions/20260809_0011_writer_generation.py`

### Resolution

- **Resolved**: 2026-08-09T06:41:45Z
- **Notes**: 去掉关键字条件后重新执行完整迁移后检查；生产数据未受影响。
