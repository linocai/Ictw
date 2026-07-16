# LinoI PROJECT_PLAN

> 本文件是项目唯一权威计划入口。历史 plan 全文在 `archive/`。

## 概述

LinoI 是单人小说写作工作台：SwiftUI iOS/macOS App + FastAPI 后端。核心是四 Agent 写作链——Memory Selector（按本章 Bible 选择历史记忆与紧邻上一章结尾起点）→ Writer（白名单约束下写初稿并负责所有扩写）→ Reviser（压缩与其他程序违规修订）→ 用户接受 → Extractor（只归档已选人物）。数据库负责记得全，Writer Prompt 只保留当前工作集。

## 技术选型

- **App**：SwiftUI（iOS + macOS），无第三方依赖；Token 存 Keychain，本地草稿缓存在 Application Support。
- **后端**：FastAPI + SQLAlchemy 2 + Alembic + SQLite，单 worker uvicorn；LLM 走 OpenAI-compatible 协议，capability registry 管推理参数（DeepSeek V4 Pro/Flash、GLM 5/5.1/5.2、Gemini 3.5 Flash、未知模型）。
- **部署**：HK 云服务器，Nginx HTTPS 反代 → 127.0.0.1:8787，systemd `linoi-backend.service`。详情见 `~/Lino/hk_info.md`。

## 当前状态（2026-07-16）

- v1.3.2 已发版部署生产（记忆导出）：后端 Alembic head `20260711_0006`（本版无迁移）、健康版本 `1.3.2`，macOS ICTW `1.3.2(11)` 已换装，GitHub Release v1.3.2 已发；iOS 真机安装由用户管理。
- Writer 负责全部扩写，Reviser 只负责压缩与其他违规；GLM 5 系列已纳入 capability registry。
- 双端阅读翻章回顶部、本地草稿提示收口完成；后端 75 测试及 iOS/macOS Debug 构建全绿。
- **v1.4.0「前端视觉升级」施工中**（纯前端，Backend/ 零改动、无迁移、无部署；后端健康仍报 `1.3.2` 属预期）。五块：Motion/视觉 token 基建 + 锁浅色 → macOS 动画平滑 → iOS 动画平滑 + 阅读三主题 + 字族/控件一致性 → 视觉 bug 扫尾 → 验收发版。双 target 抬 `1.4.0(12)`。**块① 已完成**（token 基建 + 双端锁浅色，见变更日志）；块②-⑤ 待做。详见「当前 Plan」。

## 当前 Plan

### v1.4.0 前端视觉升级

**目标**：把「13 处零散动画、无 motion 常量、圆角/透明度/字号全是字面量、双端字族与控件不一致、系统深色模式下阴阳脸」的现状，收敛成一套可复用的视觉/动效 token + 两端一致的平滑体验。四层推进：Motion 基建 → 动画平滑 → 视觉 bug 修复 → 两端一致性。

**边界（硬约束）**
- **纯前端**：`Backend/` 一行不改，无 Alembic 迁移、无生产部署。后端健康仍报 `1.3.2`，属预期。
- 不做原生深色模式——本版是**强制锁浅色**（决策 1），根治系统弹层/玻璃 chrome 阴阳脸。
- 阅读页正文/标题「宋体」是阅读排版，**不进字族统一**（决策 3 只收 chrome）。书卡封面单字 monogram、头像也是装饰字，保持宋体（两端本已一致）。
- 双 target 版本 `1.4.0`、build `12`（pbxproj `MARKETING_VERSION` 1.3.2→1.4.0 共 4 处、`CURRENT_PROJECT_VERSION` 11→12 共 4 处）。

**性能与克制原则（每处动画都必须满足）**
- 只动廉价属性：`opacity` / `scale` / `offset` / 颜色 cross-fade。**禁止**在列表/热路径里动 `shadow(radius:)`、`blur`、`.frame` 高度突变；书卡 hover 的阴影 morph 是一次性 hover，允许。
- 列表动画只 key 在数据 id（`.animation(token, value: items.map(\.id))`），绝不 key 索引或整对象。
- 一律 value-based（`.animation(_, value:)` 或 `withAnimation` 包状态变更）→ **可被打断**；不用 `.repeatForever`、不做视差、不做花哨转场。
- 分段控件滑动用 `matchedGeometryEffect`（移动一个背景矩形，廉价）。

---

### 技术选型（在此定死，不留给 build）

所有 token 追加进**已共享**的 `App/LinoI/LinoTheme.swift`（已挂两 target，零 pbxproj 改动）。新共享控件/样式追加进已共享的 `App/LinoI/LinoComponents.swift`。**除非 build 选择拆分独立文件并自行接 pbxproj，否则默认就地追加，避免 pbxproj 手术。**

**① `enum LinoMotion`（时长阶梯 + 语义动画，全部 value-based 可打断）**

| 语义 token | 定义 | 用途 |
|---|---|---|
| `press` | `.easeOut(duration: 0.14)` | 触摸按压反馈（iOS 书卡/行/chip 缩放） |
| `hover` | `.easeOut(duration: 0.18)` | macOS hover 上浮/亮度（书卡 lift、玻璃钮 brightness） |
| `drawer` | `.easeOut(duration: 0.18)` | 侧栏/右栏抽屉滑入滑出、reflow |
| `content` | `.smooth(duration: 0.22)` | 内容区切换（状态机、tab 内容、编辑器阶段块/模式、banner、toast） |
| `selection` | `.smooth(duration: 0.22)` | 分段 pill 滑动、tab 选中、人物 chip 选中、行选中 |
| `reader` | `.smooth(duration: 0.22)` | 阅读页开合、主题变色、翻章 crossfade、字号 |
| `listItem` | `.smooth(duration: 0.22)` | 列表增删 |
| `status` | `.smooth(duration: 0.30)` | 状态徽标双 key morph |

时长常量：`micro 0.14 / fast 0.18 / standard 0.22 / emphasized 0.30`（参数来源：老项目 BookCard `easeOut 0.18`、StatusBadge `smooth 0.30`、小控件 `0.14`，与现存 `smooth 0.22/0.24/0.25` 对齐取整）。

**② `enum LinoRadius`（pt）**：`chip 8 / control 10 / pill 11 / field 12 / card 14 / panel 18 / glass 20 / bar 22`。
迁移规则：字面量就近映射到 token，**仅当 |Δ|≤1pt**（视觉无感）时替换；命名例外保留：`linoGlass` 默认 24、装饰条 1.5。目标是新代码 + 主力表面走 token，不追每个一次性 one-off。

**③ `enum LinoSurface`（白卡不透明度）**：`well 0.54 / card 0.68 / input 0.72 / glassTint 0.66 / panelTint 0.18`。就近映射，残留 one-off 允许。

**④ `enum LinoType`（字族统一 = SF Rounded）**
```
static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font
    = .system(size: size, weight: weight, design: .rounded)
static let display   = rounded(30, .bold)      // 书架大标题
static let heading   = rounded(20, .bold)      // 分区标题（原 .title3.bold）
static let cardTitle = rounded(17, .semibold)  // 书卡 / 列表行标题（原 .headline / Songti16）
static let rowTitle  = rounded(15, .semibold)  // 侧栏章节行（原 Songti14.5）
```
阅读/封面/手稿的 `.custom("Songti SC", …)` 一律不动。

**⑤ `enum LinoReadingTheme`（day/sepia/night，两端共用）**
把现 `MacReadingTheme`（`MacReaderView.swift:307-386`）的三主题色板**整体上移**到共享 `LinoTheme.swift` 更名 `LinoReadingTheme`（纯 SwiftUI `Color`，可移植）；Mac 端改引用它、删除本地 `MacReadingTheme`；iOS 阅读页新增消费。色板一字不改（决策 2 要求 port 自 Mac）。

**⑥ 新共享控件（`LinoComponents.swift`）**
- `LinoISegmented<Option>`：自绘玻璃分段，`matchedGeometryEffect` 滑动白色选中底，动画 `LinoMotion.selection`；iOS 用它替换系统 `Picker(.segmented)`，视觉与 Mac `LinoMacSegmented` 同构。
- `LinoICardButtonStyle`：`configuration.isPressed` 时 `scale 0.97` + 阴影收敛，动画 `LinoMotion.press`；iOS 书卡/章节行/人物 chip 复用（补 press 态）。

---

### 块① Motion/视觉 token 基建 + 锁浅色

**改动文件**：`LinoTheme.swift`（追加 5 组 token + `LinoReadingTheme`）、`LinoComponents.swift`（追加 `LinoISegmented`/`LinoICardButtonStyle`；`LinoIStatusPill` 改双 key）、`LinoIApp.swift`（iOS 锁浅色）、`LinoIMacApp.swift` + `MacShell.swift`（macOS 锁浅色）、`MacReaderView.swift`（`MacReadingTheme`→引用共享）。存量 13 处动画就地换 token（见下）。

**锁浅色（决策 1）规格**
- **iOS**：`LinoIApp` 的 `WindowGroup` 内给 `RootView()` 加 `.preferredColorScheme(.light)`。作用于整个 scene，`sheet`/`confirmationDialog`/`Menu`/分享面板一并跟随。
- **macOS**：双保险——
  1. 加 `AppDelegate: NSObject, NSApplicationDelegate`，在 `applicationDidFinishLaunching` 设 `NSApp.appearance = NSAppearance(named: .aqua)`；`LinoIMacApp` 用 `@NSApplicationDelegateAdaptor(AppDelegate.self)` 挂上。这一步锁住 AppKit 系统面板（`NSSavePanel`、右键 `contextMenu`、`confirmationDialog`）。
  2. `MacShell` 顶层加 `.preferredColorScheme(.light)`，锁住 SwiftUI 层。

**存量 13 处动画 → token 收敛**

| 文件:行 | 现状 | 换成 |
|---|---|---|
| `NoticeBus.swift:70` | `smooth 0.24` | `LinoMotion.content`（transition :64 保留） |
| `LinoComponents.swift:29` | `smooth 0.25` value:status | `LinoMotion.status` + **加第二 key** `value: text`（双 key morph，对齐老 StatusBadge，解决 pillStatus 相同、label 变时不 morph） |
| `MacReaderView.swift:79` | `smooth 0.22` | `LinoMotion.reader` |
| `MacWorkspaceView.swift:78,97` | `easeOut 0.18` | `LinoMotion.drawer` |
| `MacWorkspaceView.swift:142` | `smooth 0.22` | `LinoMotion.reader` |
| `MacWorkspaceView.swift:50,158,169` | `.transition(opacity/move)` | 保留 transition；由块② 统一驱动 token |
| `MacBookshelfView.swift:174` | `smooth 0.18` | `LinoMotion.hover`（=easeOut 0.18） |
| `LinoMacControls.swift:90` | `smooth 0.2` | `LinoMotion.selection` |
| `LinoMacControls.swift:176` | `smooth 0.2` value:state | `LinoMotion.content` |

**验收**：双 target Debug 构建绿；系统切到深色模式后，iOS 与 macOS 的 `confirmationDialog`/右键菜单/`NSSavePanel`/分享面板均为浅色（无阴阳脸）——截图为准（块⑤正式验收，此处先冒烟）。token 文件编译通过、`LinoIStatusPill` 双 key 生效（写作阶段 label 变化时数字 morph）。

---

### 块② macOS 动画平滑

**改动文件**：`MacShell.swift`、`MacWorkspaceView.swift`、`MacRightPanel.swift`、`LinoMacControls.swift`、`MacChapterEditor.swift`、`MacReaderView.swift`、`MacChapterSidebar.swift`、`MacBookshelfView.swift`。

**每个切换点的动效规格**

| 切换点 | 位置 | 机制 | token |
|---|---|---|---|
| 状态机 连接↔书架↔工作台 | `MacShell.swift:17-25` | `Group` 分支加 `.transition(.opacity)`，`.animation(_, value:)` 挂在 `session.token.isEmpty`/`currentBook?.id` | `content` |
| reflow 跨断点 | `MacWorkspaceView.swift:44-45` | `onChange` 里 `withAnimation(LinoMotion.drawer)` 包 `rightPanelOpen/sidebarOpen=true`；三栏 if/else 列用 `.transition(.opacity)` 收敛 pop | `drawer` |
| 左抽屉 | `:164-171` | 已 `.move(.leading)`+`zIndex(2)`，驱动改 `drawer` | `drawer` |
| 右抽屉 | `:155-158` | 保留 `.move(.trailing)`，**补 `.zIndex(2)`**（块④ 修遮挡），驱动 `drawer` | `drawer` |
| reader 开合 | `:142`/`MacReaderView.swift:79` | 已 token 化（块①） | `reader` |
| 右栏 tab 内容 | `MacRightPanel.swift:13-19` | `Group` 加 `.transition(.opacity)`，`.animation(_, value: tab)` | `content` |
| 分段 pill（右栏 tab / 预览-编辑） | `LinoMacControls.swift:80-116` | 加 `matchedGeometryEffect` 滑动白色选中底（一个 `@Namespace`） | `selection` |
| 编辑器阶段块（expanding/revising/failed/finalized 提示） | `MacChapterEditor.swift:305-337` | 各分支 `.transition(.opacity)`，`.animation(_, value: writingPhase)` | `content` |
| 预览↔编辑 | `:242-252` | `.transition(.opacity)`，`.animation(_, value: draftMode)` | `content` |
| Extractor 结果段出现 | `:130-132` | `.transition(.opacity.combined(with:.offset(y:6)))`，animate `showExtraction` | `content` |
| 草稿恢复 banner | `:126` | `.transition(.opacity)`，animate `restoredLocalDraft` | `content` |
| 阅读主题整窗变色 | `MacReaderView.swift:69` | 背景/文字色加 `.animation(LinoMotion.reader, value: theme)` | `reader` |
| 阅读字号 | `:111-116` | `.animation(_, value: fontSize)` | `reader`/`content` |
| 翻章 | `:241` `.id()` | 保留 `.id`，正文列加 `.transition(.opacity)` + animate `chapter?.id` 做 crossfade（不要滑动） | `reader` |
| 主题 swatch 选中环 | `:127-155` | 选中环 `.animation(_, value: theme)` | `selection` |
| 书卡 hover | `MacBookshelfView.swift:174` | 已 token（块①） | `hover` |
| 侧栏行选中 | `MacChapterSidebar.swift:115-122` | 底/描边 `.animation(LinoMotion.selection, value: selected)` | `selection` |
| 章节列表增删 | `:59-67` | `.animation(LinoMotion.listItem, value: workspace.chapters.map(\.id))` | `listItem` |
| 玻璃图标钮 hover | `LinoMacControls.swift:65` | `.animation(LinoMotion.hover, value: hovered)` | `hover` |

**验收**：录屏或连续截图证明——状态机切换淡入淡出、reflow 拉宽/收窄不再瞬间 pop、右栏 tab 与预览-编辑 pill 平滑滑动、编辑器阶段块渐显、阅读三主题整窗渐变、翻章 crossfade、章节列表增删有过渡。双 target 构建绿。

---

### 块③ iOS 动画平滑 + 阅读三主题 + 字族/控件一致性

**改动文件**：`LinoIApp.swift`、`WorkspaceViews.swift`、`ChapterEditorViews.swift`、`ReadingViews.swift`、`ShelfViews.swift`、`CharactersViews.swift`、`SettingsViews.swift`、`LinoComponents.swift`。

**A. iOS 动画平滑（对齐块②）**

| 切换点 | 位置 | 机制 | token |
|---|---|---|---|
| RootView 状态机 书架↔工作台 | `LinoIApp.swift:55-59` | `.transition(.opacity)` + animate `currentBook?.id` | `content` |
| 工作台四 tab 内容 | `WorkspaceViews.swift:21-32` | `Group` `.transition(.opacity)` + animate `selectedTab` | `content` |
| 工作台分段 pill | `WorkspaceViews.swift:85-112` | 换 `LinoISegmented`（matchedGeometry 滑动） | `selection` |
| 章节列表增删 | `WorkspaceViews.swift:148-155` | animate `value: chapters.map(\.id)` | `listItem` |
| 编辑器阶段块 | `ChapterEditorViews.swift:380-412` | 各分支 `.transition(.opacity)` + animate `writingPhase` | `content` |
| 预览↔编辑（**替换系统 Picker**） | `:307-324` | 删 `Picker(.segmented)`，换 `LinoISegmented`；内容 `.transition(.opacity)` | `selection`+`content` |
| Extractor 结果段 / 草稿 banner 出现 | `:175-177 / :168-170` | `.transition(.opacity(+offset))` + animate | `content` |
| 人物 chip 选中 | `:274-295` | 每 chip `.animation(LinoMotion.selection, value: isSelected)` | `selection` |
| 书卡 press 态 | `ShelfViews.swift:115-175` | 套 `LinoICardButtonStyle`（scale 0.97） | `press` |
| 章节行 press 态 | `WorkspaceViews.swift:149-154` | `LinoICardButtonStyle` | `press` |
| 人物 chip 横列增删 | `CharactersViews.swift:41-48` | animate `value: characters.map(\.id)` | `listItem` |
| 故事线行 编辑态切换 | `CharactersViews.swift:254-286` | `.transition(.opacity)` + animate `isEditing` | `content` |

**B. iOS 阅读页补三主题（决策 2）**——本块最重的一块
- `ReadingViews.swift` 消费共享 `LinoReadingTheme`；新增 `@AppStorage("linoi.reader.theme")`（String，day/sepia/night），沿用现有 `linoi.reader.fontScale`（small/medium/large 不动）。
- 整窗变色：阅读视图自绘 `.background(theme.background).ignoresSafeArea()`；正文/标题/分隔线颜色全部取 `theme.*`。
- **顶栏对齐 Mac**：阅读模式 `.toolbar(.hidden, for: .navigationBar)` 隐藏系统 nav 栏，自绘主题化顶栏（返回 + 「书名·第N章」+ 三主题 swatch + A−/A+），解决「锁浅色下 night 阅读页 nav 栏仍是亮的」冲突，并与 Mac `MacReaderView` topBar 同构。
- 主题切换 `.animation(LinoMotion.reader, value: theme)`；字号 pill 换 `matchedGeometry`；翻章 `.id(chapter.id)` 保留 + crossfade。

**C. 字族统一（决策 3）+ 控件一致性**——按下表把 chrome 换 `LinoType`，宋体（阅读/封面/手稿）不动：

| 站点 | 现状 | → |
|---|---|---|
| `ShelfViews.swift:70` iOS 书架大标题 | `.system(30,rounded)` | `LinoType.display`（纯 token 化，无变化） |
| `MacBookshelfView.swift:45` 「我的作品」 | `Songti 30` | `LinoType.display`（宋体→圆体） |
| `ShelfViews.swift:137` iOS 书卡名 | `.headline` | `LinoType.cardTitle` |
| `MacBookshelfView.swift:151` Mac 书卡名 | `Songti 16` | `LinoType.cardTitle` |
| `WorkspaceViews.swift:177` iOS 章节行 | `.headline` | `LinoType.cardTitle` |
| `MacChapterSidebar.swift:105` Mac 侧栏行 | `Songti 14.5` | `LinoType.rowTitle` |
| `ChapterEditorViews.swift:189` iOS 编辑器标题 | `.system(25,rounded)` | `LinoType.rounded(25,.bold)` |
| `MacChapterEditor.swift:76` Mac 工具栏标题 | `Songti 18` | `LinoType.rounded(18,.bold)` |
| `WorkspaceViews.swift:73` iOS 书名 header | `.system(20,rounded)` | `LinoType.heading` |
| `ChapterEditorViews.swift:516`/`MacChapterEditor.swift:447` stageHeader 标题 | `.headline`/`.system(14)` | 两端 `LinoType.rowTitle` |
| stageHeader 圆标 | iOS 26×26 / Mac 24×24 | 两端 **26×26** + 数字 `LinoType.rounded(13,.bold)` |
| `.title3.bold()` 分区标题（`SettingsViews:13`/`CharactersViews:13`/`WorkspaceViews:123,207`） | SF 默认 | `LinoType.heading` |
| `MacConnectionView.swift:81` | `Songti 24` | `LinoType.rounded(24,.bold)` |
| 导入按钮 | iOS 仅图标(`ChapterEditorViews:363`) / Mac 带文字(`MacChapterEditor:288`) | 统一带文字「导入正文」 |

**验收**：iOS 三主题整窗变色 + 持久化（连续截图/录屏）；iOS 分段控件为自绘（无系统 Picker）；双端书架大标题/书卡名/章节行/编辑器标题/stageHeader 字族一致（圆体）、阅读正文仍宋体；书卡/行有 press 缩放反馈。iOS `xcodebuild` App target 构建绿（不能只跑 SwiftPM）。

---

### 块④ 视觉 bug 修复扫尾

**改动文件**：`MacWorkspaceView.swift`、`MacChapterEditor.swift`、`ChapterEditorViews.swift`、`MacReaderView.swift`、`MacChapterSidebar.swift`、`MacCharacterTab.swift`/`MacAgentTab.swift`（空态核查）、`ReadingViews.swift`。

| bug | 位置 | 修法 |
|---|---|---|
| 窄窗 <800 左右抽屉同开互相遮挡 | `MacWorkspaceView.swift` | <800 时两抽屉**互斥**（开一个自动关另一个）+ 右抽屉补 `.zIndex(2)` + 抽屉后加半透明 scrim（点击关闭） |
| 人物 chip 长名撑爆胶囊 | `MacChapterEditor.swift:213`、`ChapterEditorViews.swift:279` | 加 `.lineLimit(1)` + `.truncationMode(.tail)`，两端一致 |
| 阅读 night：ProgressView 系统蓝 | `MacReaderView.swift:223`（+ iOS 阅读 loading） | `.tint(theme.accent)` |
| 阅读 night：NSTextView 选中高亮系统蓝 | `MacReaderView.swift:454-465` | `makeNSView` 设 `selectedTextAttributes = [.backgroundColor: NSColor(theme.accent).withAlphaComponent(0.22)]`（随主题） |
| Mac 章节列表空态缺失 | `MacChapterSidebar.swift:57-74` | 0 章时渲染占位（图标+「还没有章节，点上方＋新建」），对齐 iOS |
| 右栏 人物/Agent 列表空态 | `MacCharacterTab`/`MacAgentTab` | 核查，缺则补（iOS 对应 pane 已有空态可参照） |
| Toast day 阅读页黑底突兀 | `NoticeBus.swift:61` | **可选 P2**：阅读页开启时 toast 背景随主题（暖色深底）；默认不做，仅当顺手。 |

**验收**：窄窗拖动 <800 两抽屉不再叠压（截图）；长人物名截断不撑破；night 主题 ProgressView 与文本选中均为暖色（截图）；Mac 空章节书有空态。双 target 构建绿。

---

### 块⑤ 验收发版

- **构建**：iOS `LinoI`（iphonesimulator，App target）+ macOS `LinoIMac`（platform=macOS）`xcodebuild build` 双绿、`error:` 计数 0。后端不动，`pytest -q` 复跑仍 81 绿（回归确认无误伤）。
- **截图验收范式**（本机 115 手势工具挡鼠标点击，用既有工作法）：键盘驱动（Tab/Return/⌘ 快捷键）+ 必要处临时 `#if DEBUG` 钩子（验收后 grep+git diff 确认零残留）+ 截图/录屏。三项重点：
  1. **锁浅色**：系统切深色模式，对 iOS/macOS 的 `confirmationDialog`、右键菜单、`NSSavePanel`、分享面板各截一张，证明不阴阳脸。
  2. **三主题过渡**：iOS + Mac 阅读页 day→sepia→night 连续截图或录屏，证明整窗渐变、持久化生效。
  3. **两端一致 + 动画**：书架/书卡/编辑器标题/stageHeader 双端并排截图证字族一致；分段 pill 滑动、列表增删、阶段块渐显各录一小段。
- **版本**：pbxproj 抬 `1.4.0(12)`（4+4 处）。
- **换装与发布**：macOS Release 构建（自动签名 + hardened runtime）→ `codesign --verify --deep --strict` → `ditto` 覆盖 `/Applications/ICTW.app` → 复核签名 → `open` 确认 `1.4.0(12)`；GitHub Release `v1.4.0` + `ICTW-1.4.0.zip`（`ditto` 保签名压包）挂 https://github.com/linocai/Ictw/releases 。**iOS 真机安装留用户**。
- 完成后补发版记录、施工全文移入 `archive/v1.4.0施工plan.md`。

**用户网页操作清单**：无（本版无付费能力/云端变更；GitHub Release 由 build 用 `gh` 自理）。

---

### 附录：Explore 扫描已抽查核实

立 plan 前已读 13 个视图文件 + 两 theme 文件核对：全项目 13 处动画（iOS 3 / Mac 10）、0 处 `preferredColorScheme`、圆角 16 种字面量、白卡不透明度 11 种、字族站点如上表——与扫描结论一致。老项目参数（`/Users/linotsai/Lino/Archive/LinoWritingV2`）：BookCard `easeOut 0.18`+offset −3、StatusBadge 双 key `smooth 0.30`、控件 hover `brightness 0.04`，已并入 token 定义。

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
- job_runs「最新一行」并列打破用随机 uuid，可换单调次键（review P2#6）
- write_registry 为进程内单例，未来多 worker 前必须换 DB 层 job 锁（review P2#7，前瞻）
- 阅读模式增强（书签、朗读、翻页动画等）

**运维/安全（hk_info.md §12 有排序清单）**
- 云端安全整改：关 root 密码登录、UFW、Fail2ban、服务降权、systemd 加固
- 每日自动备份 + 异地副本（当前仅一份人工备份且同盘）
- 安全更新 + 重启、NTP 修复、加 swap、Nginx 限流与 /docs 收口

## 变更日志

- 2026-07-12 v1.3.1 热修：所有实际非思考模式的模型请求统一强制发送 `top_p=0.95`；DeepSeek/GLM/Gemini 的思考模式请求主动删除 `top_p`，避免无效参数。保持各 Agent 既有 temperature 与思考开关配置不变，后端 79 测试全绿；生产备份 `20260712-163009` 后部署，实际 payload 验证 Writer/Reviser/Extractor 均为 disabled+temperature+top_p 0.95，Memory Selector 为 enabled+high 且不含 top_p，健康与数据库检查正常。
- 2026-07-12 v1.3.1 热修：思考开关对 DeepSeek V4 与 GLM 5 系列统一采用真实有效语义——支持开关的模型请求必须明确发送 enabled/disabled；旧 `NULL` 按供应商默认开启展示并显式发送开启，杜绝界面假关闭。后端 79 测试全绿；生产备份 `20260712-162422` 后部署，Writer/Reviser/Extractor 均实测发送 disabled 并携带各自 temperature，Memory Selector 实测发送 enabled+high 且不发送 temperature，健康与数据库检查正常。
- 2026-07-12 v1.3.1 热修：Writer 字数修复分流——正文低于最低合格线 60% 时使用完整初稿 Prompt 从头重写且不携带失败短稿；达到 60% 后才使用以世界观、Bible、作者备注、人物精简动态状态和当前正文为核心的轻量扩写 Prompt，不再重复上一章结尾、工作记忆和完整人物卡。GLM `sensitive`/通用 safety finish reason 首次出现即映射内容拦截并终止，不再浪费两次扩写。后端 78 测试全绿；生产备份 `20260712-152943` 后热部署，Writer 保持显式关思考与 temperature `0.9`，健康和数据库检查正常。
- 2026-07-12 v1.3.1 热修：GLM 5 系列旧绑定 `thinking_enabled=NULL` 过去在界面显示为关闭，但请求未发送 disabled、实际继承官方默认开启。现将 GLM 空值解释为有效开启，界面不再假报关闭；显式关闭后落库为 `0` 并真实发送 `thinking:{type:disabled}`，temperature 保持生效。后端 76 测试全绿；生产备份 `20260712-145649` 后部署，Writer 已通过设置 API 写为 `thinking_enabled=0`，有效 temperature 保持 `0.9`，公网健康正常。
- 2026-07-12 v1.3.1 部署：字数不足/截断改由 Writer 最多两次有机扩写，Reviser 仅处理超长与其他程序违规；GLM 5/5.1/5.2 纳入 capability registry，可显式控制 thinking、high/max effort 与 temperature；双端阅读翻章回顶部，本地草稿只对真实变化标脏且恢复提示收为页内横幅。后端 75 测试、iOS/macOS Debug 构建全绿；生产备份 `20260712-134742` 后部署，健康检查 `1.3.1`、数据库检查正常；macOS universal Release 通过 hardened runtime 与签名校验，以 `ditto` 重装并真实启动 `1.3.1(10)`。本版不建 tag/GitHub Release。（施工全文见 `archive/v1.3.1施工plan.md`。）
- 2026-07-12 v1.3.0 发版：Reviser 阶段双端展示最新程序校验原因，最终校验失败保留；Memory Selector 从紧邻已完成上一章最多 700 字原文结尾中选择最短衔接起点，结尾与既有记忆共用 1800 字预算；Writer Prompt 固定 Bible 最高权威与历史参考边界并去除重复世界观；双端同步 job 本地状态并接管 `write_running`；数字型上游 error.code 与带 Z 六位微秒时间串补兼容。后端 68 测试全绿，生产备份 `20260712-062035` 后部署，健康检查 `1.3.0`、数据库检查正常；macOS ICTW `1.3.0(9)` 已重装并真实启动，iOS 真机安装留给用户。（施工全文见 `archive/v1.3.0施工plan.md`。）
- 2026-07-12 GitHub Release v1.3.0 发布：tag `v1.3.0` + `ICTW-1.3.0.zip`（ditto 保签名压包，SHA-256 `d0bc14a89c065d61f694e98e541ba7bd9605e6cd377359c9b7476543c98d0c19`）已上传至 https://github.com/linocai/Ictw/releases/tag/v1.3.0 。
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
- 2026-07-11 v1.2.0 块⑤ 完成（v1.2.0 五块全部完工）：新建 `App/LinoIMac/` 3 文件——`MacReaderView`（全窗阅读 overlay，挂在 `MacWorkspaceView` 顶层 ZStack 而非 `MacShell`，因为它只能从已打开的章节编辑器进入且能直接复用 `selectedChapterId` 驱动翻页，不必新建跨层共享状态；52 高玻璃条=返回工作台 chip/居中「书名·第N章」/三主题 swatch+A−/A+；正文 `MacReaderBodyText`+`MacJustifiedTextRepresentable`（`NSTextView`）宋体两端对齐，`firstLineHeadIndent=fontSize*2`/`lineHeightMultiple=2.05`/`paragraphSpacing=fontSize*1.5`，`GeometryReader` 量宽+`layoutManager.usedRect` 回填高度，port 自老项目 `ReaderView.ReaderBodyText` 的稳定方案；`MacReadingTheme` 三主题 day/sepia/night 整窗变色，色值 port 自老项目 `ReadingTheme.swift`，与 `LinoTheme` 无关的独立色板；字号阶梯 `[18,19,20,21,23]` 经 `@AppStorage("linoi.mac.reader.fontSizeIndex")`/主题经 `@AppStorage("linoi.mac.reader.theme")` 持久化；`finalizedChapters` 过滤+按 index 排序算相邻章，翻页=改写 `selectedChapterId` 触发 `MacWorkspaceView` 既有 `onChange→editor.load` 管线，未新增加载逻辑）、`MacCommandBus`（`showNewBook`/`showNewChapter`/`showSettings` 三个 `@Published`）、`MacSettingsSheet`（内嵌 `MacConnectionView(firstRun:false)`，Esc 关闭用 `.onExitCommand`+`.onKeyPress(.escape)` 双保险）。`LinoIMacApp` 补 `.commands`：`CommandGroup(replacing:.appSettings)`「设置… ⌘,」、`CommandGroup(replacing:.newItem)`「新建作品 ⌘N」「新建章节 ⌘⇧N」（`.disabled(session.currentBook==nil)`，反应式跟随 `@StateObject session`）。接线 `MacShell`（`.sheet($commandBus.showSettings)`）、`MacBookshelfView`/`MacWorkspaceView`（⚙ 钮 + `onChange(showNewBook)`）、`MacWorkspaceView`（`onChange(showNewChapter)`——**放在 `MacWorkspaceView` 而非 `MacChapterSidebar`**，因为窄窗<800 且抽屉收起时侧栏未挂载，恒常挂载的工作台层才能保证命令总生效，这是相对 plan 文件列表的一个小的、有意的实现取舍）、`MacChapterEditor`（「阅读」按钮 `isDisabled: currentChapter?.status != "finalized"` 启用）。macOS AppIcon：`sips` 从 iOS `AppIcon-1024.png` 生成 16/32/128/256/512 各 1x/2x 共 10 个 PNG（512@2x 用 1024 源直接拷贝），填进 `Assets.xcassets/AppIcon.appiconset/Contents.json`。三新文件+改动挂 pbxproj（buildFile 227-229、fileRef 331-333，沿用 B000… 段）。**过程中发现并修复一个真实 bug**：`MacSettingsSheet` 初版用 `.keyboardShortcut(.escape)` 挂隐藏按钮响应 Esc，实测在 `TextField`/`SecureField` 持有第一响应者时被输入框的 `cancelOperation:` 吞掉，根本不触发；换 `.onExitCommand` 仍不触发；最终 `.onExitCommand`+`.onKeyPress(.escape)` 双保险留存（SwiftUI 正确写法），但**本机验收环境本身有一个「115浏览器手势增强工具」的全局手势覆盖层拦截了包括 Escape 在内的按键**（经对照组测试证实：同一 Esc 对完全未改动的旧 `MacNewBookSheet` 默认 `.sheet` 关闭行为、以及 `Cmd+W` 也一并失效），判定是环境干扰非代码缺陷，已如实记入验收报告，请用户自己按一次 Esc 复核。验收：macOS `LinoIMac`+iOS `LinoI` 双 target build 绿；后端 55 测试绿（本轮未碰后端）；本地起隔离 Backend+seed 数据（直接 SQL 落 `finalized` 章，不经写作链，因为块⑤不改写作逻辑）+ computer-use 实测——⌘,/⌘N（自动聚焦）/⌘⇧N（建章成功+左栏刷新+`4 章`落库核对）/⌘⇧N 无书时禁用（按下无反应，后端章数核对仍为 4）全部通过；阅读页三主题整窗变色+两端对齐首行缩进+字号阶梯全部截图肉眼确认（含 `defaults write` 预置 `@AppStorage` 值验证渲染读取路径）；相邻 finalized 翻页用短内容测试书直接截图证实——第1章「下一章」正确显示「第3章 短章3」（跳过草稿态第2章）、「上一章」正确显示禁用态「已是开篇」；「阅读」按钮 finalized 章启用/draft 章禁用两态分别截图确认；macOS AppIcon 编译进 bundle 后从 `.icns` 反抽 PNG 肉眼确认清晰无损。**已知验收局限**（如实记录，非隐瞒）：①本机全局手势覆盖层拦截鼠标点击（先前块已知）也确认拦截 Esc/Cmd+W，本轮改用全键盘流+临时 `#if DEBUG` 环境变量钩子（复用块③先例，验收后经 grep+git diff 确认零残留）驱动到工作台/阅读页；②critical toast 手动关闭这一具体分支因触发它需要的 Keychain 错误 token 场景撞上系统 SecurityAgent 授权弹窗（弹窗本身不在 computer-use 应用白名单内不可见也不该由 agent 代点），未能补一次新鲜截图，改为核对 `NoticeBus`/`LinoIToast` 代码未改动 + 块③变更日志已有的原始验证记录；③本地草稿缓存（`ChapterDraftCache`）走代码核对（共享文件未改动，`editString`/`editTargetWordCount` 的 `scheduleCacheSave()` 调用链核对无误），未做强制退出重启的实机复现。附录 A 补勾 14/18（新做）/19/20（核对既有代码，见上）。生产环境最终验收（Xcode 签名 + 真实 token）留给用户，附录 B 未动。
- 2026-07-11 v1.2.1 快修：后端裸时间串（SQLite 落库丢时区标记）解析统一收口到共享 `String.linoBackendDate`（LinoModels.swift，裸串按 UTC 解释，保留标准 ISO8601 分支）。修复 iOS 书卡相对时间因解析恒失败永远显示「最近更新」兜底（块③施工时发现的同源 bug）；同类隐患 `ChapterDraftCache.parseRemoteDate` 一并修复——此前「远端更新则放弃本地草稿」的比较因解析失败恒短路为保留本地，双端并用后此判断开始要紧；Mac 端删除私有重复实现 `parseBackendTimestamp` 改调共享层。独立 swift 脚本验证六种时间串形态（裸串带/不带小数、带 Z、带偏移、垃圾串）+ 双 target 构建绿；版本双 target 同抬 1.2.1(6)。
- 2026-07-11 v1.2.2 快修：Mac 端 App 每次激活重复弹旧失败 Toast——`refreshActiveJobIfNeeded` 对终态 job 无条件 `applyJobStatus`，而失败 job 永远是「最新」，每次前台激活都重新 publish 失败通知。修复为：非终态照旧续轮询（保留 P2#3 绕坑）；终态仅当本地章节 status 仍为 writing/extracting（后台错过的收尾）才应用。iOS 零改动；双 target 构建绿，版本 1.2.2(7)，/Applications/ICTW.app 已重装。真实诱因（LLM 上游 400，llm_upstream_rejected）待查生产审计表定位是哪个 Agent/模型。
- 2026-07-11 macOS 首次本机安装：产品名改 ICTW（PRODUCT_NAME + CFBundleDisplayName，Bundle ID 不变仍 com.lino.linoi.mac，图标即块⑤由 iOS 1024 生成的同款）；Release 构建自动签名（开发证书，hardened runtime）通过 codesign 校验，`ditto` 安装到 /Applications/ICTW.app 并启动验证。
- 2026-07-11 v1.2.0 发版：macOS App（target `LinoIMac`，Bundle `com.lino.linoi.mac`，产品名/展示名 ICTW）上线，与 iOS 完全对等（附录 A 21 项全过）；iOS 随共享层改动重编回归。五块施工——①加 macOS target + 共享层去 iOS 化 ②桌面玻璃设计系统与控件 ③书架+首启连接 ④三栏工作台（复用 ChapterEditorStore 轮询、macOS 前台无条件续查绕开 P2#3）⑤阅读模式 NSTextView 宋体两端对齐+⌘快捷键+设置。不改后端。用户已在生产真实使用，视为验收通过；施工全文（含附录 A/B）移入 `archive/v1.2.0施工plan.md`。（v1.2.1 后端裸时间串收口、v1.2.2 Mac 重复弹旧失败 Toast 两个快修已单独有记录。）
- 2026-07-11 v1.2.3 立项：全链路报错「一眼定位」（环节+模型+上游原因+建议动作全中文，iOS/macOS 同步发版）。块 A 后端 additive——上游错误按白名单摘 `error.message/code/type`（≤200 字符，不落正文/key）、`LLMError`/失败 job 补 `error_context`（agent_role/model_name/http_status/upstream_reason，含 `job_runs.error_context` 与 `GET /job` 透传）、迁移 20260711_0006 加 `job_runs.error_context` + `llm_call_audits.upstream_reason`，4xx wire 兼容不改既有 code；块 B 新建共享 `LinoErrorPresenter`（全枚举后端 code + APIError 本地 case → 中文，模板 `{环节}（{模型}）{原因}：{upstream_reason}——{建议} [code]`，内容过滤不伪装）接入 applyJobFailure/applyStartFailure/runPolling/NoticeBus，双 target 抬 1.2.3(8)；块 C 备份→迁移→重启发版（SSH 需授权）。
- 2026-07-11 v1.2.3 块A 完成（commit `96d84dd`）：后端错误上下文采集与透传，全 additive，照 plan 逐条落地无偏离。`LLMError` 增 `agent_role`/`model_name`/`upstream_reason` 三个可选字段（`safe_details()` 同步收录）；新增 `openai_compatible._safe_upstream_reason` 白名单，只摘 body 顶层 `error.message`/`code`/`type` 三键、strip 后拼一行截断 ≤200 字符，`error.metadata`/`error.param`/顶层 `messages` 回显一律不取，Gemini 原生 `promptFeedback.blockReason` 路径不重复改；`write_jobs.py` 四个 agent 调用点（memory_selector/writer/reviser/extractor）在各自 `except LLMError` 里先审计再盖章 `agent_role`/`model_name` 后 re-raise，`_run_job`/`_run_extract_job` 顶层捕获时用新 `_error_context()` 组装（agent_role/model_name/http_status/upstream_reason/finish_reason/block_reason，去 None）随 `record_job_phase` 落 `job_runs.error_context`；`record_llm_call` 同步落 `llm_call_audits.upstream_reason`（离线排查用，正文/key 均不落）。`WriteJobStatus`/`GET /chapters/{id}/job` additive 带出 `error_context`，老客户端忽略不受影响；`chapter_style` 等既有 code 枚举一个未改。顺手做了 plan 里的可选小增益：`POST /llm_profiles/{id}/test` 的上游 `LLMError` 包成结构化 502（`{code,message,details}`），不再是裸 500。新迁移 `20260711_0006`（`job_runs.error_context` JSON + `llm_call_audits.upstream_reason` Text，均 nullable）。测试新增 6 条——白名单防回显+截断+缺失分支 3 条（test_v1_pipeline.py）、失败 job 落库+`GET /job` 透传+`llm_content_blocked` 不被伪装 2 条（test_api.py）、审计列落值不落密钥 1 条（test_v1_1_features.py）；后端 61 测试全绿（55 现有 + 6 新增）。本地新建库 `alembic upgrade head` 验证迁移链完整到 `20260711_0006`，并额外做了 downgrade→re-upgrade 往返验证，无 FK 问题。只 stage/commit 了 Backend/ 12 个文件，`PROJECT_PLAN.md` 本行为追加写入、未碰其他行。下一步：块 B（客户端共享呈现器）、块 C（发版）。
- 2026-07-11 v1.2.3 块B 完成：新建共享 `App/LinoI/LinoErrorPresenter.swift`（挂 iOS+macOS 双 target），纯函数 `present(jobFailure:)`/`present(error:)` 输出 `(message, critical)`。全枚举后端 code 建静态「原因+建议」表——发版前 grep 复核时额外发现 plan 清单遗漏的 `bible_empty`（`validate_character_preflight` 的 409 结构化 code）一并补上；模板严格照 `{环节}（{模型}）{原因}：{upstreamReason 原文}——{建议} [code]`，任意缺段整段省略；`upstreamReason`/`blockReason` 原文不翻译；`llm_content_blocked`/`revision_failed`/`unauthorized`（401 纯串合成的本地 code）固定 critical=true 不伪装成普通失败；`revision_failed` 额外从 `violations` 里的 `unselected_character.names` 拼出具体未获准人物名，而非停在「未通过程序校验」的空泛提示。APIError 本地 case 分别处理：404 已知名词（book/chapter/character/profile/agent role/character event）→中文名词、409 `chapter has no draft text`→专门文案、422 settings 校验串（已中文）原样透传不重复包装、`.transport`/`.notConfigured`/`.badURL` 各自处理。`LinoModels.swift` 新增 `JobErrorContext`（snake_case CodingKeys，纯 additive）+ `WriteJobStatus.errorContext`。接线：`NoticeBus.publish(_ error:)` 改调呈现器并删掉原 `isUnauthorized` 私有扩展，全仓 33 处既有 `session.notices.publish(error)` 调用点零改动自动获得新文案（单一收口，未逐个改）；`LinoStores.applyJobFailure`/`applyStartFailure` 改用呈现器结果同时驱动 toast 与 `writingPhase.failed` 的 message；`runPolling` 断连话术收进 `LinoErrorPresenter.connectionInterrupted` 常量。pbxproj 两 target 各加一条新 PBXBuildFile（iOS `A0000…0114`、Mac `B0000…0230`）共享同一新 fileRef `A0000…0134`，双 target 版本同抬 `1.2.3(8)`（4 处 config：MARKETING_VERSION 1.2.2→1.2.3、CURRENT_PROJECT_VERSION 7→8）。验收：iOS `LinoI`（iphonesimulator）+ macOS `LinoIMac`（platform=macOS）双 target `xcodebuild build` 各自独立全量重跑均 `BUILD SUCCEEDED`、日志 `error:` 计数 0；呈现器是纯函数，未接后端联调（块 A 虽已完成但块 C 才做端到端），改用 `swiftc` 直接编译真实源文件（`LinoModels.swift`+`LinoAPI.swift`+`LinoErrorPresenter.swift`）配一个临时 driver 跑 14 组场景断言——LLM 上游拒绝/内容过滤(critical+blockReason 原文)/revision_failed 人名拼接/write_failed 无 upstream 兜底/未知 code 兜底(保留环节+model+原始 message+`[code]`，唯独不编建议)/401/两种已知 404/409/422 透传/两种 409 结构化 validation(含 bible_empty)/未知 validation code/transport/notConfigured·badURL，全过后删除临时文件与二进制，未留残留。只 stage/commit App/ 本块文件，不碰 Backend/、不碰生产；PROJECT_PLAN.md 本行追加写入、未改其他行。下一步：块 C（发版，SSH 需用户在场授权）。
- 2026-07-11 v1.2.3 块C 本地验证完成（不涉及生产部分；生产部署待用户在场授权后另行执行）：本地起隔离 Backend（scratchpad SQLite、独立 `APP_TOKEN`/`KEK_SECRET`、127.0.0.1:8788，`alembic upgrade head` 到 `20260711_0006`）+ scratchpad 起最小 stdlib OpenAI-compatible mock（127.0.0.1:8799，按请求体 `model` 字段分流 400/内容过滤/成功三态，400 响应额外掺 `error.metadata.prompt`/顶层 `messages` 回显探针验证白名单不泄漏），先 API 层直连驱动四类场景全部命中预期：①上游 400——`error_code=llm_upstream_rejected`、`error_context={agent_role:writer, model_name:mock-400, http_status:400, upstream_reason:"Model Not Exist | model_not_found | invalid_request_error"}`，回显探针字符串确认未泄漏；②内容过滤——`error_code=llm_content_blocked`、`block_reason=SAFETY`；③断连（writer 指向死端口）——`error_code=llm_transport`；④401——`{"detail":"unauthorized"}`。再用 `swiftc` 直接编译真实生产源文件（`LinoModels.swift`+`LinoAPI.swift`+`LinoErrorPresenter.swift`+`NoticeBus.swift`+`LinoTheme.swift`，未做任何修改）配临时 driver，对同一本地后端跑真实 `APIClient.startWrite`/`jobStatus` 网络请求+真实 `JSONDecoder` 解码+真实 `LinoErrorPresenter.present`+真实 `NoticeBus.publish`，四类场景 26 条断言全过，实测文案：「写正文（mock-400）上游拒绝了这次请求：Model Not Exist | model_not_found | invalid_request_error——请检查模型 Profile 配置，或稍后重试 [llm_upstream_rejected]」（critical=false）、「写正文（mock-blocked）内容被安全策略拦截，上游拒绝生成：SAFETY——请调整本章剧情或人物描写后重试 [llm_content_blocked]」（critical=true）、「写正文（mock-400）连接模型服务失败——请检查网络后重试 [llm_transport]」（critical=false）、「App↔后端登录状态已失效或 Token 不正确——请到设置里重新填写 Token [unauthorized]」（critical=true）；四段五要素（环节/模型/原因/上游原文/建议/code）与 critical 分类均与 plan 设计一致，**未发现需要修复的问题**。**App 级 GUI 视觉验证未能完成，如实记录**：macOS 路线因 ICTW.app 与本机已安装的生产版共享 Bundle ID（`com.lino.linoi.mac`）从而共享 Keychain/UserDefaults，尝试备份生产 `appToken` 时被 auto-mode classifier 判定为"未经授权提取活体 Keychain 凭证"并拒绝执行（正确行为，未强行绕过）；改用完全隔离的新建 iOS Simulator（`LinoI-v123-Verify`，自带独立 Keychain/UserDefaults，零生产风险）重新尝试，App 成功装机启动并正确显示书架空态+连接条，但后续所有坐标点击均被本机常驻的「115浏览器手势增强工具」全屏覆盖层拦截（同一现象在 v1.2.0 块⑤已有独立记录），经多点位测试确认是全屏拦截而非局部；keyboard-only 操作本身可送达（Tab 键无报错），但 iOS 无 macOS 式 Full Keyboard Access 可深度替代点击驱动三层导航；AppleScript System Events 兜底因 osascript 无辅助功能权限被拒（-1728），未尝试代为开权限（属系统安全设置，不在 agent 可动范围）。综合判断：API 层+真实源码 driver 的端到端证据链已足够扎实（覆盖网络层、JSONDecoder 字段映射、呈现器、NoticeBus 全部真实代码路径），GUI 像素级确认留空为诚实记录的已知局限，不影响验收结论。清理：本地 Backend/mock 进程已杀、scratchpad 测试 DB 与临时 iOS 模拟器已删除、被临时关闭又恢复 Booted 的用户自有 `LinoJ-iPhone16Pro` 模拟器已还原、生产 Keychain/UserDefaults 全程未被写入、`git status` 干净。macOS Release 重装：`xcodebuild -scheme LinoIMac -configuration Release -derivedDataPath <scratchpad> -allowProvisioningUpdates` 构建成功（自动签名 `Apple Development: linocai@hotmail.com`，hardened runtime），`codesign --verify --deep --strict` 通过，`osascript quit` 退出运行中的 ICTW → `rm -rf` 旧包 → `ditto`（非 cp）覆盖安装 `/Applications/ICTW.app` → `codesign` 复核仍通过 → `open` 重启，版本确认 `1.2.3(8)`、`Bundle ID com.lino.linoi.mac`、进程运行中（PID 15375，指向真实生产后端与已保存 token，未受本轮任何改动）。后端 `pytest -q` 复跑仍 61 测试全绿（本轮未改 Backend 代码）。全程未修改任何代码，故无 fix commit；仅本行 PROJECT_PLAN.md 记录。下一步：生产发版（备份 `linoi.db` → `git pull` → `alembic upgrade head` 到 `20260711_0006` → 重启 `linoi-backend.service` → 健康检查 → iOS 真机装机留用户手动），需用户在场授权 SSH 后执行。
- 2026-07-11 v1.2.3 发版前独立 review 完成：无 P0/P1，判定可发。迁移/白名单/分类铁律/呈现器映射/两个快修全部核过（依据见审查报告）。当日修掉 P2-1（revision_failed 的 error_context 带 reviser 环节+模型）与 P2-2（test_connection 把响应体传给白名单，测按钮 502 透传上游原因），后端 62 测试全绿（commit bb0938d）；P2-3/P2-4 观察项归 Backlog。
- 2026-07-11 v1.2.3 发版：全链路报错「一眼定位」上线。后端失败 job 落结构化 error_context（agent_role/model_name/http_status/upstream_reason 白名单摘要 ≤200 字）+ 审计表 upstream_reason 列（迁移 20260711_0006）+ 测按钮 502 透传上游原因；客户端共享 LinoErrorPresenter 全 code 中文映射五段式文案，双端 1.2.3(8)。生产部署完成：备份 20260711-200551 → rsync → alembic 0006 → 重启，健康检查 {"status":"ok","version":"1.2.3"}，integrity ok；/Applications/ICTW.app 已为最终包（1.2.3(8) 签名核验）；iOS 真机安装留用户。独立 review 无 P0/P1（P2-1/P2-2 已修）。施工全文移入 archive/v1.2.3施工plan.md。
- 2026-07-11 GitHub Release v1.2.3 发布：tag v1.2.3 + ICTW-1.2.3.zip（ditto 保签名压包，2.6MB）挂上 https://github.com/linocai/Ictw/releases/tag/v1.2.3 ；注明 Development 签名未公证、外机需右键打开放行。
- 2026-07-15 v1.3.2 发版：记忆导出。后端新增 GET /books/{id}/memories/export.txt（【大事记】【章节梗概】【人物记忆】三节：headline/summary/动态字段+故事线，事件按章序+created_at 排，含空态占位与已删章兜底，不含正文）；iOS 书设定页与 macOS 书设定 tab 各加「导出记忆」按钮（复用既有分享/存盘通道，MacExportSaver 通用化）。后端 81 测试全绿（新增 2 条：内容完备性+401/404、空书占位）；双 target 构建绿，版本 1.3.2(11)、后端版本串 1.3.2。生产部署：备份 20260715-182007 → rsync → 重启（无迁移，head 仍 0006），健康检查 1.3.2，真实书验证端点 200/三节/260 行。/Applications/ICTW.app 换装 1.3.2；GitHub Release v1.3.2 已发（ICTW-1.3.2.zip）；iOS 真机留用户。
- 2026-07-16 v1.4.0 立项：前端视觉升级（纯前端，`Backend/` 零改动、无迁移、无部署）。四层：Motion 基建 → 动画平滑 → 视觉 bug 修复 → 两端一致性。五块——①在共享 `LinoTheme.swift` 建 `LinoMotion`（8 语义动画/4 时长阶梯，全 value-based 可打断）+ `LinoRadius`/`LinoSurface`/`LinoType`(SF Rounded)/`LinoReadingTheme` token，13 处存量动画收敛，iOS `.preferredColorScheme(.light)` + macOS `NSApp.appearance=.aqua`+`.preferredColorScheme(.light)` 锁浅色 ②macOS 全站切换点按动效表加 transition/matchedGeometry ③iOS 同步 + 阅读页补 day/sepia/night 三主题（port 自 Mac、自绘主题化顶栏、@AppStorage 持久化）+ 系统 Picker 换自绘 `LinoISegmented` + 字族统一圆体（宋体仅留阅读/封面）④视觉 bug：窄窗双抽屉遮挡、人物 chip 长名截断、night 主题 ProgressView/文本选中蓝、Mac 空态 ⑤双 target 构建 + 截图验收（锁浅色抗深色系统弹层 / 三主题过渡录屏 / 两端一致）+ ICTW 换装 + GitHub Release v1.4.0，iOS 留用户。动效规格与逐切换点 token 分配已在「当前 Plan」定死。双 target 1.4.0(12)。
- 2026-07-16 v1.4.0 块① 完成：`LinoTheme.swift` 追加 5 组 token——`LinoMotion`（`micro/fast/standard/emphasized` 时长阶梯 0.14/0.18/0.22/0.30 + `press/hover/drawer/content/selection/reader/listItem/status` 8 个语义 `Animation`，全部 value-based）、`LinoRadius`（chip8/control10/pill11/field12/card14/panel18/glass20/bar22）、`LinoSurface`（well0.54/card0.68/input0.72/glassTint0.66/panelTint0.18）、`LinoType`（`rounded()` + display30/heading20/cardTitle17/rowTitle15，SF Rounded）、`LinoReadingTheme`（原 `MacReaderView.MacReadingTheme` 整体上移改名，色值一字未改）；本块只建常量，不做全仓字面量替换扫地（圆角/表面/字号站点收敛按 plan 排在块③等后续块，未越块）。`LinoComponents.swift` 追加 `LinoISegmented<Option>`（matchedGeometryEffect 滑动选中底，视觉同构 Mac `LinoMacSegmented`，块③起接入替换系统 Picker）与 `LinoICardButtonStyle`（press 时 scale 0.97 + 阴影收敛，块③起接入书卡/章节行/人物 chip），二者本块只新增定义、未接入任何调用点；`LinoIStatusPill` 改双 key（`LinoMotion.status` 同时 key `status` 与 `text`，对齐老项目 StatusBadge，解决 label 变化不 morph）。存量 13 处动画逐一处理：9 处 `.animation`/`withAnimation` 换 token（`NoticeBus.swift:70`→`content`，`LinoComponents.swift:29`→`status`双 key，`MacReaderView.swift`→`reader`，`MacWorkspaceView.swift` 抽屉×2→`drawer`+ reader×1→`reader`，`MacBookshelfView.swift`→`hover`，`LinoMacControls.swift`×2→`selection`/`content`）；4 处纯 `.transition`（`NoticeBus.swift:64`、`MacWorkspaceView.swift:50/158/169`）按 plan 保留不动，留给块②统一驱动。锁浅色双端落地：iOS `LinoIApp.swift` 的 `RootView()` 加 `.preferredColorScheme(.light)`；macOS 双保险——新增 `AppDelegate`（`NSApplicationDelegate`）在 `applicationDidFinishLaunching` 设 `NSApp.appearance = .aqua`，`LinoIMacApp` 用 `@NSApplicationDelegateAdaptor` 挂载（锁 AppKit 系统面板），`MacShell` 顶层加 `.preferredColorScheme(.light)`（锁 SwiftUI 层）。`MacReaderView.swift` 引用改用共享 `LinoReadingTheme`，本地 `MacReadingTheme` 定义已删除（5 处引用点同步改名）。验收：iOS `LinoI`（iphonesimulator）+ macOS `LinoIMac`（platform=macOS）`xcodebuild build` 双绿、`error:` 计数均为 0。深色系统下的 GUI 冒烟截图**未能完成**，如实记录：系统切至 `AppleInterfaceStyle Dark` 后用 `open -n` 单独拉起本次新编译的 Debug `ICTW.app`（`lsappinfo` 核实其 PID 与 bundle path 均非 `/Applications/ICTW.app`，生产实例全程未被触碰），尝试用 ⌘, 唤出 Settings sheet 截图验证时，computer-use 连续两次报 `user interrupt` 中止；核对 `ioreg` `HIDIdleTime` 实测约 0 秒，确认用户当时正在真实使用本机，判定为工具正确的安全拦截而非环境故障，未强行绕过。已第一时间将系统外观改回浅色（`defaults read -g AppleInterfaceStyle` 确认已还原为未设置/浅色）、`kill` 掉本次自建的两个 Debug 测试进程（生产 PID 全程存活未受影响），未产生任何数据变更。代码层双锁均已用 `grep` 核对确认写入正确位置；深色下系统弹层的像素级验收按 plan 本属块⑤正式验收范围，留待彼时（或用户不繁忙时）补齐。下一步：块②（macOS 动画平滑）。
