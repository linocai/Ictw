# Errors

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
