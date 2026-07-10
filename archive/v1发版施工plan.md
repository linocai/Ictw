# LinoI v1 发版施工 Plan

> 状态：待施工，设计讨论稿已收口  
> 编写日期：2026-07-10  
> 适用范围：`linoI/App`、`linoI/Backend` 与当前 HK 云端部署  
> 本文是本轮 v1 改造的施工权威；若实现与本文冲突，应先更新本文再继续施工。

---

## 0. 发版目标

v1 不再依靠一段越来越长的 Writer 人格去约束模型，而是把写作链拆成职责明确、可验证的四个 Agent：

1. **Memory Selector（记忆选择师）**：阅读本章剧情 Bible，从长期记忆库中选择本章真正需要的历史记忆。
2. **Writer（作家）**：只根据本章 Bible、作者备注、允许人物、人物当前状态和筛选后的工作记忆写初稿。
3. **Reviser（修订师）**：替代 Compressor，修正字数和未授权人物；最多修订两次。
4. **Extractor（档案员）**：用户接受章节后归档摘要、大事记和已选人物事件；无权扩大本章人物集合。

v1 的核心原则：

- **数据库负责记得全，Writer Prompt 只保留当前工作集。**
- **本章剧情 Bible 决定发生什么；人物选择决定人物权限上限。**
- **模型不能反向要求用户扩大演员表。**
- **推理开关与思考强度由用户配置，业务代码不得擅自替模型开启或关闭。**
- **能由程序验证的约束，不只写在 Prompt 里。**

目标链路：

```text
本章预检
  → Memory Selector 选择记忆 ID
  → 后端按字数预算装配工作记忆
  → Writer 流式生成初稿
  → 程序检查字数与未授权人物
  → 必要时 Reviser 修订（最多 2 次）
  → 合格草稿交给用户编辑
  → 用户接受
  → Extractor 只归档已选人物
```

---

## 1. 已确认的问题与证据

### 1.1 Writer 上下文失衡

以线上第 22 章为样本：

| 上下文部分 | 字符数 | 提到的未选人物数 |
|---|---:|---:|
| 本章剧情 Bible | 176 | 0 |
| 20 章大事记 | 503 | 7 |
| 两名已选人物的人物卡与完整时间线 | 2648 | 9 |
| 上一章梗概 | 76 | 0 |

当前章节只选择了两个人物，但人物时间线和历史大事记反复激活大量未选人物；本章 Bible 反而成为 Prompt 中最短的内容。

### 1.2 长期记忆与工作记忆混为一谈

当前 Writer 每次收到：

- 全部更早章节的大事记；
- 上一章完整梗概；
- 已选人物的完整历史时间线；
- 人物固定设定和动态状态；
- 本章剧情。

随着章节数增加，历史信息持续膨胀。即使本章切换了场景和人物，上一章梗概仍被强制注入。

### 1.3 人物权限方向错误

当前 Extractor 返回未选人物时，后端抛出 409，要求用户把该人物补选进本章。这导致：

- Writer 擅自写入未授权人物；
- 用户被迫补选；
- Extractor 随后污染该人物的故事线和动态状态；
- 被污染的人物时间线又进入后续 Writer Prompt，形成正反馈。

### 1.4 Compressor 只能压缩，不能保证交付

当前流程只在初稿超过目标字数 120% 时调用一次 Compressor，且压缩后不复检。线上 Agent 章节实际字数曾出现目标的 66%～197%。

### 1.5 模型推理参数缺乏用户控制

当前业务代码直接传固定 `temperature`，但不同模型对 thinking/reasoning 的支持不同：

- DeepSeek V4 支持思考开关；思考开启时温度参数不生效。
- Gemini 3.x 不支持真正关闭思考，但支持 `minimal/low/medium/high` 等强度。
- 其他 OpenAI-compatible 模型未必支持思考参数。

不能在业务代码里统一强开、强关或盲传参数。

### 1.6 Gemini Extractor 错误不可见

线上复现确认：Gemini 对当前小说内容返回 HTTP 200，但 `promptFeedback.blockReason=PROHIBITED_CONTENT` 且无候选内容。当前兼容层只显示“没有 message content”，无法区分内容过滤、限流、空响应和无效 JSON。

### 1.7 删除章节后端已存在，前端缺入口

后端已有 `DELETE /chapters/{chapter_id}`，但 iOS 章节编辑页没有删除按钮、确认流程、本地草稿清理和删除后导航处理。

---

## 2. v1 产品契约

### 2.1 本章剧情 Bible

`Chapter.user_prompt` 在 UI 中显示为“本章剧情 Bible”。

它是本章唯一的情节最高权威，负责描述：

- 本章发生的事件；
- 事件顺序；
- 人物的行动、决定和因果；
- 开场条件与结尾落点；
- 本章允许出现的临时路人或无人物卡角色。

世界观是设定最高权威，但不能替代本章 Bible 创造剧情。

### 2.2 作者对本章的备注

将现有 `chapter_style` 改名为 `author_note`，UI 名称为“作者对本章的备注”。

作者备注负责“怎么写”，可包含：

- 叙事视角；
- 节奏和氛围；
- 语言、文风和句式；
- 希望详写或略写的部分；
- 表现手法和额外限制。

作者备注不授予人物出场权限，也不承担情节定义职责。

### 2.3 人物选择的严格语义

本章选择的人物是**允许出现人物集合的上限**，不是 Writer 必须逐个使用的清单。

规则：

1. 已选择人物可以出场、行动、说话或被提及，但是否实际出现仍由 Bible 决定。
2. 未选择的已知人物不得出场、行动、说话、被回忆或被提及。
3. “只在对话或描写中被提到”同样算本章出现，必须先选择。
4. Bible 中出现已知人物姓名但该人物未被选择时，写作前预检直接报错。
5. Bible 明确写出的无人物卡临时角色可以出现，但不进入人物故事线和动态状态。
6. 历史记忆中提到某个人物，不构成该人物的本章出场授权。

### 2.4 删除单人物本章备注

删除 `ChapterCharacter.chapter_note` 的产品概念、API 字段、数据库字段和前端输入区。

人物本章特殊行为统一写入本章剧情 Bible 或作者备注，避免多处指令互相冲突。

### 2.5 字数契约

字数继续按中文正文去空白字符数计算。

v1 默认合格范围：

```text
目标字数的 95%～105%
```

该区间作为可配置常量集中定义，不散落在 Agent Prompt 中。

当 Bible 明显不足以安全扩写到目标长度时，Reviser 不得靠新增剧情硬凑；两次修订仍不合格时必须打回。

---

## 3. 长期记忆与记忆块

### 3.1 v1 记忆来源

现有数据直接组成记忆块，v1 暂不新增通用 Memory 表：

| 记忆类型 | 来源 | 稳定 ID 形式 |
|---|---|---|
| 一句话大事记 | `Chapter.headline` | `chapter:{chapter_id}:headline` |
| 章节梗概 | `Chapter.summary` | `chapter:{chapter_id}:summary` |
| 人物故事线事件 | `CharacterEvent.event_text` | `character_event:{event_id}` |

每个候选记忆块向 Memory Selector 提供：

- `memory_id`
- `memory_type`
- `chapter_index`
- `character_ids`
- `text`
- `char_count`

世界观、人物固定设定和动态状态不是历史记忆块，按各自契约单独进入 Writer 上下文。

### 3.2 上一章梗概不再强制注入

上一章梗概只是普通候选记忆块，可给予轻微的时间邻近信号，但 Memory Selector 可以完全不选。

场景、时间线或人物大幅切换时，不应为了“上一章”三个字强行污染当前工作集。

### 3.3 人物卡与人物故事线分离

Writer 的人物卡只包含：

- 姓名和身份；
- 固定设定；
- 当前动态状态。

人物的所有 `CharacterEvent` 都进入长期记忆候选库，不再整条注入人物卡。

### 3.4 记忆原文与溯源

Memory Selector 只能选择记忆 ID，不能向 Writer 输出自由改写的历史摘要。

后端必须：

1. 验证所有返回 ID 都来自当前书籍候选集合；
2. 按 Agent 返回顺序读取数据库原文；
3. 按字数预算装箱；
4. 不截断单个记忆块；
5. 不把选择理由传给 Writer；
6. 在 Writer Prompt 中保留记忆类型和章节来源标签。

这样可以避免 Memory Selector 二次改写历史、制造新的“事实版本”。

### 3.5 记忆字数预算

v1 采用动态预算初值：

```text
memory_budget = clamp(Bible 非空白字符数 × 1.5, 600, 1800)
```

规则：

- 预算单位为去空白字符数，不是 token 数，也不是固定记录数。
- Memory Selector 可以返回任意数量 ID。
- 后端只装入预算能容纳的完整记忆块。
- 预算值集中配置，发版后依据真实章节样本调整。
- 人物卡不计入 memory budget，但施工时需要记录人物卡总字符数，防止新的辅助上下文膨胀。

### 3.6 大规模章节的候选预筛

当前二十余章可让 Memory Selector 阅读全部候选记忆。

为避免未来把膨胀问题转移到 Memory Selector，自 v1 起预留阈值：

- 候选记忆块不超过 300 条且总字符不超过 30,000：全部交给 Memory Selector。
- 超过阈值：先按当前已选人物、Bible 关键词和章节邻近度做确定性预筛，再把候选交给 Agent 精排。
- v1 不引入向量数据库；预筛接口和数据结构必须允许后续接入 FTS/embedding。

---

## 4. Memory Selector Agent 契约

### 4.1 新增 Agent 角色

新增：

```text
agent_role = memory_selector
```

它拥有独立的：

- Agent Persona；
- LLM Profile 绑定；
- 推理开关和思考强度设置。

建议默认绑定快速、低成本模型，但发版代码不得硬编码具体模型。

### 4.2 输入

Memory Selector 输入：

1. 本章标题；
2. 本章剧情 Bible；
3. 作者备注；
4. 已选择人物 ID、姓名和当前动态状态；
5. 记忆字数预算；
6. 当前书籍的候选记忆块列表。

人物固定设定无需完整提供给选择器，除非后续验证发现缺少它会明显降低召回质量。

### 4.3 输出

严格 JSON：

```json
{
  "selected_memory_ids": [
    "chapter:...:headline",
    "character_event:...",
    "chapter:...:summary"
  ]
}
```

数组顺序即重要性顺序。

禁止输出：

- 自由概括文本；
- 不存在的 ID；
- Writer 指令；
- 新的剧情推断。

### 4.4 失败策略

- 上游 429/5xx：按 provider 规则有限重试一次。
- 无效 JSON、空结果或非法 ID：记录可见错误。
- Memory Selector 最终失败：本次写作直接失败并弹通知，不静默退回“全量记忆”或“强制上一章梗概”。
- 空选择数组是合法结果，代表本章无需历史记忆。

### 4.5 默认 Persona 方向

默认人格应强调：

- 它是检索员，不是小说家；
- 只判断哪些已存在事实对完成 Bible 必要；
- 不因记忆较近就自动选择；
- 不因记忆提到很多人物就提高优先级；
- 优先避免重复选择同一事实的大事记、梗概和人物事件三个版本；
- 允许不选择上一章任何信息。

---

## 5. Writer 工作区与 Prompt

### 5.1 Writer 输入组成

按以下顺序装配：

1. 世界观硬约束；
2. 本章允许人物白名单及权限说明；
3. 已选人物的人物卡（固定设定 + 动态状态）；
4. Memory Selector 选择的只读历史记忆；
5. 作者对本章的备注；
6. 本章剧情 Bible；
7. 目标字数与最终交稿契约。

本章 Bible 和最终交稿契约必须位于 Prompt 尾部。

### 5.2 Prompt 权限层级

从高到低：

1. 世界观中的规则性设定；
2. 本章剧情 Bible；
3. 本章允许人物集合；
4. 作者备注；
5. 人物固定设定和动态状态；
6. 筛选后的历史记忆。

历史记忆只用于避免写错，不得被当成要求续写或复现的素材清单。

### 5.3 人物白名单表达

Prompt 只列允许人物，不向 Writer 提供“禁止人物姓名清单”。

必须明确：

- 允许人物集合是上限，不是逐个使用清单；
- 只有 Bible 决定谁实际出场；
- 历史记忆中出现的人名不构成当前出场授权；
- 不得新增已有人物、临时人物或额外关系，除非 Bible 明确写出。

### 5.4 写作前预检

写作请求发出前，后端执行：

1. Bible 不得为空；
2. 从本书人物姓名中扫描 Bible；
3. Bible 提到已知人物但该人物未选择时，返回 409；
4. 错误信息列出需要选择或从 Bible 删除的人物；
5. 作者备注中的名字不自动授予出场权限；
6. 无人物卡的临时角色不参与该项检查。

### 5.5 推理参数

Writer 不再硬编码某个供应商的 thinking 状态或 reasoning effort。

每次调用从当前 AgentModelBinding 读取有效设置，经 capability adapter 转换成供应商参数。

---

## 6. Reviser：由 Compressor 升级

### 6.1 角色迁移

将：

```text
compressor → reviser
```

迁移必须保留用户现有 Compressor：

- Persona 文本；
- LLM Profile 绑定；
- 后续新增的推理设置。

前端名称统一改为“修订师”。

### 6.2 Reviser 职责

Reviser 负责：

1. 将正文调整到目标字数区间；
2. 删除所有未授权已知人物的出现、提及、行动和对白；
3. 删除由未授权人物带来的整条新增因果分支，而不是只删除姓名；
4. 保留 Bible 中的事件顺序、关键动作和结尾落点；
5. 不新增人物、线索、决定、去向、物品或剧情结果；
6. 素材不足时只扩展已有情节点的表达，不用新剧情凑字。

### 6.3 触发条件

Writer 初稿完成后，程序先检查：

- 实际字数是否在目标的 95%～105%；
- 是否出现本书未授权人物的姓名；
- 是否存在空正文或明显截断。

任一不合格则调用 Reviser。

v1 不要求每篇无条件经过 Reviser，避免对已经合格的初稿进行无意义二次改写。

### 6.4 两次上限与打回契约

Reviser 最多修订两次：

```text
Writer 初稿
  → 检查
  → Reviser 第 1 次
  → 再检查
  → Reviser 第 2 次
  → 最终检查
```

两次后仍不满足硬条件：

1. 不把结果标记为成功；
2. 不进入后续接受/Extractor 流程；
3. 写作状态回到可重新生成状态；
4. iOS 弹出持久可见通知：

```text
本次草稿未通过修订检查，请调整 Bible、目标字数或人物选择后重新生成。
```

5. 错误附带原因：字数、未授权人物、空结果或上游错误；
6. UI 恢复“重新生成”按钮；
7. 不覆盖生成前已有的服务端草稿基线。

### 6.5 Reviser 后端校验

每次 Reviser 输出后必须重新：

- 计算非空白字符数；
- 扫描未授权已知人物姓名；
- 检查正文非空；
- 记录本轮输入字数、输出字数和违规项。

模型自称“已经修好”不视为通过，程序检查结果才是唯一依据。

### 6.6 SSE 状态

新增或调整事件：

- `selecting_memory`
- `started`
- `token`
- `revising`：包含 `attempt`、当前字数和违规类型，不包含小说正文之外的敏感内容；
- `done`
- `error`：包含稳定错误码和用户可读消息。

---

## 7. Extractor 权限收口

### 7.1 动态 Schema

Extractor 的 `character_id` 不再是任意字符串，而是本章已选人物 ID 的枚举。

若本章没有选择人物：

- `character_events=[]`
- `dynamic_fields_patch=[]`

### 7.2 后端二次过滤

即使模型违反 Schema，后端仍必须：

- 丢弃未选人物的事件；
- 丢弃未选人物的动态状态更新；
- 正常保存合法的 summary、headline 和已选人物更新；
- 不抛出“请补选人物”；
- 不让模型改变 `ChapterCharacter` 集合。

### 7.3 删除补选流程

移除：

- `UnselectedCharacterReference` 驱动的用户补选流程；
- `/accept` 中对应的 409 分支；
- iOS 对“请先选择某人物”的依赖。

### 7.4 归档覆盖

重新接受章节时：

- 先在事务内删除本章旧 `CharacterEvent`；
- 写入本次仅针对已选人物的新事件；
- 更新已选人物动态状态；
- 未选人物历史数据保持不变。

### 7.5 Gemini 错误可见性

LLM 层应保留并分类：

- HTTP 状态码；
- provider 错误码；
- `promptFeedback.blockReason`；
- `finishReason`；
- 空候选；
- 无效 JSON；
- 是否可重试。

`PROHIBITED_CONTENT` 必须显示为内容过滤，不得伪装成余额不足、普通 502 或 JSON 错误。

v1 不默认实现跨供应商自动 fallback；模型绑定仍由用户决定，避免隐式产生额外费用或改变数据处理方。

---

## 8. 模型推理设置

### 8.1 设置归属

推理设置存放在 `AgentModelBinding`，而不是全局 `LLMProfile`。

原因：同一个 Profile 可能同时绑定 Writer、Reviser 或 Extractor，而不同任务需要不同思考策略。

UI 仍放在“模型 / Agent 绑定”页面，每个 Agent 绑定行显示当前模型的推理设置。

### 8.2 数据字段

为 `AgentModelBinding` 增加：

```text
thinking_enabled: bool | null
reasoning_effort: string | null
```

语义：

- `null`：使用模型默认值或该模型不支持配置；
- `true/false`：用户明确开启或关闭；
- `reasoning_effort`：只能取 capability 声明的枚举值。

### 8.3 Capability 描述

后端对每个 Profile 计算并返回：

```json
{
  "thinking_toggle_supported": true,
  "thinking_can_disable": true,
  "thinking_required": false,
  "reasoning_effort_levels": ["high", "max"],
  "temperature_effective_when_thinking": false
}
```

能力来自可维护的 provider/model capability registry，不从 `/models` 列表盲猜。

未知模型默认：

- 不发送 thinking/reasoning 参数；
- 开关和强度选择器置灰；
- UI 显示“此模型未声明可调思考参数”。

### 8.4 已知模型映射

v1 至少支持当前已有模型：

#### DeepSeek V4 Pro / Flash

- 支持开启/关闭 thinking；
- 开启时支持有效档位 `high/max`；
- 关闭时强度选择器置灰；
- 开启时提示 temperature 不生效；
- 请求转换为 DeepSeek 官方 `thinking.type` 和 `reasoning_effort`。

#### Gemini 3.5 Flash

- 不支持真正关闭思考；
- 开关显示为锁定开启并置灰；
- 支持 `minimal/low/medium/high`；
- 请求通过 Google/OpenAI 兼容映射或原生 adapter 传递；
- UI 提示思考 token 计入用量。

#### 未识别 OpenAI-compatible 模型

- 不假设支持；
- 不发送额外参数；
- 控件置灰。

能力注册表要可扩展，以便未来加入 Qwen、Claude、Kimi 等模型。

### 8.5 UI 交互

每个 Agent 的模型绑定区显示：

- 模型选择器；
- “启用思考”开关；
- “思考强度”选择器；
- 不支持原因或参数说明；
- 保存后的实际生效状态。

控件规则：

- 不支持切换：开关置灰；
- 模型强制思考：显示开启但不可操作；
- 思考关闭：强度选择器置灰；
- 模型不支持强度：选择器置灰；
- 更换模型后，立即清理不合法的旧设置，不向新模型发送残留参数。

---

## 9. 删除本章

### 9.1 前端入口

在章节编辑页增加“删除本章”破坏性按钮：

- 放在不易误触的更多菜单或页面底部危险区；
- 使用系统红色 destructive 样式；
- 显示章节序号与标题；
- 必须二次确认；
- 写作或修订进行中时，明确提示会先取消任务。

### 9.2 删除成功后的前端行为

1. 清除该章节 `LocalDraftCache`；
2. 关闭当前章节页面并返回章节列表；
3. 刷新章节列表；
4. 清除 Store 中正在编辑的章节和流状态；
5. Toast 显示“章节已删除”。

### 9.3 后端删除语义

增强现有 `DELETE /chapters/{chapter_id}`：

1. 若存在 live write/revise job，先取消并等待安全退出；
2. 删除章节；
3. 级联删除 `ChapterCharacter` 与该章 `CharacterEvent`；
4. 后续章节序号依次前移，保持连续；
5. 不修改其他章节已有正文、summary 和 headline；
6. 删除不存在章节继续保持幂等 204，或统一改为 404；施工时选定一种并补测试。

序号前移必须避免唯一约束冲突，先删除并 flush，再按升序填补空位。

### 9.4 删除 finalized 章节的提示

删除已完成章节会删除该章人物事件，但不会自动重新提取后续章节。确认文案需要明确说明该影响。

---

## 10. 数据模型与迁移

### 10.1 Alembic 迁移

新增迁移，至少完成：

1. `chapters.chapter_style` → `chapters.author_note`；
2. 删除 `chapter_characters.chapter_note`；
3. `agent_model_bindings` 增加 `thinking_enabled`；
4. `agent_model_bindings` 增加 `reasoning_effort`；
5. 新增 `memory_selector` AgentPersona 与 AgentModelBinding；
6. 将 `compressor` Persona/Binding 迁移为 `reviser`；
7. 保留现有 Compressor 的模型绑定和人格内容；
8. SQLite 使用 Alembic batch 操作保证兼容。

### 10.2 API DTO 变化

`ChapterCreate/ChapterPatch/ChapterRead/ChapterImportRequest`：

- 删除 `chapter_style`；
- 新增 `author_note`；
- `character_links` 只包含 `character_id`。

`AgentBindingRead/Patch`：

- 增加 `thinking_enabled`；
- 增加 `reasoning_effort`；
- 增加当前 Profile 的 capability 描述或 capability 引用。

### 10.3 兼容策略

由于当前 iOS 与后端同步发版，v1 可执行一次性字段迁移，不要求长期双字段兼容。

部署顺序必须避免旧 App 向新后端发送已删除字段造成不可预期行为；建议后端 Schema 在一个过渡版本中 `extra=ignore`，新 App 验证完成后再严格收口。

---

## 11. 后端施工阶段

### Phase 1：Schema、迁移与 Agent 角色

- 完成 Alembic 迁移；
- 更新 ORM、Pydantic Schema；
- 新增 Memory Selector；
- Compressor 迁移为 Reviser；
- 种子数据和默认 Persona 更新；
- 迁移测试验证现有线上数据不丢失。

### Phase 2：模型 Capability 与推理设置

- 建立 capability registry；
- 扩展 AgentModelBinding；
- provider adapter 只发送模型支持的参数；
- 错误分类和敏感信息脱敏；
- DeepSeek/Gemini/未知模型单测。

### Phase 3：记忆选择链

- 从现有数据生成记忆块候选；
- 完成 Memory Selector Prompt 和 JSON Schema；
- 验证 ID；
- 实施动态字数预算和原文装箱；
- 重建 Writer Prompt；
- 移除完整人物时间线直灌和强制上一章梗概。

### Phase 4：Writer 预检与 Reviser

- Bible 人物选择一致性预检；
- Writer 工作区与白名单；
- 字数和未授权人物检查；
- Reviser 两次修订上限；
- `revision_failed` 错误与 SSE；
- 失败不覆盖已有草稿基线。

### Phase 5：Extractor 收口

- 动态角色 ID Schema；
- 未选人物更新丢弃；
- 删除补选 409；
- 重新接受覆盖测试；
- Gemini blockReason 可见性。

### Phase 6：删除章节增强

- live job 取消；
- 事务级删除与级联；
- 章节序号前移；
- 本地缓存配套 API 行为验证。

---

## 12. iOS 施工阶段

### 12.1 章节编辑器

- “本章剧情”改为“本章剧情 Bible”；
- “本章文风”改为“作者对本章的备注”；
- 删除每个人物的本章备注输入；
- 人物选择区明确说明“选择代表允许出现，不代表 Writer 必须使用”；
- Bible 提到未选已知人物时展示后端预检错误。

### 12.2 生成状态

增加状态文案：

- 正在选择相关记忆；
- 正在生成正文；
- 修订师正在进行第 1/2 次修订；
- 修订未通过，请重新生成。

`revision_failed` 必须通过 NoticeBus/Toast 明确展示，不能只改变内部状态。

### 12.3 Agent / 模型页

- Agent 列表改为 Memory Selector / Writer / Reviser / Extractor；
- 每个 Agent 独立绑定 Profile；
- 增加思考开关和强度选择器；
- 根据 capabilities 控制可用/置灰状态；
- 显示不支持原因；
- 更换 Profile 时及时刷新有效设置。

### 12.4 删除本章

- 新增破坏性按钮与二次确认；
- 处理中禁用重复点击；
- 成功后删除本地缓存、返回列表并刷新；
- 失败时保留当前页面和草稿，显示错误。

---

## 13. 测试计划

### 13.1 后端单元与 API 测试

必须覆盖：

#### Memory Selector

- 可选择 headline、summary、CharacterEvent；
- 上一章 summary 可以不选；
- 空选择合法；
- 非本书或不存在 ID 被拒绝；
- Agent 返回顺序得到保留；
- 装箱不超过预算；
- 不截断单个记忆块；
- 不把完整人物时间线直接放入 Writer Prompt；
- 候选超阈值时预筛生效。

#### 人物权限

- Bible 提到未选已知人物时写作前 409；
- 未选人物只出现在历史记忆时不获得授权；
- 已选择人物不是强制逐个出场；
- Bible 明确临时角色可以存在；
- Writer Prompt 白名单只含已选人物。

#### Reviser

- 字数合格且无违规时不调用；
- 超长、过短触发；
- 未授权人物触发；
- 第一次修订成功；
- 第二次修订成功；
- 两次仍失败时返回 `revision_failed`；
- 失败不覆盖旧草稿；
- Reviser 后仍执行程序复检。

#### Extractor

- Schema 只允许已选人物 ID；
- 未选人物事件被丢弃且不 409；
- 未选人物动态状态不变；
- summary/headline 仍正常保存；
- 重新接受只覆盖本章已选人物事件；
- 无选择人物时事件和 patch 必须为空。

#### 模型设置

- DeepSeek thinking on/off 映射；
- DeepSeek effort 合法值；
- Gemini 强制思考与 effort 映射；
- 未知模型不发送额外参数；
- 更换模型清理非法旧设置；
- 上游错误不泄露 API Key；
- Gemini `PROHIBITED_CONTENT` 显示为内容过滤。

#### 删除章节

- 删除普通章节；
- 删除 finalized 章节级联事件；
- 删除写作中章节先取消任务；
- 删除后序号连续；
- 连续删除与删除末章；
- 不影响其他章节正文与人物动态状态。

### 13.2 回归门禁

- Bearer Token 鉴权；
- Book / Chapter / Character CRUD；
- 章节导入导出；
- Writer SSE 断线重附着与取消；
- Reopen/Accept；
- LLM Profile 增删改测；
- Agent Persona 编辑与恢复默认；
- Alembic 从当前线上 revision 升级成功。

### 13.3 iOS 构建与视觉验证

按照项目铁律：

1. `xcodebuild` iOS Simulator 构建成功；
2. 真正 `simctl launch`；
3. 截图检查章节编辑页、人物选择、修订状态、模型推理设置和删除确认框；
4. 验证小屏无横向溢出；
5. 验证推理控件置灰状态仍可读；
6. 真机验证 SSE、后台恢复和 Toast。

---

## 14. 云端发版步骤

### 14.1 发版前

1. 停止新写作操作；
2. 检查数据库中 `writing/extracting` 章节数；
3. 备份 `/opt/linoi/backend/linoi.db`；
4. 备份当前后端代码与 systemd unit；
5. 在本地数据库副本执行 Alembic 升级和回归测试。

### 14.2 部署

1. 同步 Backend 代码；
2. 安装/更新依赖；
3. 执行 `alembic upgrade head`；
4. 检查迁移后的 AgentPersona/Binding；
5. 重启单 worker `linoi-backend`；
6. 检查 Nginx 与健康接口；
7. 安装对应 iOS 构建。

### 14.3 云端烟测

- 健康接口 200；
- 四个 Agent 均可读取；
- 推理 capabilities 返回正确；
- 创建测试章并完成记忆选择、写作、修订；
- 人物白名单生效；
- 接受章节后只更新已选人物；
- 删除测试章节并确认序号与事件级联；
- Gemini 内容过滤能显示明确原因；
- 日志无密钥和正文泄漏。

### 14.4 回滚

若数据库迁移或核心写作链失败：

1. 停止服务；
2. 恢复发版前 SQLite 备份；
3. 恢复旧后端代码；
4. 重启服务；
5. 用旧版 App 验证；
6. 不尝试在生产库上手工逆改字段。

---

## 15. v1 验收标准

只有以下全部成立才可宣布 v1 完成：

- [ ] Writer 不再收到完整人物故事线和强制上一章梗概。
- [ ] Memory Selector 可从大事记、章节梗概和人物事件中按 Bible 选择记忆。
- [ ] Memory Selector 只返回 ID，Writer 使用数据库原文。
- [ ] 工作记忆受动态字符预算限制。
- [ ] 人物卡只包含固定设定和动态状态。
- [ ] 本章人物选择是严格权限上限；提及也算出现。
- [ ] Bible 提到未选已知人物时写作前拦截。
- [ ] 未选人物不会因为 Extractor 输出而要求用户补选。
- [ ] 未选人物的时间线和动态状态不会被污染。
- [ ] Compressor 已升级为 Reviser。
- [ ] Reviser 最多两次；仍失败会打回并通知重新生成。
- [ ] 字数由程序复检，不采信模型自报。
- [ ] “本章文风”已改为“作者对本章的备注”。
- [ ] 单人物本章备注已从前后端删除。
- [ ] 章节编辑页可安全删除本章。
- [ ] 删除章节会取消 live job、清本地缓存、级联事件并收拢序号。
- [ ] 模型页提供推理开关与思考强度。
- [ ] 不支持的模型控件置灰且不发送未知参数。
- [ ] 同一 Profile 在不同 Agent 上可以使用不同推理设置。
- [ ] Gemini 内容过滤、429、5xx、空响应和 JSON 错误可区分。
- [ ] 后端测试、iOS 构建、模拟器 launch 与截图检查全部通过。
- [ ] 云端数据库已备份，迁移和烟测通过。

---

## 16. 暂不纳入 v1

以下内容保留为后续版本，不阻塞本次发版：

- 通用向量数据库或 embedding 记忆检索；
- 用户手动 pin/强制选择某条历史记忆；
- 人物别名字段及别名级未授权人物扫描；
- 自动跨供应商模型 fallback；
- 多 worker 分布式写作任务；
- PostgreSQL 迁移；
- 对后续章节自动重新提取或重建记忆；
- 为每本书单独配置记忆预算公式。

这些能力的接口应尽量预留，但不得扩大 v1 施工范围。
