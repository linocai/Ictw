import SwiftUI

/// 右栏「书设定」tab：书名 + 世界观设定 editor + 保存（`WorkspaceStore.saveBook`）
/// + 导出全书 `.txt`（`MacExportSaver`）。语义对齐 iOS `LinoIBookSettingsPane`：
/// 世界观进入 Writer 硬约束区；保存后同步回书架卡片（`bookshelf.upsert`）。
struct MacBookSettingsTab: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var bookshelf: BookshelfStore

    @State private var title = ""
    @State private var world = ""
    @State private var loadedBookId: String?
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                LinoISectionLabel("书设定")
                Text("世界观设定会进入 Writer 的硬约束区。")
                    .font(.system(size: 12))
                    .foregroundStyle(LinoTheme.muted)
            }

            settingsCard
            exportCard
        }
        .onAppear(perform: sync)
        .onChange(of: session.currentBook?.id) { _, _ in sync() }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("书名")
                LinoITextField("书名", text: $title)
            }
            LinoIEditor(
                title: "世界观设定",
                text: $world,
                minHeight: 200,
                placeholder: "全局世界观、硬设定、不能违背的事实。"
            )
            Button {
                Task {
                    await workspace.saveBook(title: title, world: world)
                    if let book = session.currentBook {
                        bookshelf.upsert(book)
                    }
                }
            } label: {
                Text(workspace.isLoading ? "保存中" : "保存设定")
            }
            .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
            .onHover { pointer($0) }
        }
        .padding(14)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinoISectionLabel("导出")
            Text("把全书已完成章节导出为纯文本，方便备份或投稿。")
                .font(.system(size: 12))
                .foregroundStyle(LinoTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    guard let book = session.currentBook else { return }
                    isExporting = true
                    await MacExportSaver.exportBook(book, session: session)
                    isExporting = false
                }
            } label: {
                Text(isExporting ? "正在导出" : "导出全书")
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
            .disabled(isExporting || session.currentBook == nil)
            .onHover { pointer($0 && !isExporting && session.currentBook != nil) }
        }
        .padding(14)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private func sync() {
        guard let book = session.currentBook, loadedBookId != book.id else { return }
        loadedBookId = book.id
        title = book.title
        world = book.worldSetting
    }
}
