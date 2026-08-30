import SwiftUI
import AppKit

/// Integration root for the clean-room macOS author experience.  The app
/// entry can replace `MacShell()` with this type without changing any Store
/// construction or backend contract.
struct V2MacDeskRoot: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var notices: NoticeBus
    @EnvironmentObject private var sync: ClientSyncStore
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var agents: AgentSettingsStore

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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await flushPendingAndRefresh() }
        }
    }

    private func flushPendingAndRefresh() async {
        let applied = await sync.flush(using: session.api)
        await V2DeskConflictRefresh.run(
            applied, session: session, bookshelf: bookshelf,
            workspace: workspace, editor: editor,
            characters: characters, agents: agents
        )
    }
}

private struct V2MacSyncStatusButton: View {
    @EnvironmentObject private var sync: ClientSyncStore
    let openCenter: () -> Void

    var body: some View {
        if let state {
            Button(action: openCenter) { V2DeskSyncPill(state: state, compact: true) }
                .buttonStyle(.plain)
                .help("查看同步与冲突")
        }
    }

    private var state: V2DeskSyncPill.State? {
        if sync.hasPersistentSyncFailure { return .persistenceFailed }
        if !sync.conflicts.isEmpty { return .conflict(sync.conflicts.count) }
        if !sync.isOnline { return .offline }
        if sync.isFlushing { return .refreshing }
        if sync.pendingCount > 0 { return .pending(sync.pendingCount) }
        return nil
    }
}

private struct V2MacSyncCenter: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var sync: ClientSyncStore
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var notices: NoticeBus
    @State private var serverDecision: ContentConflict?
    @State private var localDecision: ContentConflict?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "同步与冲突", width: 700) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    V2DeskSyncPill(state: state)
                    Spacer()
                    if sync.isOnline, sync.pendingCount > 0 {
                        Button(sync.isFlushing ? "正在同步" : "立即尝试同步") { Task { await flushPendingAndRefresh() } }
                            .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
                            .disabled(sync.isFlushing)
                    }
                }
                if !sync.isOnline { V2DeskOfflineExplanation() }
                if let failure = sync.persistenceFailure {
                    Text(failure)
                        .font(V2DeskType.control(12, weight: .medium))
                        .foregroundStyle(V2DeskPalette.color(.danger, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if sync.pendingCount > 0, !sync.hasPersistentSyncFailure {
                    Text("\(sync.pendingCount) 项本机修改会在恢复连接后按原始编辑基线安全提交。")
                        .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                }
                if sync.conflicts.isEmpty {
                    Spacer()
                    Text("没有需要决定的冲突。")
                        .font(V2DeskType.prose(16)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(sync.conflicts) { conflict in
                                V2MacConflictCard(
                                    conflict: conflict,
                                    useServer: { serverDecision = conflict },
                                    keepLocal: { localDecision = conflict },
                                    queueMerge: { refreshAfterSubmit(conflict) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(22)
            .frame(minHeight: 430)
        }
        .confirmationDialog("采用服务器版本？", isPresented: Binding(get: { serverDecision != nil }, set: { if !$0 { serverDecision = nil } })) {
            Button("采用服务器版本", role: .destructive) {
                if let conflict = serverDecision {
                    sync.keepServer(conflict)
                    refreshFromServer(conflict)
                }
                serverDecision = nil
            }
            Button("取消", role: .cancel) { serverDecision = nil }
        } message: { Text("本机未同步的这项修改会被移除，服务器版本会成为新的基线。") }
        .confirmationDialog("保留本机版本并重新提交？", isPresented: Binding(get: { localDecision != nil }, set: { if !$0 { localDecision = nil } })) {
            Button("保留本机并重新提交") {
                if let conflict = localDecision {
                    guard sync.keepLocal(conflict) else {
                        notices.publish("本机未能安全保存待同步内容，请保留当前页面后重试。", critical: true)
                        localDecision = nil
                        return
                    }
                    refreshAfterSubmit(conflict)
                }
                localDecision = nil
            }
            Button("取消", role: .cancel) { localDecision = nil }
        } message: { Text("你已查看本机、服务器和共同基线。系统会使用服务器刚返回的版本作为前提重新提交，不会强制覆盖。") }
    }

    private var state: V2DeskSyncPill.State {
        if sync.hasPersistentSyncFailure { return .persistenceFailed }
        if !sync.conflicts.isEmpty { return .conflict(sync.conflicts.count) }
        if !sync.isOnline { return .offline }
        if sync.isFlushing { return .refreshing }
        if sync.pendingCount > 0 { return .pending(sync.pendingCount) }
        return .synced
    }

    private func flushPendingAndRefresh() async {
        let applied = await sync.flush(using: session.api)
        await V2DeskConflictRefresh.run(
            applied, session: session, bookshelf: bookshelf,
            workspace: workspace, editor: editor,
            characters: characters, agents: agents
        )
    }

    private func refreshAfterSubmit(_ conflict: ContentConflict) {
        Task {
            await sync.flush(using: session.api)
            await refresh(conflict)
        }
    }

    private func refreshFromServer(_ conflict: ContentConflict) {
        Task { await refresh(conflict) }
    }

    private func refresh(_ conflict: ContentConflict) async {
        await V2DeskConflictRefresh.run(
            conflict,
            session: session,
            bookshelf: bookshelf,
            workspace: workspace,
            editor: editor,
            characters: characters,
            agents: agents
        )
    }
}

private struct V2MacConflictCard: View {
    let conflict: ContentConflict
    let useServer: () -> Void
    let keepLocal: () -> Void
    let queueMerge: () -> Void
    @State private var selection = "本机"
    @EnvironmentObject private var sync: ClientSyncStore
    @EnvironmentObject private var notices: NoticeBus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            V2DeskConflictDecisionCard(
                title: "\(conflict.resourceLabel)已在另一设备更新",
                detail: "本机基线版本 \(conflict.submittedRevision)，服务器当前版本 \(conflict.currentRevision)。请先对比三份内容，再明确决定。",
                useServer: useServer,
                keepLocal: keepLocal,
                requiresSecretReentry: conflict.requiresSecretReentry
            )
            if sync.automaticMergeCandidate(for: conflict) != nil {
                Button("合并不重叠的修改") {
                    guard sync.queueAutomaticMerge(for: conflict) else {
                        notices.publish("本机未能安全保存合并结果，请保留当前页面后重试。", critical: true)
                        return
                    }
                    queueMerge()
                }
                .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
                .help("本机与服务器修改的是不同字段，可安全合并后再提交")
            }
            Picker("比较内容", selection: $selection) {
                Text("共同基线").tag("基线")
                Text("本机修改").tag("本机")
                Text("服务器版本").tag("服务器")
            }
            .pickerStyle(.segmented)
            ScrollView {
                Text(prettyJSON(data(for: selection)))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 170)
            .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func data(for choice: String) -> Data {
        switch choice {
        case "基线": conflict.baseSnapshot
        case "服务器": conflict.serverSnapshot
        default: conflict.localPayload
        }
    }

    private func prettyJSON(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: formatted, encoding: .utf8) else { return "无法读取这份比较内容。" }
        return text
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
    @State private var showingSyncCenter = false
    @State private var deleteTarget: Book?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ICTW")
                    .font(V2DeskType.prose(18, weight: .semibold))
                Spacer()
                V2MacSyncStatusButton(openCenter: { showingSyncCenter = true })
                V2MacDeskIconButton(symbol: "magnifyingglass", label: "搜索全部书籍") { sheet = .search }
                V2MacDeskIconButton(symbol: "archivebox", label: "备份或恢复项目") { sheet = .projectPackage }
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
        .sheet(isPresented: $showingSyncCenter) { V2MacSyncCenter() }
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
    @EnvironmentObject private var sync: ClientSyncStore

    @State private var selectedChapterID: String?
    @State private var contextOpen = false
    @State private var railCollapsed = false
    @State private var contextFace: V2MacContextFace = .intent
    @State private var sheet: V2MacDeskSheet?
    @State private var showingSyncCenter = false
    @State private var showReopenConfirmation = false
    @State private var showAcceptWarning = false
    @State private var showRewriteConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showReader = false
    @State private var chapterLoadID: String?
    @State private var creatingChapter = false
    /// One gate for every chapter-scope confirmation, not one per flow.
    /// Separate gates left the two preview-backed buttons able to run at the
    /// same time: on a slow network "重新编辑" neither dimmed nor reacted, so a
    /// second tap on "重写本章" started its own fetch and both dialogs' bindings
    /// ended up true at once. Delete joins the same gate — its dialog opens
    /// instantly, which would otherwise let it stack on top of an in-flight
    /// preview.
    @State private var preparingChapterAction = false
    /// Populated just before a confirmation dialog is shown. `nil` means the
    /// preview call failed, not "not yet attempted" — the dialog only appears
    /// after the fetch resolves either way.
    @State private var pendingImpact: RewriteImpactPreview?
    /// The chapter each dialog was raised for, re-checked on confirm so a
    /// selection change during the dialog's lifetime can never redirect a
    /// destructive action onto a different chapter.
    @State private var pendingChapterID: String?
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
                        onReopen: { startReopenFlow() },
                        onRewrite: { startRewriteFlow() },
                        onDelete: { startDeleteFlow() },
                        chapterActionInFlight: preparingChapterAction
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
        .sheet(isPresented: $showingSyncCenter) { V2MacSyncCenter() }
        .confirmationDialog(V2DeskReopenConfirmation.title, isPresented: $showReopenConfirmation, titleVisibility: .visible) {
            Button("保留正文并重新编辑", role: .destructive) { reopen() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(V2DeskReopenConfirmation.message(
                affected: pendingImpact?.affectedChapters ?? [],
                previewUnavailable: pendingImpact == nil
            ))
        }
        .confirmationDialog("仍然接受这一章？", isPresented: $showAcceptWarning, titleVisibility: .visible) {
            Button("接受这一章", role: .destructive) { accept(overrideChecker: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这一章会被记为完成；当前检查提出的问题将不再提醒你。")
        }
        .confirmationDialog(V2DeskRewriteConfirmation.title, isPresented: $showRewriteConfirmation, titleVisibility: .visible) {
            Button("重写", role: .destructive) { rewrite() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(V2DeskRewriteConfirmation.message(
                isAccepted: editor.currentChapter?.status == "finalized",
                affected: pendingImpact?.affectedChapters ?? [],
                previewUnavailable: pendingImpact == nil
            ))
        }
        .confirmationDialog(V2DeskDeleteConfirmation.title, isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteChapter() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(V2DeskDeleteConfirmation.message)
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
            connectionInterrupted: editor.pollingConnectionInterrupted,
            isLastChapterInBook: V2DeskChapterPosition.isLastChapter(editor.currentChapter?.id, in: workspace.chapters)
        ))
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
        guard sync.networkActionsAvailable, !creatingChapter, chapterLoadID == nil else { return }
        creatingChapter = true
        Task {
            defer { creatingChapter = false }
            if let chapter = await workspace.createChapter() {
                await navigate(to: chapter, allowsDuringCreation: true)
            }
        }
    }

    private func runPrimaryAction() {
        guard sync.networkActionsAvailable else { return }
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

    /// Fetches the read-only reopen preview before showing the confirmation
    /// dialog, mirroring `startRewriteFlow()` below. A failed preview must
    /// not block the dialog — `V2DeskReopenConfirmation.message` falls back to
    /// a conservative sentence when `pendingImpact` stays `nil`. Re-checks the
    /// chapter id after the await (same defensive shape as `rerunChecker()` in
    /// `LinoStores.swift`) so a rail selection made during the fetch cannot
    /// surface a confirmation naming the wrong chapter's impact.
    private func startReopenFlow() {
        guard sync.networkActionsAvailable, !preparingChapterAction, let chapterID = editor.currentChapter?.id else { return }
        preparingChapterAction = true
        Task {
            defer { preparingChapterAction = false }
            let impact = await editor.loadRewriteImpact()
            guard editor.currentChapter?.id == chapterID else { return }
            pendingImpact = impact
            pendingChapterID = chapterID
            showReopenConfirmation = true
        }
    }

    /// The reopen has already cascaded downstream by the time it returns, so
    /// the rail's staleness markers are refreshed — with `refreshChapters`,
    /// which leaves the author standing where they are.
    private func reopen() {
        guard let chapterID = pendingChapterID, editor.currentChapter?.id == chapterID else { return }
        Task {
            if let chapter = await editor.reopen() {
                workspace.upsert(chapter)
                if let bookID = session.currentBook?.id { await workspace.refreshChapters(bookId: bookID) }
            }
        }
    }

    /// Same preview-first shape as `startReopenFlow()`, including the
    /// post-await chapter-id re-check; the underlying `GET
    /// .../rewrite-preview` call is identical because the cascade is driven
    /// entirely by the reopen step `rewrite()` performs internally, not by
    /// whether a regeneration follows it.
    private func startRewriteFlow() {
        guard sync.networkActionsAvailable, !preparingChapterAction, let chapterID = editor.currentChapter?.id else { return }
        preparingChapterAction = true
        Task {
            defer { preparingChapterAction = false }
            let impact = await editor.loadRewriteImpact()
            guard editor.currentChapter?.id == chapterID else { return }
            pendingImpact = impact
            pendingChapterID = chapterID
            showRewriteConfirmation = true
        }
    }

    /// The chapter list is refreshed whenever the reopen landed, which
    /// includes the case where the write job then failed to start: the
    /// confirmation promised those downstream chapters would be marked, and
    /// that promise comes due even when no new prose is coming. Only
    /// `.notStarted` — where the server was never changed — skips it.
    private func rewrite() {
        guard let chapterID = pendingChapterID, editor.currentChapter?.id == chapterID else { return }
        Task {
            let outcome = await editor.rewrite()
            if let chapter = outcome.chapter { workspace.upsert(chapter) }
            guard outcome.requiresChapterListRefresh, let bookID = session.currentBook?.id else { return }
            await workspace.refreshChapters(bookId: bookID)
        }
    }

    /// Failure still reloads the chapter list: a 409 here means this client's
    /// local "is this the last chapter" view was stale (another client or
    /// session created a later chapter), and the reload corrects it so the
    /// delete command's availability reflects the server immediately. A
    /// rejected delete must not cost the author anything else, so it refreshes
    /// without disturbing navigation.
    private func startDeleteFlow() {
        guard sync.networkActionsAvailable, !preparingChapterAction, let chapterID = editor.currentChapter?.id else { return }
        pendingChapterID = chapterID
        showDeleteConfirmation = true
    }

    private func deleteChapter() {
        guard let deletedID = pendingChapterID,
              editor.currentChapter?.id == deletedID,
              let bookID = session.currentBook?.id else { return }
        Task {
            guard await editor.deleteCurrentChapter() else {
                await workspace.refreshChapters(bookId: bookID)
                return
            }
            workspace.removeChapter(id: deletedID)
            await workspace.refreshChapters(bookId: bookID)
            if let last = workspace.chapters.max(by: { $0.index < $1.index }) {
                await navigate(to: last)
            } else {
                selectedChapterID = nil
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
            V2MacSyncStatusButton(openCenter: { showingSyncCenter = true })
            V2MacDeskIconButton(symbol: "magnifyingglass", label: "搜索全部书籍") { sheet = .search }
            V2MacDeskIconButton(symbol: "archivebox", label: "备份或恢复项目") { sheet = .projectPackage }
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
    case newBook, world, people, inspiration, settings, export, search, projectPackage
    var id: String {
        switch self {
        case .newBook: "newBook"; case .world: "world"; case .people: "people"; case .inspiration: "inspiration"; case .settings: "settings"; case .export: "export"; case .search: "search"; case .projectPackage: "projectPackage"
        }
    }
}

// MARK: - Rail

private struct V2MacChapterRail: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var sync: ClientSyncStore
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
                        .disabled(!sync.networkActionsAvailable)
                        .help(sync.networkActionsAvailable ? "开始新一章" : "离线时不能新建章节")
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
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .allowsTightening(true)
                                .truncationMode(.tail)
                                .foregroundStyle(archiveRailState == .attention ? V2DeskPalette.color(.danger, scheme: colorScheme) : V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
