# Errors

新错误按 self-improvement 规范追加在这里；解决并稳定后移入 `archive/learnings/`。

## [ERR-20260813-001] final-audit-template-backtick

**Logged**: 2026-08-13T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

最终只读巡检的 JavaScript 模板字符串包含 shell 正则中的反引号，命令在进入 shell 前解析失败。

### Error

```
SyntaxError: Unexpected token ')'
```

### Context

- 失败发生在执行器解析阶段，没有运行任何巡检子命令，也没有修改文件或外部状态。

### Suggested Fix

传入执行器的多行 shell 不使用反引号字符；复杂文档边界检查拆成普通字符串或独立调用。

### Metadata

- Reproducible: yes
- Related Files: `PROJECT_PLAN.md`

### Resolution

- **Resolved**: 2026-08-13T00:00:00+08:00
- **Notes**: 已移除正则中的反引号并重新执行完整巡检。

## [ERR-20260813-002] openapi-audit-system-python

**Logged**: 2026-08-13T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: docs

### Summary

v2 能力合同的 OpenAPI 覆盖核对误用系统 Python，导入 Backend 时找不到项目依赖。

### Error

```
ModuleNotFoundError: No module named 'fastapi'
```

### Context

- 失败发生在只读复核脚本导入阶段，没有修改 Backend、数据库或三份合同文档。
- Backend 已有专用 `.venv`，且设置加载依赖 Backend 工作目录。

### Suggested Fix

所有 Backend 运行时或 OpenAPI 复核使用 `Backend/.venv/bin/python`，并从 `Backend/` 执行。

### Metadata

- Reproducible: yes
- Related Files: `docs/v2-clean-room/01_BACKEND_CAPABILITY_CONTRACT.md`

### Resolution

- **Resolved**: 2026-08-13T00:00:00+08:00
- **Notes**: 已切换到项目虚拟环境和正确工作目录重新核对。

## [ERR-20260814-001] in-app-browser-local-file-url

**Logged**: 2026-08-14T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: docs

### Summary

用内置浏览器直接打开本地 v2 HTML 原型时，`file://` URL 被浏览器安全策略拒绝。

### Error

```
Browser URL policy blocks local file navigation.
```

### Context

- 目标是只读检查 `design_handoff_ictw_v2_desk/` 中的静态高保真原型。
- 浏览器没有打开页面，也没有修改项目或外部状态。

### Suggested Fix

本地静态原型踏勘优先读取 HTML/CSS 帧定义；若必须做像素级渲染验收，可在原型目录启动只监听 `127.0.0.1` 的临时只读 HTTP 服务，再用内置浏览器访问 loopback URL。

### Metadata

- Reproducible: yes
- Related Files: `design_handoff_ictw_v2_desk/`

### Resolution

- **Resolved**: 2026-08-14T00:00:00+08:00
- **Notes**: 已先用本地源码核对，并在最终验收时通过临时 loopback HTTP 服务完成双端原型渲染检查，随后关闭标签和服务。

## [ERR-20260814-002] destructive-temp-cleanup-rejected

**Logged**: 2026-08-14T13:36:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

临时 SQLite 迁移验收把 `rm -f` 放进退出清理 trap，被执行器的破坏性命令策略在进程启动前拒绝。

### Error

```
rm -f style commands are not permitted. Use a safer approach
```

### Context

- 目标是在 `/tmp` 新建隔离数据库并执行 `alembic upgrade head`。
- 命令在 shell 启动前被拒绝，因此没有创建临时目录、数据库或修改仓库。

### Suggested Fix

验收命令不要把删除操作与迁移操作绑在一起；使用 `mktemp -d` 创建隔离目录并保留路径，完成检查后按环境允许的可恢复方式单独清理，或让系统自然清理 `/tmp`。

### Metadata

- Reproducible: yes
- Related Files: `Backend/alembic/versions/20260814_0012_book_agent_personas.py`
- See Also: ERR-20260814-001

### Resolution

- **Resolved**: 2026-08-14T13:36:00+08:00
- **Notes**: 后续迁移验收改为不含删除动作的隔离临时目录命令。

## [ERR-20260814-003] recursive-temp-cleanup-rejected

**Logged**: 2026-08-14T14:51:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

隔离 UI 验收结束后尝试递归删除明确的 `/tmp` fixture 目录，被执行器的破坏性命令策略在进程启动前拒绝。

### Error

```
rm -f style commands are not permitted. Use a safer approach
```

### Context

- 目标目录是本次创建的 `/tmp/ictw-v2-visual.nLV7aY`，包含隔离 SQLite 数据库。
- Backend 与 Debug App 已先停止；命令在 shell 启动前被拒绝，没有删除或修改任何文件。

### Suggested Fix

临时目录清理使用显式路径移动到用户废纸篓，保留可恢复性；不要向执行器提交 `rm -rf`。

### Metadata

- Reproducible: yes
- Related Files: none
- See Also: ERR-20260814-002

### Resolution

- **Resolved**: 2026-08-14T14:51:00+08:00
- **Notes**: 改用显式源、目标路径移动至废纸篓，并在移动前后核对路径。

## [ERR-20260814-004] cross-file-patch-context-mismatch

**Logged**: 2026-08-14T15:08:00+08:00
**Priority**: low
**Status**: resolved
**Area**: frontend

### Summary

一个补丁块把 iOS 意图页与灵感页的上下文误写成同一文件，导致 `apply_patch` 校验失败。

### Error

```
apply_patch verification failed: Failed to find expected lines
```

### Context

- 同一补丁需要调整 `V2IOSChapterFaces.swift` 的只读展示和 `V2IOSPeripheralViews.swift` 的 undo 门禁。
- 校验失败发生在写入前，没有产生半截修改。

### Suggested Fix

跨文件修改使用各自独立的 `Update File` 上下文，并在提交补丁前核对目标文件名。

### Metadata

- Reproducible: yes
- Related Files: `App/LinoI/V2IOS/V2IOSChapterFaces.swift`, `App/LinoI/V2IOS/V2IOSPeripheralViews.swift`

### Resolution

- **Resolved**: 2026-08-14T15:08:00+08:00
- **Notes**: 已拆分为两个正确的文件上下文并成功应用。

## [ERR-20260814-005] production-job-terminal-phase-mismatch

**Logged**: 2026-08-14T15:25:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: infra

### Summary

部署前只读门禁误用 `succeeded` 作为 JobRun 终态，导致 157 条历史 `done` 记录被误报为在途任务。

### Error

```
active_jobs=157
```

### Context

- 生产实际 phase 分布只有 `done=157`、`failed=142`、`cancelled=11`。
- 当前代码定义的终态是 `done / failed / cancelled`。
- 错误在停服前的只读阶段被识别，没有修改生产数据或服务状态。

### Suggested Fix

所有生产 JobRun 在途统计使用 `phase NOT IN ('done','failed','cancelled')`，并在异常计数时先按 phase 分组核对。

### Metadata

- Reproducible: yes
- Related Files: `Backend/app/services/write_jobs.py`, `Backend/app/models/entities.py`
- See Also: `archive/learnings/ERRORS-20260809-through-20260813.md` 中 `ERR-20260811-030`

### Resolution

- **Resolved**: 2026-08-14T15:25:00+08:00
- **Notes**: 已按当前实体终态重查，确认真实在途 JobRun 为 0。

## [ERR-20260814-006] remote-preflight-stage-cwd

**Logged**: 2026-08-14T15:37:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: infra

### Summary

远端发布包预检通过变量拼接 `runuser sh -c` 时没有让 compileall/Alembic 稳定落到解包根目录。

### Error

```
Can't list 'app'
FAILED: No 'script_location' key found in configuration.
```

### Context

- 包哈希、解包、AppleDouble 与空字节检查已经通过。
- 生产服务尚未停止，代码和数据库均未修改。
- 远端 stage 层级正确，`linoi` 用户也可访问；失败来自嵌套 shell 的 cwd 传递。

### Suggested Fix

远端生产预检使用显式绝对 stage 路径，不在 `runuser sh -c` 中混合外层临时变量。

### Metadata

- Reproducible: yes
- Related Files: `.deploy/ictw-backend-v1.9.3-build40.tar.gz`

### Resolution

- **Resolved**: 2026-08-14T15:37:00+08:00
- **Notes**: 已用显式绝对路径验证 cwd、包结构与服务仍 active，随后重跑门禁。

## [ERR-20260814-007] zero-warning-pipefail-triggered-rollback

**Logged**: 2026-08-14T15:41:00+08:00
**Priority**: high
**Status**: resolved
**Area**: infra

### Summary

生产切换已通过迁移和健康检查，但最后统计零 warning 时 `grep` 的零匹配退出码被 `pipefail` 误判为失败，触发自动回滚。

### Error

```
deployment_failed_rolling_back
rollback_health=1.9.2
```

### Context

- v1.9.3 migration、SQLite integrity/foreign keys、内外网健康均已先通过。
- `journalctl | grep | wc -l` 在没有 warning 时由 `grep` 返回 1；`set -o pipefail` 将正常的零结果升级为 ERR。
- 自动回滚恢复了旧代码与停服前数据库；复核 Alembic `20260809_0011`、无新表、内外网 v1.9.2、单实例和零在途任务。

### Suggested Fix

零匹配属于合法结果的只读统计必须使用不会因空结果失败的实现，例如 Python 计行或给过滤分支显式容错；部署成功后的非关键统计不得触发回滚。

### Metadata

- Reproducible: yes
- Related Files: `/Users/linotsai/Lino/NB_info.md`
- See Also: `archive/learnings/ERRORS-20260809-through-20260813.md` 中 Build 38 ready 误判记录

### Resolution

- **Resolved**: 2026-08-14T15:41:00+08:00
- **Notes**: 已完整验证回滚状态，后续重发移除会把零匹配视为错误的 pipeline。

## [ERR-20260814-008] exec-javascript-reserved-binding

**Logged**: 2026-08-14T15:44:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

并行站外健康与 GitHub Release 查询的编排脚本把结果变量命名为 JavaScript 保留字 `public`，解析阶段失败。

### Error

```
SyntaxError: Unexpected strict mode reserved word
```

### Context

- 失败发生在 V8 脚本解析阶段，任何 curl 或 GitHub 命令都尚未执行。
- 已上线 Backend 与生产状态不受影响。

### Suggested Fix

`functions.exec` 编排变量使用任务限定名，例如 `publicCheck`，避免 `public / private / static` 等严格模式保留字。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-14T15:44:00+08:00
- **Notes**: 已改用非保留变量名重新执行。

## [ERR-20260814-009] macos-pgrep-unavailable

**Logged**: 2026-08-14T15:46:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

本机 macOS 换装前进程检查调用 `pgrep`，当前环境没有该命令。

### Error

```
zsh: command not found: pgrep
```

### Context

- 交付包目标路径只读检查已完成，没有复制或替换 App。
- 当前环境可用 `ps` 与 `rg`。

### Suggested Fix

macOS App 换装进程检查使用 `ps -axo pid,command | rg` 精确匹配 bundle executable 路径。

### Metadata

- Reproducible: yes
- Related Files: `/Applications/ICTW.app`

### Resolution

- **Resolved**: 2026-08-14T15:46:00+08:00
- **Notes**: 已切换到 `ps | rg`。
