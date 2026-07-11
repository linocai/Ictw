import SwiftUI

/// 单窗状态机：`session.token.isEmpty` → 首启连接页；已连接但未开书 → 书架；
/// 已开书 → 工作台。三栏工作台（块④）上线前，先用一块写明"工作台施工中"
/// 的玻璃占位页顶上，保证"新建/打开/返回书架"这条链路本块就能整体跑通。
/// Toast 常驻叠底部。阅读 overlay（块⑤，`MacReaderView` 全窗盖在最上层）与
/// settings sheet（块⑤，由 `MacCommandBus.showSettings` 驱动）只留结构位，
/// 本块不接线。
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
                    MacWorkspacePlaceholder()
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

/// 块④三栏工作台上线前的占位页：确认已进入某本书、可以退回书架。不读写
/// 章节/人物数据，也不预置任何块④会用到的状态。
private struct MacWorkspacePlaceholder: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(LinoTheme.faint)
                Text("工作台施工中")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LinoTheme.ink)
                if let book = session.currentBook {
                    Text("《\(book.title.isEmpty ? "未命名书籍" : book.title)》的三栏写作台将在块④上线。")
                        .font(.system(size: 13))
                        .foregroundStyle(LinoTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("返回书架") {
                session.closeBook()
            }
            .buttonStyle(LinoITintButtonStyle())
            .onHover { pointer($0) }
        }
        .padding(40)
        .frame(maxWidth: 420)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
