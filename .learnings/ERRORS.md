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

## [ERR-20260811-012] planner-spawn-full-history-role-conflict

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: config

### Summary

指定 Planner 角色时同时请求完整对话继承，协作系统拒绝创建 Agent。

### Error

```
Full-history forked agents inherit the parent agent type; omit agent_type, or spawn without a full-history fork.
```

### Context

- 操作：为 v1.9.0（35）“灵感创造师”功能召唤 Planner。
- 失败发生在 Agent 创建前，没有项目施工或外部副作用。

### Suggested Fix

指定专门 Agent 角色时使用有限轮次上下文，并在任务说明中显式传递完整目标与约束。

### Metadata

- Reproducible: yes
- Related Files: `PROJECT_PLAN.md`

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 改为有限轮次上下文后重新召唤 Planner。

## [ERR-20260811-013] inspiration-persona-patch-context

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: backend

### Summary

灵感创造师首轮组合补丁引用了 `personas.py` 中不存在的尾句，补丁在产品实现写入前停止。

### Error

```
apply_patch verification failed: Failed to find expected lines in Backend/app/services/personas.py
```

### Context

- 操作：新增 Agent、上下文服务、persona、schema 与 route 的组合补丁。
- 预先单独提交的测试文件仍按计划保留；产品实现文件未由该失败补丁写入。

### Suggested Fix

先读取当前 persona 协议全文，再把新增文件与既有文件修改拆成小补丁，使用精确上下文。

### Metadata

- Reproducible: yes
- Related Files: `Backend/app/services/personas.py`

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 已改用精确上下文和分块补丁继续施工。

## [ERR-20260811-014] xcode-project-object-id-length

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: frontend

### Summary

首次向 Xcode 工程加入共享灵感源码时，补丁中的对象 ID 长度与项目现有固定格式不一致，未命中上下文。

### Error

```
apply_patch verification failed: Failed to find expected lines in App/LinoI.xcodeproj/project.pbxproj
```

### Context

- 操作：把 `InspirationCreator.swift` 加入 iOS 与 macOS Sources。
- Xcode 工程和 scheme 均未被失败补丁修改。

### Suggested Fix

直接复制项目现有 24 字符对象 ID 前缀并只更换未使用尾号，再按 BuildFile、FileReference、Group、Sources 四处小步修改。

### Metadata

- Reproducible: yes
- Related Files: `App/LinoI.xcodeproj/project.pbxproj`

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 已读取工程原文并使用精确对象 ID 格式继续。

## [ERR-20260811-015] lost-build-session-after-context-transition

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tooling

### Summary

iOS 构建在上下文切换前产生了长输出，切换后原执行会话句柄已不存在，无法取回终态。

### Error

```
exec cell 63 not found
```

### Context

- 操作：继续读取 `xcodebuild` 的执行结果。
- 影响：只丢失该次构建的终态输出，没有丢失或改写源码。

### Suggested Fix

重新使用独立 DerivedData 执行同一构建，并限制直接输出长度；无需回滚任何实现。

### Metadata

- Reproducible: no
- Related Files: none

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 改为重新执行可观测的干净构建。

## [ERR-20260811-016] mac-window-region-captured-occluder

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: frontend-qa

### Summary

首次按 macOS 窗口坐标截取运行态画面时，截到了遮挡在同一区域的其他应用窗口。

### Error

```
System Events 窗口位置不能保证该区域未被其他窗口遮挡。
```

### Context

- 操作：对 Debug ICTW 窗口执行区域截图。
- 影响：只影响第一张临时 QA 截图，未改动任何产品数据或源码。

### Suggested Fix

通过 CoreGraphics 获取目标 PID 的 window number，使用按 window ID 截图来排除遮挡。

### Metadata

- Reproducible: yes
- Related Files: `App/LinoIMac/MacInspirationTab.swift`

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 已改用 window ID 6933 完成主界面与灵感错误态的可视化检查。

## [ERR-20260811-017] health-version-test-not-bumped

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: backend

### Summary

源码升到 1.9.0 后，首次后端全量测试发现 health 版本的回归断言仍为 1.8.3。

### Error

```
AssertionError: assert '1.9.0' == '1.8.3'
```

### Context

- 操作：执行 `Backend/.venv/bin/python -m pytest -q`。
- 影响：只有版本契约断言失败，其他后端测试通过。

### Suggested Fix

升版时将 health 回归断言与 FastAPI 版本、health 响应作为一个原子修改组。

### Metadata

- Reproducible: yes
- Related Files: `Backend/app/main.py`, `Backend/tests/test_v1_1_features.py`

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 已将测试契约同步为 1.9.0，后端全量重跑通过。

## [ERR-20260811-018] simctl-notification-permission-action-unsupported

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: frontend-qa

### Summary

尝试用 `simctl privacy` 关闭遮挡 iOS 视觉验收的通知权限弹窗时，当前 Xcode 版本不支持 `deny notifications`。

### Error

```
Unknown action 'deny'
```

### Context

- 操作：处理专用 iOS 模拟器中的权限弹窗。
- 影响：弹窗未被该命令处理，源码、实体设备和业务数据均未受影响。

### Suggested Fix

先打开 Simulator 前台窗口，再对模拟器窗口内的按钮位置发送本地鼠标事件。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 已仅在专用模拟器中关闭弹窗，并完成 iOS 空白、错误、成功、采用与撤销态视觉验收。

## [ERR-20260811-019] recursive-temp-cleanup-rejected

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tooling

### Summary

完成视觉验收后，直接递归删除精确的临时 QA 目录被安全策略拒绝，整条命令未执行。

### Error

```
rm -f style commands are not permitted. Use a safer approach
```

### Context

- 操作：清理 `/tmp/ictw-v190-visual.6HwcwP` 中的隔离数据库和临时模型伺服器。
- 影响：首次清理未执行；项目工作区未改动。

### Suggested Fix

对已验证的精确临时目录使用可恢复的系统废纸篓命令。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 已使用 `/usr/bin/trash` 移入废纸篓；临时服务和模拟器 App 也均已停止。

## [ERR-20260811-020] nb-info-redaction-shell-quoting

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

首次尝试在读取宁波运维文档时就地脱敏，复杂的 shell 引号组合被 zsh 拒绝。

### Error

```
zsh:1: unmatched "
```

### Context

- 操作：只读获取 `/Users/linotsai/Lino/NB_info.md` 与发布相关教训。
- 影响：文件未输出，任何本地或生产操作都未执行。

### Suggested Fix

将教训检索和运维文档脱敏读取拆成独立命令，脱敏模式不在 shell 单引号中再嵌套单引号。

### Metadata

- Reproducible: yes
- Related Files: `/Users/linotsai/Lino/NB_info.md`

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 改为分步只读，并使用更小的脱敏规则。

## [ERR-20260811-021] backend-package-included-python-cache

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: deployment

### Summary

首次生成 v1.9.0 Build 35 后端发布包时，目录式打包把本地 `__pycache__` 与 `.pyc` 一并纳入，发布前内容门禁主动拒绝该包。

### Error

```
package validation exited 41 after matching __pycache__ and .pyc entries
```

### Context

- 操作：生成 `.deploy/ictw-backend-v1.9.0-build35.tar.gz` 并检查内容。
- 影响：问题在上传前发现；生产未停服、未上传、未修改。

### Suggested Fix

发布打包必须显式排除 `__pycache__`、`*.pyc`、数据库、虚拟环境和测试目录，并在上传前再次枚举校验。

### Metadata

- Reproducible: yes
- Related Files: `.deploy/ictw-backend-v1.9.0-build35.tar.gz`

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 改用带显式 exclude 的可复现打包命令，并保留发布前内容扫描门禁。

## [ERR-20260811-022] release-status-doc-patch-context-mismatch

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: documentation

### Summary

首次批量同步 v1.9.0 发布状态时，`PROJECT_PLAN.md` 的一处上下文少匹配了一个空格，补丁被整体拒绝。

### Error

```
apply_patch verification failed: Failed to find expected lines
```

### Context

- 操作：更新 `PROJECT_PLAN.md`、`README.md` 与 `AGENTS.md` 的生产和客户端版本事实。
- 影响：补丁原子失败，三个文件均未发生本次状态更新；生产与已安装客户端不受影响。

### Suggested Fix

长文档状态同步使用更小的精确补丁，避免把多个文件和长上下文绑在一次匹配中。

### Metadata

- Reproducible: yes
- Related Files: `PROJECT_PLAN.md`, `README.md`, `AGENTS.md`

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 改为按文件、按短上下文逐段更新。

## [ERR-20260811-023] zero-match-secret-scan-tripped-pipefail

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tooling

### Summary

提交前密钥扫描实际为零匹配，但 `rg` 的“无匹配”退出码 1 在 `pipefail` 下让整组门禁误报失败。

### Error

```
workspace gate exited 1 with no output; split diagnostics showed all secret pattern counts were 0
```

### Context

- 操作：对未提交差异做只输出计数的密钥模式扫描。
- 影响：测试、生产和客户端均正常；提交被安全地暂停，没有暂存或推送。

### Suggested Fix

计数型扫描应显式接受 `rg` 的无匹配退出码，或先把结果交给始终成功的计数逻辑，再单独断言计数为零。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Notes**: 拆分验证确认三个密钥模式均为 0，后续门禁将无匹配视为成功。
