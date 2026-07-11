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
- v1.2.0 块①②③④已完成（块①加 target、块②桌面玻璃设计系统与控件、块③书架＋首启连接、块④三栏工作台），块⑤（阅读模式＋⌘快捷键＋设置 sheet＋收尾）待做。

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
1. [x] 书架：书卡网格 + 新建书 + 删书确认 + 连接状态条
2. [x] 首启连接配置：baseURL + Bearer Token 存 Keychain
3. [x] 工作台入口四区可达：章节（左栏）/ 人物 / 设定 / Agent（右栏三 tab 覆盖后三者）
4. [x] 章节编辑①：标题 / 剧情 Bible / 目标字数 / 作者备注
5. [x] 章节编辑②：允许人物 chips，上限语义（被提及也算出现）
6. [x] 章节编辑③：正文 预览/编辑 + 生成 / 停止 / 接受 / 重开
7. [x] 豁免重试（未授权人物 → 本章豁免并重试）
8. [x] 导入正文
9. [x] Extractor 结果：headline / summary 可编辑保存
10. [x] 删除章节：finalized 与 draft 两套确认文案
11. [x] 人物卡：固定设定可编辑 / 动态字段只读 / 故事线 events 单条改/删（数据层无新增事件接口，与 iOS 一致）
12. [x] 新建人物 + 导入人物卡 + 删除人物
13. [x] 书设定：书名 / 世界观 / 导出全书 .txt（NSSavePanel）
14. [ ] 设置-连接：baseURL / token（⌘, 或右栏）
15. [x] LLM Profile：增 / 删 / 改 / 测
16. [x] AgentModelBinding：模型 Picker / 思考 Toggle / 强度 Picker / temperature 滑杆 0–2 按 `temperature_adjustable` 置灰
17. [x] Agent 人格：编辑 / 恢复默认
18. [ ] 阅读模式：宋体 + 字号档位 AppStorage + 相邻 finalized 翻页
19. [ ] Toast：critical 常驻可手动关
20. [ ] 本地草稿缓存自动生效（`ChapterDraftCache`）
21. [x] 写作状态机：selectingMemory/writing/revising(attempt)/extracting/failed 呈现 + 字数=去空白 + 前台恢复轮询

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
- 2026-07-11 v1.2.0 块② 完成：新建 `App/LinoIMac/LinoMacTheme.swift`（`LinoMacMetrics` 度量常量 + `.linoToolbarGlass()`/`.linoSidebarGlass()`/`.linoPanelGlass()` 三档玻璃，`glassEffect(.regular,in:)` + 顶部 1px 高光 + 0.5px hairline 描边，色值一律经 `LinoTheme.hex`/`LinoTheme.page` 派生，未建平行色板）与 `LinoMacControls.swift`（`LinoMacIconButton` 34×34 玻璃图标钮支持 normal/danger/warning 三态 tint + hover 亮度 + `NSCursor.pointingHand` + help tooltip；`LinoMacSegmented<Option>` 泛型玻璃分段控件；`pointer(_:)` hover helper；`LinoMacConnectionChip` 三态连接点，探测=一次 `session.api.request("/books")`，2xx→已连接、401→Token 失效、其余→未连接，`.task(id:)` 随 baseURL/token 变化自动重探）。状态徽标直接复用共享 `LinoIStatusPill`，未新写。`MacShell.swift` 占位页换成设计系统冒烟页（三档玻璃卡 + 3 个 LinoMacIconButton + 2 个 LinoMacSegmented + 2 个 LinoIStatusPill + LinoMacConnectionChip），注释标明块③会整体替换。两个新文件挂进 pbxproj（B00000000000000000000213/214 build file、B00000000000000000000315/316 fileRef，沿用 B000… 段）。验收：macOS scheme LinoIMac build + iOS scheme LinoI 回归 build 双绿；本机 `open` 已编译的 .app 并用 computer-use 截图肉眼确认三档玻璃亮度差异化、danger/warning 图标钮 tint、hover 亮度变化 + help tooltip、分段控件选中态、状态徽标配色、连接点默认「未配置」态均正常。
- 2026-07-11 v1.2.0 块③ 完成：`MacShell.swift` 补全为单窗状态机（`token.isEmpty`→`MacConnectionView(firstRun:true)`；`currentBook==nil`→`MacBookshelfView`；否则→占位工作台页「工作台施工中」+ 返回书架，块④会整体替换），底部叠 `LinoIToast`，reader/settings 留结构位注释。新建 `MacBookshelfView.swift`（居中容器 + header：kicker/大标题/新建作品主按钮/⚙占位钮/`LinoMacConnectionChip`+baseURL；`LazyVGrid(.adaptive(minimum:220))` 书卡+虚线新建卡；书卡 hover 上浮3px+阴影加深+手型，右键菜单打开/删除，删除 `confirmationDialog` 文案对齐 iOS；空态+首次加载 ProgressView；全部复用 `BookshelfStore`）、`MacNewBookSheet.swift`（固定尺寸 sheet，书名+创建，`createBook` 自带自动 open 无需额外调用）、`MacConnectionView.swift`（firstRun 与设置内嵌共用一张卡片，baseURL 等宽字段+Token 安全字段+保存并连接，Return 键可提交，真实反馈靠卡片内 `LinoMacConnectionChip` 探测）。三新文件挂 pbxproj（215-217 build file、317-319 fileRef，沿用 B000… 段）。**过程中意外发现并修复**：后端 SQLite 落库丢失时区标记，`updated_at` 实际是裸时间字符串（如 `2026-07-11T05:57:11.827494`，无 `Z`），若照搬 iOS `linoShortDate` 的纯 `ISO8601DateFormatter` 解析会稳定返回 nil——书卡相对时间会永远卡在"最近更新"退化态；`MacBookshelfView` 新增 `parseBackendTimestamp` 按 UTC 显式兜底解析裸时间戳（经 swift 脚本用真实后端响应验证），今天/昨天/N天前/M月d日四态均正确。验收：macOS/iOS 双 target build 绿，后端 57 测试绿；本地起 Backend（`alembic upgrade head` 补齐迁移）实测：Keychain 空→首启连接页渲染正确；错误 token 保存后正确路由到书架并显示「Token 失效」红点 + critical toast「unauthorized」（键盘输入触发，因电脑上无关背景 App 的全屏手势遮罩挡住了 computer-use 的点击判定，退化用 Tab+键入+Return 全键盘流验证，遮罩不影响截图/hover/键盘操作）；正确 token 下书架真实渲染 2 本种子书（含 hover 阴影变化）；书籍 CRUD（创建/列表/删除）直接对真实后端 curl 验证响应结构与 `Book` 模型字段一致；打开书→工作台占位页→返回书架的路由用临时 `#if DEBUG` 环境变量钩子复用真实 `open(_:)` 验证后已还原（git diff 确认 `LinoIMacApp.swift` 无残留）。测试书目与本机 UserDefaults/Keychain 测试态已清理干净。
- 2026-07-11 v1.2.0 块④ 完成：三栏工作台上线。新建 `App/LinoIMac/` 8 文件——`MacWorkspaceView`（自绘 46 高 `.linoToolbarGlass` 标题栏：返回书架 chip/居中书名/连接 chip/⚙ 占位/抽屉开关；`GeometryReader` 三档 reflow ≥1100 三栏并列、800–1100 右栏收抽屉、<800 左栏也收抽屉；`@State selectedChapterId` 变化 `await editor.load`）、`MacChapterSidebar`（章节列表：序号封面块+Songti 标题+`LinoIStatusPill`+选中 accent，新建章节复用 `WorkspaceStore.createChapter`）、`MacChapterEditor`（三阶段①标题/Bible/目标字数/作者备注 ②允许人物 FlowLayout chips ③生成/停止/接受/重开/豁免重试/导入/预览-编辑切换/删章 finalized 与 draft 两套文案 + Extractor 结果段 headline/summary 可编辑，写作逻辑零新增全调现有 store）、`MacRightPanel`（`LinoMacSegmented` 角色/书设定/Agent 三 tab）、`MacCharacterTab`（人物 chips+可编辑卡+动态字段只读+故事线改/删+新建/导入/删除人物）、`MacBookSettingsTab`（书名/世界观/保存/导出全书）、`MacAgentTab`（LLM Profile 增改删测 + 绑定卡模型/思考/强度/temperature 按 capability 置灰 + 人格编辑/恢复默认，capability 语义逐条照 iOS）、`MacExportSaver`（`NSSavePanel` 存 `.txt`）。挂 pbxproj（buildFile 218-226、fileRef 322-329，沿用 B000… 段），`MacShell` 占位工作台换成 `MacWorkspaceView`。**共享层唯一改动**：`ChapterEditorStore` 新增 macOS 专用 `refreshActiveJobIfNeeded()`——有 `currentChapter` 且 `!writingPhase.isActive` 时无条件发一次 `jobStatus` 并按非终态续 `pollJob`，**不加 `status==writing/extracting` 守卫**（绕开 iOS P2#3），只由 `MacWorkspaceView` 的 `NSApplication.didBecomeActiveNotification` 调用，iOS 代码路径零改动（+26 行、无删除）。验收：macOS `LinoIMac` + iOS `LinoI` 双 target build 绿；本地起 Backend（隔离 scratchpad DB，**绝不碰生产**）+ scratchpad 最小 OpenAI-compatible mock（按请求形态分流 Memory Selector/Writer/Reviser/Extractor，Writer 按 Bible 字数区间生成、violate 模式提未选人物名），对真实后端 API 跑通全链 22/22——生成→轮询→待接受→接受→提取→已完成、停止、豁免重试（mock Writer 提未选「赵云」触发 unselected_character，本章豁免后重试通过）、导入正文、重开；App 内真连本地后端肉眼确认三栏工作台渲染、章节切换（`editor.load` 命中后端）、Extractor 结果段与角色卡动态字段/故事线均正确、切后台再激活精确触发一次 `/job` 续查（验证 `refreshActiveJobIfNeeded`）。故事线 events 仅改/删（本项目数据层无新增事件接口，与 iOS 完全一致）。附录 A 勾掉 3–13/15–17/21。
