# ICTW PROJECT_PLAN

> 本文件是唯一现行计划与状态来源；与归档冲突时以本文为准。完整 v1.6 施工与发版记录见 [`archive/v1.6.0施工plan.md`](archive/v1.6.0施工plan.md)。本次仅收口本文件，不新建平行计划或归档。

## 当前状态

- `v1.7.1(23)` 双端补丁发版已完成：iOS 与 macOS 的 Debug/Release 均统一为 `1.7.1(23)`；客户端状态测试、双端 Debug、双端签名 Release Archive、包内版本／Bundle ID／架构／签名复核均通过。iOS 已导出本机开发签名 IPA，未上传 App Store Connect；macOS 已完成通用架构 Archive、正式 App 换装并启动。统一 tag 与 GitHub Release 为 `v1.7.1`，公开资产仅含 macOS ZIP。
- Backend `v1.7.1` 人物记忆快修已完成并部署。根因是 v1.6 Extractor 只收到无姓名映射的 UUID 白名单，模型无法把正文姓名可靠绑定到人物 ID，而后端只校验 ID 在白名单内便直接落库；前端只是原样展示，不是故障源。
- 现行合约：Extractor 只输出白名单内精确人物姓名，后端机械映射 UUID；人物事件／动态字段必须有可定位的正文证据，事件文本必须明确所属人物；事件类型、中文动态字段和关系键固定化。代词证据只在所属人物出现在该证据或其前置近邻正文时接受，非法条目整次回滚。
- 单书重建采用“在线演练生成 0600 验证包 → 章节／Bible／人物状态指纹复核 → 停服原样原子提交”，正式落库不再二次调用模型。生产备份为 `/opt/linoi/backups/20260803-152134`；《骁扬》8 个已定稿章节已重建为 54 条事件、22 条字段补丁，10 人物中 8 人有动态更新。
- 最终门禁：Backend 97 项测试、compileall、`git diff --check`、Alembic `20260801_0008`、内外网 `1.7.1` 健康、SQLite integrity／foreign keys 全绿。54 条事件错挂、非法事件类型、非法动态／补丁 key、章节记忆人物错挂均为 0；正文、Bible、标题、大事记、摘要与备份逐字一致，另外两本书的业务表哈希全部一致。Backend 快修无 migration，随后仅改双端版本号完成 `1.7.1(23)` 客户端发版。
- 上一目标完成记录：`LinoIMac` 的原生 SwiftUI 前端已升级为 iOS `v1.7.0(22)` 已验收的“纸与墨”体系；代码、自动回归、正式 Archive、本机换装、Git Tag 与 GitHub Release 全部完成，发布号为 `1.7.0(22)`。
- 视觉事实源仅为仓库内的 iOS 成品：`App/LinoI/LinoTheme.swift`、`LinoComponents.swift`、`NoticeBus.swift` 及 Shelf／Workspace／Characters／Settings+Agent／Editor／Reader 页面；无新的外部设计稿。
- macOS Debug/Release 与本机正式 App、`LinoI` Debug/Release 当前均为 `1.7.1(23)`；Backend 为 `1.7.1`，Alembic head 保持 `20260801_0008`。
- 用户工作树不干净：`.learnings/ERRORS.md`、`App/LinoI.xcodeproj/xcshareddata/xcschemes/LinoIMac.xcscheme`、`design_handoff_ios_visual_upgrade/` 均为用户资产；不得查看以外改动、暂存、覆盖、回退或纳入验收产物。
- 本轮代码变更：`LinoTheme` macOS 动态纸墨 token／阅读 token、`NoticeBus` macOS Toast 与 `App/LinoIMac` 的窗口 chrome、书架、三栏、人物、Agent、编辑器纸面层级；iOS 条件路径、业务 Store、导出与命令路由未改。
- 已验证：`Tests/run_client_state_tests.sh`、iOS Debug build、macOS Debug build 和 `git diff --check` 通过；禁止路径（Backend、工程设置、iOS 页面、`MacCommandBus`、`MacExportSaver`）零 diff，`LinoIMac` 仍为 `1.6.5(20)`。
- 隔离 QA 使用独立 bundle、临时 token、仅绑定 `127.0.0.1` 的临时 SQLite 完成，不读取既有 Keychain／数据；已实测浅／深书架、三栏与最小断点、长名称、人物／书设定／Agent、旧正文保留失败与 Checker 输入、reader day/sepia/night／字号／导航／Esc、新建与设置 sheet、File 菜单、连接失败与恢复，以及原生 `NSSavePanel` 打开后取消。结果留在 `/tmp/ictw-visualqa.qyoSop/screenshots`。
- QA 发现并修复两项 macOS 反馈缺陷：新建作品卡的 `3:4` 比例原施加在 label 导致卡片横置，现移至 Button；连接失败时曾同时显示“未连接”和成功文案，现以本次 `NoticeBus` 真实错误取代成功反馈，隔离 `127.0.0.1:1` 已复验。
- 隔离 QA 与双端回归门禁均已完成；未调用外部模型，Writer／Checker／Extractor 使用无副作用的种子状态核验；发布授权前未驱动当前机器的 `/Applications/ICTW.app`。
- 2026-08-03 用户授权正式发版：仅 `LinoIMac` 的 Debug/Release 升至 `1.7.0(22)`；客户端状态测试、iOS/macOS Debug 与签名 macOS Release Archive 全绿。Archive 为 `arm64 + x86_64`、Apple Development 签名，包内版本与 Bundle ID 正确。本机 `/Applications/ICTW.app` 已换装、验签并启动 `1.7.0(22)`，旧版备份位于 `/tmp/ictw-app-backup-v170-macos.QcSXpq/ICTW-v1.6.5-build20.app`。发布 ZIP 为 2,290,209 B，SHA-256 `b26f4d379c8040c820b2bb9f25157a5a795a4ee0c10bb636b5b1c09a77863956`；实现提交 `1ff31b9`，annotated tag `v1.7.0-macos-build22` 指向该提交，main、tag 与 GitHub Release <https://github.com/linocai/Ictw/releases/tag/v1.7.0-macos-build22> 均已发布，云端资产 digest 与本地一致。Backend 与 iOS 无发布动作。
- 2026-08-03 双端发版产物：iOS IPA 2,532,604 B，SHA-256 `f41ca04a1df5e6b427c0732090761c31e08b17d294edfb095f75d21b62fb36a2`；macOS ZIP 2,290,210 B，SHA-256 `57fe07bccb0aa56f690ea099b8f0a8c65ffb41392553aea8683e6fb85cd55f8f`。本机旧 macOS App 备份位于 `/tmp/ictw-app-backup-v171.Tif6J5/ICTW-v1.7.0-build22.app`。
- 下一步：无进行中的版本施工；等待用户安装 iOS 包并实测后续章节的 Extractor 结果。

## v1.7 iOS 完成记录（凝缩保留）

- `v1.7.0(21)`：iOS 纸墨视觉、全状态逐屏验收、新 App Icon、正式 Archive、本机开发签名 IPA、tag 与 GitHub Release 已完成。
- `v1.7.0(22)`：修复书架“新建”卡片尺寸，独立复审、正式 Archive、本机开发签名 IPA、`v1.7.0-build22` tag 与 GitHub Release 已完成；Backend 与 macOS 未变更。
- iOS 的 palette、排版、实体卡片、阅读器层级与反馈语义是本轮唯一基线；其 target、版本、资源和业务逻辑均冻结，后续共享文件改动必须证明 iOS 零回归。

## 目标、边界与发布门禁

- macOS 交付：在保留单窗口、三栏／侧栏、抽屉、鼠标悬停、键盘快捷键、菜单、原生 sheet 与 `NSSavePanel` 的前提下，使所有工作界面呈现同一套纸墨语言；不是把手机两栏或底部 Tab 放大到桌面。
- 保持所有模型、Store、API、写作状态机、草稿恢复、任务所有权、Checker／Extractor 行为、连接与导出行为原样；只调整 macOS 视觉结构和允许的共享视觉条件分支。
- 本轮绝不改 `App/LinoI.xcodeproj/project.pbxproj`、scheme、Bundle ID、Keychain／UserDefaults／本地草稿／wire 标识或版本号。仅在全部验收通过且用户另行明确授权发版后，才可将 **LinoIMac 的 Debug 与 Release** 同时改为 `MARKETING_VERSION=1.7.0`、`CURRENT_PROJECT_VERSION=22`；`LinoI` 两组值不得触碰。
- 禁止触碰 `Backend/**`、Alembic、生产数据、部署文件；禁止改 iOS 专属业务／页面／资源文件、`.learnings/**`、`design_handoff_ios_visual_upgrade/**`、用户 scheme 与未跟踪交接物；不 commit、tag、release、deploy、Archive、安装或上传。

## 稳定视觉决定

| 范畴 | iOS 基线 | macOS 落地决定 |
| --- | --- | --- |
| 色彩与表面 | 暖灰背景、白／深灰纸面、朱红强调、低对比墨线 | `LinoTheme` 的 macOS 分支采用同值动态 light/dark palette；普通工作面改为实体 paper surface，淘汰蓝色渐变和泛用 glass。仅阅读器浮层／原生 transient chrome 可保留克制 material。 |
| 字体与层级 | SF 作为操作 UI，Songti 为书名、正文和叙事标题；16pt card、14pt control 圆角 | macOS 使用同一字体分工、色阶、1px 边线、16pt card／14pt control；允许更密的信息密度，但不再使用 rounded-SaaS 标题体系。 |
| 书架与工作区 | 3:4 纸书脊、层级清楚的章节行、纸面分区 | 书架保留自适应多列与 hover/context menu；工作区保留 258pt 左栏、中心编辑区、326pt 右栏及原有断点／抽屉，不复制手机底部导航。 |
| 编辑与阅读 | 编辑是可操作的分层纸面；阅读器是低干扰独立阅读面 | 编辑保留桌面 toolbar／快捷操作与完整状态链；阅读器保留全屏、Esc、A-/A+、选择文本和 macOS 独立偏好键，只映射主题与 chrome 层级。 |
| 动画与反馈 | 快速、低幅度、成功／警告／失败颜色语义一致 | 维持现有 hover、focus、键盘与加载可达性；采用同一 `LinoMotion` 节奏，Toast、空态、加载、错误和生成失败统一纸墨语义，禁止以动画掩盖失败。 |

## 允许改动面与共享约束

- 共享视觉入口仅限 `App/LinoI/LinoTheme.swift`、`LinoComponents.swift`、`NoticeBus.swift`：保留公开 API、回调、iOS 分支和业务语义；新增或改动必须局限 `#if os(macOS)` 路径。`LinoTheme` 的 macOS 动态色使用 AppKit appearance provider，与 iOS token 数值对齐；阅读主题同样对齐，但保留 macOS 既有偏好键。
- macOS 可改：`LinoIMacApp.swift`、`MacShell.swift`、`LinoMacTheme.swift`、`LinoMacControls.swift`、`MacBookshelfView.swift`、`MacNewBookSheet.swift`、`MacConnectionView.swift`、`MacSettingsSheet.swift`、`MacWorkspaceView.swift`、`MacChapterSidebar.swift`、`MacRightPanel.swift`、`MacBookSettingsTab.swift`、`MacCharacterTab.swift`、`MacAgentTab.swift`、`MacChapterEditor.swift`、`MacReaderView.swift`。
- 不改 `MacCommandBus.swift`、`MacExportSaver.swift` 的行为或 API；其入口、菜单、快捷键、AppKit 控件、确认框和 `NSSavePanel` 必须仍可达。除非实测发现纯视觉编译阻塞，否则不扩大此名单。

## 执行计划

### Phase 0 — 保护基线与可回滚边界

状态：完成。用户三项工作树资产已隔离，版本与禁止路径已复核；未建立 mock、资源、依赖或 target。

- Builder 首先复读本计划、`git status --short` 与 iOS／macOS 的四组版本配置；记录用户已有三项工作树变更，确保 diff 起点只含自身改动。
- 建立页面—状态—交互检查表，不建 mock、假数据、图片资产、依赖或新 target；将截图输出放在仓库外临时目录，禁止写入用户未跟踪 handoff。
- 每阶段结束执行 `git diff --check`，逐文件确认没有 Backend、iOS 专属页面、工程设置或版本配置漂移；发现业务回归即撤销**本阶段自身的可识别改动**，不动用户变更。

### Phase 1 — 纸墨基础与窗口 chrome

状态：完成。macOS 动态 light/dark 纸墨 token、实体 toolbar／sidebar／panel、SF/Songti 分工及非强制浅色均已落地。

- 先改共享文件的 macOS 条件分支：令 palette、reading palette、字体、圆角、边线、状态色、Toast／空态／输入／生成卡对齐 iOS；不改变任何 iOS 条件分支、组件签名或 `NoticeBus` 生命周期。
- 在 `LinoMacTheme` 将 toolbar／sidebar／panel modifier 重定义为分层实体纸面，统一 hover/focus/pressed；在 `LinoMacControls` 重绘 icon、连接状态和分段控件，保留 pointer、help 与 accessibility label。
- 在 `LinoIMacApp` 与 `MacShell` 移除 `.aqua`／`.preferredColorScheme(.light)` 强制锁定，使系统 light/dark 生效；保留 AppDelegate、Commands、窗口最小 `1080×720`、root state、overlay 顺序和所有命令路由。
- 验收：macOS light/dark 启动都无蓝色渐变、全局玻璃墙或强制浅色；iOS build 与关键书架／编辑／阅读冒烟截图不变。

### Phase 2 — 书架、连接与全局反馈

状态：完成（代码、构建与连接失败隔离实测）。书架改为 3:4 纸书封／虚线新建卡，连接和 Toast 走动态实体纸面；连接失败会在表单内显示既有真实错误。

- `MacBookshelfView`／`MacNewBookSheet` 采用 iOS 纸书脊、3:4 封面、朱红主操作、新建虚线卡和实体空／加载／错误面；保持桌面自适应多列、悬停抬升、右键删除、焦点和提交行为。
- `MacConnectionView`／`MacSettingsSheet` 改为纸面表单、分组和明确错误反馈；不改 Keychain、连接测试、保存、关闭或原生 sheet 逻辑。
- 验收：书架正常、空、加载、连接失败和删除确认均有一致 toast／error 语义，宽窗口不降为手机两列。

### Phase 3 — 三栏工作台、人物、设定与 Agent

状态：完成。三栏和 drawer 保持原断点／菜单／快捷键，人物、书设定、Agent inspector 已切换至动态纸面；长文本、最小窗口与 drawer 已由隔离 QA 复核。

- `MacWorkspaceView`、`MacChapterSidebar`、`MacRightPanel` 以纸面标题栏、章节行、侧栏 tab／抽屉和分区重构层级；保留 ≥1100 三栏、`1080×720` 右栏抽屉、既有更窄布局代码、菜单和快捷键。
- `MacCharacterTab` 映射 iOS 人物的列表／细节／空态／导入反馈，保留桌面 chip flow、选择、编辑、删除和菜单；`MacBookSettingsTab` 映射书籍设定分组，同时保留导出入口与 `NSSavePanel`。
- `MacAgentTab` 映射 iOS Agent 的 profile／绑定／persona 信息层级为桌面 inspector／可展开组，而非强制 push 页面；所有 picker、toggle、effort、temperature、保存和错误行为不变。
- 验收：超长书名、章节名、人物名与 persona 不截断关键操作；右栏收起时每个 tab 仍可从 drawer 完整操作。

### Phase 4 — 编辑状态链与阅读器

状态：完成。编辑器保留既有四阶段、Checker／Extractor、恢复和导入回调并改用纸面层级；阅读器三主题、宋体正文、字号、导航、Esc 与 macOS 偏好键已由隔离 QA 复核。

- `MacChapterEditor` 以 iOS 的标题、Bible、人物 chips、四阶段（Memory Selector → Writer → Bible check → Extractor）、context／Checker trace、预览／编辑和底部行动语义重排为桌面纸面；保留所有现有 callback、任务轮询、确认框、重试、旧正文与错误分类。
- `MacReaderView` 采用 iOS day／sepia／night paper palette、Songti 正文、低干扰 chrome 与阅读设置层级；保留原生选择／两端对齐、全屏 overlay、主题切换、A-/A+、Esc／Return、章节导航及 `linoi.mac.reader.*` 键。
- 验收：长正文可连续阅读且不挤压操作栏；生成失败、Checker 未通过、Extractor 完成、阅读设置切换和退出阅读器均可回到原路径。

### Phase 5 — 双端回归、视觉签收与待授权发布

状态：完成。自动回归与隔离视觉 QA 已覆盖核心书架、三栏、inspector／editor、reader、sheet、菜单、连接失败和 `NSSavePanel`；外部模型链以无副作用种子状态核验。版本、Archive、换装、tag 与 GitHub Release 已全部完成。

- 先完成下列构建和客户端状态回归，再做实际 macOS 交互与截图矩阵；不因视觉通过跳过 iOS shared-file 回归。

```bash
cd App && Tests/run_client_state_tests.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoI \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project App/LinoI.xcodeproj -scheme LinoIMac \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

git diff --check
git status --short
```

- 截图与交互矩阵（每项均需 light/dark，阅读器另含 day/sepia/night）：①书架正常／空／加载／连接错误／新建与删除确认；② `1280×840` 三栏工作台及 `1080×720` 最小窗口右栏 drawer；③长书名、长章节、长人物、长 persona 和长正文；④人物、书籍设定、Agent profile／绑定／persona；⑤ editor idle／生成中／上游失败／Checker 未通过／Extractor 完成／恢复旧正文；⑥ reader 字号、主题、选择、导航、Esc；⑦ Toast、错误、空态、sheet、菜单、快捷键、`NSSavePanel` 入口。
- 每张图以 iOS 成品源代码的 palette、字体分工、卡片／边线／圆角、编辑—阅读层级及反馈语义评分；桌面排版、三栏密度、hover 与原生控制可不同。任一核心页视觉总分低于 90/100 或功能不可达不得进入发布门禁。
- 签收前逐项审查 diff：共享文件仅有 macOS 条件变化；LinoI 版本和所有禁止路径无差异。该门禁已通过，用户随后授权将 `LinoIMac` 升至 `1.7.0(22)` 并完成正式发版。

## 风险、回滚与 Backlog

- 最大风险：共享 `LinoTheme`／`LinoComponents`／`NoticeBus` 的视觉改动意外影响 iOS，及将 macOS 纸墨化时误伤三栏断点、键盘菜单或生成状态链。缓解方式是 macOS 条件隔离、每阶段 Mac build、Phase 5 双 target build 与真实状态矩阵。
- 次要风险：dark mode 解除强制浅色后出现 AppKit／SwiftUI 色彩不一致；以动态 token 和 light/dark 截图逐面校正，绝不恢复全局浅色锁定来掩盖问题。
- 回滚：只回退本轮可识别的 macOS／macOS 条件视觉 diff；不回退用户已有 worktree 变更，不触碰数据、迁移或发布状态。未获版本授权时回滚不涉及 `project.pbxproj`。
- Backlog：宁波云迁移、阅读器功能增强、v1.6 记忆参数评估及任何 Backend 改动均不随本计划推进；外部网页操作清单：无。
