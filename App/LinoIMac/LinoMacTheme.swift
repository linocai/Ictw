import SwiftUI

/// 桌面度量常量与纸面 surface modifier。色值一律来自共享 `LinoTheme`：
/// 常规工作界面使用实体纸面，阅读器以外不使用 glass/material 墙。
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
    static let cardRadius: CGFloat = 16
    /// 输入框 / 按钮 / 标签圆角。
    static let controlRadius: CGFloat = 14

    // MARK: - 描边 / 高光

    static let hairline = LinoTheme.line
    static let hairlineWidth: CGFloat = 1
}

private struct LinoMacPaperModifier: ViewModifier {
    var surface: Color
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background { shape.fill(surface) }
            .overlay(shape.stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth).allowsHitTesting(false))
    }
}

extension View {
    /// 工具栏 / 自绘标题栏的第一层纸面。
    func linoToolbarGlass(cornerRadius: CGFloat = 0) -> some View {
        modifier(LinoMacPaperModifier(surface: LinoTheme.surface, cornerRadius: cornerRadius))
    }

    /// 侧栏 / 右栏的第二层纸面。
    func linoSidebarGlass(cornerRadius: CGFloat = 0) -> some View {
        modifier(LinoMacPaperModifier(surface: LinoTheme.surface2, cornerRadius: cornerRadius))
    }

    /// 内容卡片的实体纸面。
    func linoPanelGlass(cornerRadius: CGFloat = LinoMacMetrics.cardRadius) -> some View {
        modifier(LinoMacPaperModifier(surface: LinoTheme.surface, cornerRadius: cornerRadius))
    }
}
