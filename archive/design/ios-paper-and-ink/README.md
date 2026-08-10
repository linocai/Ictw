# 交接稿：LinoI iOS 视觉升级（代号「纸与墨」）

## 0. 给施工 Agent 的第一条说明（务必先读）

**这个包里的 `.dc.html` 文件是设计参考稿，不是要交付的代码。**

它们是用 HTML/CSS/JS 画出来的 SwiftUI 界面效果图 + 可点原型，只是为了让人能在浏览器里看到和点到最终效果。

**落地施工时必须用纯 Swift / SwiftUI 实现，直接修改现有工程 `App/LinoI/*.swift`。**

严禁：

- 引入 WKWebView / WebKit 承载 HTML
- 引入 React / JS / CSS 任何形式的跨端方案
- 把 HTML 里的 class、style 字符串搬进 Swift
- 新建 target 或重写工程结构

正确做法：**读懂 HTML 稿的视觉规格（本文档已把所有数值列出），用 SwiftUI 原生 View、`Font`、`Color`、`RoundedRectangle`、`TabView`、`NavigationStack` 重新实现。**

**另一条铁律：本次只做视觉升级，不改任何功能。**

- 不动 `LinoAPI.swift`、`LinoStores.swift`、`LinoModels.swift` 的业务逻辑与网络层
- 不增删任何按钮的行为、任何字段、任何状态机分支
- 所有现有入口必须仍然可达（下面第 4 节列了导航重组后的新位置）
- 后端契约、Keychain 键、UserDefaults 键、草稿目录一律不动

---

## 1. 概述

LinoI 是单人小说写作工作台（SwiftUI iOS + macOS + FastAPI）。现状前端是「浅蓝渐变背景 + 半透明玻璃卡 + SF Rounded 圆体」的通用 SaaS 风，用户明确指出四个问题：

1. 书卡封面（渐变 + 两个字）很丑
2. 玻璃用得牵强，没发挥出玻璃该有的好看
3. 切换动画牵强
4. 工具栏（四等分 segmented）划分不好

升级方向定为 **「纸与墨」**：纸色画布 + 墨色文字 + 一个克制的朱砂强调色；玻璃只保留在真正悬浮的地方；作者写的内容一律宋体，系统说的话一律黑体。

- 工作台（书架、章节列表、人物列表）**紧凑**
- 章节编辑器、阅读页 **宽松**
- 浅色为主，附带完整暗色

## 2. 保真度

**高保真（hifi）**。颜色、字号、行高、圆角、间距、动效时长全部为最终值，本文档逐项列出。施工时按数值 1:1 还原。

设计基准机型：**iPhone 17 Pro（402 × 874 pt）**。所有数值单位为 pt。

---

## 3. 字体（用户特别要求明确说明）

### 3.1 HTML 稿里用了什么

| 用途 | HTML 里写的 font-family | 实际渲染成 |
|---|---|---|
| 界面文字（按钮、标签、状态、说明、数字） | `-apple-system, system-ui, sans-serif` | **SF Pro**（系统默认无衬线） |
| 内容文字（书名、章节名、人物名、正文、摘要、Bible、人格词） | `'Songti SC', STSong, serif` | **宋体 SC** |
| 错误代码、Base URL、Temperature 数值 | `ui-monospace, Menlo, monospace` | **SF Mono**（等宽，仅用于机器串） |

设计稿左侧说明面板里的字体只是文档排版，不属于 App 界面，忽略。

### 3.2 落到 SwiftUI 怎么写

```swift
// 界面文字：系统默认 design（= SF Pro）。注意 design 参数不要再写 .rounded。
.font(.system(size: 15, weight: .semibold))

// 内容文字：宋体
.font(.custom("Songti SC", size: 15.5).weight(.semibold))

// 机器串：等宽
.font(.system(size: 11.5).monospaced())
```

### 3.3 现状要改掉的地方

现状 `LinoTheme.swift` 里的 `LinoType` 全部用了 `design: .rounded`：

```swift
enum LinoType {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)   // ← 圆体，全部去掉
    }
    static let display   = rounded(30, .bold)
    static let heading   = rounded(20, .bold)
    static let cardTitle = rounded(17, .semibold)
    static let rowTitle  = rounded(15, .semibold)
}
```

**改成：**

```swift
enum LinoType {
    /// 界面字：系统默认 design（SF Pro）。原 `rounded(...)` 全部改走这里。
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// 内容字：宋体，作者写的东西一律用它。
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }

    static let display    = serif(30, .bold)      // 书架大标题「书架」
    static let paneTitle  = serif(22, .bold)      // 分区标题「稿件 / 人物 / 设定」
    static let bookTitle  = serif(17, .semibold)  // 导航栏书名
    static let cardTitle  = serif(15.5, .semibold)// 章节行 / 人物行标题
    static let editorTitle = serif(26, .bold)     // 编辑器章节标题
    static let body       = serif(15)             // 正文预览
    static let reading    = serif(19)             // 阅读页正文（随字号档位变）
    static let sectionLabel = ui(10.5, .semibold) // 小节标签，字距 1.2
    static let control    = ui(15)                // 列表行、按钮
    static let caption    = ui(11.5)              // 次要说明
}
```

### 3.4 字族分工规则（施工时按这个判断该用哪种）

| 内容 | 字体 |
|---|---|
| 书名、章节标题、正文、章节摘要、大事记、世界观设定、Bible、人物名、固定设定、动态字段值、故事线事件、人格词、封面竖排书名 | **宋体** |
| 按钮文案、tab 标签、状态文案、小节标签、字数、日期、说明文字、Agent 名、模型名、开关标题 | **SF Pro** |
| 错误代码、Base URL、Temperature 数值 | **SF Mono** |

阅读页正文字号三档沿用现状 `ReaderFontScale`：小 16 / 中 19 / 大 22，行高 = 字号 × 2.0（比现状略松）。

---

## 4. 导航结构变更（唯一的结构性改动）

**现状**：进书后是一条四等分 `LinoISegmented`（章节 / 人物 / 设定 / Agent）。

**升级后**：底部三段 tab bar + 二级页。

```
书架 (LinoIShelfView)
 └─ 书 (LinoIWorkspaceView)  ← 底部 TabView：稿件 / 人物 / 设定
     ├─ 稿件 → 章节编辑器 (push) → 阅读页 (fullScreenCover)
     ├─ 人物
     └─ 设定
         ├─ Agent 与模型 (push)  ← 原第四个 tab 搬到这里
         │    └─ 单个 Agent 详情 (push)：绑定模型 / 启用思考 / 思考强度 / Temperature / 人格
         └─ 后端连接 (sheet)
```

要点：

- Agent 是 App 级配置（`agents.load()` 不带 bookId），本来就不该和书内三个 tab 平级；移到「设定 › Agent 与模型」，**功能一个不少**
- 原 `LinoIAgentSettingsPane` 里堆在一页的「绑定卡 + 人格卡」拆成：列表页（4 个 Agent + Profile 列表）→ 详情页（该 Agent 的绑定/思考/温度/人格）
- 原 `LinoIConnectionSettingsSection` 与书架右上角的连接入口合并为同一个 sheet
- 底部 tab bar：高度 56 + 30 底部安全区，图标 21×21 线性图标，选中色 `--accent`，未选中 `--muted`，标签 10.5pt

---

## 5. 设计 Token

### 5.1 颜色（浅色）

| Token | 值 | 用途 |
|---|---|---|
| `bg` | `#F4F2ED` | 页面纸色背景（替代现状蓝渐变，**不要再用渐变**） |
| `bg2` | `#EAE7E0` | 凹陷底（分段控件槽） |
| `surface` | `#FFFFFF` | 卡片、列表 |
| `surface2` | `#FAF8F5` | 卡内二级块、按下态 |
| `ink` | `#17181C` | 主文字 |
| `ink2` | `#494B52` | 正文、长文本 |
| `muted` | `#84868E` | 次要文字 |
| `faint` | `#ABADB4` | 标签、占位、禁用 |
| `line` | `rgba(23,24,28,0.09)` | 分隔线、卡片描边 |
| `line2` | `rgba(23,24,28,0.16)` | 强分隔、次要按钮描边 |
| `accent` | `#C0472C` 朱砂 | 主操作、选中态、进行中 |
| `accentsoft` | `rgba(192,71,44,0.10)` | 强调底色（草稿恢复条、冲突提示） |
| `accenttext` | `#FFFFFF` | 强调底上的文字 |
| `green` | `#2F6B52` | 已完成、已连接 |
| `amber` | `#9A6A1C` | 待接受、警示 |
| `danger` | `#B3453A` | 失败、删除 |
| `shadow` | `0 1px 2px rgba(23,24,28,0.04)` | 卡片阴影（**极轻，不要现状的 18/10 大阴影**） |
| 封面纸色 | `#E4DCCB` / `#D5DDE3` / `#D9E1D4` | 按书轮换 |
| 封面墨色 | `#3D3B34` | 封面竖排书名 |

### 5.2 颜色（暗色）

| Token | 值 |
|---|---|
| `bg` | `#121316` |
| `bg2` | `#0C0D0F` |
| `surface` | `#1B1D21` |
| `surface2` | `#212429` |
| `ink` | `#EDEBE6` |
| `ink2` | `#C4C3BF` |
| `muted` | `#8B8D95` |
| `faint` | `#6B6D75` |
| `line` | `rgba(255,255,255,0.10)` |
| `line2` | `rgba(255,255,255,0.18)` |
| `accent` | `#E2664A` |
| `accentsoft` | `rgba(226,102,74,0.16)` |
| `green` | `#5DA485` |
| `amber` | `#D0A051` |
| `danger` | `#DE7264` |
| `shadow` | 无 |
| 封面纸色 | `#3A362E` / `#2C333A` / `#2F362D`，封面墨色 `#CFCABE` |

暗色施工说明：现状 `LinoIApp.swift` 里写死了 `.preferredColorScheme(.light)`，**去掉这一行**，改由 `@Environment(\.colorScheme)` 驱动上表两套值。阅读页三主题（日间/护眼/夜间）保持独立于 App 明暗，与现状一致。

### 5.3 阅读页三主题（与工作台色板独立）

| 主题 | 背景 | 文字 | 次要 | 分隔 | 首字分隔条 | 工具条底 |
|---|---|---|---|---|---|---|
| 日间 | `#F8F6F1` | `#22232A` | `#8A8B93` | `rgba(23,24,28,.10)` | `rgba(23,24,28,.30)` | `rgba(248,246,241,.72)` |
| 护眼 | `#F1E7D2` | `#42372A` | `#96876C` | `rgba(120,90,50,.18)` | `rgba(120,90,50,.45)` | `rgba(241,231,210,.72)` |
| 夜间 | `#17181A` | `#CFCDC8` | `#7E7F88` | `rgba(255,255,255,.10)` | `rgba(255,255,255,.22)` | `rgba(23,24,26,.72)` |

### 5.4 圆角

| 用途 | 半径 |
|---|---|
| 卡片 / 列表容器 | 16 |
| 卡内块、按钮（大） | 14 |
| 二级块、输入块 | 11–12 |
| 小分段按钮 | 6–9 |
| 胶囊（chip、状态条、主按钮圆形） | 999 |
| 书封 | `4 10 10 4`（左侧书脊侧小圆角） |
| Sheet 顶部 | 20 |

全部用 `RoundedRectangle(cornerRadius:style: .continuous)`。

### 5.5 间距

- 页面左右边距：书架 20、工作台 16、编辑器 20、阅读页 26
- 卡片内边距：14（列表行左右 14，高度见组件）
- 小节之间：22
- 小节标题与内容：11
- 卡片之间：14–16
- 底部安全区：30（tab bar / 吸底操作栏），阅读页底部 30

### 5.6 字号表

| 元素 | 字体 | 字号 / 字重 | 行高 |
|---|---|---|---|
| 书架大标题「书架」 | 宋体 | 30 / bold | 1.15 |
| 分区标题（稿件/人物/设定） | 宋体 | 22 / bold | 1.2 |
| 导航栏书名 | 宋体 | 17 / semibold | 1.2 |
| 编辑器章节标题（可编辑） | 宋体 | 26 / bold | 1.3 |
| 章节行标题 | 宋体 | 15.5 / semibold | 1.2 |
| 人物行姓名 | 宋体 | 15 / semibold | 1.2 |
| 书卡书名（列表下方） | 宋体 | 15 / semibold | 1.3 |
| 封面竖排书名 | 宋体 | 19 / semibold，字距 5 | 1 |
| 正文预览段落 | 宋体 | 15 | 2.0 |
| 阅读页正文 | 宋体 | 16 / 19 / 22 | 2.0 |
| 阅读页章节标题 | 宋体 | 25 / bold | 1.4 |
| 长文本（Bible、摘要、固定设定、人格词） | 宋体 | 14–14.5 | 1.9 |
| 列表行主文案 | SF Pro | 15 | 1 |
| 按钮 | SF Pro | 13–15 / semibold | 1 |
| 小节标签（全大写风格） | SF Pro | 10.5 / semibold，字距 1.2 | 1 |
| 状态文案、字数、日期 | SF Pro | 11.5 | 1 |
| 说明文字 | SF Pro | 12–12.5 | 1.4–1.7 |
| tab 标签 | SF Pro | 10.5 / medium | 1 |

### 5.7 动效

沿用现状 `LinoMotion` 的时长阶梯，只调整语义：

| 场景 | 时长 | 曲线 |
|---|---|---|
| 换屏（书架↔书↔编辑器↔Agent 详情） | 0.22s | easeOut，**上浮 7pt + 淡入**（替代现状交叉淡化） |
| tab 内容切换 | 0.22s | 同上 |
| 抽屉展开 / 折叠区 | 0.20s | easeOut，箭头同步 180° 旋转 |
| Sheet 弹出 | 0.26–0.28s | `cubic-bezier(.32,.72,0,1)`，对应 SwiftUI `.spring(response:0.34, dampingFraction:0.86)` |
| Toast 出现 | 0.24s | easeOut，下方上浮 14pt |
| 选中态 / 开关 / 分段 | 0.18–0.20s | easeOut，只动底色与位置 |
| 书卡按压 | 0.18s | `scale 0.975` |
| 列表行按压 | 0.14s | 底色变 `surface2` |
| 进行中步骤点 | 1.1s 循环 | 透明度 1 → 0.35 → 1（`.repeatForever`，需遵守「减少动态效果」） |
| 主题/明暗切换 | 0.25s | 只过渡颜色，正文段落排除在隐式动画外（沿用现状 v1.4.1 性能修复的做法） |

**明确要求**：不要用整页 opacity 交叉淡化两棵视图树（现状 `containerSwap` 的做法），换成新树上浮淡入、旧树直接移除。

---

## 6. 逐屏规格

### 6.1 书架

- 顶部：`LINOI` 字距 1.6 的 11.5pt 全大写标签 → 下方 30pt 宋体「书架」；右侧胶囊「● 已连接」（高 34，圆角 999，`surface` 底 + `line` 描边，绿点 6pt），点击打开连接 sheet
- 副行：`3 本书 · 31 章 · 上次写作 2 小时前`，12/1.5 `muted`（数据来自现有 `Book.chapterCount` / `updatedAt`，**不要新增字段**）
- 书格：`grid 2 列，列宽等分（重要：用等分而不是自适应），行距 22 列距 18`
- **书封（重点重做项）**：宽高比 3:4，圆角 `4 10 10 4`；纸色填充；`inset 5px 0 0 rgba(0,0,0,.055)` 模拟书脊暗边；`inset 0 0 0 1px rgba(0,0,0,.05)` 边缘；内部 `12/12/12/20` 处一圈 1px `rgba(61,59,52,.20)` 压边框；书名竖排（`writing-mode: vertical-rl` → SwiftUI 用逐字 VStack 或 `.rotationEffect` 方案），19pt 宋体 semibold，字距 5，顶部 24 起；底部 22 处一行 9.5pt 字距 2.4 的拼音缩写标记 `rgba(61,59,52,.55)`
- 封面下方：书名（宋体 15 semibold）+ 元信息（11.5 `muted`）
- 新建书：同尺寸虚线框（1px dashed `line2`）+ 加号 + 「新建书」，点击弹 sheet
- **删掉**：现状的 `coverGradient` 四套渐变、`linoCard` 大阴影、玻璃连接条

### 6.2 书内 · 稿件（章节列表）

- 导航条：46 高，返回箭头 38×38 无底色 + 宋体 17 书名 + 右侧 `···`
- 分区头：宋体 22「稿件」+ 12pt 统计行；右侧朱砂胶囊「＋ 新章」（高 32，圆角 999）
- 章节列表：**一张卡内多行**（`surface` + 1px `line` + 圆角 16 + 极轻阴影），行高 60，行间 1px 分隔线（不是现状的一行一张卡）
  - 左：章节序号，宋体 15，`faint`，宽 26 居中（**不要现状的渐变色块**）
  - 中：章节名（宋体 15.5 semibold）+ 状态行（5pt 圆点 + 状态文字 + 字数，11.5pt）
  - 右：7×12 chevron，`faint`
- 状态色：已完成 `green` / 待接受 `amber` / 写作中 `accent` / 未完成 `danger` / 草稿 `muted` / 提取中 `amber`（文案沿用 `linoStatusLabel`）
- 空态：虚线卡，图标 30pt 线性 + 宋体 16 标题 +12.5 说明 + 朱砂胶囊按钮

### 6.3 书内 · 人物

- 上方人物列表卡：行高 58，34pt 圆形头像（纸色底 + 宋体姓氏），姓名 + 身份，右侧事件条数
- 下方选中人物卡：46pt 头像 + 宋体 18 姓名 + 身份 + `···`（删除确认）；分隔线；「固定设定」宋体 14/1.9；「动态字段 · Extractor」为 1px 缝隙的分组行（左标签 60 宽 `muted`，中值，右章节号 `faint`）；「人物故事线」时间线：左侧 44 宽轨道（7pt 圆点，当前章朱砂、历史 `line2`，下接 1px 竖线）+ 章节号 11pt + 宋体 13.5/1.8 事件文本 + 右侧 `···`
- 空态：同 6.2 样式，文案「还没有人物 / 可以从已有的人物卡文本导入，也可以先建一个空人物。」

### 6.4 书内 · 设定

分组列表（每组一张卡）：

1. 书：书名（小节标签 + 宋体 17）/ 世界观设定（小节标签 + 宋体 14/1.9）
2. 导出：两行 52 高列表行，右侧 `.txt` + chevron
3. 模型与连接：`Agent 与模型`（副标题「4 个 Agent · 2 个 Profile」）、`后端连接`（副标题 host + Keychain 说明，右侧绿点）

### 6.5 Agent 与模型（二级页）+ Agent 详情（三级页）

- 列表页：四个 Agent 行（62 高，名称 + 「Profile 名 · 模型名」+ 右侧思考档位 + chevron）；Profile 列表（62 高，名称 + `模型 · host`，右侧 `···`）；末行「＋ 新增 Profile」朱砂文字行
- 详情页「模型与推理」卡：
  - 绑定模型（54 高行，右侧当前 Profile 名 + chevron）
  - 启用思考（54 高行 + 50×30 开关，开启为 `accent`）
  - 思考强度（分段：低/中/高，槽 `bg2`，选中块 `surface`，圆角 7）
  - Temperature（行内标题 + 等宽数值 + 「默认」文字按钮；下方 3pt 轨道，已填充段 `accent`，24pt 圆钮 `surface` + `line2` 描边）
  - 能力说明 11.5/1.6 `muted`（文案沿用现状 `capabilityDescription` 的生成逻辑）
- 详情页「人格」卡：可编辑人格词（宋体 14/1.9）；程序协议只读块（`surface2` 底 + 锁图标 + 10.5 标签 + 12.5/1.75 `muted`）；底部「恢复默认」次要按钮 + 「保存人格」朱砂按钮

### 6.6 章节编辑器（核心屏，表单式，宽松）

自上而下：

1. 顶栏 46 高：返回 + 宋体 15「第 N 章」+ 5pt 状态点 + 状态文字 + 右侧「已同步」+ `···`（删除本章确认）
2. 本地草稿恢复条（有则显示）：`accentsoft` 底、圆角 12、时钟图标 + 「已恢复本地草稿」+ 右侧「知道了」
3. 章节标题：宋体 26 bold 无边框输入（占位即标题本身），下方「N 字 · 最低 4000 字」11.5 `faint`
4. 小节头样式统一：10.5 小节标签 + 一条 1px 横线撑满 +（可选右侧附加信息）
5. 本章剧情 Bible：`surface` 卡，宋体 14.5/1.9
6. 本章允许人物：34 高胶囊 chip，选中 = `accent` 填充 + 白字，未选 = `surface` + `line2` 描边 + `ink2` 字；右上角显示「已选 M / N」
7. 流程：`surface` 卡内四行，16pt 圆环（已完成 = `green` 实心 + 中心 `surface` 点；进行中 = `accent` 描边 + 中心点 + 1.1s 呼吸；待进行 = `faint` 描边空心）+ 阶段名 + 右侧状态词
   - 失败态在同卡内追加：3pt 竖条 `danger` + 「Writer 未完成」+ 原因 + 等宽错误代码 + `surface2` 块内「未选人物」提示 + 「重新生成」「本章豁免并重试」两枚按钮
8. 正文：小节头右侧「导入」朱砂文字按钮 + 预览/编辑分段；下方 `surface` 卡，宋体 15/2.0
9. 留痕（**新增的折叠抽屉，替代现状两个 DisclosureGroup**）：一张卡内两行 52 高
   - 「本次写作上下文」右侧摘要「简报 8 条 · 来源 16」+ 箭头；展开：Writer 实际记忆简报（宋体 13.5/1.85）、上一章尾段（`surface2` 块）、「简报占用：N 字符 · M 条审计来源」、审计来源分组行（左章节号 52 宽）、Bible 冲突提示（`accentsoft` 块 + 3pt `amber` 竖条）
   - 「Bible 检查结果」右侧绿点 + 「通过」+ 箭头；展开：结论行、说明、正文证据 / Bible 证据两块、「重新检查」「编辑后检查」两枚次要按钮
10. Extractor 结果：一张卡内分行——大事记（可编辑，宋体 15.5 semibold）、章节摘要（宋体 14/1.9）、状态变化 / 未决事项 / 原子记忆（`—` 起首的条目，13/1.6）、底部「修改会影响后续章节的候选记忆。」`amber` 11.5 + 「保存归档」次要按钮
11. 吸底操作栏（10 上内边距 + 30 安全区，顶部 1px `line`）：
    - 生成中：左侧「■ 停止」（`danger` 描边）
    - 非生成中：左侧 48×48 重新生成图标按钮
    - 中间主按钮 48 高圆角 14：待接受 = `accent`「接受本章」；已完成 = `green`「进入阅读」；生成中 = `bg2` + `muted`「生成中…」
    - 右侧 48×48 进入阅读图标按钮

读取中：居中 26pt 转圈（2px 轨道，`accent` 弧）+「读取章节」。
读取失败：虚线卡 + `danger` 感叹号圆 + 「章节读取失败 / 返回章节列表后再试一次。」+ 「返回章节」按钮。

### 6.7 阅读页

- 顶栏 48 高（+ 状态栏），仅返回 / 居中「书名 · 第 N 章」12.5 / `Aa`，底部 1px 主题分隔线；点正文区域整条工具栏与底栏 0.22s 收起（高度 → 0，透明度 → 0）
- 正文区：左右 26，章节号 11.5 字距 1.4 → 宋体 25 bold 标题 → 38×1.5pt 短横（`rule` 色，替代现状整行细线）→ 段落宋体 16/19/22，行高 2.0，段距 22
- `Aa` 面板：顶部 112 处浮层，圆角 18，主题色底 + `blur(24)` + 1px 主题描边 + `0 14px 36px rgba(0,0,0,.16)`；「阅读主题」三个 52 高色块（选中 2px 边框为当前主题文字色）+ 「字号」三档 40 高胶囊
- 底部：48 高胶囊工具条（主题色 72% 底 + `blur(22)` + 1px 描边）：左「读到 34%」+ 右上一章/下一章
- **这里是全 App 唯一保留玻璃（backdrop blur）的两处**：顶栏 / 底部工具条 / Aa 面板

### 6.8 Sheet 与确认弹窗

- 小 sheet（新建书、后端连接）：从底部升起，圆角 20，抓手 36×5，50 高标题栏（左「取消」朱砂 + 居中标题），内容为 `surface` 分组卡，底部 48 高朱砂主按钮，底内边距 34
- 大 sheet（导入正文、导入人物卡、新增 Profile）：顶部留 14，其余同上，内容区可滚动，主按钮吸底
- 确认弹窗（删除本章 / 删除人物）：iOS action sheet 形态——底部两个 16 圆角块，上块 = 标题 13.5 semibold + 说明 12/1.65 + 分隔线 + 54 高 `danger` 破坏性按钮，下块 = 54 高「取消」；遮罩 `rgba(0,0,0,.30)`
- Toast：底部上浮，`ink` 底 + `bg` 色文字，圆角 14，左侧 6pt 绿点，13.5/1.3，2.6s 自动消失（沿用现状 `NoticeBus` 逻辑与时长）

---

## 7. 交互与状态（均为现状已有行为，只换外观）

| 交互 | 行为 |
|---|---|
| 点书卡 | 进入书内，默认「稿件」tab |
| 点章节行 | push 章节编辑器 |
| 生成 | 四步流程依次推进；每步状态 待进行/进行中/已完成/未完成/已停止 |
| 停止 | 终止任务，草稿保留，toast「任务已停止，当前草稿仍保留」 |
| 接受本章 | 状态 → 已完成，主按钮变「进入阅读」，toast「已接受本章，Extractor 归档完成」 |
| Checker 未过 | 主按钮禁用，另给「忽略检查并接受」（走确认弹窗） |
| 点人物行 | 下方详情卡切换 |
| 点 tab | 内容 0.22s 上浮淡入 |
| 阅读页点正文 | 工具栏收起/展开 |
| Aa | 打开面板，改主题/字号即时生效并持久化（沿用现状 `@AppStorage` 键） |

**原型里的定时器、假数据只是演示，施工时全部接现有 store（`ChapterEditorStore` / `WorkspaceStore` / `CharactersStore` / `AgentSettingsStore`）。**

---

## 8. 施工文件对照

| 文件 | 要做的事 |
|---|---|
| `LinoTheme.swift` | 重写色板为第 5 节两套值；删除 `background` 渐变、`coverGradient`、`accentGradient`、`successGradient`、`logoGradient`；`linoGlass` 只保留给阅读页三处，其余调用点改成实色卡；`LinoType` 按 3.3 重写；圆角表按 5.4 调整 |
| `LinoIApp.swift` | 删除 `.preferredColorScheme(.light)`；`tint` 改 `accent` |
| `ShelfViews.swift` | 书封重做（6.1）；等分两列；删除玻璃连接条，改胶囊连接状态 |
| `WorkspaceViews.swift` | `LinoISegmented` 四等分 → 底部 `TabView` 三段；章节列表改单卡多行 |
| `CharactersViews.swift` | 横向 chip 滚动条 → 竖向列表卡；补故事线时间线样式 |
| `SettingsViews.swift` | 拆成「Agent 与模型」列表页 + Agent 详情页；连接设置并入 sheet |
| `ChapterEditorViews.swift` | 按 6.6 重排；两个 `DisclosureGroup` → 「留痕」抽屉卡；新增吸底操作栏 |
| `ReadingViews.swift` | 顶栏/底栏保留玻璃；`Aa` 由菜单改浮层面板；正文行高 2.0、短横分隔 |
| `LinoComponents.swift` | 按钮样式（主/次/破坏）、状态点、小节头、空态卡、Toast 全部按新 token 重做 |
| `LinoModels.swift` / `LinoStores.swift` / `LinoAPI.swift` | **不动** |

---

## 9. 验收清单

- [ ] 全 App 无蓝色渐变背景，无 `.rounded` 圆体
- [ ] 作者内容全部宋体，系统文案全部 SF Pro，机器串等宽
- [ ] 玻璃只出现在阅读页顶栏、底部工具条、Aa 面板
- [ ] 书封为纸色 + 竖排宋体书名 + 压边框 + 书脊暗边
- [ ] 底部三段 tab，Agent 在设定二级页，所有原有入口可达
- [ ] 浅色/暗色两套跑通，阅读页三主题独立
- [ ] 换屏为上浮淡入，无双树交叉淡化
- [ ] 所有状态齐备：空态 / 读取中 / 读取失败 / 生成中 / 失败+豁免重试 / 草稿恢复 / 各 sheet / 删除确认 / toast
- [ ] 功能零变更：接口、字段、状态机、Keychain/UserDefaults 键全部不变

---

## 10. 包内文件

| 文件 | 说明 |
|---|---|
| `01 现状复刻.dc.html` | 现状逐屏复刻（对照基准），照 `App/LinoI/*.swift` 1:1 还原，未做任何美化 |
| `02 视觉升级 · 可点原型.dc.html` | 升级方案 + 可点交互原型（左侧面板可跳转各屏、跑生成流程、看失败态、切深色） |
| `screenshots/` | 升级方案逐屏截图，804×1748（iPhone 17 Pro @2x），见下表 |
| `ios-frame.jsx` / `support.js` | 仅为让上面两个 HTML 能在浏览器里渲染的支撑文件，**与施工无关** |

### 截图清单

| 文件 | 对应章节 |
|---|---|
| `01-书架.png` | 6.1 书架 · 纸色书封 |
| `02-稿件.png` | 6.2 章节列表 · 单卡多行 |
| `03-人物.png` | 6.3 人物列表 + 人物卡 |
| `04-设定.png` | 6.4 设定分组列表 |
| `05-Agent与模型.png` | 6.5 Agent 列表页 |
| `06-Agent详情.png` | 6.5 Agent 详情（开关 / 分段 / 滑杆 / 人格） |
| `07-编辑器·输入与人物.png` | 6.6 第 1–6 项（草稿恢复条、标题、Bible、人物 chip、流程） |
| `08-编辑器·正文与留痕.png` | 6.6 第 8–9 项（正文预览、留痕两行收起态） |
| `09-编辑器·写作上下文展开.png` | 6.6 第 9 项展开态（记忆简报、尾段、审计来源、冲突提示） |
| `10-编辑器·Extractor结果.png` | 6.6 第 10 项 |
| `11-编辑器·生成失败与豁免.png` | 6.6 第 7 项失败态 |
| `12-阅读页·日间与Aa面板.png` | 6.7 阅读页 + 阅读设置浮层 |
| `13-阅读页·夜间.png` | 6.7 夜间主题 |
| `14-空态.png` | 6.2 空态 |
| `15-暗色·书架.png` | 5.2 暗色 |
| `16-暗色·章节编辑器.png` | 5.2 暗色 |

截图里的文案是演示数据（《雾港纪事》、沈砚等），施工时接真实 store 数据，**不要硬编码**。

用浏览器直接打开 `.dc.html` 即可查看可点原型。再次强调：**这些是效果参考，施工产物必须是纯 Swift / SwiftUI。**
