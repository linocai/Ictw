# LinoI PROJECT_PLAN

> 本文件是项目唯一权威计划入口。历史 plan 全文在 `archive/`。

## 概述

LinoI 是单人小说写作工作台：SwiftUI iOS App + FastAPI 后端。核心是四 Agent 写作链——Memory Selector（按本章 Bible 从大事记/梗概/人物事件中选记忆 ID）→ Writer（白名单约束下流式写初稿）→ Reviser(仅程序校验不合格时修订，最多两次)→ 用户接受 → Extractor（只归档已选人物）。数据库负责记得全，Writer Prompt 只保留当前工作集。

## 技术选型

- **App**：SwiftUI（iOS），无第三方依赖；Token 存 Keychain，本地草稿缓存在 Application Support。
- **后端**：FastAPI + SQLAlchemy 2 + Alembic + SQLite，单 worker uvicorn；LLM 走 OpenAI-compatible 协议，capability registry 管推理参数（DeepSeek V4 Pro/Flash、Gemini 3.5 Flash、未知模型）。
- **部署**：HK 云服务器，Nginx HTTPS 反代 → 127.0.0.1:8787，systemd `linoi-backend.service`。详情见 `~/Lino/hk_info.md`。

## 当前状态（2026-07-11）

- v1.0.0 已发版上线，云端健康检查正常；Alembic head `20260710_0002`。
- 线上数据：2 本书、23 章、11 个人物；仓库从 https://github.com/linocai/Ictw 克隆。
- 后端 31 个测试全绿（本地新克隆验证过）；`chapter_style` 兼容窗口仍开着（本轮不收口）。
- v1.1.1 已发版上线（绑定级 temperature）；Alembic head `20260711_0004`；后端 52 测试全绿。
- v1.1.2 已发版上线（删章回滚人物动态字段，迁移 `20260711_0005`）；iOS 版本 1.1.2(4)。
- v1.2.0 立项（2026-07-11）：新增 macOS App（target `LinoIMac`，Bundle `com.lino.linoi.mac`），功能与 iOS 完全对等；同一 `App/LinoI.xcodeproj` 手工加 macOS target，共享数据层，桌面三栏 UI 只借鉴 `Archive/LinoWritingV2` 的样式与交互结构（语义一律本项目为准）。不动后端。详见「当前 Plan」。

## 当前 Plan

### v1.2.0 — macOS App（与 iOS 完全对等）

**目标**：在同一 `App/LinoI.xcodeproj` 内新增原生 SwiftUI macOS target，复用现有数据层与写作链，桌面端做三栏工作台 + 沉浸阅读。硬约束：**iOS 有的功能 macOS 必须都有**（对等清单见附录 A）；**iOS 回归不破坏**；**不改后端**（双端并发 409 是已知 P2，Mac 端只做友好呈现，不接管任务）。

**技术选型（定死，不留给 build 决定）**
- 单工程双 target：新 target `LinoIMac`，产物 `LinoIMac.app`，Bundle ID `com.lino.linoi.mac`，`SDKROOT=macosx`、`MACOSX_DEPLOYMENT_TARGET=26.0`、`SWIFT_VERSION=6.0`、`DEVELOPMENT_TEAM=HX73DFL88G`、`CODE_SIGN_STYLE=Automatic`、`ENABLE_HARDENED_RUNTIME=YES`、`GENERATE_INFOPLIST_FILE=NO`。手工改 `project.pbxproj`（objectVersion 71，沿用现有友好 ID 风格，Mac 侧用 `B00000000000000000000xxx` 段），不引入 xcodegen。
- 沙盒 entitlements：`com.apple.security.app-sandbox` + `com.apple.security.network.client` + `com.apple.security.files.user-selected.read-write`（导出存盘用）。
- macOS 桌面 UI 全部**新写**（三栏、自绘标题栏、hover、⌘ 快捷键、NSTextView 阅读排版），只从 `Archive/LinoWritingV2/App/LinoWriting/` 借样式与布局结构；iOS 的 14 个 View 文件不复用到 Mac，也不改动其行为。
- 生成流程：**复用 `ChapterEditorStore` 轮询状态机**（`GET /chapters/{id}/job` 每 2.5s，`WritingPhase` 状态机），**不做假打字机**；后端非流式，正文只在 `phase==done` 落 `draftText`，写作中只显示 phase pill + spinner + 上一版预览（与 iOS 一致）。
- 版本：iOS 与 macOS 两 target 同抬 `MARKETING_VERSION=1.2.0`、`CURRENT_PROJECT_VERSION=5`（共享层动过，iOS 需重编回归，故一并升版）。

**共享边界（唯一权威分类）**
- **双端编译（7 个文件，`App/LinoI/` 原地，同时挂进两个 target 的 Sources）**：`LinoStores.swift`、`LinoAPI.swift`、`LinoModels.swift`、`ChapterDraftCache.swift`、`NoticeBus.swift`（含 `LinoIToast`，跨平台）、`LinoTheme.swift`（`glassEffect` 在 macOS 26 可用）、`LinoComponents.swift`（去 iOS 化后共享，见块①）。核对结论：前 6 个已零 iOS 依赖，只有 `LinoComponents.swift` 有 4 处 iOS API 需处理。
- **iOS-only（留在 LinoI target，不进 Mac target，无需改）**：`LinoIApp.swift`、`ShelfViews.swift`、`WorkspaceViews.swift`、`ChapterEditorViews.swift`、`CharactersViews.swift`、`SettingsViews.swift`、`ReadingViews.swift`。它们的 iOS-only modifier（`navigationBarTitleDisplayMode`/`presentationDetents`/`.topBarTrailing` 等）因不在 Mac target 编译，**一律不用动**。
- **macOS-only（新建，仅进 Mac target，放 `App/LinoIMac/`）**：见各块新文件清单。

---

#### 块① pbxproj 加 target + 共享层去 iOS 化 + 双 target 编译通过

**改现有文件**
- `App/LinoI/LinoComponents.swift`（4 处，最小改动）：
  1. 顶部 `import UIKit`（L2）→ `#if canImport(UIKit)\nimport UIKit\n#endif`。
  2. `ActivityView`（L197–207，`UIViewControllerRepresentable`）整体包 `#if os(iOS)`（Mac 导出改走块④的 `MacExportSaver`）。
  3. `LinoISecureField` 的 `.textInputAutocapitalization(.never)`（L102）包 `#if os(iOS)`（`.autocorrectionDisabled()` 跨平台，保留）。
  4. `LinoINumberField` 的 `.keyboardType(.numberPad)`（L123）包 `#if os(iOS)`。
- `App/LinoI.xcodeproj/project.pbxproj`（手写）：
  - 新增 `PBXGroup "LinoIMac"`（指向 `App/LinoIMac/`）。
  - 新增 `PBXNativeTarget "LinoIMac"`（productType application），自带 Sources / Frameworks / Resources 三个 build phase。
  - Mac 的 Sources phase：为 **7 个共享文件各建一个新的 `PBXBuildFile`**（复用同一 fileRef，新 uuid）挂入；再挂 Mac-only 新文件（块①–⑤陆续加）。
  - 新增 `LinoIMac` 的 Debug/Release `XCBuildConfiguration` 与 `XCConfigurationList`；关键 buildSettings：`SDKROOT=macosx`、`MACOSX_DEPLOYMENT_TARGET=26.0`、`PRODUCT_BUNDLE_IDENTIFIER=com.lino.linoi.mac`、`MARKETING_VERSION=1.2.0`、`CURRENT_PROJECT_VERSION=5`、`INFOPLIST_FILE=LinoIMac/Info.plist`、`CODE_SIGN_ENTITLEMENTS=LinoIMac/LinoIMac.entitlements`、`CODE_SIGN_STYLE=Automatic`、`DEVELOPMENT_TEAM=HX73DFL88G`、`ENABLE_HARDENED_RUNTIME=YES`、`GENERATE_INFOPLIST_FILE=NO`、`SWIFT_VERSION=6.0`、`ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`、`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`（Debug）。
  - 在 `PBXProject.targets` 与 `TargetAttributes` 注册新 target；iOS 两个 config 的 `MARKETING_VERSION` 改 `1.2.0`、`CURRENT_PROJECT_VERSION` 改 `5`。
  - 在 `App/LinoI.xcodeproj/xcshareddata/xcschemes/` 建共享 scheme `LinoIMac.xcscheme`（xcodebuild 按名字找 scheme）。

**新文件（`App/LinoIMac/`）**
- `Info.plist`（`CFBundleDisplayName=LinoI`、`LSMinimumSystemVersion=$(MACOSX_DEPLOYMENT_TARGET)`、`NSPrincipalClass=NSApplication`、`ITSAppUsesNonExemptEncryption=false`）。
- `LinoIMac.entitlements`（上述三项沙盒）。
- `Assets.xcassets`（macOS `AppIcon` 图标集，可由现有 1024 生成；`AccentColor` 复用色值）。
- `LinoIMacApp.swift`：`@main`，与 `LinoIApp` 一样用 `init()` 建 `NoticeBus/AppSession/BookshelfStore/WorkspaceStore/CharactersStore/ChapterEditorStore/AgentSettingsStore` 并注入；再注入 macOS-only 的 `MacCommandBus`（块⑤）。`WindowGroup { MacShell() }` + `.frame(minWidth:1080,minHeight:720)` + `.windowStyle(.hiddenTitleBar)` + `.windowResizability(.contentMinSize)` + `.task { await session.bootstrap(); await bookshelf.load() }`。本块先放一个占位 `MacShell`（只显示一块玻璃面板），后续块替换。commands 块⑤补。
- `MacShell.swift`：占位版（块③补全状态机）。

**关键决策**：`LinoComponents.swift` 提升为第 7 个共享文件（iOS 设计系统直接复用到 Mac，视觉统一）；`ActivityView` 仅 iOS 编译，Mac 用 save panel。Keychain service 仍是 `LinoI`——iOS 与 Mac 是不同沙盒容器，**不共享 token**，Mac 需各自配一次连接（预期行为，附录 B 注明）。

**验收**：两条命令都要过。
```
# macOS 新 target 编译通过
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoIMac \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
# iOS 回归编译通过（去 iOS 化不破坏 iOS）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoI \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

---

#### 块② 设计系统与组件移植（桌面玻璃 + 交互控件）

**新文件（`App/LinoIMac/`，全部 macOS-only）**
- `LinoMacTheme.swift`：port `LWMetrics` → `LinoMacMetrics`（`sidebarWidth 258`、`rightPanelWidth 326`、`contentMaxWidth 720`、`shelfMaxWidth 1080`、窗口 min `1080×720`、default `1280×840`、`cardRadius 14`、`controlRadius 10`、hairline `rgba(40,45,70,0.10)`）。View 扩展 `.linoToolbarGlass()`/`.linoSidebarGlass()`/`.linoPanelGlass()`（port `LiquidGlass.swift` 的 `glassEffect(.regular,in:)` + 顶部 1px 高光 + 0.5px 描边），色值取 `LinoTheme`。
- `LinoMacControls.swift`：`LinoMacIconButton`（hover 变 `NSCursor.pointingHand`、可设 size/fontSize/help）、`LinoMacSegmented`（玻璃分段控件，供右栏 tab / 正文预览-编辑切换）、`pointer(_:)` hover helper、`LinoMacConnectionChip`（连接状态点：未配置/已连接/未连接，探测方式=一次 `session.api.request("/books")`，2xx→已连接、401→token 失效、transport error→未连接；复用现有授权调用，不假设 health 路径）。
- 状态徽标复用共享 `LinoIStatusPill`（已含 `numericText` 动画，无需再 port 老项目 StatusBadge）。

**关键决策**：桌面「工具栏/侧栏/面板」三档玻璃亮度差异化（对齐老项目 lwToolbar/lwSidebar/lwPanel），但底座是共享 `LinoTheme` 色，避免依赖 macOS-only 主题文件（老项目 CLAUDE.md 的跨平台色值坑）。

**验收**：`LinoIMacApp` 临时页放几个 `LinoMacIconButton`/分段控件/三档玻璃面板 + 一个 `LinoIStatusPill`，`xcodebuild -scheme LinoIMac ... build` 通过，Xcode 预览或 Run 起来玻璃/描边/hover 正常。

---

#### 块③ 书架 + 首启连接配置

**新文件（`App/LinoIMac/`）**
- `MacShell.swift`（补全）：单窗状态机 ZStack——`session.token.isEmpty` → `MacConnectionView(firstRun:true)`；否则 `session.currentBook == nil` → `MacBookshelfView`；否则 `MacWorkspaceView`（块④）。reader overlay（块⑤）叠在 ZStack 顶层；settings sheet（块⑤）由 `MacCommandBus.showSettings` 驱动。底部叠共享 `LinoIToast`。
- `MacBookshelfView.swift`：书卡网格（`LinoTheme.coverGradient(book.id)`、hover 上浮 3px、书名/章数/人物数/相对时间）、"新建书"虚线卡、顶部连接状态条（`LinoMacConnectionChip` + baseURL）、右上 ⚙（开 settings）。删除：`contextMenu` + `confirmationDialog`（macOS 可用）。复用 `BookshelfStore.load/createBook/open/delete`。
- `MacNewBookSheet.swift`：`LinoITextField` 书名 + 创建（`bookshelf.createBook` 后自动 `open`）。
- `MacConnectionView.swift`：首启 + ⌘, 连接段共用——baseURL（`LinoITextField`）+ token（`LinoISecureField`）+ 保存（`session.baseURL/token` → `session.saveConnection()` → `bookshelf.load()`）。首启态多一句引导文案。

**验收**：token 空→首启连接页；填 baseURL+token 保存→书架列出线上书；新建/打开/删除（含确认）均生效；`xcodebuild -scheme LinoIMac` 与 iOS 回归双绿。

---

#### 块④ 三栏工作台（章节编辑器三阶段 + 右栏 人物/设定/Agent）

**新文件（`App/LinoIMac/`）**
- `MacWorkspaceView.swift`：`GeometryReader` reflow——`≥1100` 三栏并列；`800–1100` 右栏收成工具栏切换的抽屉；`<800` 左侧栏也收抽屉。自绘标题栏（46 高 `.linoToolbarGlass` + `.hiddenTitleBar` 已在 App 层保证不被原生栏压洗）：左「写作台」logo chip（点回书架）、居中书名、右侧 `LinoMacConnectionChip` + ⚙ + 抽屉开关。body row：`MacChapterSidebar | MacChapterEditor | MacRightPanel`。选中章节用本视图 `@State selectedChapterId`（不动共享 store），变化时 `await editor.load(summary)`。
- `MacChapterSidebar.swift`：章节列表（序号封面块 + 标题 + `LinoIStatusPill`），顶部"新建章节"（`workspace.createChapter`，⌘⇧N）。复用 `WorkspaceStore.chapters`。
- `MacChapterEditor.swift`：三阶段——① 标题/剧情 Bible/目标字数/作者备注（`LinoITextField`/`LinoIEditor`/`LinoINumberField`）；② 允许人物 chips（`FlowLayout` + 选中态，文案写明"选择=允许出现上限，被提及也算出现"）；③ 正文（`LinoMacSegmented` 预览/编辑，`LinoIDraftPreview`）+ 生成/停止/接受/重开 + 豁免重试 prompt + 导入正文 sheet + 字数（`editor.draftCharCount`，去空白）+ status/phase 双 pill。Extractor 结果段（headline `LinoITextField` + summary `LinoIEditor`，可编辑保存）。删除本章（menu + `confirmationDialog`，finalized 与 draft 两套文案照 iOS）。"阅读"按钮 → 开 reader overlay。**全部复用** `ChapterEditorStore` 的 `generate/accept/cancelWriting/reopen/exemptAndRetry/importDraft/save`，不新增写作逻辑。
- `MacRightPanel.swift`：`LinoMacSegmented` 三 tab = 角色 / 书设定 / Agent。
  - `MacCharacterTab.swift`：人物 chips 横向选择 + 选中卡（姓名/身份/固定设定可编辑；动态字段只读；故事线 events 单条增/改/删）+ 新建/导入人物卡 + 删除人物。复用 `CharactersStore` 全套。
  - `MacBookSettingsTab.swift`：书名 + 世界观 editor + 保存（`workspace.saveBook`）+ 导出全书 `.txt`（走 `MacExportSaver`）。
  - `MacAgentTab.swift`：LLM Profiles（增/改/删/测）+ Agent 绑定（模型 Picker / 启用思考 Toggle / 思考强度 Picker / temperature 滑杆 0–2，按 `temperatureAdjustable` 置灰，同 iOS 的 capability 语义）+ Agent 人格（编辑/恢复默认）。复用 `AgentSettingsStore` 全套。
- `MacExportSaver.swift`：`NSSavePanel` 存 `.txt`（替代 iOS `ActivityView`），数据取 `session.api.rawRequest("/books/{id}/export.txt")`。

**关键决策**：右栏三 tab 直接满足任务要求的「人物/设定/Agent」；书设定里的导出、Agent 里的模型/人格全部到位，功能对等不靠 ⌘, 兜底（⌘, 只放连接）。并发 409（`write_running` 等）：`applyStartFailure` 已把结构化错误经 `NoticeBus` 弹 Toast——Mac 端只需保证不崩、把消息呈现出来，不接管已有任务（对齐 iOS P2#5）。

**前台/启动恢复轮询（重点，绕开 iOS P2#3 同类坑）**
- iOS 靠 `scenePhase.active → handleScenePhaseActive()`，但该方法有 `status==writing/extracting` 的前置守卫，本会话内启动的任务因本地 `status` 不刷新而漏网（Backlog P2#3）。
- macOS **不复制这个守卫**：在 `ChapterEditorStore` 新增 macOS 专用方法 `func refreshActiveJobIfNeeded()`——若有 `currentChapter` 且当前非 active，则**无条件**发一次 `jobStatus(chapterId:)`，`applyJobStatus` 后若非终态就 `pollJob`。此方法**只被 macOS 调用**（iOS 行为零变化，无回归）。
- `MacWorkspaceView` 用 `.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))`（`import AppKit`）触发它；切换侧栏选中章节时 `editor.load` 已自带 stale-poll 收尾，无需额外处理。

**验收**：三栏渲染 + 三档 reflow 随窗宽切换；对真实后端跑通 生成→轮询→待接受→接受→提取→已完成 全链；停止/重开/豁免重试生效；字数=去空白；删章文案正确；右栏三 tab 全功能；把 App 切后台再切回，写作中任务能自动续查（不靠冷启动）；`xcodebuild -scheme LinoIMac` 与 iOS 回归双绿。

---

#### 块⑤ 阅读模式 + 设置 + 快捷键 + 收尾验证

**新文件（`App/LinoIMac/`）**
- `MacReaderView.swift`：全窗 overlay 阅读页。正文用 `NSTextView`（`NSViewRepresentable`）宋体两端对齐——`firstLineHeadIndent = fontSize*2`、`lineHeightMultiple = 2.05`、`paragraphSpacing = fontSize*1.5`（port 老 `ReaderView` 的 `ReaderBodyText`，macOS 稳定可搬）。字号 `@AppStorage` 阶梯 `[18,19,20,21,23]` A−/A+（≥ iOS 三档，属超集，允许）；相邻 **finalized** 章 in-place 翻页（按 id 重载）；退出回编辑态。三主题（day/sepia/night 整窗变色，port `ReadingTheme`）作为附带 polish 一并搬。
- `MacSettingsSheet.swift`：⌘, 打开的 sheet，内嵌 `MacConnectionView(firstRun:false)`（连接段）。首启连接与它共用 `MacConnectionView`。
- `MacCommandBus.swift`：macOS-only `ObservableObject`（`showNewBook`/`showNewChapter`/`showSettings` 三个 `@Published`）；`LinoIMacApp` 注入，`MacShell`/`MacBookshelfView`/`MacChapterSidebar` 监听触发对应 sheet/动作。避免动共享 store。
- `LinoIMacApp.swift`（补 commands）：`.commands { CommandGroup(replacing: .appSettings){ 设置... ⌘, } ; CommandGroup(replacing: .newItem){ 新建书 ⌘N ; 新建章节 ⌘⇧N（`currentBook==nil` 时 disabled） } }`。

**关键决策**：`.windowStyle(.hiddenTitleBar)` 必须保留（老项目坑：不隐藏则原生工具栏压洗自绘标题栏）。`LWTextArea` 夺焦那类坑本期用共享 `LinoIEditor`（SwiftUI `TextEditor`）规避，不 port 老的 AppKit 文本域。

**验收**：finalized 章进阅读页宋体两端对齐正确、字号持久化、相邻 finalized 翻页、退出回编辑；⌘N/⌘⇧N/⌘, 均生效且 ⌘⇧N 无书时禁用；窗口 min 1080×720、自绘标题栏不被压洗；critical Toast 常驻；**附录 A 对等清单逐项勾**；最终 `xcodebuild -scheme LinoIMac` 与 iOS 回归双绿；连真实后端手测主流程通。

---

**版本与变更日志占位**
- 两 target `MARKETING_VERSION=1.2.0`、`CURRENT_PROJECT_VERSION=5`。
- 收尾后在「变更日志」补一条 v1.2.0 发版记录（macOS 上线 + iOS 随共享层改动重编），本 plan 移入 `archive/v1.2.0施工plan.md`。

---

**附录 A — iOS 功能对等 checklist（验收逐项勾）**
1. [ ] 书架：书卡网格 + 新建书 + 删书确认 + 连接状态条
2. [ ] 首启连接配置：baseURL + Bearer Token 存 Keychain
3. [ ] 工作台入口四区可达：章节（左栏）/ 人物 / 设定 / Agent（右栏三 tab 覆盖后三者）
4. [ ] 章节编辑①：标题 / 剧情 Bible / 目标字数 / 作者备注
5. [ ] 章节编辑②：允许人物 chips，上限语义（被提及也算出现）
6. [ ] 章节编辑③：正文 预览/编辑 + 生成 / 停止 / 接受 / 重开
7. [ ] 豁免重试（未授权人物 → 本章豁免并重试）
8. [ ] 导入正文
9. [ ] Extractor 结果：headline / summary 可编辑保存
10. [ ] 删除章节：finalized 与 draft 两套确认文案
11. [ ] 人物卡：固定设定可编辑 / 动态字段只读 / 故事线 events 单条增删改
12. [ ] 新建人物 + 导入人物卡 + 删除人物
13. [ ] 书设定：书名 / 世界观 / 导出全书 .txt
14. [ ] 设置-连接：baseURL / token（⌘, 或右栏）
15. [ ] LLM Profile：增 / 删 / 改 / 测
16. [ ] AgentModelBinding：模型 Picker / 思考 Toggle / 强度 Picker / temperature 滑杆 0–2 按 `temperature_adjustable` 置灰
17. [ ] Agent 人格：编辑 / 恢复默认
18. [ ] 阅读模式：宋体 + 字号档位 AppStorage + 相邻 finalized 翻页
19. [ ] Toast：critical 常驻可手动关
20. [ ] 本地草稿缓存自动生效（`ChapterDraftCache`）
21. [ ] 写作状态机：selectingMemory/writing/revising(attempt)/extracting/failed 呈现 + 字数=去空白 + 前台恢复轮询

**附录 B — 用户手动操作清单（Xcode GUI / 网页，agent 办不了）**
- 首次为新 Bundle ID 签名：Xcode 选 `LinoIMac` target → Signing & Capabilities → 确认 Automatic + Team `HX73DFL88G`，让 Xcode 生成 macOS 开发签名；若自动失败，去 https://developer.apple.com/account/resources/identifiers/list 确认/注册 App ID `com.lino.linoi.mac`。
- 首次运行：Keychain 访问弹窗点「始终允许」（app 读写 service=`LinoI` 的 token；Mac 与 iOS 沙盒隔离，需在 Mac 上**重新填一次** baseURL + Bearer Token）。
- 分发（Developer ID / 公证）不在本期范围；本期只需本机 Run + 双 target xcodebuild 编译通过。

## Backlog

**产品/功能（v1 明确延后项）**
- 向量数据库 / embedding 记忆检索（预筛接口已预留）
- 用户手动 pin/强制选择某条历史记忆
- 人物别名字段及别名级未授权人物扫描
- 跨供应商模型 fallback
- 对后续章节自动重新提取 / 重建记忆
- 每本书单独配置记忆预算公式
- PostgreSQL 迁移、多 worker 分布式写作任务

**技术债**（含 2026-07-11 v1.1.0 review 的 P2 遗留）
- `chapter_style` 兼容字段收口（新 App 验证后）
- capability registry 扩充（Qwen、Claude、Kimi 等）
- 短名整词匹配的可选轻量分词方案（提升 2 字名精度；1 字名左边界启发式对 CJK 扩展区/々等罕用前字有漏判，一并解决）
- LLM 审计表的查询/统计入口（当前仅落库，靠直连 DB 查看）
- iOS：本会话内启动任务后 currentChapter.status 不更新为 writing/extracting，前台恢复轮询的安全网只对冷启动生效（review P2#3）
- iOS：write_running 等 409 呈现为 failed，未接管已有任务（review P2#5）
- job_runs「最新一行」并列打破用随机 uuid，可换单调次键（review P2#6）
- write_registry 为进程内单例，未来多 worker 前必须换 DB 层 job 锁（review P2#7，前瞻）
- 阅读模式增强（书签、朗读、翻页动画等）

**运维/安全（hk_info.md §12 有排序清单）**
- 云端安全整改：关 root 密码登录、UFW、Fail2ban、服务降权、systemd 加固
- 每日自动备份 + 异地副本（当前仅一份人工备份且同盘）
- 安全更新 + 重启、NTP 修复、加 swap、Nginx 限流与 /docs 收口

## 变更日志

- 2026-07-10 v1.0.0 发版：四 Agent 链、记忆选择、Reviser 两次上限、Extractor 权限收口、推理参数配置、删除章节。（施工全文见 archive/v1发版施工plan.md）
- 2026-07-10 仓库从 GitHub 克隆重建本地工作区；恢复 Backend/.env；建立 PROJECT_PLAN.md 与项目 CLAUDE.md，v1 施工 plan 移入 archive/。
- 2026-07-10 v1.1.0 立项：去流式 + 任务持久化（job_runs）、accept 异步化、字数放宽 80%~120%、记忆预算固定常量 + summary≤2、短名校验修复 + 章级豁免、LLM 审计表、单条人物事件接口、ChapterPatch 放开 summary/headline、事件 60 字上限；iOS 去流式轮询、阅读模式、新建直进、章节行简化、故事线增删改、梗概可编辑、导出全书、删书。（施工全文见 archive/v1.1.0施工plan.md）
- 2026-07-10 v1.1.0 施工完成并验证：后端 45 测试全绿、iOS xcodebuild 通过、前后端契约交叉检查通过、本地全新建库迁移链 + API 冒烟通过；iOS 版本抬到 1.1.0(2)。本机新生成部署密钥并完成服务器授权与主机键核验（见 hk_info.md）。
- 2026-07-11 快修上线：Memory Selector 返回非法/截断记忆 ID 不再导致整次写作失败（跳过 + 唯一前缀救回 + Prompt 加固，commit 5ff703b）；真机实报 bug，当日修复部署。
- 2026-07-11 独立 review 完成：无 P0/P1，7 条 P2。当日修掉 P2#1（memory selector 对非数组/非串 memory_ids 降级为过滤/空选择，不再炸写作）与 P2#2（CLAUDE.md 字数区间订正为 80%~120%）；其余 P2 归入 Backlog 技术债。
- 2026-07-11 v1.1.1 发版：AgentModelBinding 新增 temperature 设置（迁移 20260711_0004）。语义=「请求实际会携带 temperature 才可调」：DeepSeek 关思考时可调、未知模型恒可调、Gemini 恒锁；开思考自动清 temperature（与关思考清 effort 对称）；范围 0.0~2.0。iOS 绑定卡新增滑杆 + 模型默认复位，按 temperature_adjustable 置灰；版本 1.1.1(3)。
- 2026-07-11 v1.1.2 发版：修复「删除章节不回滚人物动态字段」。新表 character_field_patches（迁移 20260711_0005）记录每章改了哪些键及改前值；删除章节逐键回滚——被更晚章节覆盖的键以晚章为准，本章新增的键直接移除；重新接受保留最初的改前基线。iOS 删除确认文案同步更新，版本 1.1.2(4)。
- 2026-07-11 v1.2.0 立项：macOS App（target LinoIMac，Bundle com.lino.linoi.mac）与 iOS 完全对等。五块施工——①加 macOS target + 共享层去 iOS 化（仅 LinoComponents.swift 4 处）②桌面玻璃设计系统与控件移植 ③书架＋首启连接 ④三栏工作台（章节编辑器三阶段＋右栏人物/设定/Agent，复用 ChapterEditorStore 轮询、macOS 前台无条件续查绕开 P2#3）⑤阅读模式（NSTextView 宋体两端对齐）＋⌘快捷键＋设置＋收尾。不改后端。施工 plan 见「当前 Plan」，完成后补发版记录并移入 archive/。
- 2026-07-11 v1.2.0 块① 完成：手工改 project.pbxproj（objectVersion 71，Mac 侧对象用 B000… 段）新增 LinoIMac native target（application，SDKROOT=macosx、MACOSX_DEPLOYMENT_TARGET=26.0、Bundle com.lino.linoi.mac、沙盒 entitlements），7 个共享文件（LinoStores/LinoAPI/LinoModels/ChapterDraftCache/NoticeBus/LinoTheme/LinoComponents）各建新 PBXBuildFile 复用现有 fileRef 挂进 Mac Sources；新建 App/LinoIMac/（Info.plist、entitlements、Assets、LinoIMacApp @main、MacShell 占位）与共享 scheme LinoIMac.xcscheme。LinoComponents.swift 去 iOS 化 4 处（import UIKit→canImport、ActivityView→#if os(iOS)、textInputAutocapitalization/keyboardType→#if os(iOS)）。iOS 与 macOS 两 target 同抬 MARKETING_VERSION=1.2.0、CURRENT_PROJECT_VERSION=5。验收：macOS scheme LinoIMac build + iOS scheme LinoI 回归 build 双绿。
