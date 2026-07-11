import SwiftUI

/// 桌面外壳设计系统冒烟页（块②）。**块③会把本页整体替换**为真正的单窗
/// 状态机（`session.token.isEmpty` → 连接配置 / 书架 / 工作台 + reader
/// /settings overlay）。本页只用来肉眼验收玻璃材质、描边、hover、状态点
/// 是否正常，不承载任何真实业务逻辑，也不读写任何 Store 的数据。
struct MacShell: View {
    @State private var previewEditSelection = "预览"
    @State private var rightPanelTabSelection = "角色"

    var body: some View {
        ZStack {
            LinoTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    glassTiers
                    controlsSection
                    statusSection
                }
                .padding(32)
                .frame(maxWidth: LinoMacMetrics.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 14) {
            LinoIAvatar(name: "L", size: 44, rounded: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("LinoI for Mac · 设计系统冒烟页")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LinoTheme.ink)
                Text("块③ 会把这页换成连接配置 / 书架 / 工作台状态机")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LinoTheme.muted)
            }
            Spacer()
            LinoMacConnectionChip()
        }
    }

    private var glassTiers: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinoISectionLabel("三档玻璃")
            HStack(spacing: 14) {
                tierLabel("Toolbar\n工具栏 · 最亮")
                    .linoToolbarGlass(cornerRadius: LinoMacMetrics.cardRadius)
                tierLabel("Sidebar\n侧栏 · 中等")
                    .linoSidebarGlass(cornerRadius: LinoMacMetrics.cardRadius)
                tierLabel("Panel\n内容面板 · 最透")
                    .linoPanelGlass()
            }
        }
    }

    private func tierLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(LinoTheme.ink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(height: 84)
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinoISectionLabel("图标钮 · 分段控件")
            HStack(spacing: 14) {
                LinoMacIconButton(systemName: "gearshape", help: "设置（普通）") {}
                LinoMacIconButton(systemName: "trash", style: .danger, help: "删除（danger）") {}
                LinoMacIconButton(systemName: "exclamationmark.triangle", style: .warning, help: "警告（warning）") {}
                LinoMacSegmented(options: ["预览", "编辑"], label: { $0 }, selection: $previewEditSelection)
                Spacer()
            }
            .padding(16)
            .linoPanelGlass()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinoISectionLabel("状态徽标 · 右栏 Tab 分段")
            HStack(spacing: 14) {
                LinoIStatusPill(text: "已完成", status: "finalized")
                LinoIStatusPill(text: "写作中", status: "writing")
                LinoMacSegmented(options: ["角色", "书设定", "Agent"], label: { $0 }, selection: $rightPanelTabSelection)
                Spacer()
            }
            .padding(16)
            .linoPanelGlass()
        }
    }
}
