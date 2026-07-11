import SwiftUI
import AppKit

/// 三栏工作台容器：`GeometryReader` reflow（≥1100 三栏并列；800–1100 右栏收成
/// 工具栏切换的抽屉；<800 左侧栏也收抽屉）+ 自绘标题栏（46 高
/// `.linoToolbarGlass`）。选中章节用本视图 `@State selectedChapterId`（不动共享
/// store），变化时 `await editor.load(summary)`。前台恢复：监听
/// `NSApplication.didBecomeActiveNotification` 调 macOS 专用
/// `editor.refreshActiveJobIfNeeded()`（无 status 守卫，绕开 iOS P2#3）。
struct MacWorkspaceView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var editor: ChapterEditorStore

    @State private var selectedChapterId: String?
    @State private var rightTab: MacRightTab = .characters
    @State private var rightPanelOpen = true
    @State private var sidebarOpen = true

    private static let wideBreakpoint: CGFloat = 1100
    private static let mediumBreakpoint: CGFloat = 800

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width > 0 ? proxy.size.width : Self.wideBreakpoint
            let showRightInline = width >= Self.wideBreakpoint
            let showSidebarInline = width >= Self.mediumBreakpoint

            VStack(spacing: 0) {
                titleBar(showRightInline: showRightInline, showSidebarInline: showSidebarInline)
                bodyRow(showRightInline: showRightInline, showSidebarInline: showSidebarInline)
            }
            .onChange(of: showRightInline) { _, inline in if inline { rightPanelOpen = true } }
            .onChange(of: showSidebarInline) { _, inline in if inline { sidebarOpen = true } }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: session.currentBook?.id) { await reload() }
        .onChange(of: selectedChapterId) { _, id in loadSelected(id) }
        .onChange(of: editor.currentChapter?.status) { _, _ in
            if let chapter = editor.currentChapter { workspace.upsert(chapter) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await editor.refreshActiveJobIfNeeded() }
        }
    }

    // MARK: - Title bar

    private func titleBar(showRightInline: Bool, showSidebarInline: Bool) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 70, height: 1) // 交通灯挡位

            if !showSidebarInline {
                LinoMacIconButton(systemName: "sidebar.left", size: 28, fontSize: 13, help: "章节") {
                    withAnimation(.easeOut(duration: 0.18)) { sidebarOpen.toggle() }
                }
            }

            logoChip

            Spacer(minLength: 8)
            Text(session.currentBook?.title.isEmpty == false ? (session.currentBook?.title ?? "未命名书籍") : "未命名书籍")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LinoTheme.body.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 8)

            LinoMacConnectionChip()
            LinoMacIconButton(systemName: "gearshape", size: 28, fontSize: 14, help: "设置（块⑤开放）", isDisabled: true) {}
            if !showRightInline {
                LinoMacIconButton(systemName: "sidebar.right", size: 28, fontSize: 13, help: "辅助面板") {
                    withAnimation(.easeOut(duration: 0.18)) { rightPanelOpen.toggle() }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .linoToolbarGlass()
        .overlay(alignment: .bottom) {
            Rectangle().fill(LinoMacMetrics.hairline).frame(height: LinoMacMetrics.hairlineWidth)
        }
    }

    private var logoChip: some View {
        Button {
            selectedChapterId = nil
            session.closeBook()
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(LinoTheme.logoGradient)
                    .frame(width: 16, height: 16)
                Text("返回书架")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LinoTheme.body)
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("返回书架")
        .onHover { pointer($0) }
    }

    // MARK: - Body row (three columns + reflow)

    private func bodyRow(showRightInline: Bool, showSidebarInline: Bool) -> some View {
        HStack(spacing: 0) {
            if showSidebarInline {
                MacChapterSidebar(selectedChapterId: $selectedChapterId)
                    .frame(width: LinoMacMetrics.sidebarWidth)
            }
            ZStack(alignment: .topLeading) {
                MacChapterEditor(selectedChapterId: $selectedChapterId)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !showSidebarInline && sidebarOpen {
                    sidebarDrawer
                }
            }
            .frame(maxWidth: .infinity)

            if showRightInline {
                MacRightPanel(tab: $rightTab)
                    .frame(width: LinoMacMetrics.rightPanelWidth)
            } else if rightPanelOpen {
                MacRightPanel(tab: $rightTab)
                    .frame(width: LinoMacMetrics.rightPanelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebarDrawer: some View {
        MacChapterSidebar(selectedChapterId: $selectedChapterId)
            .frame(width: LinoMacMetrics.sidebarWidth)
            .background(.regularMaterial)
            .shadow(color: LinoTheme.hex(0x141C3C, opacity: 0.18), radius: 18, x: 6)
            .transition(.move(edge: .leading))
            .zIndex(2)
    }

    // MARK: - Coordination

    private func reload() async {
        guard let book = session.currentBook else { return }
        await workspace.load(bookId: book.id)
        await characters.load(bookId: book.id)
        await agents.load()
        if selectedChapterId == nil || !workspace.chapters.contains(where: { $0.id == selectedChapterId }) {
            selectedChapterId = workspace.chapters.first?.id
        }
    }

    private func loadSelected(_ id: String?) {
        guard let id, let summary = workspace.chapters.first(where: { $0.id == id }) else { return }
        Task { await editor.load(summary) }
    }
}
