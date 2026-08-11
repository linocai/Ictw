# ICTW PROJECT_PLAN

> 唯一现行控制面。仅保留当前状态、已定决策与可施工计划；`archive/` 只保存已完成版本和历史资料，不能作为当前 Builder 指令。

## 当前状态

- 当前源码、宁波 Backend 生产与本机 macOS 已安装版均为 `v1.9.2(39)`；Alembic head `20260809_0011`，iOS 打包由用户处理，公开客户端仍为 `v1.8.1(32)`。
- v1.8.3 的 Writer／Extractor 生命周期整改、独立 Review 和宁波生产门禁均已完成。历史结论与回滚记录：`archive/plans/PROJECT_PLAN-v1.8.3-completed.md`；生产真相与运维命令仅见仓库外 `/Users/linotsai/Lino/NB_info.md`。
- **v1.9.2（39）篇幅与推进边界快修**已完成源码施工、本地门禁、宁波 Backend 部署和本机 macOS 换装：每个 `body` 为 200–300 个去空白字符，并以自然语句收束有限的新状态与未解决事项；关系、认知、秘密、冲突和长期主线默认只推进最小但有意义的一步。双端仅新增一句可选“这一章最多推进到哪里”，仍由明确按钮触发，界面只呈现输入、loading、结果或“生成失败”；该句只随本次快照发送，不写 Bible 或数据库。Extractor／灵感创造师固定为程序级非思考角色，正常生成要求 3 条，超长正文只允许按 200–300 字内最后一个自然句末裁切。Backend 全量 168 collected／156 passed／12 skipped，客户端纯逻辑、双端 Debug、签名 macOS 通用 Release Build 39 与 diff check 均通过；无 migration。
- Build 39 生产验收：内外网鉴权 health `1.9.2`、未鉴权 401、docs 200、SQLite integrity 正常／foreign keys 为空、Alembic `20260809_0011 (head)`、MainPID 与 8787 监听 PID 一致、`NRestarts=0`、零 warning／failed unit；数据仍为 3 books／69 chapters／26 characters，非终态任务、未完成 revision 与 writing chapter 均为 0。真实公网 smoke 23 秒一次成功，返回固定“方向一～三”，body 为 279／294／278 字，审计 `finish_reason=stop`、无 error／upstream reason，业务表计数不变。
- 隔离验收已覆盖空 Bible／无人物、未配置、3／5 条长文、采用、陈旧提示、一次撤销，macOS 1080 抽屉与 1200 并列形态；采用后复查隔离后端，持久化 Bible 仍为空。
- 保留全部既有未提交改动，绝不覆盖、回退或擅自暂存；不触碰未跟踪 `archive/ICTW-Local-Archive/`。受保护的 `App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme` 一律不在范围。

## 不可破坏规则

- 写作链固定为 Memory Selector → Writer → Checker → 用户接受 → Extractor。灵感创造师是只读、手动的侧挂能力，不得进入流程、JobRun、正文候选或 Extractor 生命周期。
- 正文接受与归档独立；Extractor 每 revision 只调用一次，只有完整 v2 结果可激活；partial／failed／stale 不进 Selector、人物故事线或状态投影。
- 人物选择是本章允许出现人物的上限。有效历史不自动授权人物；程序能校验的约束必须程序复检。
- 历史每章只用一个有效来源：active v2 优先，否则仅 legacy eligible；不得自动历史重提、重跑 Extractor 或修改生产历史。
- 生产表结构只经 Alembic，启动不 `create_all`；部署前停服备份并验证 SQLite integrity、foreign keys、head、单实例及公网鉴权健康。
- `thinking`／`effort` 由 capability registry 决定；Extractor 与灵感创造师固定关闭 thinking／effort，模型若不能关闭则安全 409；其他非思考请求统一 `top_p=0.95`。日志、审计与 API 不含 API key、persona、prompt、Bible／正文、历史片段、候选或 provider 原文。
- 保持 target／Bundle ID／Keychain／UserDefaults／本地草稿路径及 `chapter_style` 兼容窗口；不暴露 Writer 候选正文或选择接口。

## v1.9.2（39）目标与边界

**目标**：内部角色 `inspiration_creator`（“灵感创造师”）由用户手动对当前章节 Bible 求取 3–5 张实质不同的灵感卡；每张 `body` 为 200–300 个去空白字符，形成足够具体但仍给作者留白的连贯章节进程。模型只生成方向正文及可选历史依据／备注，不另拟章节标题；公开响应由服务器映射固定方向标签。选择后只加入本地 Bible 草稿，默认不保存、不覆盖。

**读取边界**：客户端当前内存的章节标题、Bible（可以为空）、人物选择（可以为空）；服务端的世界观、已选人物固定卡／章节前投影状态，以及同书此前章节的有效历史。当前临时 snapshot 绝不能被数据库旧字段替代。

**不做**：不调用 Memory Selector、不生成正文、不运行 Checker／Extractor、不创建 JobRun／候选／revision、不写 Chapter／Book／Character／Archive、不保留建议全文、不自动选人物或保存 Bible、不新增 UI 框架。

## 已定后端决策

### 1. 同步、无持久化接口

- 鉴权 `POST /chapters/{chapter_id}/inspirations` 请求为 `{title,bible,selected_character_ids,pacing_boundary}`，响应为 `{cards:[...]}`。`pacing_boundary` 是不超过 500 字的可选单次推进上限，不持久化。接口是单次同步、有界 LLM 请求，不入队、不轮询、不提供结果读取或服务端取消端点；格式不合格最多一次修复调用。
- `title`、`bible` 允许为空字符串，`selected_character_ids` 允许空数组。服务端只校验请求类型、ID 去重及所选人物属于当前书；不以空 Bible／空人物、Writer 或 Extractor 活动阻断请求，也不触发、取消、失效任何 SOP job。
- 业务数据只读；唯一允许副作用是现有 `LLMCallAudit` 记录 `inspiration_creator` 的 chapter ID、模型、耗时、token、安全 finish／error 分类及 `job_id=NULL`。不新增表、Chapter 字段、JobRun kind 或 Alembic migration。
- 稳定错误：章／人物 ID 无效为 404／422，未配置 profile 复用 `LLMConfigurationError` 的 409（`details.agent_role=inspiration_creator`），上游／输出错误为安全 `detail={code,message,details}`。保留白名单 http status／finish／block／upstream 分类，不回传 provider 原文、建议或输入。

### 2. 独立角色、上下文与安全日志

- 在 `DEFAULT_PERSONAS`、`PROGRAM_PROTOCOLS`、`AGENT_ROLES`、LLM factory、测试依赖和设置页加入 `inspiration_creator`。seed 新增独立 persona／binding，默认不绑定 Writer profile；模型与 temperature 由该 binding 独立配置，thinking／effort 与 Extractor 一样由程序固定关闭，设置 API 返回真实生效状态。
- 新建确定性 `inspiration_context`，不调用 `MemorySelectorAgent`：只读取同书、此前、finalized 章节的有效 archive 记忆，active v2 优先，其他仅 legacy eligible。不得读取 failed／partial／stale revision、历史正文或再次调用 Extractor。
- 内部只分两种模式：至少两个不同历史章节有有效记忆时为“承接模式”，允许引用真实 source IDs；否则统一进入“自由发想模式”，少量有效历史只作防冲突背景，`history_basis=null`、`source_ids=[]`。零历史、空 Bible、无人选择都不得成为失败条件。
- 上下文按已选人物命中、当前 title／Bible 关键词、章节临近度和稳定 ID 排序并设固定预算；Bible／人物均空时退化为章节临近度和稳定 ID，仍可生成。请求人物为空时只提供空白名单和无人物状态，不暗中扩大到全书人物。
- Prompt 把世界观、人物卡／状态、历史都标为只读材料；历史不能授权人物。已有章节标题是不可改拟的锚点，模型不得生成或建议标题。正文／备注不得使用未选的已知人物；若方向需要新人物，只能在可选备注标明“可能需要新增人物”。
- 成功和失败仅审计／日志 request 或 chapter 标识、尝试数、模型、耗时、卡片数及安全分类；不记录 persona、prompt、Bible、世界观、人物状态、历史片段、卡片文本或 provider message。审计写入失败不影响主结果。

### 3. 卡片协议与程序复检

- 每张公开卡保留兼容字段 `title`、新建议 `body`、可选 `history_basis`、可选 `note`、服务器映射的 `history_chapter_indexes`；`title` 仅由服务器顺序映射为“方向一”至“方向五”，不承载模型创意标题。模型协议不含 `title`。
- `body` 应是介于一句话梗概与正式正文之间的自然连贯章节进程，程序按 body 自身复检 200–300 个去空白字符，目标 220–280 字；固定方向标签、`history_basis` 与 `note` 不计入正文长度，两个可选字段各自不超过 120 字。模型可用若干自然衔接的互动、动作、内心、回忆、梦境、环境或意象场景构思，也可只用一个持续的文学性场景；场景化不是输出模板，不设固定场景数、场景编号或剧情阶段。
- 用户可给一句 `pacing_boundary`，它是剧情、关系和主线的推进硬上限；其中“不／尚未／不要”等否定事项不得反向写成实际事件。未填写时，除非标题或 Bible 明确要求重大跃迁，否则默认只推进最小但有意义的一步。每个 body 最后以自然语句交代本章停在哪里以及仍未说破或解决之处，不输出结构标签。
- `body` 是默认可插入的新建议；`history_basis` 只在有本轮历史 source IDs 时存在，UI 显示“承接既有记录”；`note` 可给风险、新人物或自由提示。内部 source IDs 不返回客户端。
- 后端正常请求固定要求 3 条，公开协议与逐卡校验仍兼容 3–5 条；body 必须为 200–300 字，超过上限时只有在 200–300 字区间存在自然句末才安全裁切，否则拒绝。建议字段不含未选已知人物且无高相似重复；无效或过长的可选备注、历史元数据安全丢弃，只要已有三张有效卡就返回。不足三张才定向修复一次，仍不足时稳定报错；日志只记机器分类，不落卡片文本。

## 已定前端体验

### 1. 共享状态、陈旧结果、采用与撤销

- 新建共享 `InspirationCreatorStore`，与 `ChapterEditorStore` 和 `writingPhase` 分离。每次冻结 chapter／title／Bible／排序后人物选择／可选推进边界快照和 request token；切章或显式“停止本次”仅取消本地等待、丢弃迟到响应，服务端不需要配合取消。
- 打开 sheet、展开右栏或切换“灵感” tab 都是零网络副作用的展示动作；用户只需按需写一句“这一章最多推进到哪里”，再点击“开始找灵感”“重新生成”“按最新内容重想”或“换一批”等明确按钮。等待时只显示 loading，成功显示结果，失败明确显示“生成失败”。
- 用户可在请求中继续编辑。返回时快照变化就显示“基于先前草稿”，首要操作“按最新内容重想”；这两个用户主动操作以及“换一批”直接替换当前临时结果，不再弹确认。一次仅一个在途请求。
- SOP 正在写作／提取时仍可生成和浏览；任何会改 Bible 的“采用”按钮改为不可用并说明“等待本章可编辑后采用”。不得为了采用停止、取消或修改 Writer／Extractor，也不得保存或远端 PATCH。
- 采用只使用 `body`：空 Bible 直接填入，非空 Bible 以两个换行追加；经现有 `editString` 标记未保存并使 Checker 失效。记录仅内存的 before／after，当前 chapter 的 Bible 仍完全等于 after 时给一次“撤销插入”；后续手改、再采用、切章或重载即失效。
- 结果不进入 ChapterDraftCache／UserDefaults／数据库；关闭应用后消失。无人物与空 Bible 是文案提示，绝不是按钮禁用或网络拦截条件。

### 2. iOS：Bible 就近入口 + 可收起 sheet

- 在“本章剧情 BIBLE” section header trailing 加轻量 `sparkles` “找灵感”。不放全局工具栏、不加入流程卡、不把结果常驻塞进 Bible 输入卡。
- 点击只打开可下拉的 large sheet，先显示说明与“开始找灵感”按钮，不读取历史也不请求模型；用户点击按钮后才冻结当前 snapshot 并生成。loading 明示可收起后继续编辑，收起不取消，显式“停止本次”才取消本地等待。空 Bible／无人时显示“可从空白开始发想”的提示并允许生成。
- 结果用单层纵向 ScrollView + divider rows：标题、新建议正文、可选“承接既有记录”／备注、采用状态和撤销。禁止横向轮播、卡片套卡片；300 字长文本必须完整换行，控件不能被挤掉。
- 分别实现 loading、空 Bible、无人、模型未配置、上游／格式错误、陈旧结果、换一批、3／5 条、采用锁定、撤销、VoiceOver 与大字体状态。

### 3. macOS：右侧辅助栏，不遮挡创作

- `MacRightPanel` 新增第四个“灵感” tab。Bible 附近的小入口经 `MacWorkspaceView` 切 tab 并打开现有右栏／drawer，但不会自动请求；用户点击“开始找灵感”后才生成。中央 Bible 保持可编辑，建议在旁对照，不用 modal。
- 灵感 tab 复用同一 Store、语义和单层 divider rows；无章节、空 Bible、无人、loading、error、陈旧及 SOP 锁定采用均有可行动状态，不能留下空白死端。
- 保持现有布局：≥1100 inline；当前 `minWidth=1080`，视觉验证 1080–1099 的 drawer 与 ≥1100 的 inline。保留 <800 抽屉互斥代码，不为本功能改最小窗口；四个分段标签不得溢出。

## 施工阶段、文件范围与验收

1. **后端纯读边界先行（已完成）**
   - 新增 `Backend/app/agents/inspiration_creator.py` 与必要纯 context service；修改 `personas.py`、`llm/factory.py`、`schemas/chapter.py`、`routers/chapters.py`、必要审计接线、`main.py` 版本和测试 fixture。禁止修改 entities、write job、archive service、migration。
   - 后端测试新增 `test_v1_9_inspiration.py`：空／非空 snapshot 均可用且优先于持久 Chapter；空人物可用；有效历史单源与空条件降级排序；人物 ID 所属关系；3–5／300／source／近重复；一次格式修复；配置／上游脱敏；成功和失败均零 JobRun／candidate／revision／业务写入。

2. **共享客户端状态与双端接入（已完成）**
   - 修改 `App/LinoI/LinoModels.swift`、`LinoAPI.swift`、`LinoStores.swift`、`LinoIApp.swift`、`LinoIMacApp.swift`；新增双 target 编译的 `InspirationCreator.swift`。iOS 改 `ChapterEditorViews.swift`；macOS 改 `MacChapterEditor.swift`、`MacWorkspaceView.swift`、`MacRightPanel.swift` 并新增 `MacInspirationTab.swift`。
   - 双端设置改 `SettingsViews.swift`、`MacAgentTab.swift` 和角色中文名，把“四个现役 Agent”更新为“五个”；新增源只更新 `App/LinoI.xcodeproj/project.pbxproj` 的 source membership，绝不改 scheme。
   - Foundation client-state tests 覆盖 response/API、空 snapshot 可请求、快照陈旧、client-only cancel、append、一次撤销和手改失效；SwiftUI 共享改动默认双 target 构建。

3. **版本、门禁与发布（Build 39 已完成）**
   - 全目标／配置 `MARKETING_VERSION=1.9.2`、`CURRENT_PROJECT_VERSION=39`；Backend health/version `1.9.2`。无 migration，Alembic head 保持 `20260809_0011`。
   - 自动门禁：`cd Backend && .venv/bin/python -m pytest -q`、`.venv/bin/python -m alembic heads`、`cd .. && App/Tests/run_client_state_tests.sh`、`git diff --check`、iOS/macOS 串行 Debug build。
   - v1.9.0 已完成 iOS 浅／深色、大字体与 macOS 四 tab、drawer／inline 等视觉验收；v1.9.1 另以隔离假数据验证“第三章／空 Bible／无人物”：主区“找灵感”必然切换右侧灵感页，停在“开始找灵感”，且 LLM 审计数仍为 0。
   - 生产灵感创造师保持独立绑定到 `Deepseek / deepseek-v4-pro`，未复制或耦合 Writer binding；运行时 thinking／effort 固定关闭，设置端显示实际关闭状态。
   - 已按 `NB_info.md` 完成 Build 39 停服备份、integrity／foreign keys／head、单实例、内外网鉴权、真实生成 smoke 与 macOS 签名通用包换装；生产包、备份哈希及验收事实均已同步。回滚只回退代码／客户端，不降 DB。

## 完成定义、风险与下一步

- 完成 = 灵感建议从业务链彻底隔离；空白 Bible／无人也能开始；仅有效历史进入；已有标题不被改拟；3–5 条、每条 body 200–300 字、推进边界、角色和来源边界可程序证明；场景化保持弹性且不退化为一句话梗概；编辑不会被结果覆盖；iOS/macOS 在各自容器清晰可用；自动、构建与生产门禁均有记录。
- 最大风险是把“辅助灵感”做成隐形写作任务，或让异步结果覆盖新的 Bible；先用无业务写入后端测试、snapshot／append／undo 规则封边界，再施工 UI。
- 下一动作：观察 Build 39 的真实写作反馈；iOS 打包与安装仍由用户自行完成。

## 历史索引

- v1.8.3 完成记录：`archive/plans/PROJECT_PLAN-v1.8.3-completed.md`。
- v1.8.1 完整施工与生产验收：`archive/plans/PROJECT_PLAN-v1.8.1-completed.md`。
- 清理前规范与发布流水：`archive/operations/AGENTS-through-2026-08-08.md`。
