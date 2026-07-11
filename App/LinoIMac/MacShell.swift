import SwiftUI

/// 单窗状态机：`session.token.isEmpty` → 首启连接页；已连接但未开书 → 书架；
/// 已开书 → 三栏工作台（`MacWorkspaceView`，块④）。Toast 常驻叠底部。阅读
/// overlay（块⑤，`MacReaderView` 全窗盖在最上层）与 settings sheet（块⑤，由
/// `MacCommandBus.showSettings` 驱动）只留结构位，本块不接线。
struct MacShell: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        ZStack {
            LinoTheme.background.ignoresSafeArea()

            Group {
                if session.token.isEmpty {
                    MacConnectionView(firstRun: true)
                } else if session.currentBook == nil {
                    MacBookshelfView()
                } else {
                    MacWorkspaceView()
                }
            }

            // 块⑤: MacReaderView 全窗 overlay 叠在这一层之上，退出回工作台。
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            LinoIToast()
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        // 块⑤: .sheet(isPresented: $commandBus.showSettings) { MacSettingsSheet() }
        //       内嵌 MacConnectionView(firstRun: false)，由 ⌘, 与右上 ⚙ 触发。
    }
}
