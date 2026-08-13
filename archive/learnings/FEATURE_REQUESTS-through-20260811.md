# Feature Requests — through 2026-08-11

## [FEAT-20260811-001] inspiration-creator-agent

**Logged**: 2026-08-11T00:00:00+08:00
**Priority**: high
**Status**: resolved
**Area**: full-stack

### Requested Capability

新增完全独立的“灵感创造师” Agent，在用户编写章节 Bible 灵感枯竭时，结合有效历史与当前编辑上下文，每轮给出 3–5 张可选择的灵感卡片。

### User Context

功能不能进入或干扰既有写作 SOP；灵感卡结构需保持宽松，每张不超过 300 字，并把前端的触发、比较、采纳、重抽与未保存草稿保护做好。

### Complexity Estimate

complex

### Suggested Implementation

作为手动触发、只读上下文、无业务持久化的独立 Agent；为 iOS/macOS Bible 编辑器设计专用灵感浏览体验，用户采纳后只写入本地草稿并保留撤销能力。

### Resolution

- **Resolved**: 2026-08-11T00:00:00+08:00
- **Version**: `v1.9.0(35)`
- **Notes**: 已实现独立 `inspiration_creator` 绑定、有效历史只读上下文、3–5 条／每条不超过 300 个去空白字符的程序复检、iOS sheet 与 macOS 右侧灵感页签；采用只追加到本地 Bible，可一次撤销，不进入既有 SOP。

### Metadata

- Frequency: first_time
- Related Features: persona bindings, chapter Bible editor, history context

---
