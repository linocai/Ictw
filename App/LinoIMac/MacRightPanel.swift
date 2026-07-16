import SwiftUI

/// 右栏：`LinoMacSegmented` 三 tab = 角色 / 书设定 / Agent，内容在 `ScrollView`
/// 内切换，`.linoSidebarGlass`。功能对等不靠 ⌘, 兜底——导出在书设定 tab、模型/
/// 人格在 Agent tab 全部就位。
struct MacRightPanel: View {
    @Binding var tab: MacRightTab

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                // tab 内容瞬时切换：三个 tab 都是整栏玻璃卡堆，交叉淡化会让两个
                // tab 的玻璃层短暂并存导致掉帧（v1.4.1 性能修复）；切换的动效
                // 由分段控件的滑动 pill 承担。
                Group {
                    switch tab {
                    case .characters: MacCharacterTab()
                    case .book: MacBookSettingsTab()
                    case .agent: MacAgentTab()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .linoSidebarGlass()
        .overlay(alignment: .leading) {
            Rectangle().fill(LinoMacMetrics.hairline).frame(width: LinoMacMetrics.hairlineWidth)
        }
    }

    private var tabBar: some View {
        LinoMacSegmented(
            options: MacRightTab.allCases,
            label: { $0.label },
            selection: $tab
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

enum MacRightTab: String, CaseIterable, Identifiable {
    case characters, book, agent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .characters: return "角色"
        case .book: return "书设定"
        case .agent: return "Agent"
        }
    }
}
