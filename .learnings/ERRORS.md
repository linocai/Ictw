# Errors

## [ERR-20260801-017] Checker override test depended on another test's global character ID

**Logged**: 2026-08-01T12:55:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: tests

### Summary

Checker 覆盖接受用例单独运行时 Extractor 失败，因为默认替身读取了其它测试写入的 `pytest.character_id`。

### Error

```text
expected extract phase done, got failed
```

### Context

- 全量测试按既定顺序运行时会被前置用例意外初始化，因此过去保持绿色。
- 新增定向回归把该测试隔离运行后暴露了顺序依赖，产品运行时不使用该全局变量。

### Suggested Fix

不需要人物输出的用例显式注入空 Extractor，避免共享 `pytest` 全局状态；每个测试自行声明完整依赖。

### Metadata

- Reproducible: yes
- Related Files: Backend/tests/test_api.py, Backend/tests/conftest.py

### Resolution

- **Resolved**: 2026-08-01T12:56:00+08:00
- **Notes**: Checker 失败稿改为后端闸门后不再进入 Extractor；该用例已完全移除对默认 Extractor 和全局人物 ID 的隐式依赖，可独立运行。

---

## [ERR-20260801-016] Client state harness excludes error presenter dependencies

**Logged**: 2026-08-01T12:52:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

在纯状态测试中加入统一错误文案断言后，测试脚本因未编译 `LinoErrorPresenter` 及其 `APIError` 依赖而链接失败。

### Error

```text
cannot find 'LinoErrorPresenter' in scope
```

### Context

- `run_client_state_tests.sh` 有意只编译 `LinoModels.swift` 与 `ClientStateTests.swift`。
- 产品双端 target 本身包含 `LinoErrorPresenter.swift`；此前 iOS/macOS 构建均通过。

### Suggested Fix

纯状态 harness 继续只测试状态映射与刷新竞态；统一错误文案由双端 target 编译覆盖。若未来需要独立文案单测，再建立包含 `APIError` 最小依赖的专用 harness。

### Metadata

- Reproducible: yes
- Related Files: App/Tests/run_client_state_tests.sh, App/LinoI/LinoErrorPresenter.swift

### Resolution

- **Resolved**: 2026-08-01T12:53:00+08:00
- **Notes**: 移除越界的 harness 断言，保留产品文案修改并由双端构建验证。

---

## [ERR-20260801-015] Production verification assumed non-existent job status columns

**Logged**: 2026-08-01T12:34:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

发版后只读统计先后假设 `job_runs.status` 和 `job_runs.state` 存在，SQLite 查询失败。

### Error

```text
no such column: status
no such column: state
```

### Context

- 服务、迁移与数据库均已正常，失败仅发生在补充统计查询。
- 实际任务状态列为 `phase`，人格角色列为 `agent_role`。

### Suggested Fix

生产核验脚本先读取 `pragma_table_info`，或直接复用当前 SQLAlchemy 模型中的列名；终态按 `phase` 的 `done/failed/cancelled` 统计。

### Metadata

- Reproducible: yes
- Related Files: Backend/app/models.py, /Users/linotsai/Lino/hk_info.md

### Resolution

- **Resolved**: 2026-08-01T12:35:00+08:00
- **Notes**: 按实际 `phase` 分组复核，生产任务全部处于终态。

---

## [ERR-20260728-007] staged-secret-scan

**Logged**: 2026-07-28T18:52:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: config

### Summary

提交前的宽范围凭证正则命中仓库内容，提交被安全门禁阻止。

### Error

```text
POTENTIAL_SECRET_FOUND
```

### Context

- 扫描对象是整个 Git index，而非仅本次 staged diff。
- 命中内容未输出；`git commit` 和 `git push` 均未执行。

### Suggested Fix

只列命中文件名，再区分示例占位符、文档字面量与实际秘密；随后对 staged diff 重新扫描。

### Metadata

- Reproducible: yes
- Related Files: staged release files

### Resolution

- **Resolved**: 2026-07-28T18:53:00+08:00
- **Notes**: 命中仅来自已提交的 `Backend/.env.example` 明文占位符；无私钥、GitHub token 或真实 App/KEK secret。后续扫描排除该示例文件并继续提交。

---

## [ERR-20260801-006] isolated-migration-cleanup

**Logged**: 2026-08-01T11:47:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

隔离迁移校验命令因包含 `rm -rf` 临时目录清理而被安全策略拒绝。

### Error

```text
Rejected: rm -f style commands are not permitted. Use a safer approach
```

### Context

- 计划用 `mktemp -d` 创建一次性 SQLite，再在同一复合命令尾部删除临时目录。
- 命令在进程创建前即被拒绝，因此没有运行迁移或删除任何文件。

### Suggested Fix

隔离校验使用明确的 scratchpad 路径并保留小型临时数据库，或通过系统临时目录生命周期清理；不要在验证命令中附带递归删除。

### Metadata

- Reproducible: yes
- Related Files: Backend/alembic/versions/20260801_0007_v1_6_agent_foundation.py

### Resolution

- **Resolved**: 2026-08-01T11:47:00+08:00
- **Notes**: 改为不含删除动作的安全临时数据库校验。

---

## [ERR-20260728-006] apply_patch

**Logged**: 2026-07-28T18:49:00+08:00
**Priority**: low
**Status**: resolved
**Area**: docs

### Summary

发版状态跨文件补丁因历史记录中的空格不匹配而未应用。

### Error

```text
apply_patch verification failed: Failed to find expected lines in PROJECT_PLAN.md
```

### Context

- 同时更新 README、AGENTS 和 PROJECT_PLAN 的生产部署状态。
- 最后一条历史记录上下文少匹配了一个空格；工具保证没有部分应用。

### Suggested Fix

发布状态按文件和短段落分别更新，历史记录只用末尾插入。

### Metadata

- Reproducible: yes
- Related Files: README.md, AGENTS.md, PROJECT_PLAN.md

### Resolution

- **Resolved**: 2026-07-28T18:49:00+08:00
- **Notes**: 拆为独立小补丁继续。

---

## [ERR-20260728-005] remote-log-filter

**Logged**: 2026-07-28T18:46:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

生产服务器未安装 `rg`，附加的访问日志过滤未执行。

### Error

```text
bash: line 1: rg: command not found
```

### Context

- 后端部署和 macOS 换装均已成功。
- 仅在只读确认 App 是否请求生产 API 时使用了服务器不存在的工具。

### Suggested Fix

远端运维命令默认使用系统自带 `grep`，除非预检确认 `rg` 可用。

### Metadata

- Reproducible: yes
- Related Files: /Users/linotsai/Lino/hk_info.md

### Resolution

- **Resolved**: 2026-07-28T18:46:00+08:00
- **Notes**: 改用 `grep -E` 完成日志核对。

---

## [ERR-20260728-004] apply_patch

**Logged**: 2026-07-28T18:43:00+08:00
**Priority**: low
**Status**: resolved
**Area**: docs

### Summary

香港运维记录的整块更新因旧统计表内容与预期不一致而未应用。

### Error

```text
apply_patch verification failed: Failed to find expected lines in /Users/linotsai/Lino/hk_info.md
```

### Context

- 部署成功后同步版本、备份和生产实体统计。
- 旧记录中的实体数量与补丁上下文不一致；工具保证没有部分应用。

### Suggested Fix

先读取对应小节，再分别更新版本、健康响应、统计和备份条目。

### Metadata

- Reproducible: yes
- Related Files: /Users/linotsai/Lino/hk_info.md

### Resolution

- **Resolved**: 2026-07-28T18:43:00+08:00
- **Notes**: 改用精确的小范围补丁同步运维记录。

---

## [ERR-20260728-001] collaboration.spawn_agent

**Logged**: 2026-07-28T15:17:33+08:00
**Priority**: low
**Status**: resolved
**Area**: config

### Summary

Planner 角色不能与完整会话继承同时传入。

### Error

```text
Full-history forked agents inherit the parent agent type; omit agent_type, or spawn without a full-history fork.
```

### Context

- 尝试按项目迁移门禁启动 planner。
- 调用同时使用了 `agent_type: planner` 与 `fork_turns: all`。

### Suggested Fix

需要指定 planner 角色时使用 `fork_turns: none`，并在任务消息中显式提供所需项目路径、范围与约束。

### Metadata

- Reproducible: yes
- Related Files: PROJECT_PLAN.md

### Resolution

- **Resolved**: 2026-07-28T15:17:33+08:00
- **Notes**: 后续调用改用独立上下文，并在任务描述中携带完整边界。

---

## [ERR-20260728-003] apply_patch

**Logged**: 2026-07-28T18:16:00+08:00
**Priority**: low
**Status**: resolved
**Area**: frontend

### Summary

跨文件补丁因一段 Swift 注释上下文不完全匹配而整体未应用。

### Error

```text
apply_patch verification failed: Failed to find expected lines in App/LinoI/LinoStores.swift
```

### Context

- 在同一个补丁中同时重命名对账参数、更新两处调用、修改注释并补测试。
- 目标注释的换行与补丁上下文不一致；工具保证没有部分应用。

### Suggested Fix

先读取窄范围的准确上下文，再将模型、Store、测试和注释拆为小补丁。

### Metadata

- Reproducible: yes
- Related Files: App/LinoI/LinoModels.swift, App/LinoI/LinoStores.swift, App/Tests/ClientStateTests.swift

### Resolution

- **Resolved**: 2026-07-28T18:16:00+08:00
- **Notes**: 确认无部分修改，改用精确的小范围补丁继续。

---

## [ERR-20260801-004] apply_patch

**Logged**: 2026-08-01T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: docs

### Summary

计划补丁引用的精确句子与实际文档不一致，工具未写入任何部分修改。

### Error

```text
apply_patch verification failed: Failed to find expected lines in archive/v1.6.0施工plan.md
```

### Context

- 已建立 v1.6.0 详细施工记录后，尝试在「已确认的产品决定」中补充四个 Agent 的默认人格职责。
- 补丁用到的原句遗漏了「只读不可覆盖协议」，导致上下文不匹配。

### Suggested Fix

先读取目标段的窄范围精确文本，再使用只改一处的小补丁；每次失败确认无部分修改后继续。

### Metadata

- Reproducible: yes
- Related Files: archive/v1.6.0施工plan.md
- See Also: ERR-20260728-003

### Resolution

- **Resolved**: 2026-08-01T00:00:00+08:00
- **Notes**: 已按精确上下文重新定位；业务代码未受影响。

---

## [ERR-20260728-002] pip-install

**Logged**: 2026-07-28T15:21:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: backend

### Summary

重建虚拟环境时，PyPI TLS 连接异常导致构建依赖无法下载。

### Error

```text
SSLError: [SSL: UNEXPECTED_EOF_WHILE_READING]
ERROR: Could not find a version that satisfies the requirement setuptools>=68
```

### Context

- 旧 `.venv` 已先移动到明确的 `/tmp` 备份，因此依赖和环境未丢失。
- 新环境在 editable install 的隔离构建阶段访问 PyPI 失败。

### Suggested Fix

网络恢复后可重新全量创建；当前采用离线恢复旧环境并精确替换虚拟环境文本文件中的旧仓库根路径，随后验证所有入口脚本、迁移和测试。

### Metadata

- Reproducible: unknown
- Related Files: Backend/pyproject.toml

### Resolution

- **Resolved**: 2026-07-28T15:21:00+08:00
- **Notes**: 使用可回滚的旧环境备份完成离线路径重定位，并以入口命令和测试验证。

---

## [ERR-20260801-005] pytest-command-path

**Logged**: 2026-08-01T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: backend

### Summary

在 `Backend/` 工作目录内重复写入 `Backend/.venv`，导致测试解释器路径不存在。

### Error

```text
zsh:1: no such file or directory: Backend/.venv/bin/python
```

### Context

- 阶段 3 Extractor 变更后的定向 pytest 首次执行。

### Suggested Fix

进入 `Backend/` 后统一使用 `.venv/bin/python`；仓库根目录才使用 `Backend/.venv/bin/python`。

### Metadata

- Reproducible: yes
- Related Files: Backend/tests

### Resolution

- **Resolved**: 2026-08-01T00:00:00+08:00
- **Notes**: 已用正确路径运行定向测试，全部通过。

---
## [ERR-20260801-007] UI fixture Python heredoc newline escaping

**Logged**: 2026-08-01T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: testing

### Summary
An inline Python fixture script received a literal newline inside a quoted string because JavaScript template interpolation consumed `\\n`.

### Error
`SyntaxError: unterminated string literal`

### Cause and correction
When JavaScript composes a Python heredoc, escape nested newlines twice or avoid the ambiguity by joining complete Python string literals. The failed run stopped before opening the database, so no partial fixture data was written.
## [ERR-20260801-008] Fixture assumed undeclared ORM relationships

**Logged**: 2026-08-01T00:05:00+08:00
**Priority**: low
**Status**: resolved
**Area**: testing

### Summary
The isolated UI fixture passed `chapter=`/`job=` to models that expose only `chapter_id`/`job_id` columns.

### Error
`TypeError: 'chapter' is an invalid keyword argument for ChapterDraftCandidate`

### Cause and correction
Inspect relationship declarations before composing seed fixtures. Use explicit foreign-key IDs for `JobRun` and `ChapterDraftCandidate`; the failed transaction exited before commit.
## [ERR-20260801-009] Fixture insert order lacked ORM dependency edge

**Logged**: 2026-08-01T00:10:00+08:00
**Priority**: low
**Status**: resolved
**Area**: testing

### Summary
The isolated fixture added a `JobRun` and a candidate referencing it in one flush, but explicit ID-only models gave SQLAlchemy no dependency edge for insert ordering.

### Error
`sqlite3.IntegrityError: FOREIGN KEY constraint failed`

### Cause and correction
Flush the parent `JobRun` before adding `ChapterDraftCandidate` rows that reference its ID. SQLite correctly rolled back the whole failed transaction.
## [ERR-20260801-010] Compact Swift AX helper parsing

**Logged**: 2026-08-01T00:15:00+08:00
**Priority**: low
**Status**: resolved
**Area**: testing

### Summary
A compact inline Swift accessibility helper omitted whitespace around `== .success`, which the parser interpreted as an invalid postfix operator.

### Correction
Keep normal Swift spacing in inline helpers; do not over-compress diagnostic code.
## [ERR-20260801-011] AX scroll action constant unavailable in Swift

**Logged**: 2026-08-01T00:20:00+08:00
**Priority**: low
**Status**: resolved
**Area**: testing

### Summary
The Swift CoreServices overlay did not expose `kAXScrollToVisibleAction`.

### Correction
Use the documented accessibility action string `"AXScrollToVisible"` when the named constant is unavailable.
## [ERR-20260801-012] Remote preflight script expanded by local shell

**Logged**: 2026-08-01T12:20:00+08:00
**Priority**: high
**Status**: resolved
**Area**: infra

### Summary
A production preflight command embedded a multi-line remote script in a locally evaluated command string; command substitutions and SQL metacharacters were expanded by the local zsh before SSH ran.

### Error
`command not found: systemctl`, local `stat`/`df` errors, and no remote execution.

### Context
- The failure occurred before connecting to or mutating the production host.
- The script contained `$()`, SQL parentheses, and nested quotes.

### Suggested Fix
Send multi-line deployment scripts to `ssh ... bash -s` over standard input so the local shell only handles the SSH command and never parses remote script contents.

### Metadata
- Reproducible: yes
- Related Files: `/Users/linotsai/Lino/hk_info.md`

### Resolution
- **Resolved**: 2026-08-01T12:20:00+08:00
- **Notes**: Switched the production workflow to a stdin-fed remote script.
## [ERR-20260801-013] systemd active preceded backend readiness

**Logged**: 2026-08-01T12:25:00+08:00
**Priority**: high
**Status**: resolved
**Area**: infra

### Summary
The production deployment treated `systemctl is-active` as application readiness and issued one immediate health request before Uvicorn had bound port 8787.

### Error
`curl: (7) Failed to connect to 127.0.0.1 port 8787`

### Context
- Alembic migration and database checks had passed.
- The guarded deployment automatically restored the pre-release database/code backup and restarted the old service.

### Suggested Fix
After starting systemd, poll the authenticated health endpoint with a bounded retry loop; service process state alone is not a readiness probe.

### Metadata
- Reproducible: timing-dependent
- Related Files: `/Users/linotsai/Lino/hk_info.md`

### Resolution
- **Resolved**: 2026-08-01T12:25:00+08:00
- **Notes**: Added bounded authenticated health polling before accepting the deployment.
## [ERR-20260801-014] LaunchServices -609 after atomic App replacement

**Logged**: 2026-08-01T12:30:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: infra

### Summary
The first macOS atomic replacement passed staging and signature checks, but `open` returned LaunchServices error `-609` immediately after quitting the old app.

### Error
`_LSOpenURLsWithCompletionHandler() failed with error -609`

### Context
- The guarded installer restored `/Applications/ICTW.app` from its backup.
- The backend deployment was already complete and unaffected.

### Suggested Fix
Wait for the old application and LaunchServices registration to settle, register the replacement explicitly, and launch a new instance with `open -n` before judging readiness.

### Metadata
- Reproducible: timing-dependent
- Related Files: `/Applications/ICTW.app`

### Resolution
- **Resolved**: 2026-08-01T12:30:00+08:00
- **Notes**: Added a short post-quit delay, explicit LaunchServices registration, and new-instance launch.
## [ERR-20260801-015] Production role audit used a nonexistent column

**Logged**: 2026-08-01T13:10:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary
The final read-only production audit queried `agent_personas.role`, but the deployed schema names the column `agent_role`.

### Error
`sqlite3: no such column: role`

### Context
- The failed statement was read-only and ran after service health, Alembic, integrity, foreign-key, and entity-count checks had passed.
- `set -e` stopped the remaining remote audit statements; local App and GitHub checks continued independently.

### Suggested Fix
Inspect `pragma_table_info` before writing ad-hoc production SQL, or reuse a versioned verification query from the repository.

### Metadata
- Reproducible: yes
- Related Files: `/Users/linotsai/Lino/hk_info.md`

### Resolution
- **Resolved**: 2026-08-01T13:10:00+08:00
- **Notes**: Confirmed the live column is `agent_role`, reran the role and remaining service checks, and observed no production error markers.
## [ERR-20260801-016] New cancellation test captured assertions from its neighbor

**Logged**: 2026-08-01T13:35:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary
The first v1.6.2 targeted test run failed because two assertions from the existing cancellation test were left below the newly inserted test function.

### Error
`NameError: name 'started' is not defined`

### Context
- The new cancel-during-Checker behavior itself passed through all of its assertions.
- Only the test file's function boundary was wrong; no application failure was involved.

### Suggested Fix
When inserting a test between existing functions, inspect the complete neighboring function and keep all of its assertions above the next `def`.

### Metadata
- Reproducible: yes
- Related Files: `Backend/tests/test_api.py`

### Resolution
- **Resolved**: 2026-08-01T13:35:00+08:00
- **Notes**: Restored the original assertions to `test_cancelled_job_remains_current_after_chapter_restore` and reran the targeted suites.

## [ERR-20260801-017] Zsh client test script invoked through Bash

**Logged**: 2026-08-01T16:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary
The Swift client-state test launcher uses zsh path expansion and fails when its shebang is bypassed with `bash`.

### Error
`App/Tests/run_client_state_tests.sh: line 4: A: unbound variable`

### Context
- The script declares `#!/bin/zsh` and uses `${0:A:h}`.
- Invoking it as `bash App/Tests/run_client_state_tests.sh` forced the wrong shell; application code was never compiled.

### Suggested Fix
Execute `App/Tests/run_client_state_tests.sh` directly or invoke it explicitly with `zsh`.

### Metadata
- Reproducible: yes
- Related Files: `App/Tests/run_client_state_tests.sh`

### Resolution
- **Resolved**: 2026-08-01T16:00:00+08:00
- **Notes**: Corrected the invocation to use the script's declared zsh runtime.

## [ERR-20260801-018] Multi-file patch included context from the wrong test file

**Logged**: 2026-08-01T16:05:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary
A multi-file patch was rejected because an assertion from the migration test was accidentally placed under the prompt-test file section.

### Error
`apply_patch verification failed: Failed to find expected lines in Backend/tests/test_prompt.py`

### Context
- The rejected patch made no file changes.
- The intended assertion belongs to `Backend/tests/test_v1_schema_and_settings.py`.

### Suggested Fix
Keep each file's hunk under its own update header and split broad multi-file patches when contexts are easy to confuse.

### Metadata
- Reproducible: yes
- Related Files: `Backend/tests/test_prompt.py`, `Backend/tests/test_v1_schema_and_settings.py`

### Resolution
- **Resolved**: 2026-08-01T16:05:00+08:00
- **Notes**: Reapplied the changes with the migration assertion in the correct test file.

## [ERR-20260801-019] SQLite batch drop cascaded chapter child rows

**Logged**: 2026-08-01T16:10:00+08:00
**Priority**: critical
**Status**: resolved
**Area**: backend

### Summary
Alembic batch-table recreation for dropping the legacy chapter summary column caused SQLite foreign-key cascades to delete child rows.

### Error
`test_v1_6_migration_preserves_notes_custom_persona_and_child_rows: expected 1 chapter_character, found 0`

### Context
- The data backfill itself succeeded.
- Rebuilding the parent `chapters` table with foreign keys enabled deleted related `chapter_characters` rows when the old table was dropped.
- The migration test also protects character events and other existing child data.

### Suggested Fix
Use SQLite's native `ALTER TABLE ... DROP COLUMN` for an unconstrained legacy column, and retain explicit pre/post foreign-key checks plus child-row regression tests.

### Metadata
- Reproducible: yes
- Related Files: `Backend/alembic/versions/20260801_0008_merge_chapter_summaries.py`, `Backend/tests/test_v1_schema_and_settings.py`

### Resolution
- **Resolved**: 2026-08-01T16:10:00+08:00
- **Notes**: Replaced batch-table recreation with Alembic's native drop-column operation and reran the migration suite.

## [ERR-20260801-020] Expected inactive systemd state tripped errexit

**Logged**: 2026-08-01T16:05:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: infra

### Summary
The guarded v1.6.3 deployment stopped the backend successfully, but checking the expected inactive state with `systemctl is-active` triggered Bash `errexit` because systemd returns a nonzero status for inactive units.

### Error
`DEPLOY_FAILED status=1 line=43` followed by `ROLLBACK_SERVICE=active`

### Context
- Failure happened before the backup directory was created and before any code or database migration.
- The rollback handler restarted the unchanged v1.6.2 service.
- Follow-up checks confirmed Alembic `20260801_0007`, the legacy summary column, database integrity, foreign keys, and v1.6.2 health were unchanged.

### Suggested Fix
Read expected inactive state through `systemctl show -p ActiveState --value`, whose success status is independent of the unit state, instead of using `systemctl is-active` inside an errexit-sensitive command substitution.

### Metadata
- Reproducible: yes
- Related Files: `/Users/linotsai/Lino/hk_info.md`
- See Also: ERR-20260801-013

### Resolution
- **Resolved**: 2026-08-01T16:05:00+08:00
- **Notes**: Confirmed the server remained on the intact v1.6.2 state and changed the stop assertion to use `ActiveState` before retrying.
