# ICTW PROJECT_PLAN

> 唯一现行控制面。仅保留当前状态、已定决策与可施工计划；`archive/` 只保存已完成版本和历史资料，不能作为当前 Builder 指令。

## 当前状态

- 当前源码与宁波 Backend 生产均为 `v1.9.0(35)`，Alembic head `20260809_0011`；本机 macOS 已换装 Build 35，iOS 打包由用户处理；公开客户端仍为 `v1.8.1(32)`。
- v1.8.3 的 Writer／Extractor 生命周期整改、独立 Review 和宁波生产门禁均已完成。历史结论与回滚记录：`archive/plans/PROJECT_PLAN-v1.8.3-completed.md`；生产真相与运维命令仅见仓库外 `/Users/linotsai/Lino/NB_info.md`。
- **v1.9.0（35）灵感创造师**已完成源码施工、本地与生产门禁：后端 158 collected，146 passed／12 skipped；客户端纯逻辑、双 target Build 35 与隔离环境双端视觉验收均通过。无 migration；宁波生产已部署并显式绑定独立 Profile，本机 macOS 已换装。
- 生产验收：内外网鉴权 health `1.9.0`、未鉴权 401、docs 200、SQLite integrity 正常／foreign keys 为空、Alembic `20260809_0011 (head)`、单实例、零重启／warning；数据仍为 3 books／68 chapters／26 characters，非终态任务、未完成 revision 与 writing chapter 均为 0。
- 隔离验收已覆盖空 Bible／无人物、未配置、3／5 条长文、采用、陈旧提示、一次撤销，macOS 1080 抽屉与 1200 并列形态；采用后复查隔离后端，持久化 Bible 仍为空。
- 保留全部既有未提交改动，绝不覆盖、回退或擅自暂存；不触碰未跟踪 `archive/ICTW-Local-Archive/`。受保护的 `App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme` 一律不在范围。

## 不可破坏规则

- 写作链固定为 Memory Selector → Writer → Checker → 用户接受 → Extractor。灵感创造师是只读、手动的侧挂能力，不得进入流程、JobRun、正文候选或 Extractor 生命周期。
- 正文接受与归档独立；Extractor 每 revision 只调用一次，只有完整 v2 结果可激活；partial／failed／stale 不进 Selector、人物故事线或状态投影。
- 人物选择是本章允许出现人物的上限。有效历史不自动授权人物；程序能校验的约束必须程序复检。
- 历史每章只用一个有效来源：active v2 优先，否则仅 legacy eligible；不得自动历史重提、重跑 Extractor 或修改生产历史。
- 生产表结构只经 Alembic，启动不 `create_all`；部署前停服备份并验证 SQLite integrity、foreign keys、head、单实例及公网鉴权健康。
- `thinking`／`effort` 由 capability registry 决定；非思考统一 `top_p=0.95`。日志、审计与 API 不含 API key、persona、prompt、Bible／正文、历史片段、候选或 provider 原文。
- 保持 target／Bundle ID／Keychain／UserDefaults／本地草稿路径及 `chapter_style` 兼容窗口；不暴露 Writer 候选正文或选择接口。

## v1.9.0（35）目标与边界

**目标**：新增内部角色 `inspiration_creator`（“灵感创造师”）。用户手动对当前章节 Bible 求取 3–5 张实质不同的灵感卡；每张总计不超过 300 个去空白字符，结构放松为标题、自由正文、可选历史依据／备注。选择后只加入本地 Bible 草稿，默认不保存、不覆盖。

**读取边界**：客户端当前内存的章节标题、Bible（可以为空）、人物选择（可以为空）；服务端的世界观、已选人物固定卡／章节前投影状态，以及同书此前章节的有效历史。当前临时 snapshot 绝不能被数据库旧字段替代。

**不做**：不调用 Memory Selector、不生成正文、不运行 Checker／Extractor、不创建 JobRun／候选／revision、不写 Chapter／Book／Character／Archive、不保留建议全文、不自动选人物或保存 Bible、不新增 UI 框架。

## 已定后端决策

### 1. 同步、无持久化接口

- 新增鉴权 `POST /chapters/{chapter_id}/inspirations`；请求为 `{title,bible,selected_character_ids}`，响应为 `{cards:[...]}`。它是单次同步、有界 LLM 请求，不入队、不轮询、不提供结果读取或服务端取消端点；格式不合格最多一次修复调用。
- `title`、`bible` 允许为空字符串，`selected_character_ids` 允许空数组。服务端只校验请求类型、ID 去重及所选人物属于当前书；不以空 Bible／空人物、Writer 或 Extractor 活动阻断请求，也不触发、取消、失效任何 SOP job。
- 业务数据只读；唯一允许副作用是现有 `LLMCallAudit` 记录 `inspiration_creator` 的 chapter ID、模型、耗时、token、安全 finish／error 分类及 `job_id=NULL`。不新增表、Chapter 字段、JobRun kind 或 Alembic migration。
- 稳定错误：章／人物 ID 无效为 404／422，未配置 profile 复用 `LLMConfigurationError` 的 409（`details.agent_role=inspiration_creator`），上游／输出错误为安全 `detail={code,message,details}`。保留白名单 http status／finish／block／upstream 分类，不回传 provider 原文、建议或输入。

### 2. 独立角色、上下文与安全日志

- 在 `DEFAULT_PERSONAS`、`PROGRAM_PROTOCOLS`、`AGENT_ROLES`、LLM factory、测试依赖和设置页加入 `inspiration_creator`。seed 新增独立 persona／binding，默认不绑定 Writer profile；模型、thinking／effort／temperature 均由该 binding 独立配置，不套用 Extractor 的关闭 thinking 特例。
- 新建确定性 `inspiration_context`，不调用 `MemorySelectorAgent`：只读取同书、此前、finalized 章节的有效 archive 记忆，active v2 优先，其他仅 legacy eligible。不得读取 failed／partial／stale revision、历史正文或再次调用 Extractor。
- 上下文按已选人物命中、当前 title／Bible 关键词、章节临近度和稳定 ID 排序并设固定预算；Bible／人物均空时退化为章节临近度和稳定 ID，仍可生成。请求人物为空时只提供空白名单和无人物状态，不暗中扩大到全书人物。
- Prompt 把世界观、人物卡／状态、历史都标为只读材料；历史不能授权人物。建议标题／正文／备注不得使用未选的已知人物；若方向需要新人物，只能在可选备注标明“可能需要新增人物”。
- 成功和失败仅审计／日志 request 或 chapter 标识、尝试数、模型、耗时、卡片数及安全分类；不记录 persona、prompt、Bible、世界观、人物状态、历史片段、卡片文本或 provider message。审计写入失败不影响主结果。

### 3. 卡片协议与程序复检

- 每张公开卡是 `title`、新建议 `body`、可选 `history_basis`、可选 `note`、服务器映射的 `history_chapter_indexes`。这是宽松表达，不增加标题硬上限、固定剧情栏、类别栏或字数配额；唯一内容上限是四个文本字段合计去空白字符 ≤300。
- `body` 是默认可插入的新建议；`history_basis` 只在有本轮历史 source IDs 时存在，UI 显示“承接既有记录”；`note` 可给风险、新人物或自由提示。内部 source IDs 不返回客户端。
- 后端复检：3–5 条、title／body 非空、总字符数 ≤300、history basis 与有效 source IDs 成对、source 仅来自本轮上下文、建议字段不含未选已知人物、归一化标题／正文无相同或高相似重复。两次不合格后稳定报 `inspiration_invalid_response`，不落任何卡片文本。

## 已定前端体验

### 1. 共享状态、陈旧结果、采用与撤销

- 新建共享 `InspirationCreatorStore`，与 `ChapterEditorStore` 和 `writingPhase` 分离。每次冻结 chapter／title／Bible／排序后人物选择快照和 request token；切章或显式“停止本次”仅取消本地等待、丢弃迟到响应，服务端不需要配合取消。
- 用户可在请求中继续编辑。返回时快照变化就显示“基于先前草稿”，首要操作“按最新内容重想”；这两个用户主动操作以及“换一批”直接替换当前临时结果，不再弹确认。一次仅一个在途请求。
- SOP 正在写作／提取时仍可生成和浏览；任何会改 Bible 的“采用”按钮改为不可用并说明“等待本章可编辑后采用”。不得为了采用停止、取消或修改 Writer／Extractor，也不得保存或远端 PATCH。
- 采用只使用 `body`：空 Bible 直接填入，非空 Bible 以两个换行追加；经现有 `editString` 标记未保存并使 Checker 失效。记录仅内存的 before／after，当前 chapter 的 Bible 仍完全等于 after 时给一次“撤销插入”；后续手改、再采用、切章或重载即失效。
- 结果不进入 ChapterDraftCache／UserDefaults／数据库；关闭应用后消失。无人物与空 Bible 是文案提示，绝不是按钮禁用或网络拦截条件。

### 2. iOS：Bible 就近入口 + 可收起 sheet

- 在“本章剧情 BIBLE” section header trailing 加轻量 `sparkles` “找灵感”。不放全局工具栏、不加入流程卡、不把结果常驻塞进 Bible 输入卡。
- 点击打开可下拉的 large sheet 并以当前 snapshot 立即生成；loading 明示可收起后继续编辑，收起不取消，显式“停止本次”才取消本地等待。空 Bible／无人时显示“可从空白开始发想”的提示并照常生成。
- 结果用单层纵向 ScrollView + divider rows：标题、新建议正文、可选“承接既有记录”／备注、采用状态和撤销。禁止横向轮播、卡片套卡片；300 字长文本必须完整换行，控件不能被挤掉。
- 分别实现 loading、空 Bible、无人、模型未配置、上游／格式错误、陈旧结果、换一批、3／5 条、采用锁定、撤销、VoiceOver 与大字体状态。

### 3. macOS：右侧辅助栏，不遮挡创作

- `MacRightPanel` 新增第四个“灵感” tab。Bible 附近的小入口经 `MacWorkspaceView` 切 tab 并打开现有右栏／drawer；中央 Bible 保持可编辑，建议在旁对照，不用 modal。
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

3. **版本、视觉与发布（已完成）**
   - 全目标／配置 `MARKETING_VERSION=1.9.0`、`CURRENT_PROJECT_VERSION=35`；Backend health/version `1.9.0`。无 migration，Alembic head 保持 `20260809_0011`。
   - 自动门禁：`cd Backend && .venv/bin/python -m pytest -q`、`.venv/bin/python -m alembic heads`、`cd .. && App/Tests/run_client_state_tests.sh`、`git diff --check`、iOS/macOS 串行 Debug build。
   - 视觉验收：iOS 浅／深色、大字体、空 Bible／无人、sheet 收起继续编辑、长文本、陈旧与采用锁定；macOS 四 tab、1080–1099 drawer、≥1100 inline、长文本、键鼠和辅助功能。
   - 发布前已在测试／本地验证独立 binding；生产已把灵感创造师独立绑定到 `Deepseek / deepseek-v4-pro`，关闭思考、temperature `0.8`，首次点击不会落到未配置状态。
   - 已按 `NB_info.md` 完成停服、备份、integrity／foreign keys／head、单实例重启和内外网鉴权 health `1.9.0`；生产包、备份哈希与验收事实已同步到仓库外运维记录。回滚只回退代码／客户端，不降 DB。

## 完成定义、风险与下一步

- 完成 = 灵感建议从业务链彻底隔离；空白 Bible／无人也能开始；仅有效历史进入；3–5 条、≤300、角色和来源边界可程序证明；编辑不会被结果覆盖；iOS/macOS 在各自容器清晰可用；自动、构建、视觉和生产门禁都有记录。
- 最大风险是把“辅助灵感”做成隐形写作任务，或让异步结果覆盖新的 Bible；先用无业务写入后端测试、snapshot／append／undo 规则封边界，再施工 UI。
- 下一动作：iOS 打包与安装由用户自行完成；项目暂无未完成施工项，下一版本目标由后续需求确定。

## 历史索引

- v1.8.3 完成记录：`archive/plans/PROJECT_PLAN-v1.8.3-completed.md`。
- v1.8.1 完整施工与生产验收：`archive/plans/PROJECT_PLAN-v1.8.1-completed.md`。
- 清理前规范与发布流水：`archive/operations/AGENTS-through-2026-08-08.md`。
