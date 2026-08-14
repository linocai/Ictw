import SwiftUI
import AppKit

/// Integration root for the clean-room macOS author experience.  The app
/// entry can replace `MacShell()` with this type without changing any Store
/// construction or backend contract.
struct V2MacDeskRoot: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var notices: NoticeBus

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if session.token.isEmpty {
                    V2MacConnectionScreen()
                } else if session.currentBook == nil {
                    V2MacBookshelf()
                } else {
                    V2MacWorkspaceDesk()
                }
            }
            V2MacDeskToast()
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(V2MacDeskSurface(token: .desk) { Color.clear })
    }
}

private struct V2MacDeskToast: View {
    @EnvironmentObject private var notices: NoticeBus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let notice = notices.current {
                HStack(spacing: 9) {
                    V2DeskStatusMark(
                        marker: V2DeskMarker(kind: .solidDot, tone: notice.isCritical ? .danger : .warning),
                        diameter: 7
                    )
                    Text(notice.message)
                        .font(V2DeskType.control(12))
                        .foregroundStyle(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if notice.isCritical {
                        V2MacDeskIconButton(symbol: "xmark", label: "关闭提示") { notices.dismiss() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: 500, alignment: .leading)
                .background(V2DeskPalette.color(.ink, scheme: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)) }
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                .task(id: notice.id) {
                    guard !notice.isCritical else { return }
                    try? await Task.sleep(for: .seconds(2.6))
                    if notices.current?.id == notice.id { notices.dismiss() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Connection and shelf

private struct V2MacConnectionScreen: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var endpoint = ""
    @State private var token = ""
    @State private var isSaving = false
    @State private var message: String?
    @FocusState private var endpointFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 7) {
                Text("ICTW")
                    .font(V2DeskType.prose(27, weight: .semibold))
                    .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
                Text("从第一本开始")
                    .font(V2DeskType.control(13))
                    .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
            }
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 14) {
                V2MacDeskSectionLabel(text: "连接你的工作台")
                TextField("后端地址", text: $endpoint)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)) }
                    .focused($endpointFocused)
                SecureField("访问密钥", text: $token)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)) }
                    .onSubmit { Task { await save() } }
                if let message {
                    Text(message)
                        .font(V2DeskType.control(11.5))
                        .foregroundStyle(V2DeskPalette.color(.danger, scheme: colorScheme))
                }
                Button(isSaving ? "正在连接" : "保存并连接") { Task { await save() } }
                    .buttonStyle(V2MacDeskButton(kind: .primary))
                    .disabled(!canSave || isSaving)
            }
            .padding(22)
            .frame(width: 390)
            .background(V2DeskPalette.color(.card, scheme: colorScheme))
            .overlay { RoundedRectangle(cornerRadius: V2DeskMetric.panelCornerRadius).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
        }
        .onAppear {
            endpoint = session.baseURL
            token = session.token
            endpointFocused = endpoint.isEmpty
        }
    }

    private var canSave: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: normalizedEndpoint)?.scheme != nil else {
            message = "后端地址需要包含 http(s)://"
            return
        }
        isSaving = true
        session.baseURL = normalizedEndpoint
        session.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        session.saveConnection()
        await bookshelf.load()
        isSaving = false
    }
}

private struct V2MacBookshelf: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var commandBus: MacCommandBus
    @State private var sheet: V2MacDeskSheet?
    @State private var deleteTarget: Book?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ICTW")
                    .font(V2DeskType.prose(18, weight: .semibold))
                Spacer()
                V2MacDeskIconButton(symbol: "gearshape", label: "设置") { sheet = .settings }
                Button("新建一本") { sheet = .newBook }
                    .buttonStyle(V2MacDeskButton(kind: .primary))
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 28)
            .frame(height: V2DeskMetric.titleBarHeight + 12)
            .background(V2DeskPalette.color(.titleBar, scheme: colorScheme))
            V2MacDeskHairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if bookshelf.isLoading && bookshelf.books.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 70)
                    } else if bookshelf.books.isEmpty {
                        V2MacDeskEmptyPrompt(title: "从第一本开始", actionTitle: "新建一本") { sheet = .newBook }
                            .frame(minHeight: 260)
                    } else {
                        ForEach(bookshelf.books) { book in
                            V2MacBookRow(book: book, open: { Task { await bookshelf.open(book) } }, remove: { deleteTarget = book })
                            V2MacDeskHairline()
                        }
                    }
                }
                .frame(maxWidth: 760)
                .padding(.top, 30)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .task { await bookshelf.load() }
        .onChange(of: commandBus.showNewBook) { _, requested in
            guard requested else { return }
            commandBus.showNewBook = false
            sheet = .newBook
        }
        .onChange(of: commandBus.showSettings) { _, requested in
            guard requested else { return }
            commandBus.showSettings = false
            sheet = .settings
        }
        .sheet(item: $sheet) { V2MacDeskSheetHost(sheet: $0) }
        .confirmationDialog("删除《\(deleteTarget?.title.isEmpty == false ? deleteTarget!.title : "未命名书籍")》？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除这本书", role: .destructive) { if let deleteTarget { Task { await bookshelf.delete(deleteTarget) }; self.deleteTarget = nil } }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("这本书的章节、人物和已整理的记忆都会一起删除。")
        }
    }
}

private struct V2MacBookRow: View {
    let book: Book
    let open: () -> Void
    let remove: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: open) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title.isEmpty ? "未命名书籍" : book.title)
                        .font(V2DeskType.prose(17))
                        .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
                    Text("\(book.chapterCount) 章 · \(book.characterCount) 人物")
                        .font(V2DeskType.control(11.5))
                        .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                }
                Spacer()
                if book.archiveAttentionCount > 0 {
                    HStack(spacing: 5) {
                        V2DeskStatusMark(marker: .unreliable, diameter: 7)
                        Text("\(book.archiveAttentionCount) 章记忆待重整")
                    }
                    .font(V2DeskType.control(11.5))
                    .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                } else if book.archivePendingCount > 0 {
                    Text("正在整理记忆")
                        .font(V2DeskType.control(11.5))
                        .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                } else {
                    Text("最近更新")
                        .font(V2DeskType.control(11.5))
                        .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                }
                Button(action: remove) { Image(systemName: "ellipsis") }
                    .buttonStyle(.plain)
                    .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                    .help("更多操作")
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Workspace desk

struct V2MacWorkspaceDesk: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var commandBus: MacCommandBus

    @State private var selectedChapterID: String?
    @State private var contextOpen = false
    @State private var railCollapsed = false
    @State private var contextFace: V2MacContextFace = .intent
    @State private var sheet: V2MacDeskSheet?
    @State private var showReopenConfirmation = false
    @State private var showAcceptWarning = false
    @State private var showReader = false
    @State private var chapterLoadID: String?
    @State private var creatingChapter = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let contextInlineAt: CGFloat = 1120
        static let railInlineAt: CGFloat = 720
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let usesInlineContext = width >= Layout.contextInlineAt
            let usesFullRail = width >= Layout.railInlineAt && !railCollapsed
            VStack(spacing: 0) {
                titleBar(usesInlineContext: usesInlineContext)
                HStack(spacing: 0) {
                    V2MacChapterRail(
                        selectedID: selectedChapterID,
                        collapsed: !usesFullRail,
                        onOpenSheet: { sheet = $0 },
                        onSelect: { chapter in
                            Task { await navigate(to: chapter) }
                        },
                        onCreate: createChapter
                    )
                    .frame(width: usesFullRail ? V2DeskMetric.chapterRail : V2DeskMetric.collapsedRail)
                    V2MacManuscriptDesk(
                        snapshot: snapshot,
                        onOpenContext: { contextOpen = true },
                        onOpenReader: { showReader = true },
                        onStartNewChapter: createChapter,
                        performAction: runAction,
                        onPrimary: runPrimaryAction,
                        onReopen: { showReopenConfirmation = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if usesInlineContext && contextOpen {
                        V2MacContextPanel(face: $contextFace, onOpenSheet: { sheet = $0 })
                            .frame(width: V2DeskMetric.contextPanel)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    } else if usesInlineContext {
                        V2MacCollapsedContextRail(needsAttention: snapshot.contextNeedsAttention) { contextOpen = true }
                            .frame(width: V2DeskMetric.collapsedRail)
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if !usesInlineContext && contextOpen {
                    V2MacFloatingContext(face: $contextFace, dismiss: { contextOpen = false }, onOpenSheet: { sheet = $0 })
                }
            }
            .animation(V2DeskMotion.sheet(reduceMotion: reduceMotion), value: contextOpen)
        }
        .task(id: session.currentBook?.id) { await loadBook() }
        .onChange(of: editor.currentChapter?.status) { _, _ in
            if let chapter = editor.currentChapter { workspace.upsert(chapter) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await editor.refreshActiveJobIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            editor.persistLocalDraftIfNeeded()
        }
        .onDisappear { editor.persistLocalDraftIfNeeded() }
        .onChange(of: commandBus.showNewBook) { _, requested in
            guard requested else { return }
            commandBus.showNewBook = false
            sheet = .newBook
        }
        .onChange(of: commandBus.showSettings) { _, requested in
            guard requested else { return }
            commandBus.showSettings = false
            sheet = .settings
        }
        .onChange(of: commandBus.showNewChapter) { _, requested in
            guard requested else { return }
            commandBus.showNewChapter = false
            guard session.currentBook != nil else { return }
            createChapter()
        }
        .sheet(item: $sheet) { V2MacDeskSheetHost(sheet: $0, currentChapterID: selectedChapterID) }
        .confirmationDialog("重新编辑这一章？", isPresented: $showReopenConfirmation, titleVisibility: .visible) {
            Button("保留正文并重新编辑", role: .destructive) { reopen() }
            Button("取消", role: .cancel) {}
        } message: {
            reopenConfirmationMessage
        }
        .confirmationDialog("仍然接受这一章？", isPresented: $showAcceptWarning, titleVisibility: .visible) {
            Button("接受这一章", role: .destructive) { accept(overrideChecker: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这一章会被记为完成；当前检查提出的问题将不再提醒你。")
        }
        .sheet(isPresented: $showReader) {
            V2MacReaderSheet(
                selectedChapterID: $selectedChapterID,
                onReadChapter: { chapter in
                    await navigate(to: chapter)
                },
                onOpenWriting: { chapter in
                    showReader = false
                    await navigate(to: chapter)
                },
                onStartNewChapter: {
                    showReader = false
                    createChapter()
                }
            )
        }
    }

    private var snapshot: V2DeskSnapshot {
        V2DeskPresentation.make(V2DeskEditorSource(
            chapter: editor.currentChapter,
            writingPhase: editor.writingPhase,
            checkerResult: editor.checkerResult,
            checkerAppliesToVisibleDraft: editor.checkerAppliesToVisibleDraft,
            checkerRefreshing: editor.checkerRefreshing,
            staleCheckedSnapshot: editor.staleCheckedSnapshot,
            saveState: editor.saveState,
            connectionInterrupted: editor.pollingConnectionInterrupted
        ))
    }

    private var reopenMessage: String {
        guard let current = editor.currentChapter else { return "正文与本章意图会保留。" }
        let downstream = workspace.chapters.filter { $0.index > current.index }.map { "第 \($0.index) 章" }
        return downstream.isEmpty
            ? "正文与本章意图会保留。这一章的归档将失效。"
            : "正文与本章意图会保留；\(downstream.joined(separator: "、")) 的记忆会标为不再可靠。"
    }

    private var reopenConfirmationMessage: Text {
        Text(reopenMessage)
    }

    private func loadBook() async {
        guard let book = session.currentBook else { return }
        await workspace.load(bookId: book.id)
        await characters.load(bookId: book.id)
        await agents.load()
        if selectedChapterID == nil || !workspace.chapters.contains(where: { $0.id == selectedChapterID }) {
            if let first = workspace.chapters.first {
                await navigate(to: first)
            }
        }
    }

    /// All rail and reader selection converges here.  Keeping one in-flight
    /// load prevents repeated reader taps from racing the editor and leaving
    /// the selected rail row out of sync with the visible manuscript.
    private func navigate(to summary: ChapterSummary, allowsDuringCreation: Bool = false) async {
        guard !creatingChapter || allowsDuringCreation else { return }
        guard chapterLoadID == nil else { return }
        guard selectedChapterID != summary.id || editor.currentChapter?.id != summary.id else { return }

        let previousEditorChapterID = editor.currentChapter?.id
        chapterLoadID = summary.id
        defer { chapterLoadID = nil }
        selectedChapterID = summary.id
        inspiration.clearIfChapterChanged(to: summary.id)
        await editor.load(summary)

        // `editor.load` deliberately keeps the current chapter on a network
        // failure.  Restore the rail to that same visible chapter instead of
        // leaving a newly selected row beside an older manuscript.
        guard editor.currentChapter?.id == summary.id else {
            selectedChapterID = editor.currentChapter?.id ?? previousEditorChapterID
            inspiration.clearIfChapterChanged(to: selectedChapterID)
            return
        }
    }

    private func createChapter() {
        guard !creatingChapter, chapterLoadID == nil else { return }
        creatingChapter = true
        Task {
            defer { creatingChapter = false }
            if let chapter = await workspace.createChapter() {
                await navigate(to: chapter, allowsDuringCreation: true)
            }
        }
    }

    private func runPrimaryAction() {
        runAction(snapshot.primaryAction)
    }

    private func runAction(_ action: V2DeskPrimaryAction) {
        switch action {
        case .generate, .retryGeneration: Task { if let chapter = await editor.generate() { workspace.upsert(chapter) } }
        case .cancelGeneration: Task { if let chapter = await editor.cancelWriting() { workspace.upsert(chapter) } }
        case .rerunChecker: Task { _ = await editor.rerunChecker() }
        case .accept: accept(overrideChecker: false)
        case .acceptWithWarning: showAcceptWarning = true
        case .retryArchive: Task { if let chapter = await editor.retryArchive() { workspace.upsert(chapter) } }
        case .startNewChapter: createChapter()
        case .openSettings: sheet = .settings
        case .none: break
        }
    }

    private func accept(overrideChecker: Bool) {
        Task { if let chapter = await editor.accept(overrideChecker: overrideChecker) { workspace.upsert(chapter) } }
    }

    private func reopen() {
        Task {
            if let chapter = await editor.reopen() {
                workspace.upsert(chapter)
                if let bookID = session.currentBook?.id { await workspace.load(bookId: bookID) }
            }
        }
    }

    private func titleBar(usesInlineContext: Bool) -> some View {
        HStack(spacing: 8) {
            Text("ICTW")
                .font(V2DeskType.prose(18, weight: .semibold))
                .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
                .frame(width: 68, alignment: .leading)
            V2MacDeskIconButton(symbol: "books.vertical", label: "返回书架") { session.closeBook() }
            Text(session.currentBook?.title.isEmpty == false ? (session.currentBook?.title ?? "") : "未命名书籍")
                .font(V2DeskType.control(13, weight: .medium))
                .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                .lineLimit(1)
            Spacer()
            if snapshot.showsUnsavedLocalDraft {
                Text("未保存")
                    .font(V2DeskType.control(10.5))
                    .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            }
            V2MacDeskIconButton(symbol: "square.and.arrow.down", label: "导出") { sheet = .export }
            V2MacDeskIconButton(symbol: "gearshape", label: "设置") { sheet = .settings }
            if !usesInlineContext {
                V2MacDeskIconButton(symbol: "sidebar.right", label: "意图与证据") { contextOpen.toggle() }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: V2DeskMetric.titleBarHeight)
        .background(V2DeskPalette.color(.titleBar, scheme: colorScheme))
        .overlay(alignment: .bottom) { V2MacDeskHairline() }
    }
}

enum V2MacContextFace: String, CaseIterable, Identifiable {
    case intent, evidence, memory
    var id: String { rawValue }
    var title: String {
        switch self { case .intent: "本章意图"; case .evidence: "证据"; case .memory: "这一章留下的" }
    }
}

enum V2MacDeskSheet: Identifiable {
    case newBook, world, people, inspiration, settings, export
    var id: String {
        switch self {
        case .newBook: "newBook"; case .world: "world"; case .people: "people"; case .inspiration: "inspiration"; case .settings: "settings"; case .export: "export"
        }
    }
}

// MARK: - Rail

private struct V2MacChapterRail: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    let selectedID: String?
    let collapsed: Bool
    let onOpenSheet: (V2MacDeskSheet) -> Void
    let onSelect: (ChapterSummary) -> Void
    let onCreate: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if !collapsed {
                V2MacDeskSectionLabel(text: "章节轨")
                    .padding(.horizontal, 13).padding(.vertical, 13)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(workspace.chapters) { chapter in
                            V2MacChapterRailRow(
                                chapter: chapter,
                                selected: chapter.id == selectedID,
                                current: chapter.id == editor.currentChapter?.id,
                                collapsed: collapsed
                            ) { onSelect(chapter) }
                            .id(chapter.id)
                        }
                        Button(action: onCreate) {
                            HStack(spacing: 7) {
                                Text("＋").frame(width: 24)
                                if !collapsed { Text("开始新一章") }
                            }
                            .font(V2DeskType.control(11.5))
                            .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .padding(.horizontal, collapsed ? 10 : 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear { scrollToSelected(proxy) }
                .onChange(of: selectedID) { _, _ in scrollToSelected(proxy) }
            }
            V2MacDeskHairline()
            VStack(alignment: .leading, spacing: 0) {
                V2MacRailFooter(title: collapsed ? nil : "人物 \(characters.characters.count)", symbol: "person.2") { onOpenSheet(.people) }
                V2MacRailFooter(title: collapsed ? nil : "世界观", symbol: "text.book.closed") { onOpenSheet(.world) }
                V2MacRailFooter(title: collapsed ? nil : "找方向", symbol: "sparkles") { onOpenSheet(.inspiration) }
            }
            .padding(.vertical, 5)
        }
        .background(V2DeskPalette.color(.rail, scheme: colorScheme))
        .overlay(alignment: .trailing) { V2MacDeskHairline().frame(width: 1, height: nil) }
    }

    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(selectedID, anchor: .center)
        }
    }
}

private struct V2MacRailFooter: View {
    let title: String?
    let symbol: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 14)
                if let title { Text(title).lineLimit(1) }
            }
            .font(V2DeskType.control(11.5))
            .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.horizontal, 13)
        }.buttonStyle(.plain)
    }
}

private struct V2MacChapterRailRow: View {
    let chapter: ChapterSummary
    let selected: Bool
    let current: Bool
    let collapsed: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var archiveRailState: ChapterArchiveRailState {
        ChapterArchiveRailState.resolve(status: chapter.archiveStatus, canRetry: chapter.archiveCanRetry)
    }

    private var marker: V2DeskMarker {
        if chapter.status == "finalized" { return .confirmed }
        if archiveRailState == .attention { return .unreliable }
        return .notYetHappened
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if !collapsed {
                    Text("\(chapter.index)")
                        .font(V2DeskType.chapterNumber())
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 24, alignment: .trailing)
                }
                V2DeskStatusMark(marker: marker, diameter: 6)
                if !collapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chapter.title.isEmpty ? "未命名" : chapter.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let label = archiveRailState.label {
                            Text(label)
                                .font(V2DeskType.control(9.5))
                                .foregroundStyle(archiveRailState == .attention ? V2DeskPalette.color(.danger, scheme: colorScheme) : V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                        }
                    }
                }
            }
            .font(V2DeskType.control(selected ? 12 : 11.5, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? V2DeskPalette.color(.ink, scheme: colorScheme) : V2DeskPalette.color(.tertiaryInk, scheme: colorScheme))
            .frame(maxWidth: .infinity, minHeight: selected ? 34 : 30, alignment: .leading)
            .padding(.horizontal, collapsed ? 13 : 10)
            .background {
                ZStack {
                    if selected { V2DeskPalette.color(.desk, scheme: colorScheme) }
                    if archiveRailState == .attention { V2MacDeskStripeBackground().opacity(selected ? 0.42 : 0.7) }
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(current && archiveRailState == .attention ? V2DeskPalette.color(.danger, scheme: colorScheme) : V2DeskPalette.color(.accent, scheme: colorScheme))
                        .frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
