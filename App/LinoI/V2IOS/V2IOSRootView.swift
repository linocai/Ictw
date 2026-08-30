import SwiftUI

/// Integration root. The app entry may replace the legacy `RootView` with this
/// type without changing any Store construction or environment wiring.
struct V2IOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var notices: NoticeBus
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var showingSyncCenter = false

    var body: some View {
        NavigationStack(path: $workspace.chapterPath) {
            Group {
                if session.token.v2IOSTrimmed.isEmpty {
                    V2IOSConnectionView()
                } else if session.currentBook == nil {
                    V2IOSBookshelfView()
                } else {
                    V2IOSChapterRailView()
                }
            }
            // The book shelf and chapter rail own their root-level chrome.
            // Destinations explicitly restore the system navigation bar.
            .toolbar(.hidden, for: .navigationBar)
            .v2IOSNoticeOverlay()
            .navigationDestination(for: ChapterSummary.self) { summary in
                V2IOSChapterDestinationView(summary: summary)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            V2IOSSyncStatusBar(openCenter: { showingSyncCenter = true })
        }
        .v2IOSPage()
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                editor.handleScenePhaseActive()
                Task { await flushPendingAndRefresh() }
            default: editor.persistLocalDraftIfNeeded()
            }
        }
        .sheet(isPresented: $showingSyncCenter) {
            V2IOSSyncCenter()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
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

private struct V2IOSSyncStatusBar: View {
    @EnvironmentObject private var sync: ClientSyncStore
    let openCenter: () -> Void

    var body: some View {
        if let state {
            Button(action: openCenter) {
                HStack(spacing: 8) {
                    V2DeskSyncPill(state: state, compact: true)
                    if let failure = sync.persistenceFailure { Text(failure) }
                    else if !sync.isOnline { Text("已打开的资料仍可阅读和编辑") }
                    else if !sync.conflicts.isEmpty { Text("比较后决定采用哪个版本") }
                    else { Text("恢复网络后会安全提交") }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(V2DeskType.control(10.5))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.secondary.opacity(0.06))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同步状态，\(state.title)")
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

private struct V2IOSSyncCenter: View {
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

    var body: some View {
        NavigationStack {
            List {
                Section("同步状态") {
                    V2DeskSyncPill(state: currentState)
                    if let failure = sync.persistenceFailure {
                        Text(failure)
                            .font(V2DeskType.control(12, weight: .medium))
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !sync.isOnline { V2DeskOfflineExplanation() }
                    if sync.pendingCount > 0, !sync.hasPersistentSyncFailure {
                        Text("\(sync.pendingCount) 项本机修改会在恢复连接后按原始编辑基线安全提交。")
                            .font(V2DeskType.control(12)).foregroundStyle(Color.secondary)
                    }
                    if sync.isOnline, sync.pendingCount > 0 {
                        Button("立即尝试同步") { Task { await flushPendingAndRefresh() } }
                            .disabled(sync.isFlushing)
                    }
                }
                if !sync.conflicts.isEmpty {
                    Section("需要处理的冲突") {
                        ForEach(sync.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 10) {
                                V2DeskConflictDecisionCard(
                                    title: "\(conflict.resourceLabel)已在另一设备更新",
                                    detail: "本机基线版本 \(conflict.submittedRevision)，服务器当前版本 \(conflict.currentRevision)。请先对比三份内容，再明确决定。",
                                    useServer: { serverDecision = conflict },
                                    keepLocal: { localDecision = conflict },
                                    requiresSecretReentry: conflict.requiresSecretReentry
                                )
                                if sync.automaticMergeCandidate(for: conflict) != nil {
                                    Button("合并不重叠的修改") {
                                        guard sync.queueAutomaticMerge(for: conflict) else {
                                            notices.publish("本机未能安全保存合并结果，请保留当前页面后重试。", critical: true)
                                            return
                                        }
                                        refreshAfterSubmit(conflict)
                                    }
                                    .font(V2DeskType.control(12, weight: .medium))
                                    .accessibilityHint("本机与服务器修改的是不同字段，可安全合并后再提交")
                                }
                                V2IOSConflictDiff(conflict: conflict)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .v2IOSNoticeOverlay()
            .navigationTitle("同步与冲突")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction) } }
        }
        .v2IOSPage()
        .confirmationDialog("采用服务器版本？", isPresented: Binding(get: { serverDecision != nil }, set: { if !$0 { serverDecision = nil } }), titleVisibility: .visible) {
            Button("采用服务器版本", role: .destructive) {
                if let conflict = serverDecision {
                    sync.keepServer(conflict)
                    refreshFromServer(conflict)
                }
                serverDecision = nil
            }
            Button("取消", role: .cancel) { serverDecision = nil }
        } message: { Text("本机未同步的这项修改会被移除，服务器版本会成为新的基线。") }
        .confirmationDialog("保留本机版本并重新提交？", isPresented: Binding(get: { localDecision != nil }, set: { if !$0 { localDecision = nil } }), titleVisibility: .visible) {
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

    private var currentState: V2DeskSyncPill.State {
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

private struct V2IOSConflictDiff: View {
    let conflict: ContentConflict
    @State private var selection = "本机"

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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
            .frame(maxHeight: 180)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
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
              let string = String(data: formatted, encoding: .utf8) else {
            return "无法读取这份比较内容。"
        }
        return string
    }
}

struct V2IOSConnectionView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var notices: NoticeBus
    @State private var baseURL = ""
    @State private var token = ""
    @State private var connecting = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            VStack(spacing: 7) {
                Text("连接 ICTW").font(V2DeskType.prose(27, weight: .semibold))
                Text("连接你的写作空间").font(V2DeskType.control(12.5)).foregroundStyle(Color.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                connectionField(label: "后端地址") {
                    TextField("https://…", text: $baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                connectionField(label: "访问密钥") {
                    SecureField("访问密钥", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            V2IOSPrimaryButton(title: connecting ? "正在连接" : "保存并连接", disabled: connecting || baseURL.v2IOSTrimmed.isEmpty || token.v2IOSTrimmed.isEmpty) { connect() }
            Spacer()
        }
        .padding(.horizontal, 28)
        .onAppear { baseURL = session.baseURL }
    }

    private func connectionField<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            V2IOSSectionLabel(title: label)
            content().font(V2DeskType.control(14)).padding(13).v2IOSPaper()
        }
    }

    private func connect() {
        connecting = true
        session.baseURL = baseURL.v2IOSTrimmed
        session.token = token.v2IOSTrimmed
        session.saveConnection()
        Task {
            await bookshelf.load()
            connecting = false
            if bookshelf.books.isEmpty && !bookshelf.isLoading { notices.publish("已连接，可以新建第一本书。") }
        }
    }
}

extension View {
    /// Surfaces NoticeBus messages without covering this view's bottom chrome.
    /// Every presentation context that can trigger a save needs one: a single
    /// overlay on the app root is invisible inside pushed destinations and
    /// sheets, which is exactly where saving happens.
    func v2IOSNoticeOverlay() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { V2IOSNoticeToast() }
    }
}

struct V2IOSNoticeToast: View {
    @EnvironmentObject private var notices: NoticeBus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let notice = notices.current {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: iconName(for: notice.tone))
                    .foregroundStyle(iconColor(for: notice.tone))
                    .accessibilityHidden(true)
                Text(notice.message)
                    .font(V2DeskType.control(12))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    notices.dismiss(id: notice.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityLabel("关闭提示")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel(for: notice))
            // Padding lives inside the branch so an absent notice occupies no
            // height and never shifts the host's content.
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: notice.id)
        }
    }

    private func iconName(for tone: NoticeTone) -> String {
        switch tone {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    private func iconColor(for tone: NoticeTone) -> Color {
        switch tone {
        case .info: Color.blue.opacity(0.9)
        case .success: Color.green.opacity(0.9)
        case .warning: Color.orange.opacity(0.95)
        case .error: Color.red.opacity(0.95)
        }
    }

    private func accessibilityLabel(for notice: NoticeBus.Notice) -> String {
        if notice.isCritical { return "重要错误" }
        switch notice.tone {
        case .info: return "提示"
        case .success: return "成功提示"
        case .warning: return "注意"
        case .error: return "错误"
        }
    }
}
