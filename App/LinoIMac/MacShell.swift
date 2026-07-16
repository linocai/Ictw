import SwiftUI

/// 单窗状态机：`session.token.isEmpty` → 首启连接页；已连接但未开书 → 书架；
/// 已开书 → 三栏工作台（`MacWorkspaceView`）。Toast 常驻叠底部。设置 sheet 由
/// `MacCommandBus.showSettings` 驱动（⌘, 与书架/工作台的 ⚙ 均经它派发）。
/// 阅读 overlay（`MacReaderView`）没有挂在这一层——它只能从已打开的章节
/// 编辑器进入，`MacWorkspaceView` 本身已铺满整窗，挂在那一层可以直接复用其
/// `selectedChapterId`，不必再为阅读单独建一份跨层共享状态。
struct MacShell: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var commandBus: MacCommandBus

    var body: some View {
        ZStack {
            LinoTheme.background.ignoresSafeArea()

            Group {
                if session.token.isEmpty {
                    MacConnectionView(firstRun: true)
                        .transition(.opacity)
                } else if session.currentBook == nil {
                    MacBookshelfView()
                        .transition(.opacity)
                } else {
                    MacWorkspaceView()
                        .transition(.opacity)
                }
            }
            .animation(LinoMotion.content, value: session.token.isEmpty)
            .animation(LinoMotion.content, value: session.currentBook?.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            LinoIToast()
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
        }
        .sheet(isPresented: $commandBus.showSettings) {
            MacSettingsSheet()
        }
        // 锁浅色双保险之二：SwiftUI 层锁定，配合 `LinoIMacApp.AppDelegate` 的
        // `NSApp.appearance = .aqua`（锁住 AppKit 系统面板）。
        .preferredColorScheme(.light)
    }
}
