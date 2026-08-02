# ICTW PROJECT_PLAN

> 本文件是唯一现行计划与状态来源。历史记录以 [`archive/v1.6.0施工plan.md`](archive/v1.6.0施工plan.md) 为准；归档与本文冲突时，以本文为准。

## 当前状态

- 已发布基线：`v1.7.0(21)`（2026-08-02）；本版仅发布 iOS「纸与墨」原生 SwiftUI 视觉体系与全新 App Icon，Backend、Alembic 与 macOS App 维持 `v1.6.5(20)`，Alembic head 仍为 `20260801_0008`。
- 当前状态：v1.7.0 阶段 0–5 全部完成；LinoI target 已升至 `1.7.0(21)`，正式 iOS Archive、本机开发签名 IPA、tag 与 GitHub Release 均已完成，无进行中的版本施工。
- 设计事实源：[`README.md`](design_handoff_ios_visual_upgrade/README.md) §3–§9 为尺寸与状态规格；[`02 视觉升级 · 可点原型.dc.html`](design_handoff_ios_visual_upgrade/02%20视觉升级%20·%20可点原型.dc.html) 仅用于阅读结构和交互；`screenshots/` 是逐屏验收基准。
- 截图均为 iPhone 17 Pro `402×874 pt` 的 `804×1748 px @2x`。`05-Agent与模型.png`=`06-Agent详情.png`、`14-空态.png`=`01-书架.png`（SHA-256 相同）；这两项以 README §6.2／§6.5 和可点原型的对应状态为准，不把重复图片当作基准。
- 工作树已有用户改动：`.learnings/ERRORS.md`、`App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme`；以及未跟踪的 `design_handoff_ios_visual_upgrade/`。施工不得改动、暂存、覆盖或回滚它们。
- 已使用现有 iOS 26.5 runtime 创建标准 `ICTW-v170-iPhone17Pro`（402×874 pt）Simulator；浅／暗模式、空态与全部主要动态状态均在该设备完成逐屏矩阵，不以其他机型替代 90% 门槛。

### 本轮施工进度（2026-08-02）

- 阶段 1：iOS 动态纸墨色板、SF Pro／宋体分工、实色控件、Toast、浅暗模式与转场已落地；macOS 条件分支保持原外观。
- 阶段 2：书架、稿件／人物／设定三段工作台、Agent＋Profile 二级／三级页已完成；所有原入口和回调保留。
- 阶段 3：章节编辑器已改为宽松表单、四步流程、真实失败原因、人物豁免、留痕抽屉、Extractor 与吸底栏；阅读器已完成独立三主题、三字号、轻触 chrome 与原生 `Aa` 浮层。
- 已通过 `Tests/run_client_state_tests.sh`、iOS Debug build、macOS Debug build 与 `git diff --check`；源码审计未发现 iOS WebView／HTML 移植、旧渐变调用或非阅读 Material。
- 阶段 4：使用仅位于 `/tmp` 的本地数据库与临时 UI 测试工程，在标准 iPhone 17 Pro Simulator 完成两轮全链路交互；浅色覆盖书架、稿件、人物、人物详情、编辑器输入／流程、失败＋人物豁免、写作上下文、Checker 证据、Extractor、阅读／Aa、设定、Agent 列表／详情，暗色覆盖同一主链。两轮测试均为 `0 failures`，截图逐屏对照交接稿后未发现遮挡、溢出或低于 90% 门槛的结构性偏差；原生字体渲染与测试文案差异计入约定容差。
- 阶段 5：**LinoI target** 已升至 `1.7.0(21)`；新 App Icon 已进入正式资源，iOS Release Archive 完成开发签名、包内版本校验并导出本机 IPA，随后发布 `v1.7.0` tag 与 GitHub Release。Backend、Alembic 与 macOS 未部署、迁移或换装。

## 目标、边界与不变量

**目标**：在不改变功能的前提下，将 iOS 从蓝色玻璃 SaaS 风升级为高保真「纸与墨」；每个指定基准屏的视觉评分不低于 90%，只允许原生控件、安全区、字体渲染、动态数据与无障碍造成的 10% 差异。

- 仅改 iOS 前端视觉和既有 iOS 导航编排；Backend、API 契约、业务模型、Store、状态机、数据与 macOS 外观均不变。
- 最终产物仅使用现有 Swift／SwiftUI；禁止 WebView、WebKit、HTML/CSS/JS、React、跨端容器、新依赖、新 target 或工程重构。`.dc.html` 的 class/style/演示定时器和假数据不得移植。
- 既有按钮、字段、状态和数据入口必须可达；只能依照下方导航重组改变位置。不得硬编码交接稿的书、人物、章节或 Agent 演示文案。
- 绝不改变 Bundle ID、target 名、Keychain 键、UserDefaults 键（包括 `linoi.reader.fontScale`、`linoi.reader.theme`）、`LinoI/ChapterDrafts`，也不改 `chapter_style`／wire 兼容。

### 禁止修改

| 范围 | 禁止原因 |
| --- | --- |
| `Backend/**`、Alembic、部署／生产库 | 本版无后端、迁移或运维范围。 |
| `App/LinoI/LinoAPI.swift`、`LinoModels.swift`、`LinoStores.swift`、`ChapterDraftCache.swift`、`LinoErrorPresenter.swift` | 网络、模型、状态机、本地草稿与错误语义零变更。 |
| `App/LinoIMac/**`、`App/LinoIMac/Info.plist` | macOS 暂不做视觉或功能变更。 |
| `App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme` | 用户自己的未提交修改。 |
| `design_handoff_ios_visual_upgrade/**`、`.learnings/ERRORS.md` | 设计输入／用户文件只读，不纳入产品实现。 |
| `App/Tests/**` | 不借视觉升级修改共享行为或既有状态测试。 |

`App/LinoI.xcodeproj/project.pbxproj` 在施工阶段不改；仅在所有验收通过且用户另行授权发包时，才可只改 **LinoI target** 的 Debug/Release `MARKETING_VERSION=1.7.0`、`CURRENT_PROJECT_VERSION=21`。不得触碰 LinoIMac 配置或任何 scheme。

## 已确认的实现决定

### 视觉系统与平台隔离

- `LinoTheme.swift`、`LinoComponents.swift`、`NoticeBus.swift` 是双 target 编译的共享文件。纸墨 token、控件、Toast 和阅读玻璃仅置于 `#if os(iOS)`；现有 macOS token／圆体／渐变／glass 实现保留在 macOS 分支，`App/LinoIMac/**` 零 diff。不得以修改共享默认值影响 Mac。
- 在 `LinoTheme.swift` 定义 iOS 专用的动态「纸与墨」token：浅色 `bg #F4F2ED / surface #FFF / ink #17181C / accent #C0472C`，暗色 `#121316 / #1B1D21 / #EDEBE6 / #E2664A`；同时落实 README §5 的 `bg2`、`surface2`、`ink2`、`muted`、`faint`、`line`、`line2`、绿／琥珀／危险及三套封面纸色。移除 iOS 所有蓝色渐变和大阴影，卡片仅 `1px line` 与 `0 1px 2px` 轻阴影。
- iOS 专用字体 token：作者内容一律 `Songti SC`（书／章／人物名、正文、Bible、摘要、世界观、人格、封面）；系统文案使用非 rounded 的 SF Pro；URL、错误代码、Temperature 使用 SF Mono。标题／正文／标签字号、行高、页边距、圆角、56+安全区 tab bar 等逐项按 README §3、§5、§6，不以系统默认间距替代。
- 删除 iOS 的 `.preferredColorScheme(.light)`，由系统明暗驱动上述动态 token；阅读器仍以独立的日间 `#F8F6F1`、护眼 `#F1E7D2`、夜间 `#17181A` 三主题工作，保留现有 AppStorage raw 值。
- 非阅读页不得调用 `.glassEffect`／`Material`；仅阅读页顶栏、底部工具条、`Aa` 浮层可用规格中的原生模糊。所有圆角用 continuous：卡／列表 16、按钮 14、内块 11–12、胶囊 999。
- 动效只用现有 `LinoMotion` 时长：换屏／tab 上浮 7pt + 淡入 `0.22s easeOut`（旧树直接移除，不交叉淡化），折叠 `0.20s`、sheet `spring(0.34, 0.86)`、按钮 `0.18s`、行按压 `0.14s`。进行中点仅在未启用“减少动态效果”时 1.1s 呼吸；主题颜色 `0.25s`，正文不参与隐式动画。

### 原生导航、页面与状态

`书架 → 书内 TabView（稿件／人物／设定）→ 章节编辑器 push → 阅读页 fullScreenCover`；`设定 → Agent 与模型 push → Agent 详情 push`；后端连接由书架和设定进入同一个 sheet。保留 `WorkspaceTab.agents` 数据兼容，但 iOS TabView 仅渲染前三项，若遗留 UI 选中 `.agents` 则仅在 View 层归位到 `.settings`；不得改 Model／Store。

| 页面／组件 | 原生落地与必须保留的行为 |
| --- | --- |
| 书架 | 等分两列、稳定 book-id 种子轮换三种纸封；竖排宋体书名、书脊／压边框、虚线新建书、连接胶囊。计数／日期仅用现有 `Book` 数据。 |
| 稿件／人物／设定 | 章节为单卡多行 60pt、状态点保留 `linoStatusLabel`；人物改 58pt 竖行＋详情卡、动态字段分组和故事线；设定为书／导出／模型连接三组。 |
| Agent | 将当前绑定／人格堆页拆为 Agent＋Profile 列表与单 Agent 详情；保留绑定、思考、强度、Temperature、人格恢复／保存、Profile 新增／编辑／测试／删除及现有 capability 禁用逻辑。 |
| 编辑器 | 自绘 46pt 顶栏仍调用现有保存／删除；保留草稿恢复、Bible、人物、四步、预览／编辑、导入、重试／停止／豁免／接受／阅读和 Extractor。两个 DisclosureGroup 合为「留痕」两行抽屉，数据仍取现有 context／visible checker 字段；底部 48pt 操作栏不遮挡输入。 |
| 阅读器／系统反馈 | `Aa` Menu 改原生浮层，点正文收起／展开 chrome；三档字号仍为 16／19／22、行高约字号 2 倍，短横分隔。小／大 sheet、原生 destructive confirmationDialog、读取中／失败、空态、正常／critical Toast 均按 README §6.7–§8 重画，语义、回调与自动消失时长不变。 |

## 分阶段施工计划

| 阶段 | 文件边界与顺序 | 完成门槛 |
| --- | --- | --- |
| 0. 施工护栏 | 只读确认 handoff、git diff 与 iOS target；不建文件、不改项目设置。 | 记录禁止范围；确认没有把用户 scheme／交接稿纳入 diff。 |
| 1. iOS 纸墨底座 | `LinoTheme.swift`（iOS 条件 token／字体／阅读 palette／动效）、`LinoComponents.swift`（iOS 条件卡、字段、按钮、状态点、小节、空态、流程）、`NoticeBus.swift`（iOS Toast）、`LinoIApp.swift`（解除强制浅色、根背景／转场）。 | 浅暗切换、字体分工、无蓝渐变／rounded、非阅读玻璃清零；共享文件 macOS 编译通过且 macOS 源码零改动。 |
| 2. 工作台与导航 | `ShelfViews.swift` → `WorkspaceViews.swift` → `CharactersViews.swift` → `SettingsViews.swift`。先书架和三段 TabView，再章节／人物／设定，最后 Agent 列表／详情及复用连接 sheet。 | 原四 tab 中 Agent 完整迁至设定二级页；所有建书、建章、人物、导出、连接、Agent／Profile 操作仍可达。 |
| 3. 写作与阅读 | `ChapterEditorViews.swift`：顶栏、宽松表单、流程／失败、留痕、Extractor、吸底栏；`ReadingViews.swift`：独立主题、chrome 轻触、Aa 浮层、阅读比例。 | 真实 Store 驱动的加载、恢复、生成／取消／失败／豁免、checker、归档和翻章均只改外观。 |
| 4. 逐屏收口 | 只回改上述 iOS 视觉文件；逐屏捕获、对照和修正 token、基线、间距、长文／长标题、暗色及减少动态效果。 | 16 项视觉矩阵全过，自动与手动回归全过，工作树只含允许文件。 |
| 5. 发版（已完成） | 仅 iOS target 版本号升至 `1.7.0(21)`，生成正式 Archive 与本机开发签名 IPA，提交并发布 tag／GitHub Release。 | Release Archive、IPA 导出、签名、包内版本、双端编译与客户端状态测试通过；Backend、Alembic、macOS 均无发布动作。 |

## 验收与回归门禁

### 自动与边界门禁

每阶段结束运行受影响 iOS Debug build；阶段 1 触及共享文件时额外运行 macOS Debug build，仅验证编译和未回归，不做 macOS 视觉升级。阶段 4 必须全部通过：

```bash
cd App && Tests/run_client_state_tests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project App/LinoI.xcodeproj -scheme LinoI -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project App/LinoI.xcodeproj -scheme LinoIMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

- 复核 diff：禁止范围无变动；`App/LinoIMac/**`、用户 scheme、`Backend/**` 为零 diff；若触及 `.pbxproj`，发布前不得存在且最终仅允许两组 LinoI target 版本值。
- 源码审计：无 `WebKit`／`WKWebView`／HTML／JS／CSS／React／新 package；iOS 仅阅读三处使用 Material／glass；无 `.rounded` 或 `coverGradient`／旧蓝渐变残留在 iOS 视图路径。
- 不为截图加 demo 开关、mock Store、假定时器或后端分支；用可丢弃的本地开发数据和既有交互进入状态，截图不含生产文本、Token 或密钥。

### 90% 视觉验收

1. 在标准文字大小、Display Zoom 默认、浅／暗模式的 iPhone 17 Pro 运行 iOS Debug；每屏通过 `xcrun simctl io <udid> screenshot` 捕获，必要时用 `sips -z 1748 804` 统一为 `804×1748`，不得裁切安全区。
2. 对 `01–16` 同名基准逐张叠图检查；重复的 05／06、14 按本计划「当前状态」的 README／原型定义补拍 Agent 详情与章节空态。真实数据仅可导致文案不同，不能改变层级、控件、位置或状态样式。
3. 每屏按几何／安全区 30、色板／表面 20、字体／行高 20、导航／控件 20、状态呈现 10 评分；每屏和平均均须 `≥90/100`。10 分容差仅用于已声明的原生差异，不可用于遗漏页面或功能。
4. 另做交互走查：三 tab、Agent／Profile／连接、所有 sheet／确认、空态、读取中／失败、草稿恢复、生成中／停止、失败＋豁免、两种留痕展开、Extractor、阅读三主题／三字号／chrome、Toast、浅暗切换与减少动态效果。长标题、长人物名、长 Bible 和 VoiceOver／Dynamic Type 不得溢出或遮挡吸底栏。

## 风险、回滚与待办

| 风险 | 控制／回滚 |
| --- | --- |
| 共享 Theme／组件意外改变 macOS | 仅 iOS 条件分支、macOS build 和零源码 diff；失败即回退该 iOS 分支，不改 Mac 文件。 |
| 视觉重排误接 Store 或失去入口 | 逐项对照现有回调，阶段 2／3 交互走查；发现即回退该 View 的布局提交，数据／API 从未迁移。 |
| 动态色、长文本或安全区偏离基准 | 以真机型截图和 90 分评分收口；未达标不得进入版本号／发包阶段。 |
| 基准 Simulator 缺失 | 安装 iPhone 17 Pro runtime 后再启动视觉验收；在此之前可以实现和构建，但不能声明 v1.7.0 验收完成。 |

- 回滚不涉及数据库、迁移、Backend 或本地数据：revert v1.7.0 的允许 iOS UI 改动并重新构建 LinoI；不得清理 Keychain、UserDefaults 或草稿目录。
- 无用户网页操作。App Store Connect 上传与设备安装未执行；如需分发，由用户通过已生成 Archive 继续操作。

## 里程碑与 Backlog

- `v1.5.0(14)`、`v1.6.0(15)` 至 `v1.6.5(20)`：均已发布；完整部署、发布和 iOS 未发包记录见 [`archive/v1.6.0施工plan.md`](archive/v1.6.0施工plan.md)。
- `v1.7.0(21)`：iOS 视觉施工、全状态逐屏验收、全新 App Icon、正式 Archive、本机开发签名 IPA、tag 与 GitHub Release 已完成；Backend 与 macOS 不在本版升级范围。
- 宁波云迁移、阅读器功能增强和 v1.6 记忆参数评估继续保留为非本版本 Backlog；云迁移仍受既有 ICP／DNS／停服门禁约束。
