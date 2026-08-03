import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

    #if os(iOS)
    private static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightOpacity: Double = 1,
        darkOpacity: Double = 1
    ) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let value = isDark ? dark : light
            let opacity = isDark ? darkOpacity : lightOpacity
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: opacity
            )
        })
    }

    // iOS v1.7「纸与墨」。页面与控件只使用实色；玻璃仅由阅读页显式添加。
    static let bg = adaptive(light: 0xF4F2ED, dark: 0x121316)
    static let bg2 = adaptive(light: 0xEAE7E0, dark: 0x0C0D0F)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1B1D21)
    static let surface2 = adaptive(light: 0xFAF8F5, dark: 0x212429)
    static let ink = adaptive(light: 0x17181C, dark: 0xEDEBE6)
    static let ink2 = adaptive(light: 0x494B52, dark: 0xC4C3BF)
    static let muted = adaptive(light: 0x84868E, dark: 0x8B8D95)
    static let faint = adaptive(light: 0xABADB4, dark: 0x6B6D75)
    static let line = adaptive(light: 0x17181C, dark: 0xFFFFFF, lightOpacity: 0.09, darkOpacity: 0.10)
    static let line2 = adaptive(light: 0x17181C, dark: 0xFFFFFF, lightOpacity: 0.16, darkOpacity: 0.18)
    static let accent = adaptive(light: 0xC0472C, dark: 0xE2664A)
    static let accentSoft = adaptive(light: 0xC0472C, dark: 0xE2664A, lightOpacity: 0.10, darkOpacity: 0.16)
    static let accentText = Color.white
    static let success = adaptive(light: 0x2F6B52, dark: 0x5DA485)
    static let warning = adaptive(light: 0x9A6A1C, dark: 0xD0A051)
    static let danger = adaptive(light: 0xB3453A, dark: 0xDE7264)
    static let coverInk = adaptive(light: 0x3D3B34, dark: 0xCFCABE)

    static let background = bg
    static let page = bg
    static let body = ink2
    static let panel = surface
    static let stroke = line
    static let hairline = line
    static let accentDeep = accent
    static let cyan = success
    static let amber = warning

    static func coverPaper(_ seed: String) -> Color {
        let light = [0xE4DCCB, 0xD5DDE3, 0xD9E1D4]
        let dark = [0x3A362E, 0x2C333A, 0x2F362D]
        let idx = stableIndex(seed, count: light.count)
        return adaptive(light: UInt32(light[idx]), dark: UInt32(dark[idx]))
    }

    private static func stableIndex(_ value: String, count: Int) -> Int {
        let hash = value.utf8.reduce(UInt64(1469598103934665603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
        return Int(hash % UInt64(count))
    }
    #else
    // macOS 使用与 iOS 相同数值的动态「纸与墨」色板。AppKit provider 会随
    // 当前 window appearance 解析，避免把 NSPanel、菜单和 SwiftUI 内容锁进浅色。
    private static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightOpacity: Double = 1,
        darkOpacity: Double = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: isDark ? darkOpacity : lightOpacity
            )
        })
    }

    static let bg = adaptive(light: 0xF4F2ED, dark: 0x121316)
    static let bg2 = adaptive(light: 0xEAE7E0, dark: 0x0C0D0F)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1B1D21)
    static let surface2 = adaptive(light: 0xFAF8F5, dark: 0x212429)
    static let ink = adaptive(light: 0x17181C, dark: 0xEDEBE6)
    static let ink2 = adaptive(light: 0x494B52, dark: 0xC4C3BF)
    static let muted = adaptive(light: 0x84868E, dark: 0x8B8D95)
    static let faint = adaptive(light: 0xABADB4, dark: 0x6B6D75)
    static let line = adaptive(light: 0x17181C, dark: 0xFFFFFF, lightOpacity: 0.09, darkOpacity: 0.10)
    static let line2 = adaptive(light: 0x17181C, dark: 0xFFFFFF, lightOpacity: 0.16, darkOpacity: 0.18)
    static let accent = adaptive(light: 0xC0472C, dark: 0xE2664A)
    static let accentSoft = adaptive(light: 0xC0472C, dark: 0xE2664A, lightOpacity: 0.10, darkOpacity: 0.16)
    static let accentText = Color.white
    static let success = adaptive(light: 0x2F6B52, dark: 0x5DA485)
    static let warning = adaptive(light: 0x9A6A1C, dark: 0xD0A051)
    static let danger = adaptive(light: 0xB3453A, dark: 0xDE7264)
    static let coverInk = adaptive(light: 0x3D3B34, dark: 0xCFCABE)

    static let background = bg
    static let page = bg
    static let body = ink2
    static let panel = surface
    static let stroke = line
    static let hairline = line
    static let accentDeep = accent
    static let cyan = success
    static let amber = warning
    static let accentGradient = LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
    static let successGradient = LinearGradient(colors: [success, success], startPoint: .top, endPoint: .bottom)
    static let logoGradient = LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)

    static func coverPaper(_ seed: String) -> Color {
        let light = [0xE4DCCB, 0xD5DDE3, 0xD9E1D4]
        let dark = [0x3A362E, 0x2C333A, 0x2F362D]
        let hash = seed.utf8.reduce(UInt64(1469598103934665603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1099511628211
        }
        let idx = Int(hash % UInt64(light.count))
        return adaptive(light: UInt32(light[idx]), dark: UInt32(dark[idx]))
    }

    static func coverGradient(_ seed: String) -> LinearGradient {
        let color = coverPaper(seed)
        return LinearGradient(colors: [color, color], startPoint: .top, endPoint: .bottom)
    }
    #endif
}

// MARK: - LinoMotion（时长阶梯 + 语义动画）

/// 动效 token：时长阶梯 + 语义动画。全部经 `linoAnimation` 走 value-based
/// transaction，因此天然可被打断，并统一遵循“减少动态效果”；不含
/// `.repeatForever` 或视差类持续动画。时长参数来源：老项目 BookCard `easeOut 0.18`、
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
    static let press = Animation.easeOut(duration: fast)
    /// macOS hover 上浮/亮度（书卡 lift、玻璃钮 brightness）。
    static let hover = Animation.easeOut(duration: fast)
    /// 侧栏/右栏抽屉滑入滑出、reflow。
    static let drawer = Animation.easeOut(duration: 0.20)
    /// 内容区切换（状态机、tab 内容、编辑器阶段块/模式、banner、toast）。
    #if os(iOS)
    static let content = Animation.easeOut(duration: standard)
    #else
    static let content = Animation.smooth(duration: standard)
    #endif
    /// 分段 pill 滑动、tab 选中、人物 chip 选中、行选中。
    #if os(iOS)
    static let selection = Animation.easeOut(duration: 0.20)
    #else
    static let selection = Animation.smooth(duration: standard)
    #endif
    /// 阅读页开合、主题变色、翻章 crossfade、字号。
    #if os(iOS)
    static let reader = Animation.easeOut(duration: standard)
    #else
    static let reader = Animation.smooth(duration: standard)
    #endif
    /// 列表增删。
    static let listItem = Animation.smooth(duration: standard)
    /// 状态徽标双 key morph。
    static let status = Animation.smooth(duration: emphasized)
    /// 整页/大容器换面（书架↔工作台等）。新旧两棵树交叉淡化期间玻璃层数翻倍，
    /// 合成开销大，必须用最短时长压缩重叠窗口（v1.4.1 性能修复）。
    static let containerSwap = Animation.easeOut(duration: standard)

    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct LinoValueAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(LinoMotion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    func linoAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(LinoValueAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - LinoRadius（pt）

/// 圆角 token。迁移规则：字面量就近映射，仅当 |Δ|≤1pt（视觉无感）时替换；
/// `linoGlass` 默认 24、装饰条 1.5 等命名例外保留，不强收每个一次性 one-off。
enum LinoRadius {
    #if os(iOS)
    static let chip: CGFloat = 9
    static let control: CGFloat = 14
    static let pill: CGFloat = 999
    static let field: CGFloat = 12
    static let card: CGFloat = 16
    static let panel: CGFloat = 16
    static let glass: CGFloat = 18
    static let bar: CGFloat = 999
    #else
    static let chip: CGFloat = 9
    static let control: CGFloat = 14
    static let pill: CGFloat = 999
    static let field: CGFloat = 12
    static let card: CGFloat = 16
    static let panel: CGFloat = 16
    static let glass: CGFloat = 18
    static let bar: CGFloat = 999
    #endif
}

enum LinoControlMetrics {
    static var compactHeight: CGFloat {
        #if os(iOS)
        44
        #else
        34
        #endif
    }

    static var regularHeight: CGFloat {
        #if os(iOS)
        44
        #else
        42
        #endif
    }

    static var segmentedHeight: CGFloat {
        #if os(iOS)
        38
        #else
        26
        #endif
    }
}

// MARK: - LinoSurface（白卡不透明度）

/// 表面不透明度 token，就近映射，残留 one-off 允许。
enum LinoSurface {
    #if os(iOS)
    static let well: Double = 1
    static let card: Double = 1
    static let input: Double = 1
    static let glassTint: Double = 0.72
    static let panelTint: Double = 1
    #else
    static let well: Double = 1
    static let card: Double = 1
    static let input: Double = 1
    static let glassTint: Double = 0.72
    static let panelTint: Double = 1
    #endif
}

// MARK: - LinoType（字族统一 = SF Rounded）

/// chrome 字族统一 token（书架/书卡/章节行/编辑器标题等）。阅读正文、封面/
/// 头像装饰字、手稿等排版用途的「宋体」不在此列，一律不动。
enum LinoType {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        #if os(iOS)
        .system(size: size, weight: weight)
        #else
        .system(size: size, weight: weight)
        #endif
    }

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }

    // Compatibility name used by existing views while they migrate to semantic tokens.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        ui(size, weight)
    }

    #if os(iOS)
    static let display = serif(30, .bold)
    static let heading = serif(22, .bold)
    static let paneTitle = serif(22, .bold)
    static let bookTitle = serif(17, .semibold)
    static let cardTitle = serif(15.5, .semibold)
    static let rowTitle = serif(15, .semibold)
    static let editorTitle = serif(26, .bold)
    static let bodyText = serif(15)
    static let reading = serif(19)
    static let sectionLabel = ui(10.5, .semibold)
    static let control = ui(15)
    static let caption = ui(11.5)
    #else
    static let display = serif(30, .bold)
    static let heading = serif(22, .bold)
    static let paneTitle = heading
    static let bookTitle = serif(17, .semibold)
    static let cardTitle = serif(15.5, .semibold)
    static let rowTitle = serif(15, .semibold)
    static let editorTitle = serif(26, .bold)
    static let bodyText = serif(15)
    static let reading = serif(19)
    static let sectionLabel = ui(11, .bold)
    static let control = ui(15)
    static let caption = ui(11.5)
    #endif
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
        #if os(iOS)
        case .day: return LinoTheme.hex(0xF8F6F1)
        case .sepia: return LinoTheme.hex(0xF1E7D2)
        case .night: return LinoTheme.hex(0x17181A)
        #else
        case .day: return LinoTheme.hex(0xF8F6F1)
        case .sepia: return LinoTheme.hex(0xF1E7D2)
        case .night: return LinoTheme.hex(0x17181A)
        #endif
        }
    }

    var text: Color {
        switch self {
        #if os(iOS)
        case .day: return LinoTheme.hex(0x22232A)
        case .sepia: return LinoTheme.hex(0x42372A)
        case .night: return LinoTheme.hex(0xCFCDC8)
        #else
        case .day: return LinoTheme.hex(0x22232A)
        case .sepia: return LinoTheme.hex(0x42372A)
        case .night: return LinoTheme.hex(0xCFCDC8)
        #endif
        }
    }

    var secondary: Color {
        switch self {
        #if os(iOS)
        case .day: return LinoTheme.hex(0x8A8B93)
        case .sepia: return LinoTheme.hex(0x96876C)
        case .night: return LinoTheme.hex(0x7E7F88)
        #else
        case .day: return LinoTheme.hex(0x8A8B93)
        case .sepia: return LinoTheme.hex(0x96876C)
        case .night: return LinoTheme.hex(0x7E7F88)
        #endif
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
        #if os(iOS)
        case .day: return LinoTheme.hex(0x17181C, opacity: 0.10)
        case .sepia: return LinoTheme.hex(0x785A32, opacity: 0.18)
        case .night: return Color(.sRGB, white: 1, opacity: 0.10)
        #else
        case .day: return LinoTheme.hex(0x17181C, opacity: 0.10)
        case .sepia: return LinoTheme.hex(0x785A32, opacity: 0.18)
        case .night: return Color(.sRGB, white: 1, opacity: 0.10)
        #endif
        }
    }

    var rule: Color {
        switch self {
        case .day: return LinoTheme.hex(0x17181C, opacity: 0.30)
        case .sepia: return LinoTheme.hex(0x785A32, opacity: 0.45)
        case .night: return Color(.sRGB, white: 1, opacity: 0.22)
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
        #if os(iOS)
        case .day: return Color(.sRGB, red: 248 / 255, green: 246 / 255, blue: 241 / 255, opacity: 0.72)
        case .sepia: return Color(.sRGB, red: 241 / 255, green: 231 / 255, blue: 210 / 255, opacity: 0.72)
        case .night: return Color(.sRGB, red: 23 / 255, green: 24 / 255, blue: 26 / 255, opacity: 0.72)
        #else
        case .day: return Color(.sRGB, red: 248 / 255, green: 246 / 255, blue: 241 / 255, opacity: 0.72)
        case .sepia: return Color(.sRGB, red: 241 / 255, green: 231 / 255, blue: 210 / 255, opacity: 0.72)
        case .night: return Color(.sRGB, red: 23 / 255, green: 24 / 255, blue: 26 / 255, opacity: 0.72)
        #endif
        }
    }

    /// 主题挑选按钮自身的色块（night 比整窗背景略深一点，与 handoff 对齐）。
    var swatchFill: Color {
        switch self {
        #if os(iOS)
        case .day: return LinoTheme.hex(0xF8F6F1)
        case .sepia: return LinoTheme.hex(0xF1E7D2)
        case .night: return LinoTheme.hex(0x17181A)
        #else
        case .day: return LinoTheme.hex(0xF8F6F1)
        case .sepia: return LinoTheme.hex(0xF1E7D2)
        case .night: return LinoTheme.hex(0x17181A)
        #endif
        }
    }
}

extension View {
    #if os(macOS)
    func linoGlass(cornerRadius: CGFloat = 24) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background { shape.fill(LinoTheme.surface) }
            .overlay(shape.stroke(LinoTheme.line, lineWidth: 1))
    }
    #endif

    func linoCard(cornerRadius: CGFloat = 18) -> some View {
        #if os(iOS)
        self
            .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
            .shadow(color: LinoTheme.hex(0x17181C, opacity: 0.04), radius: 2, y: 1)
        #else
        self
            .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
            .shadow(color: LinoTheme.hex(0x17181C, opacity: 0.04), radius: 2, y: 1)
        #endif
    }
}
