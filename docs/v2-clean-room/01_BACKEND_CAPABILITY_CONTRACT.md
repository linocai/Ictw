# ICTW v2 后端能力合同

> 面向 clean-room 前端设计。事实基线：Backend `v1.9.3`，API 前缀 `/api/v1`。

## 1. 使用方式

本文只描述现有后端能够提供什么、数据如何变化、哪些状态必须被前端正确表达。它不规定页面、导航、布局、控件或视觉形式。

设计 Agent 可以读取本文、同目录的产品行为合同和 v2 设计简报。不要读取现有 `App/` 源码、旧界面截图或历史视觉稿来补全本文没有规定的内容。本文没有承诺的能力，应标记为需要产品或后端确认，不得自行假设存在。

## 2. 通用协议

- 所有业务接口均位于 `/api/v1`。
- 所有接口都要求 `Authorization: Bearer <token>`；缺失或错误时返回 `401`。
- 常规读写使用 JSON；两个后端导出接口返回 UTF-8 纯文本。共享客户端还可用已读取并保存的 Book／Chapter／Character 数据组合更多导出格式，但那不是额外的 Backend 导出协议。
- ID 是不透明字符串。客户端不得从 ID 推断顺序、类型或时间。
- 时间字段是服务端时间戳。章节顺序以 `index` 为准，不以创建时间为准。
- 当前接口没有分页、搜索、批量删除、乐观锁版本号或多用户协作协议。
- `204` 删除接口具有幂等语义：目标已经不存在时仍可返回成功。
- FastAPI 参数校验通常返回 `422` 且 `detail` 为数组；领域错误可能是简单字符串，也可能是结构化对象：

```json
{
  "detail": {
    "code": "stable_machine_code",
    "message": "面向用户的说明",
    "details": {}
  }
}
```

- LLM 未配置或配置不兼容通常返回 `409`；模型或上游失败通常返回 `502`。前端必须以 HTTP 状态与机器码判断，不解析自然语言字符串。
- API Key 只在创建或更新模型配置时作为输入；读取配置时永不返回密钥。

## 3. 领域关系

```text
Book
├── Chapters（按 index 排序）
│   ├── 本章允许人物集合
│   ├── 当前可见正文
│   ├── 最新任务状态
│   └── 归档状态与可见记忆
└── Characters
    ├── 固定人物资料
    ├── Extractor 维护的动态状态
    └── 按章节组织的人物事件

每本书可选地保存五个 Agent 的 persona 覆盖；没有覆盖时继承全局设置。

Global Settings
├── Agent Personas
├── LLM Profiles
└── Agent → Profile Bindings
```

- 删除书会级联删除其章节、人物和相关历史。
- 删除章节会取消该章当前任务、收拢后续章节编号，并使依赖它的后续记忆重新失效。
- 删除人物会移除其章节关联，并使受影响的 Writer 输入与归档失效。
- 章节选中的人物集合是该章允许出现的已知人物上限；历史事实不会自动扩大它。

## 4. 核心数据合同

### 4.1 Book

| 字段 | 类型 | 含义 |
|---|---|---|
| `id` | string | 书 ID |
| `title` | string | 书名 |
| `world_setting` | string | 全书世界观与稳定背景 |
| `chapter_count` | integer | 当前章节数 |
| `character_count` | integer | 当前人物数 |
| `archive_pending_count` | integer | `pending` 或 `extracting` 的归档数 |
| `archive_attention_count` | integer | 有实际归档 revision 且当前为 `stale`、`partial` 或 `failed` 的归档数；从未归档的新草稿不计入 |
| `created_at` / `updated_at` | datetime | 创建与更新时间 |
| `last_opened_at` | datetime? | 最近读取书详情的时间 |

读取单本书会更新 `last_opened_at`。修改 `world_setting` 会使相关在途或旧 Writer 结果失效。

### 4.2 Character

| 字段 | 类型 | 所有权 |
|---|---|---|
| `id`, `book_id` | string | 服务端 |
| `name` | string | 用户可编辑 |
| `role` | string | 用户可编辑 |
| `fixed_profile` | string | 用户可编辑的固定人物卡 |
| `dynamic_fields` | object | Extractor 生成的当前状态投影；客户端只读 |
| `dynamic_fields_updated_chapter_index` | integer? | 最近影响动态状态的章节 |
| `events` | array | 人物故事线 |

人物事件字段：`id`、`chapter_id`、`chapter_index`、`event_type`、`event_text`、`source`、`editable` 及时间戳。

- `source="legacy"` 且 `editable=true` 的旧事件可修改或删除。
- `source="archive_v2"` 且 `editable=false` 的事实来自有效归档，只能通过章节归档生命周期改变，不能直接编辑。
- 创建和更新人物时即使旧客户端发送 `dynamic_fields`，后端也不会把它作为客户端拥有的数据写入。

### 4.3 ChapterSummary

章节列表返回：`id`、`book_id`、`index`、`title`、`status`、`source`、`updated_at`，以及无需逐章详情请求即可读取的 `archive_status`、`archive_schema`、`archive_can_retry`、`archive_latest_attempt_status`。

### 4.4 ChapterRead

| 字段 | 含义 |
|---|---|
| `id`, `book_id`, `index` | 身份与书内顺序 |
| `title` | 本章标题，可为空 |
| `user_prompt` | 本章剧情 Bible，可为空 |
| `target_word_count` | 存储的目标字数提示，必须为正数 |
| `author_note` | 作者附注 |
| `draft_text` | 当前对用户可见的正文 |
| `character_links` | 本章允许人物集合 |
| `status` | 章节生命周期状态 |
| `source` | `agent` 或 `imported` |
| `archive` | 当前归档读取模型 |
| `headline`, `long_summary` | 兼容期的章节记忆字段，可由用户修改 |
| `state_changes`, `unresolved_items`, `atomic_memories` | 兼容期记忆字段 |
| `exempted_character_names` | 章级人物名称校验豁免 |

兼容字段：`chapter_style` 是 `author_note` 的旧镜像；`summary` 是 `long_summary` 的旧镜像。新前端应使用规范字段，但解码时必须容忍镜像字段仍存在。

### 4.5 ChapterArchiveRead

| 字段 | 含义 |
|---|---|
| `status` | `stale`、`pending`、`extracting`、`complete`、`partial` 或 `failed` |
| `schema` | `v2`、`legacy` 或 `none` |
| `revision_id`, `revision` | 当前有效 v2 revision；没有时为空 |
| `summary` | 可进入后续记忆链的章节摘要 |
| `facts` | 有效规范事实，含类型、重要度、文字、参与人物与来源 span ID |
| `state_delta_count` | 本次有效状态变化数量 |
| `error_code`, `error_message` | 最近归档失败的安全说明 |
| `can_retry` | 当前是否允许用户重试归档 |
| `latest_attempt_status` | 最近一次尝试的状态 |
| `inactive_preview` | 可选、只供展示的失效 revision 摘要、事实数和状态变化数；不属于当前记忆 |

只有完整、激活的 v2 revision 才会作为 v2 记忆；`partial`、`failed`、`stale` 和 `inactive_preview` 都不会进入后续写作记忆或人物投影。旧数据可能以 `schema="legacy"` 暂时提供完整状态。

### 4.6 WriteJobStatus

| 字段 | 含义 |
|---|---|
| `chapter_id`, `job_id` | 任务归属和身份 |
| `kind` | `write` 或 `extract` |
| `phase` | 当前阶段 |
| `outcome_current` | 终态是否仍适用于当前章节内容；非终态可能为空 |
| `attempt` | Writer 或归档尝试次数 |
| `error_code`, `error_message`, `error_context` | 安全错误信息 |
| `violations` | 确定性校验问题 |
| `memory_context` | Writer 实际使用的记忆简报与来源清单 |
| `checker_result` | 该任务的 Checker 结果 |
| `visible_checker_result` | 与当前可见正文严格匹配的 Checker 结果 |
| `chapter` | 任务成功完成时的最新章节 |
| `updated_character_ids`, `added_event_ids` | Extractor 成功后的变更标识 |

任务阶段全集：

```text
idle
selecting_memory → writing → checking → done | failed | cancelled
extracting → done | failed | cancelled
```

终态不等于仍然有效。`outcome_current=false` 表示用户编辑、重开或另一任务已经使旧结果失效；前端不得把它重新应用到当前章节。

### 4.7 Checker 结果

- 有效 verdict：`passed`、`suspect`、`violation`。
- `issues` 中每项包含 `kind`、`draft_evidence`、`bible_evidence`、`reason`。
- 上游不可用或结构无效时使用 `status="unavailable"` 与 `error_code`。
- Checker 不修改正文。
- `visible_checker_result` 为空意味着没有可证明属于当前可见正文的检查结果，不能把旧检查状态继续显示为当前有效。

### 4.8 InspirationResponse

同步返回 `cards`。每张卡包含：

- `title`：服务器生成的固定方向标签，不是模型另拟章节标题。
- `body`：可加入 Bible 的建议，200–300 个去空白字符。
- `history_basis`：可选的既有历史依据。
- `note`：可选风险或新增人物提示。
- `history_chapter_indexes`：可选来源章节编号。

正常实现请求 3 条；公开合同兼容 3–5 条。该接口不创建 JobRun，不保存建议，不改章节，也不启动 Writer、Checker 或 Extractor。

### 4.9 Agent 与模型设置

现役角色：

```text
memory_selector
writer
checker
extractor
inspiration_creator
```

- 全局 Persona 响应同时返回 `editable_persona`、`default_persona` 和只读 `program_protocol`。
- 单书 Persona 返回 `source`（`book`、`global` 或 `default`）、本书覆盖、当前全局值和实际生效值；没有覆盖记录即跟随当前全局值。
- 用户只能编辑非空、最多 8000 字符的 persona，不能覆盖程序协议；单书设置也不能修改模型 Profile、Binding、thinking、effort 或 temperature。
- Agent 在每次请求或异步任务启动时解析并冻结有效人格；后续设置修改不回写在途任务。
- LLM Profile 包含名称、OpenAI-compatible provider、base URL 和模型名；读取时不返回 API Key。
- Binding 将每个 Agent 绑定到一个 Profile，并报告配置值与实际生效值。
- Extractor 与灵感创造师固定关闭 thinking／effort；不能关闭思考的模型不能绑定给它们。
- 前端应以 `capabilities` 和 `temperature_adjustable` 决定哪些参数可编辑，不应硬编码模型名称规则。

## 5. 接口清单

### 5.1 系统与书

| 方法与路径 | 输入 | 成功结果与副作用 |
|---|---|---|
| `GET /health` | 无 | `{status, version}` |
| `GET /books` | 无 | 按最近打开和更新时间排序的 Book 列表 |
| `POST /books` | `{title, world_setting}` | 创建 Book，`201` |
| `GET /books/{book_id}` | 无 | Book；同时更新最近打开时间 |
| `PATCH /books/{book_id}` | 可选 `title`, `world_setting` | 更新 Book；世界观变化会失效相关 Writer 结果 |
| `DELETE /books/{book_id}` | 无 | 级联删除，`204` |
| `GET /books/{book_id}/agent-personas` | 无 | 读取本书五个角色的继承与有效人格 |
| `PUT /books/{book_id}/agent-personas/{agent_role}` | `{editable_persona}` | 创建或完整替换本书覆盖 |
| `DELETE /books/{book_id}/agent-personas/{agent_role}` | 无 | 删除覆盖并恢复跟随全局，幂等 `204` |
| `GET /books/{book_id}/export.txt` | 无 | 仅导出 finalized 章节正文；共享客户端的 Markdown／范围／逐章文件导出由已保存读取数据在本地组合 |
| `GET /books/{book_id}/memories/export.txt` | 无 | 导出摘要、事实、人物动态状态和故事线，不含正文 |

### 5.2 人物

| 方法与路径 | 输入 | 成功结果与副作用 |
|---|---|---|
| `GET /books/{book_id}/characters` | 无 | Character 列表 |
| `POST /books/{book_id}/characters` | `name`, 可选 `role`, `fixed_profile` | 创建人物，`201` |
| `POST /books/{book_id}/characters/import` | `{items:[...]}` | 批量创建人物 |
| `GET /characters/{character_id}` | 无 | Character |
| `PATCH /characters/{character_id}` | 可选 `name`, `role`, `fixed_profile` | 更新固定卡并失效受影响 Writer 输入 |
| `DELETE /characters/{character_id}` | 无 | 删除人物、关联和受影响记忆，`204` |
| `PATCH /character-events/{event_id}` | `{event_text}` | 只适用于可编辑 legacy 事件 |
| `DELETE /character-events/{event_id}` | 无 | 只适用于可编辑 legacy 事件，`204` |

### 5.3 章节与创作

| 方法与路径 | 输入 | 成功结果与副作用 |
|---|---|---|
| `GET /books/{book_id}/chapters` | 无 | ChapterSummary 列表 |
| `POST /books/{book_id}/chapters` | 标题、Bible、目标字数、作者附注、人物集合 | 创建下一编号章节，`201`；并发编号冲突可能 `409 chapter_index_busy` |
| `GET /chapters/{chapter_id}` | 无 | ChapterRead |
| `PATCH /chapters/{chapter_id}` | 章节可编辑字段 | 保存当前内容；任何相关输入变化会失效旧 Writer，正文或上下文变化可能使本章及后续归档失效 |
| `DELETE /chapters/{chapter_id}` | 无 | 取消当前任务、删除、收拢编号并重算后续记忆，`204` |
| `POST /chapters/{chapter_id}/import` | 正文及可选章节字段 | 将外部正文设为当前 `draft_ready`，`source="imported"` |
| `POST /chapters/{chapter_id}/inspirations` | 当前 `title`, `bible`, `pacing_boundary`, `selected_character_ids` | 同步返回临时灵感；业务数据零写入 |
| `POST /chapters/{chapter_id}/write` | `{replace_draft:false}` | 启动异步写作任务并立即返回 Job；`replace_draft=true` 可主动替换当前在途写作 |
| `GET /chapters/{chapter_id}/job` | 无 | 读取该章最新任务；无任务时 `phase="idle"` |
| `POST /chapters/{chapter_id}/write/cancel` | 无 | 取消当前 write 或 extract，恢复可见章节状态 |
| `POST /chapters/{chapter_id}/check` | 无 | 对当前可见正文同步重跑 Checker；不会修改正文 |
| `POST /chapters/{chapter_id}/accept` | `{override_checker:false}` | 接受当前正文，章节立即 finalized，并异步启动 Extractor；必要时要求明确 override |
| `POST /chapters/{chapter_id}/archive/retry` | 通常为空；维护流程可带 provenance 与正文 hash | 仅 finalized 章节可重试归档 |
| `POST /chapters/{chapter_id}/reopen` | 无 | 将 finalized 章节恢复为可编辑，取消归档并使本章及后续有效记忆失效 |

### 5.4 Agent 和模型设置

| 方法与路径 | 用途 |
|---|---|
| `GET /agent-personas` | 读取五个 Agent 的可编辑人格、默认人格和程序协议 |
| `PATCH /agent-personas/{agent_role}` | 修改一个 Agent 的全局可编辑人格 |
| `POST /agent-personas/{agent_role}/reset` | 恢复默认人格 |
| `GET /llm_profiles` | 读取模型配置列表，不含密钥 |
| `POST /llm_profiles` | 创建 Profile，API Key 必填 |
| `PATCH /llm_profiles/{profile_id}` | 修改 Profile；未提供 API Key 时保留旧密钥 |
| `DELETE /llm_profiles/{profile_id}` | 删除 Profile，相关 binding 变为空 |
| `POST /llm_profiles/{profile_id}/test` | 测试连接，成功返回 `{status:"ok"}` |
| `GET /agent-model-bindings` | 读取每个角色的绑定、能力和实际生效参数 |
| `PATCH /agent-model-bindings/{agent_role}` | 修改角色绑定与受模型能力约束的参数 |

## 6. 关键状态与副作用

### 6.1 Writer

1. 启动时冻结有效 Writer、Memory Selector、Checker 人格，以及 Bible、世界观、人物集合、人物状态和当前正文基线。
2. Memory Selector 只选择有来源的历史；Writer 从同一输入生成完整整章。
3. 正文必须达到至少 4000 个去空白字符并正常结束；长度或截断问题最多完整重写一次。
4. 候选先留在 Backend，确定性校验和 Checker 都通过后才原子替换可见正文。
5. 失败、被拒绝或 Checker 不可用时，失败稿不通过公开 API 返回，可见正文保持启动前基线。
6. 用户在任务期间修改相关输入会使旧任务 cancelled 或 `outcome_current=false`；旧结果不得恢复或覆盖新内容。

### 6.2 接受与 Extractor

1. 接受要求当前正文非空。
2. 若存在当前候选，Checker 必须对完全相同的正文和输入 `passed`；否则后端返回 `checker_override_required`，用户可明确忽略检查后接受。
3. 接受后章节立即变为 `finalized`，不等待 Extractor。
4. Extractor 在启动时冻结本书有效人格，对该 revision 只调用一次；只有摘要、规范事实和状态净变化整体通过后才原子激活。
5. Extractor 失败不会撤销正文接受，也不会重跑 Checker；前端应把“正文已完成”和“记忆归档失败”表达为两个独立事实。

### 6.3 重开与上游失效

- finalized 章节不能直接启动 Writer，必须先 reopen。
- reopen 会取消未完成的 Extractor，使本章归档失效，并使依赖该章的后续归档与人物状态重新失效。
- 编辑世界观、人物固定卡、章节正文、Bible、人物集合，或删除章节/人物，可能使已经显示过的任务和记忆不再适用。

## 7. 稳定机器错误

前端至少应对以下机器码给出可行动状态：

| 机器码 | 含义 |
|---|---|
| `chapter_index_busy` | 并发创建章节导致编号占用，可重试 |
| `chapter_finalized` | 章节已接受，先重开才能写作 |
| `write_running` | 当前章已有互斥任务 |
| `ambiguous_character` | 人物名称校验存在歧义 |
| `unselected_character` | 正文或输入使用了本章未授权的已知人物 |
| `empty_body`, `minimum_length`, `length_truncated` | 正文确定性长度/结束校验失败 |
| `checker_preflight_failed` | 当前正文未通过程序校验，未调用 Checker |
| `checker_override_required` | Checker 未通过、失效或不可用，需要用户明确决定 |
| `chapter_not_finalized` | 尚未接受正文，不能单独重试归档 |
| `archive_report_mismatch` | 维护报告对应的正文已变化，拒绝历史重提 |
| `inspiration_character_invalid` | 灵感请求包含不属于本书的人物 |

还必须容忍 `llm_*`、`writer_*`、`checker_*`、`archive_*` 等安全错误码。未知机器码应显示通用失败与服务端安全消息，不应崩溃。

## 8. 明确不存在或不可依赖的能力

- 没有用户账号、角色权限、团队协作、评论或实时多人编辑协议。
- 没有服务端草稿自动保存、冲突合并或文档版本浏览 API。
- 没有公开 Writer 候选列表、候选选择或失败候选全文接口。
- 没有灵感历史、收藏、服务端取消或结果读取接口。
- 没有 Agent 聊天线程、消息记录或通用工具调用界面。
- 没有服务端全文搜索、过滤、分页、封面、标签、文件夹或书籍排序写入接口。
- 没有进度推送；异步任务需要轮询 `/job`。

这些缺口可以在设计中标为后端增强建议，但不得在“可直接实现”的 v2 方案里伪装成已存在。
