import SwiftUI
import AppKit

/// 三栏工作台容器：`GeometryReader` reflow（≥1100 三栏并列；800–1100 右栏收成
/// 工具栏切换的抽屉；<800 左侧栏也收抽屉）+ 自绘标题栏（46 高
/// `.linoToolbarGlass`）。选中章节用本视图 `@State selectedChapterId`（不动共享
/// store），变化时 `await editor.load(summary)`。前台恢复：监听
/// `NSApplication.didBecomeActiveNotification` 调 macOS 专用
/// `editor.refreshActiveJobIfNeeded()`（无 status 守卫，绕开 iOS P2#3）。
///
/// 阅读页（`MacReaderView`）作为本视图顶层 ZStack 的一个分支挂载——本视图
/// 本身已铺满整窗，挂在这里既满足「全窗 overlay」，又能直接复用
/// `selectedChapterId` 驱动翻页，不必新建共享状态。⌘⇧N（新建章节）的监听也
/// 放在本视图而非 `MacChapterSidebar`：窄窗（<800）且抽屉收起时侧栏并未挂载，
/// 放在恒常挂载的本视图才能保证命令总是生效。
struct MacWorkspaceView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var commandBus: MacCommandBus

    @State private var selectedChapterId: String?
    @State private var rightTab: MacRightTab = .characters
    @State private var rightPanelOpen = true
    @State private var sidebarOpen = true
    @State private var isReaderOpen = false

    private static let wideBreakpoint: CGFloat = 1100
    private static let mediumBreakpoint: CGFloat = 800

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let width = proxy.size.width > 0 ? proxy.size.width : Self.wideBreakpoint
                let showRightInline = width >= Self.wideBreakpoint
                let showSidebarInline = width >= Self.mediumBreakpoint

                VStack(spacing: 0) {
                    titleBar(showRightInline: showRightInline, showSidebarInline: showSidebarInline)
                    bodyRow(showRightInline: showRightInline, showSidebarInline: showSidebarInline)
                }
                .onChange(of: showRightInline) { _, inline in if inline { withAnimation(LinoMotion.drawer) { rightPanelOpen = true } } }
                .onChange(of: showSidebarInline) { _, inline in if inline { withAnimation(LinoMotion.drawer) { sidebarOpen = true } } }
            }

            if isReaderOpen {
                MacReaderView(selectedChapterId: $selectedChapterId, isPresented: $isReaderOpen)
                    .transition(.opacity)
                    .zIndex(3)
            }
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
        .onChange(of: commandBus.showNewChapter) { _, trigger in
            guard trigger else { return }
            commandBus.showNewChapter = false
            createChapterViaCommand()
        }
    }

    // MARK: - Title bar

    private func titleBar(showRightInline: Bool, showSidebarInline: Bool) -> some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 70, height: 1) // 交通灯挡位

            if !showSidebarInline {
                LinoMacIconButton(systemName: "sidebar.left", size: 28, fontSize: 13, help: "章节") {
                    toggleSidebarDrawer()
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
            LinoMacIconButton(systemName: "gearshape", size: 28, fontSize: 14, help: "设置") {
                commandBus.showSettings = true
            }
            if !showRightInline {
                LinoMacIconButton(systemName: "sidebar.right", size: 28, fontSize: 13, help: "辅助面板") {
                    toggleRightDrawer(showRightInline: showRightInline, showSidebarInline: showSidebarInline)
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
                    .transition(.opacity)
            }
            ZStack(alignment: .topLeading) {
                MacChapterEditor(
                    selectedChapterId: $selectedChapterId,
                    onOpenReader: { withAnimation(LinoMotion.reader) { isReaderOpen = true } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !showSidebarInline && sidebarOpen {
                    drawerScrim { closeSidebarDrawer() }
                        .zIndex(1)
                    sidebarDrawer
                }
            }
            .frame(maxWidth: .infinity)

            if showRightInline {
                MacRightPanel(tab: $rightTab)
                    .frame(width: LinoMacMetrics.rightPanelWidth)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            // 右抽屉走独立的 overlay（而非 HStack 里的并列子项）：这样它才能像
            // 左抽屉一样「浮在」正文之上而不是把正文再挤窄一次，scrim 也才能
            // 铺满整块内容区，而不是只盖住右抽屉自己那一小条。<800 时与左抽屉
            // 互斥——左抽屉正在显示时右抽屉让位（block④ 修复：窄窗两侧抽屉同开
            // 会互相咬合遮挡）。
            if isRightDrawerVisible(showRightInline: showRightInline, showSidebarInline: showSidebarInline) {
                ZStack(alignment: .trailing) {
                    drawerScrim { closeRightDrawer() }
                    rightDrawer
                }
            }
        }
        .animation(LinoMotion.drawer, value: showSidebarInline)
        .animation(LinoMotion.drawer, value: showRightInline)
    }

    /// 右抽屉当前是否应该可见：窄窗（<800）时与左抽屉互斥，左抽屉优先（章节
    /// 导航是更基础的默认态）；中宽窗（800–1100）时不受左栏影响，因为左栏
    /// 此时已内嵌显示，不再是抽屉，不存在互斥问题。
    private func isRightDrawerVisible(showRightInline: Bool, showSidebarInline: Bool) -> Bool {
        guard !showRightInline else { return false }
        return rightPanelOpen && !(!showSidebarInline && sidebarOpen)
    }

    /// 抽屉后的半透明遮罩：铺满整块内容区、点击可关闭当前抽屉，让抽屉读作
    /// 「浮在正文之上的临时面板」而非与正文拼接的一列，避免窄窗下视觉咬合。
    private func drawerScrim(onTap: @escaping () -> Void) -> some View {
        Color.black.opacity(0.16)
            .contentShape(Rectangle())
            .transition(.opacity)
            .onTapGesture(perform: onTap)
    }

    private var sidebarDrawer: some View {
        MacChapterSidebar(selectedChapterId: $selectedChapterId)
            .frame(width: LinoMacMetrics.sidebarWidth)
            .background(.regularMaterial)
            .shadow(color: LinoTheme.hex(0x141C3C, opacity: 0.18), radius: 18, x: 6)
            .transition(.move(edge: .leading))
            .zIndex(2)
    }

    private var rightDrawer: some View {
        MacRightPanel(tab: $rightTab)
            .frame(width: LinoMacMetrics.rightPanelWidth)
            .background(.regularMaterial)
            .shadow(color: LinoTheme.hex(0x141C3C, opacity: 0.18), radius: 18, x: -6)
            .transition(.move(edge: .trailing))
            .zIndex(2)
    }

    // MARK: - Drawer toggling（<800 互斥：开一个自动关另一个）

    private func toggleSidebarDrawer() {
        withAnimation(LinoMotion.drawer) {
            sidebarOpen.toggle()
            // 这个按钮只在 !showSidebarInline（即 <800）时才会出现，此时打开
            // 左抽屉必须同时收起右抽屉，否则两者会同时争用同一块窄窗空间。
            if sidebarOpen { rightPanelOpen = false }
        }
    }

    private func toggleRightDrawer(showRightInline: Bool, showSidebarInline: Bool) {
        // 用「当前是否真的可见」而非裸 flag 判断——<800 时右抽屉可能因为左
        // 抽屉正在显示而被互斥隐藏，此时 rightPanelOpen 仍是 true，直接
        // `.toggle()` 会把它误关成 false，导致按钮看起来毫无反应。
        let currentlyVisible = isRightDrawerVisible(showRightInline: showRightInline, showSidebarInline: showSidebarInline)
        withAnimation(LinoMotion.drawer) {
            if currentlyVisible {
                rightPanelOpen = false
            } else {
                rightPanelOpen = true
                if !showSidebarInline { sidebarOpen = false }
            }
        }
    }

    private func closeSidebarDrawer() {
        withAnimation(LinoMotion.drawer) { sidebarOpen = false }
    }

    private func closeRightDrawer() {
        withAnimation(LinoMotion.drawer) { rightPanelOpen = false }
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

    /// ⌘⇧N 落地处：与 `MacChapterSidebar` 的「+」按钮调用同一个
    /// `workspace.createChapter()`，额外把抽屉打开（窄窗时也能看见新章节）。
    private func createChapterViaCommand() {
        sidebarOpen = true
        Task {
            await workspace.createChapter()
            if let created = workspace.chapterPath.last {
                selectedChapterId = created.id
            }
        }
    }
}
