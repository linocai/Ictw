import SwiftUI

/// 桌面度量常量 + 三档玻璃材质。色值底座一律来自共享 `LinoTheme`
/// （`LinoTheme.hex` 或既有色值属性），**不新建平行色板**——三档玻璃只是
/// 同一块玻璃材质在 tint 亮度上的差异化（工具栏最亮、面板最透），不是
/// 三套独立配色。macOS 26 起 `.glassEffect(.regular, in:)` 可用（与
/// `LinoTheme.linoGlass` 同一前提），本文件仅 Mac target 编译。
enum LinoMacMetrics {

    // MARK: - 三栏宽度

    /// 左侧章节栏宽度。
    static let sidebarWidth: CGFloat = 258
    /// 右侧面板宽度。
    static let rightPanelWidth: CGFloat = 326
    /// 居中内容流的最大宽度（编辑器 / 书架容器）。
    static let contentMaxWidth: CGFloat = 720
    /// 书架容器最大宽度。
    static let shelfMaxWidth: CGFloat = 1080

    // MARK: - 窗口尺寸

    static let windowMinWidth: CGFloat = 1080
    static let windowMinHeight: CGFloat = 720
    static let windowDefaultWidth: CGFloat = 1280
    static let windowDefaultHeight: CGFloat = 840

    // MARK: - 圆角

    /// 卡片 / 面板圆角。
    static let cardRadius: CGFloat = 14
    /// 输入框 / 按钮 / 标签圆角。
    static let controlRadius: CGFloat = 10

    // MARK: - 描边 / 高光

    /// 0.5px 玻璃描边：`rgba(40,45,70,0.10)`。
    static let hairline = LinoTheme.hex(0x282D46, opacity: 0.10)
    static let hairlineWidth: CGFloat = 0.5
    /// 顶部内嵌高光：`inset 0 1px 0 rgba(255,255,255,0.7)`。
    static let topHighlight = Color.white.opacity(0.7)
}

// MARK: - 顶部 1px 内嵌高光

private struct LinoMacTopHighlight: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .inset(by: 0.5)
            .stroke(
                LinearGradient(
                    colors: [LinoMacMetrics.topHighlight, LinoMacMetrics.topHighlight.opacity(0)],
                    startPoint: .top,
                    endPoint: .center
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }
}

// MARK: - 玻璃材质核心 modifier

private struct LinoMacGlassModifier: ViewModifier {
    var tint: Color
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background { shape.fill(tint) }
            .glassEffect(.regular, in: shape)
            .overlay(LinoMacTopHighlight(cornerRadius: cornerRadius))
            .overlay(
                shape
                    .inset(by: 0.25)
                    .stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// 工具栏 / 自绘标题栏玻璃——三档中最亮，贴近纯白高不透明度。
    func linoToolbarGlass(cornerRadius: CGFloat = 0) -> some View {
        modifier(LinoMacGlassModifier(tint: Color.white.opacity(0.72), cornerRadius: cornerRadius))
    }

    /// 侧栏 / 右栏玻璃——中等亮度，取 `LinoTheme.page` 的极浅蓝调而非新色。
    func linoSidebarGlass(cornerRadius: CGFloat = 0) -> some View {
        modifier(LinoMacGlassModifier(tint: LinoTheme.page.opacity(0.55), cornerRadius: cornerRadius))
    }

    /// 内容面板 / 卡片玻璃——三档中最透，白色低不透明度。
    func linoPanelGlass(cornerRadius: CGFloat = LinoMacMetrics.cardRadius) -> some View {
        modifier(LinoMacGlassModifier(tint: Color.white.opacity(0.18), cornerRadius: cornerRadius))
    }
}
