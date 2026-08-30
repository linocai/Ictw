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
- **Recurrence**: 2026-08-30 收尾时对仓库内测试生成的 `.build/` 提交精确 `rm -rf` 仍被同一策略拒绝；目录保留，不影响交付。后续不再把非必要生成物清理纳入最终门禁命令。

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

## [ERR-20260814-010] gh-release-is-latest-field-unsupported

**Logged**: 2026-08-14T15:50:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tooling

### Summary

当前 `gh release view` 版本不支持 JSON 字段 `isLatest`，导致首次 Release 元数据复核退出 1。

### Error

```
Unknown JSON field: "isLatest"
```

### Context

- Release 与附件已经成功创建，失败只发生在随后的只读元数据查询。
- 当前 `gh` 支持 `tagName`、`assets`、`publishedAt` 等字段，但不暴露 `isLatest`。

### Suggested Fix

用 `gh api repos/{owner}/{repo}/releases/latest` 判断 latest，并继续用 `gh release view` 核对附件元数据。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-14T15:51:00+08:00
- **Notes**: 已通过 Releases API 确认 `v2.0.0` 是 latest，附件大小与 SHA-256 digest 均和本地交付包一致。

## [ERR-20260814-011] ssh-short-alias-resolved-to-fake-ip

**Logged**: 2026-08-14T15:52:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: infra

### Summary

最终只读复核使用未配置的短主机名 `nb`，本机代理 DNS 将它解析到 `198.18.18.54`，SSH 在 banner 阶段超时。

### Error

```
Connection timed out during banner exchange
Connection to 198.18.18.54 port 22 timed out
```

### Context

- 超时连接仅执行只读复核，未触达生产主机，也未改变已部署服务。
- 遗留探测进程已中止；生产公网 health 在此期间一直可用。

### Suggested Fix

在 SSH config 未明确配置别名之前，生产运维使用 `NB_info.md` 记录的精确主机地址并设置 `BatchMode` 与 `ConnectTimeout`。

### Metadata

- Reproducible: yes
- Related Files: `/Users/linotsai/Lino/NB_info.md`

### Resolution

- **Resolved**: 2026-08-14T15:53:00+08:00
- **Notes**: 改用精确主机地址后，Alembic、SQLite、systemd、监听 PID 及内外网鉴权健康复核全部通过。

## [ERR-20260814-012] swift-pure-library-linked-without-main

**Logged**: 2026-08-14T16:50:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

验证 v2.0.1 共享纯 Swift 文件时误用 `swiftc -o` 进入链接阶段，因没有 `main` 而退出。

### Error

```
link command failed: undefined symbol: main
```

### Context

- 共享文件是供 App 与测试 runner 编译的库代码，本身不应生成可执行文件。
- 失败只发生在额外的本地验证命令，正式客户端状态测试随后通过。

### Suggested Fix

纯库文件的独立验证使用 `swiftc -typecheck`；只有包含入口点时才使用 `-o` 链接可执行文件。

### Metadata

- Reproducible: yes
- Related Files: `App/LinoI/V2Shared/V2DeskPresentation.swift`

### Resolution

- **Resolved**: 2026-08-14T16:50:00+08:00
- **Notes**: 已改用类型检查与现有客户端状态测试 runner 验证共享切片。

## [ERR-20260814-013] ios-codesign-entitlements-file-format

**Logged**: 2026-08-14T17:23:00+08:00
**Priority**: low
**Status**: resolved
**Area**: config

### Summary

iOS Release 验签时把 `codesign -d --entitlements <file>` 的文本输出交给 PlistBuddy，因该格式不是可解析 plist 而失败。

### Error

```
Unexpected character [ at line 1
Error Reading File
```

### Context

- App 的代码签名、Designated Requirement 与版本检查均已先行通过。
- 失败仅发生在额外的 entitlement 内容复核，不影响签名产物。

### Suggested Fix

读取已签名 App 的 entitlement 时使用 `codesign -d --entitlements :- <app>`，该形式输出标准 XML plist，再交给 plist 工具或做精确字段检查。

### Metadata

- Reproducible: yes
- Related Files: `App/LinoI.xcodeproj/project.pbxproj`

### Resolution

- **Resolved**: 2026-08-14T17:23:00+08:00
- **Notes**: 已改用标准输出形式确认 iOS 为 Apple Development 签名，包含预期的 `get-task-allow=true`；macOS Developer ID 产物仍明确不含该权限。

## [ERR-20260814-014] apply-patch-wrong-source-path

**Logged**: 2026-08-14T18:30:00+08:00
**Priority**: low
**Status**: resolved
**Area**: frontend

### Summary
一次存储层补丁误用了省略 `LinoI` 的源文件路径，工具在写入前拒绝操作。

### Error

```
Failed to read file to update /Users/linotsai/Lino/Ictw/App/LinoStores.swift
```

### Context

- 项目客户端源文件实际位于 `App/LinoI/`。
- 操作未修改工作区内容。

### Suggested Fix

在补丁前复用已检索到的精确路径。

### Metadata

- Reproducible: yes
- Related Files: `App/LinoI/LinoStores.swift`

### Resolution

- **Resolved**: 2026-08-14T18:30:00+08:00
- **Notes**: 后续补丁使用完整正确路径。

## [ERR-20260814-015] apply-patch-stale-context

**Logged**: 2026-08-14T18:45:00+08:00
**Priority**: low
**Status**: resolved
**Area**: frontend

### Summary
一次 UI 头部补丁遗漏了中间的布局行，精确上下文校验拒绝写入。

### Error

```
apply_patch verification failed: Failed to find expected lines
```

### Context

- 目标文件没有被该次失败操作改变。

### Suggested Fix

补丁前先读取目标的当前完整块，并按实际上下文构造最小替换。

### Metadata

- Reproducible: yes
- Related Files: `App/LinoI/V2IOS/V2IOSPeripheralViews.swift`

### Resolution

- **Resolved**: 2026-08-14T18:45:00+08:00
- **Notes**: 已按当前块重新构造补丁。

## [ERR-20260814-016] inspiration-gate-generic-activate-collision

**Logged**: 2026-08-14T18:53:45+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

人物 Sheet 离开协调器使用通用方法名 `activate`，撞上“灵感界面不得打开即生成”的源码门禁，导致客户端状态测试误报。

### Error

```
Inspiration UI must not generate on open
```

### Context

- 门禁有意全局禁止历史灵感入口 `func activate(`，以防恢复打开即请求模型的旧行为。
- 新方法只注册未保存编辑的离开回调，不涉及灵感或网络生成。

### Suggested Fix

非灵感组件避免使用已被产品门禁保留的通用 `activate` 方法名；优先使用能说明职责的 `register`。

### Metadata

- Reproducible: yes
- Related Files: `App/LinoI/V2IOS/V2IOSPeripheralViews.swift`, `App/Tests/run_client_state_tests.sh`

### Resolution

- **Resolved**: 2026-08-14T18:53:45+08:00
- **Notes**: 将离开协调器方法改名为 `register`，不放宽灵感产品门禁。

## [ERR-20260830-001] pytest-node-selection

**Logged**: 2026-08-30T00:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

Used a nonexistent pytest node name while attempting a targeted health check.

### Error

`ERROR: not found: ...test_v1_1_features.py::test_health`

### Suggested Fix

Use `pytest --collect-only` or run the containing test module when the exact test name has not been verified.

### Resolution

- **Resolved**: 2026-08-30T00:00:00+08:00
- **Notes**: 已改为运行已核对的测试文件；后续清理命令末尾误拼解释器路径也以同一原则用干净命令重跑确认。

## [ERR-20260830-002] alembic-wrong-working-directory

**Logged**: 2026-08-30T17:16:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

在仓库根目录执行 Alembic head 检查，未读到 `Backend/alembic.ini`。

### Error

```
FAILED: No 'script_location' key found in configuration.
```

### Context

- 执行了 `Backend/.venv/bin/python -m alembic heads`，但当前目录是仓库根目录。
- 代码和迁移文件未受影响。

### Suggested Fix

遵循项目验证命令，先进入 `Backend/` 再运行 Alembic，或显式指定其配置文件。

### Metadata

- Reproducible: yes
- Related Files: `Backend/alembic.ini`

### Resolution

- **Resolved**: 2026-08-30T17:16:00+08:00
- **Notes**: 按项目规定的 `cd Backend && .venv/bin/python -m alembic heads` 重跑。

## [ERR-20260830-003] simctl-launch-option-name

**Logged**: 2026-08-30T19:22:13+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

使用了不存在的 `simctl launch --terminate-running` 缩写选项。

### Error

```
Invalid device: --terminate-running
```

### Context

- 目标是为已安装的 Debug App 传入临时环境并重启。
- 新版 `simctl` 支持的完整选项名为 `--terminate-running-process`。

### Suggested Fix

对不确定的 `simctl` 选项先运行 `xcrun simctl help <subcommand>` 核对。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T19:22:13+08:00
- **Notes**: 改用文档明确支持的 `--terminate-running-process`。

## [ERR-20260830-004] node-repl-block-scoped-image-helpers

**Logged**: 2026-08-30T19:48:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

在后续 Computer Use 调用中复用了只在前一次条件块内建立的图片读取变量，导致变量不可见。

### Error

```
fs is not defined
```

### Context

- 目标是读取 Simulator 的最新截图。
- `node_repl` 会保留顶层绑定，但不应假定条件块内的临时绑定在后续调用可用。

### Suggested Fix

将 `node:fs/promises` 与 `node:url` 的导入明确写入每次需要截图的调用，或在无条件顶层建立稳定的全局绑定。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T19:48:00+08:00
- **Notes**: 后续截图调用会在同一段代码内重新导入所需模块，不再依赖条件块中的旧变量。

## [ERR-20260830-005] simulator-drag-started-on-bezel

**Logged**: 2026-08-30T19:52:00+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

模拟 iOS 边缘返回手势时从设备黑色边框起手，Computer Use 将该点判定为窗口外。

### Error

```
Computer Use server error -10005: windowNotFoundAtPosition
```

### Context

- Simulator 截图包含窗口工具栏、设备边框和实际屏幕内容。
- 手势起点落在黑色设备边框，而不是 App 的左侧内容边缘。

### Suggested Fix

坐标手势应先按最新截图确认实际屏幕边界，从屏幕内容区左缘内侧约 10–20 点起手。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T19:52:00+08:00
- **Notes**: 后续改用屏幕内容区内侧坐标执行边缘返回手势。

## [ERR-20260830-006] computer-use-native-pipe-closed-on-drag

**Logged**: 2026-08-30T20:04:01+08:00
**Priority**: low
**Status**: pending
**Area**: tests

### Summary

在 Simulator 中执行 iOS 边缘返回拖动时，Computer Use 原生通信通道在返回结果前关闭。

### Error

```
Sky Computer Use native pipe closed before response
```

### Context

- 目标是从 App 内容区左缘向右拖动，验证系统原生边缘返回手势。
- 拖动坐标位于模拟器屏幕内容区内，调用前 Simulator 页面可正常读取。
- 需要重新连接 Computer Use 后读取实际页面，区分手势是否已执行与控制通道故障。

### Suggested Fix

重新建立 Computer Use 会话并先读取 Simulator 状态；若通道持续中断，改用无副作用的系统返回按钮完成其余视觉复审，并将边缘手势标为未能自动化确认。

### Metadata

- Reproducible: unknown
- Related Files: none
- See Also: ERR-20260830-005

---

## [ERR-20260830-013] gh-release-view-islatest-field

**Logged**: 2026-08-30T21:10:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

GitHub Release 创建成功后，元数据复核请求了当前 `gh` 版本不支持的 `isLatest` JSON 字段。

### Error

```
Unknown JSON field: "isLatest"
```

### Context

- `v2.1.0` Release 与 macOS 附件已经成功创建。
- 失败仅发生在随后读取展示字段时。

### Suggested Fix

只请求 `gh release view` 明确列出的兼容字段，并通过重新下载附件完成独立哈希与签名复核。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T21:10:00+08:00
- **Notes**: 改用 `url`、`name`、`tagName`、`isDraft`、`isPrerelease`、`assets` 等可用字段。

---

## [ERR-20260830-012] remote-sha-awk-quoting

**Logged**: 2026-08-30T21:06:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

后端包上传后的远端 SHA-256 提取命令在双层 Shell 中错误转义了 `awk`，导致哈希比较没有执行。

### Error

```
awk: cmd. line:1: {print \\}
```

### Context

- SCP 已完成，但生产服务尚未停止、部署尚未开始。
- 问题只发生在本地解析远端输出。

### Suggested Fix

远端只运行 `sha256sum` 返回完整行，本地再用 Shell 参数展开提取首字段，避免嵌套 `awk` 引号。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T21:06:00+08:00
- **Notes**: 改用完整哈希行进行本地比较。

---

## [ERR-20260830-011] nb-shortname-stale-resolution

**Logged**: 2026-08-30T21:02:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: infra

### Summary

宁波发布预检使用 `nb` 短名时被本机网络解析到代理保留地址，SSH banner 握手超时。

### Error

```
Connection timed out during banner exchange
Connection to 198.18.18.54 port 22 timed out
```

### Context

- 现行运维记录已注明公网 IP 于 2026-08-30 更换。
- 直接读取记录中的新 IP，并先用 ED25519 指纹比对权威记录，结果完全一致。

### Suggested Fix

宁波连接在短名不可用时，使用现行文档 IP；连接前必须以 `ssh-keyscan` 的 ED25519 SHA-256 指纹对照 `NB_info.md`，再启用严格主机校验。

### Metadata

- Reproducible: yes
- Related Files: /Users/linotsai/Lino/NB_info.md

### Resolution

- **Resolved**: 2026-08-30T21:02:00+08:00
- **Notes**: 新 IP 指纹匹配，`deploy` 公钥登录与无交互 sudo 均已恢复。

---

## [ERR-20260830-010] backend-package-nul-check

**Logged**: 2026-08-30T21:00:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

后端部署包文件名空字节门禁用 Shell 的空字节参数调用 `grep`，参数被折叠为空模式并恒定误报。

### Error

```
listing_nul=FOUND
```

### Context

- 禁止文件和 `LIBARCHIVE.xattr` 检查均已通过。
- POSIX 参数不能承载 NUL，故该检查方式无效。

### Suggested Fix

使用 Python 读取 tar 成员名及文本列表的原始字节，直接断言不存在 `\\x00`。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T21:00:00+08:00
- **Notes**: 发布门禁改为 Python 字节级检查。

---

## [ERR-20260830-009] release-signature-check-temp-cleanup

**Logged**: 2026-08-30T20:57:00+08:00
**Priority**: low
**Status**: resolved
**Area**: infra

### Summary

发布签名校验脚本因包含 `rm -f` 临时文件清理，被执行安全策略整段拒绝。

### Error

```
rejected: rm -f style commands are not permitted. Use a safer approach
```

### Context

- 校验对象为已完成签名归档的 macOS 与 iOS App。
- 被拒绝发生在脚本启动前，制品没有被修改。

### Suggested Fix

只读发布校验使用固定在 release 目录内的临时输出，并保留到发布结束；不在同一命令中加入删除动作。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T20:57:00+08:00
- **Notes**: 改为保留 entitlement 检查文件的只读校验流程。

---

## [ERR-20260830-015] computer-use-swiftui-post-sheet-ax-failure

**Logged**: 2026-08-30T20:46:25+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

关闭 SwiftUI sheet 后在同一次 Computer Use 调用里立即点击主窗口按钮，偶发 AXError.failure。

### Error

```
Accessibility error: AXError.failure
```

### Context

- 先关闭“找方向”弹层，再读取主窗口并立即尝试打开“意图与证据”。
- App 本身未崩溃，属于 sheet 层级切换后的辅助功能瞬时失败。

### Suggested Fix

关闭 macOS SwiftUI sheet 后把“重新读取主窗口状态”和“下一次点击”拆成两个调用，避免在层级切换期间连续操作。

### Metadata

- Reproducible: intermittent
- Related Files: none
- See Also: ERR-20260830-007

### Resolution

- **Resolved**: 2026-08-30T20:46:25+08:00
- **Notes**: 重新读取主窗口后分步继续。

---

## [ERR-20260830-014] computer-use-app-path-change-guard

**Logged**: 2026-08-30T20:45:05+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

macOS 候选包进入全屏后，Computer Use 的 App 路径变更保护要求在下一次动作前重新读取状态。

### Error

```
The user changed '.../ICTW.app'. Re-query the latest state with get_app_state before sending more actions.
```

### Context

- 候选包没有被重新构建或替换。
- 进入全屏后尝试立即发送 Escape；工具将窗口/应用状态变化视为需要重新确认。

### Suggested Fix

macOS 全屏、窗口层级或应用状态发生变化后，先重新调用 `get_app_state`，再发送退出全屏等后续动作。

### Metadata

- Reproducible: unknown
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T20:45:05+08:00
- **Notes**: 重新读取全屏状态后继续。

---

## [ERR-20260830-013] computer-use-paste-without-element

**Logged**: 2026-08-30T20:43:45+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

在 macOS SwiftUI 搜索弹层中，仅依赖当前焦点调用 Computer Use `paste` 返回参数错误。

### Error

```
Invalid params
```

### Context

- 搜索框在 AX 状态中显示为已聚焦。
- 调用只提供 App 和文本，没有显式目标元素。

### Suggested Fix

SwiftUI 表单自动化应优先对最新 AX 树中的文本框使用 `set_value` 和明确的 `element_index`，不依赖隐式焦点粘贴。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T20:43:45+08:00
- **Notes**: 改用带元素索引的 set_value 继续验证。

---

## [ERR-20260830-012] computer-use-scrollbar-set-value

**Logged**: 2026-08-30T20:41:25+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

Computer Use 的通用 `set_value` 不能直接用数值设置 macOS AXScrollBar。

### Error

```
Invalid params
```

### Context

- 设置模型页的滚轮动作未产生位移，尝试把可设置滚动条的值直接改为 `1`。
- 该接口适合表单值，不接受这类滚动条数值参数。

### Suggested Fix

滚动区无响应时改用指针位于内容区的坐标滚动或拖动滚动条，不用 `set_value` 操作 AXScrollBar。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T20:41:25+08:00
- **Notes**: 不再使用 set_value 控制滚动条。

---

## [ERR-20260830-011] computer-use-macos-end-key

**Logged**: 2026-08-30T20:40:20+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

Computer Use 的 macOS 键盘接口不接受 `END` 作为页面滚动按键名。

### Error

```
Computer Use server error -10005: keyNotFound("END")
```

### Context

- 目标是查看设置页可滚动内容的底部。
- 页面本身和 App 状态均正常。

### Suggested Fix

长页面视觉审核直接使用 `scroll` 动作，不依赖平台相关的 End 键名。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T20:40:20+08:00
- **Notes**: 改用滚轮滚动继续审核。

---

## [ERR-20260830-010] computer-use-screenshot-direct-emit

**Logged**: 2026-08-30T20:37:10+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

Computer Use 返回的 app-state screenshot 不能在当前会话中直接交给 `emitImage`。

### Error

```
nodeRepl.emitImage received an unsupported value
```

### Context

- 通过候选 `.app` 绝对路径已成功定位窗口。
- 读取状态后直接传递 `state.screenshot` 触发类型错误。

### Suggested Fix

先检查状态对象的 screenshot 字段类型；需要展示时使用工具返回的可支持图像对象，或把截图保存为 PNG 后再读取。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T20:37:10+08:00
- **Notes**: 后续先读取语义状态，截图改走落盘后显示的稳定路径。

---

## [ERR-20260830-009] macos-computer-use-ambiguous-bundle-id

**Logged**: 2026-08-30T20:36:30+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

macOS 视觉审核时，同一 Bundle ID 存在已安装包和多个 DerivedData 构建，Computer Use 无法仅凭 Bundle ID 选择目标 App。

### Error

```
Ambiguous app identifier 'com.lino.linoi.mac'. Multiple apps share this bundle identifier.
```

### Context

- 审核目标是本次 `.build/DerivedData-macOS-visual` 内的当前源码候选包。
- 机器上同时保留 `/Applications/ICTW.app` 和多个历史 Debug 构建。

### Suggested Fix

对 macOS 候选构建做视觉审核时，启动并传给 Computer Use 的都应是该候选 `.app` 的绝对路径，避免误审旧安装包。

### Metadata

- Reproducible: yes
- Related Files: none

### Resolution

- **Resolved**: 2026-08-30T20:36:30+08:00
- **Notes**: 改用本次构建产物的绝对路径继续审核。

---

## [ERR-20260830-007] simulator-window-transient-control-errors

**Logged**: 2026-08-30T20:12:11+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

双 Simulator 窗口切换和设备自动关停期间，Computer Use 的坐标动作与连续页面操作出现瞬时窗口不可用或超时。

### Error

```
Computer Use server error -10005: noWindowsAvailable
Computer Use server error -10005: timeoutReached
Computer Use server error -10005: keyNotFound("[")
```

### Context

- 视觉复审先后操作 iPhone 17 Pro 与 iPhone 13 两个现有模拟器窗口。
- 坐标返回动作偶发找不到窗口；连续关闭弹层并打开下一页时偶发超时。
- xdotool 风格按键名不接受 `super+[`，但接受 `super+bracketleft`。

### Suggested Fix

每次窗口切换后重新读取完整 Simulator 状态；返回快捷键使用 `super+bracketleft`；设备关停时用现有 UDID 重新启动并分步操作，避免把多个页面跳转塞进一次调用。

### Metadata

- Reproducible: intermittent
- Related Files: none
- See Also: ERR-20260830-005, ERR-20260830-006

### Resolution

- **Resolved**: 2026-08-30T20:12:11+08:00
- **Notes**: 重新启动现有 iPhone 13、按步骤重新读取状态，并用正确快捷键完成剩余复审。

---

## [ERR-20260830-008] nested-swift-source-guard-regex

**Logged**: 2026-08-30T20:19:59+08:00
**Priority**: low
**Status**: resolved
**Area**: tests

### Summary

为 SwiftUI 视图新增的多行源码门禁试图用正则识别完整嵌套 `List`，被内部闭合大括号提前截断并产生误报。

### Error

```
Book-settings notices must stay below the navigation bar
```

### Context

- App 代码已将 `.v2IOSNoticeOverlay()` 放到书设置列表内部并紧邻 `.navigationTitle("书设置")`。
- 初版 Perl 模式使用 `List {.*?}` 推断 Swift 嵌套结构；非贪婪匹配在首个 Section 内部大括号处结束。

### Suggested Fix

源码门禁只断言与缺陷直接相关且稳定的相邻标记，不用正则解析 Swift 语法树。

### Metadata

- Reproducible: yes
- Related Files: App/Tests/run_client_state_tests.sh

### Resolution

- **Resolved**: 2026-08-30T20:19:59+08:00
- **Notes**: 改为断言通知修饰器紧邻唯一的书设置导航标题。

---
