import SwiftUI

enum LinoTheme {
    static func hex(_ value: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: opacity
        )
    }

    static let background = LinearGradient(
        colors: [hex(0xEEF8FF), hex(0xF8FCFF), .white],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let page = hex(0xEEF8FF)
    static let accent = hex(0x2688E8)
    static let accentDeep = hex(0x1E5FAE)
    static let accentSoft = hex(0xD8EDFF)
    static let cyan = hex(0x1F8FA3)
    static let ink = hex(0x202B3A)
    static let body = hex(0x334155)
    static let muted = hex(0x78889D)
    static let faint = hex(0x9AABC0)
    static let panel = Color.white.opacity(0.66)
    static let stroke = hex(0x2A5D80, opacity: 0.12)
    static let hairline = hex(0x1D3B55, opacity: 0.10)
    static let success = hex(0x2F8F5B)
    static let warning = hex(0xB8731F)
    static let danger = hex(0xC0564F)

    static let accentGradient = LinearGradient(
        colors: [hex(0x52B7FF), hex(0x2688E8)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let successGradient = LinearGradient(
        colors: [success, hex(0x39B270)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let logoGradient = LinearGradient(
        colors: [hex(0x66B9FF), hex(0x8AC7FF)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func coverGradient(_ seed: String) -> LinearGradient {
        let palettes: [[UInt32]] = [
            [0x3E8EF7, 0x56B6FF, 0x8FD8FF],
            [0x2EA7C7, 0x5BC8DA, 0xA8E9F0],
            [0x5B8DEF, 0x7CAEFF, 0xBED7FF],
            [0x4CA3D9, 0x7DC7F0, 0xD5F1FF],
        ]
        let idx = abs(seed.hashValue) % palettes.count
        return LinearGradient(colors: palettes[idx].map { hex($0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - LinoMotion（时长阶梯 + 语义动画）

/// 动效 token：时长阶梯 + 语义动画。全部走 value-based（`.animation(_, value:)`
/// 或 `withAnimation` 包状态变更），因此天然可被打断；不含 `.repeatForever`
/// 或视差类持续动画。时长参数来源：老项目 BookCard `easeOut 0.18`、
/// StatusBadge 双 key `smooth 0.30`、小控件 `0.14`，与本项目现存
/// `smooth 0.22/0.24/0.25` 对齐取整。
enum LinoMotion {
    // 时长阶梯
    static let micro: Double = 0.14
    static let fast: Double = 0.18
    static let standard: Double = 0.22
    static let emphasized: Double = 0.30

    // 语义动画
    /// 触摸按压反馈（iOS 书卡/行/chip 缩放）。
    static let press = Animation.easeOut(duration: micro)
    /// macOS hover 上浮/亮度（书卡 lift、玻璃钮 brightness）。
    static let hover = Animation.easeOut(duration: fast)
    /// 侧栏/右栏抽屉滑入滑出、reflow。
    static let drawer = Animation.easeOut(duration: fast)
    /// 内容区切换（状态机、tab 内容、编辑器阶段块/模式、banner、toast）。
    static let content = Animation.smooth(duration: standard)
    /// 分段 pill 滑动、tab 选中、人物 chip 选中、行选中。
    static let selection = Animation.smooth(duration: standard)
    /// 阅读页开合、主题变色、翻章 crossfade、字号。
    static let reader = Animation.smooth(duration: standard)
    /// 列表增删。
    static let listItem = Animation.smooth(duration: standard)
    /// 状态徽标双 key morph。
    static let status = Animation.smooth(duration: emphasized)
    /// 整页/大容器换面（书架↔工作台等）。新旧两棵树交叉淡化期间玻璃层数翻倍，
    /// 合成开销大，必须用最短时长压缩重叠窗口（v1.4.1 性能修复）。
    static let containerSwap = Animation.easeOut(duration: micro)
}

// MARK: - LinoRadius（pt）

/// 圆角 token。迁移规则：字面量就近映射，仅当 |Δ|≤1pt（视觉无感）时替换；
/// `linoGlass` 默认 24、装饰条 1.5 等命名例外保留，不强收每个一次性 one-off。
enum LinoRadius {
    static let chip: CGFloat = 8
    static let control: CGFloat = 10
    static let pill: CGFloat = 11
    static let field: CGFloat = 12
    static let card: CGFloat = 14
    static let panel: CGFloat = 18
    static let glass: CGFloat = 20
    static let bar: CGFloat = 22
}

// MARK: - LinoSurface（白卡不透明度）

/// 表面不透明度 token，就近映射，残留 one-off 允许。
enum LinoSurface {
    static let well: Double = 0.54
    static let card: Double = 0.68
    static let input: Double = 0.72
    static let glassTint: Double = 0.66
    static let panelTint: Double = 0.18
}

// MARK: - LinoType（字族统一 = SF Rounded）

/// chrome 字族统一 token（书架/书卡/章节行/编辑器标题等）。阅读正文、封面/
/// 头像装饰字、手稿等排版用途的「宋体」不在此列，一律不动。
enum LinoType {
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let display = rounded(30, .bold)        // 书架大标题
    static let heading = rounded(20, .bold)        // 分区标题（原 .title3.bold）
    static let cardTitle = rounded(17, .semibold)  // 书卡 / 列表行标题（原 .headline / Songti16）
    static let rowTitle = rounded(15, .semibold)   // 侧栏章节行（原 Songti14.5）
}

// MARK: - LinoReadingTheme（day/sepia/night，两端共用）

/// 阅读页三主题色板，与 `LinoTheme` 品牌色无关——阅读要的是纸感暖色调而非
/// 工作台玻璃的蓝调。整体 port 自 macOS 端原 `MacReaderView.MacReadingTheme`
/// （色值一字不改），现挂共享层供 iOS/macOS 阅读页共同消费。
enum LinoReadingTheme: String, CaseIterable, Identifiable {
    case day
    case sepia
    case night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "日间"
        case .sepia: return "护眼"
        case .night: return "夜间"
        }
    }

    var background: Color {
        switch self {
        case .day: return LinoTheme.hex(0xFBFAF7)
        case .sepia: return LinoTheme.hex(0xF1E3C8)
        case .night: return LinoTheme.hex(0x1A1B1F)
        }
    }

    var text: Color {
        switch self {
        case .day: return LinoTheme.hex(0x26262B)
        case .sepia: return LinoTheme.hex(0x4A3B27)
        case .night: return LinoTheme.hex(0xCDCDD2)
        }
    }

    var secondary: Color {
        switch self {
        case .day: return LinoTheme.hex(0x7C7D86)
        case .sepia: return LinoTheme.hex(0x9A8568)
        case .night: return LinoTheme.hex(0x7E7F88)
        }
    }

    var accent: Color {
        switch self {
        case .day: return LinoTheme.hex(0x9A6A3A)
        case .sepia: return LinoTheme.hex(0xA8742E)
        case .night: return LinoTheme.hex(0xC0A06A)
        }
    }

    var hairline: Color {
        switch self {
        case .day: return Color(.sRGB, red: 60 / 255, green: 55 / 255, blue: 45 / 255, opacity: 0.14)
        case .sepia: return Color(.sRGB, red: 120 / 255, green: 90 / 255, blue: 50 / 255, opacity: 0.22)
        case .night: return Color(.sRGB, white: 1, opacity: 0.12)
        }
    }

    var chipBackground: Color {
        switch self {
        case .day: return Color(.sRGB, red: 120 / 255, green: 110 / 255, blue: 90 / 255, opacity: 0.08)
        case .sepia: return Color(.sRGB, red: 120 / 255, green: 90 / 255, blue: 50 / 255, opacity: 0.10)
        case .night: return Color(.sRGB, white: 1, opacity: 0.06)
        }
    }

    var barBackground: Color {
        switch self {
        case .day: return Color(.sRGB, red: 251 / 255, green: 250 / 255, blue: 247 / 255, opacity: 0.80)
        case .sepia: return Color(.sRGB, red: 241 / 255, green: 227 / 255, blue: 200 / 255, opacity: 0.82)
        case .night: return Color(.sRGB, red: 26 / 255, green: 27 / 255, blue: 31 / 255, opacity: 0.82)
        }
    }

    /// 主题挑选按钮自身的色块（night 比整窗背景略深一点，与 handoff 对齐）。
    var swatchFill: Color {
        switch self {
        case .day: return LinoTheme.hex(0xFBFAF7)
        case .sepia: return LinoTheme.hex(0xF1E3C8)
        case .night: return LinoTheme.hex(0x1C1D22)
        }
    }
}

extension View {
    func linoGlass(cornerRadius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background { shape.fill(LinoTheme.panel) }
            .glassEffect(.regular, in: shape)
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.74), LinoTheme.stroke], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.7
                )
            )
    }

    func linoCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
            .shadow(color: LinoTheme.hex(0x143052, opacity: 0.10), radius: 18, y: 10)
    }
}
