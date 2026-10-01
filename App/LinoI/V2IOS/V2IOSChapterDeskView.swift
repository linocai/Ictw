import SwiftUI

/// A chapter summary is only a navigation hint. The destination always loads
/// the complete server chapter before choosing the author-facing space, so an
/// out-of-date rail row can never send a reopened/finalized chapter to the
/// wrong surface.
struct V2IOSChapterDestinationView: View {
    let summary: ChapterSummary

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @StateObject private var actions = V2IOSChapterActionCoordinator()
    @State private var resolvedChapter: Chapter?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let resolvedChapter {
                if resolvedChapter.status == "finalized" {
                    V2IOSChapterReaderView(summary: summary, resolvedChapter: resolvedChapter, actions: actions)
                } else {
                    V2IOSChapterDeskView(summary: summary, actions: actions)
                }
            } else if loadFailed {
                VStack(spacing: 12) {
                    Text("这一章没有读到")
                        .font(V2DeskType.prose(19, weight: .semibold))
                    Text("请返回章节轨后重试")
                        .font(V2DeskType.control(12.5))
                        .foregroundStyle(Color.secondary)
                    V2IOSSecondaryButton(title: "返回章节轨", action: dismiss.callAsFunction)
                        .padding(.top, 4)
                }
                .padding(24)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("读取章节")
                        .font(V2DeskType.control(12.5))
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .task(id: summary.id) {
            resolvedChapter = nil
            loadFailed = false
            inspiration.clearIfChapterChanged(to: summary.id)
            await editor.load(summary)
            guard let chapter = editor.currentChapter, chapter.id == summary.id else {
                loadFailed = true
                return
            }
            workspace.upsert(chapter)
            resolvedChapter = chapter
        }
        .onChange(of: editor.currentChapter) { _, chapter in
            guard let chapter, chapter.id == summary.id else { return }
            workspace.upsert(chapter)
            resolvedChapter = chapter
        }
        .onChange(of: workspace.chapterNavigationID) { _, _ in actions.invalidate() }
        .onDisappear { actions.invalidate() }
        // Keep the notice inside the destination so its top safe-area inset
        // begins below the system navigation bar instead of covering it.
        .v2IOSNoticeOverlay()
        .navigationTitle(summary.title.v2IOSTrimmed.isEmpty ? "第 \(summary.index) 章" : summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

/// Reading is intentionally a separate surface, rather than a read-only
/// variation of the writing desk. Its only primary navigation is the real
/// ordered next chapter supplied by the shared policy.
struct V2IOSChapterReaderView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var isMoving = false
    @State private var showingSettings = false
    let summary: ChapterSummary
    let resolvedChapter: Chapter
    @ObservedObject var actions: V2IOSChapterActionCoordinator

    var body: some View {
        VStack(spacing: 0) {
            if let banner = snapshot.taskBanner {
                V2IOSTaskBanner(
                    banner: banner,
                    // Reader has no task primary dock. Keep the recovery
                    // action visible in its banner instead of suppressing it
                    // merely because the shared snapshot calls it primary.
                    primaryAction: .none,
                    perform: performReaderAction,
                    networkActionsAvailable: sync.networkActionsAvailable && !actions.busy && !editor.isSaving
                )
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("第 \(chapter.index) 章")
                        .font(V2DeskType.control(12, weight: .medium))
                        .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                    Text(displayTitle(chapter))
                        .font(V2DeskType.prose(28, weight: .semibold))
                    Text(chapter.draftText)
                        .font(V2DeskType.prose())
                        .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                        .lineSpacing(V2DeskType.proseLineSpacing)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 30)
                .padding(.bottom, 30)
            }
            readerDock
        }
        .v2IOSPage()
        .navigationTitle(displayTitle(chapter))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .v2IOSChapterActions(
            chapterID: chapter.id,
            bookID: summary.bookId,
            commands: commands,
            isAccepted: chapter.status == "finalized",
            coordinator: actions
        )
        .sheet(isPresented: $showingSettings) {
            V2IOSSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
    }

    private var chapter: Chapter {
        // The destination only creates this view after a matching successful
        // load. The fallback avoids a transient crash while SwiftUI replaces a
        // route after a reopen.
        editor.currentChapter?.id == summary.id ? editor.currentChapter! : resolvedChapter
    }

    private var commands: V2DeskChapterCommands {
        V2DeskPresentation.make(
            V2DeskEditorSource(
                chapter: chapter,
                writingPhase: editor.writingPhase,
                checkerResult: editor.checkerResult,
                checkerAppliesToVisibleDraft: editor.checkerAppliesToVisibleDraft,
                checkerRefreshing: editor.checkerRefreshing,
                staleCheckedSnapshot: editor.staleCheckedSnapshot,
                saveState: editor.saveState,
                connectionInterrupted: editor.pollingConnectionInterrupted,
                taskMonitoringMessage: editor.taskMonitoringMessage,
                preflightAcceptanceMessage: editor.preflightAcceptanceMessage,
                canRetryGeneratedCandidateChecker: editor.candidateCheckerRetrySourceJobID != nil,
                generatedCandidateCheckerUnavailable: editor.failedCandidateCheckerResult?.status == "unavailable",
                checkerTarget: editor.checkerTarget,
                isLastChapterInBook: V2DeskChapterPosition.isLastChapter(chapter.id, in: workspace.chapters)
            )
        ).commands
    }

    private var snapshot: V2DeskSnapshot {
        V2DeskPresentation.make(
            V2DeskEditorSource(
                chapter: chapter,
                writingPhase: editor.writingPhase,
                checkerResult: editor.checkerResult,
                checkerAppliesToVisibleDraft: editor.checkerAppliesToVisibleDraft,
                checkerRefreshing: editor.checkerRefreshing,
                staleCheckedSnapshot: editor.staleCheckedSnapshot,
                saveState: editor.saveState,
                connectionInterrupted: editor.pollingConnectionInterrupted,
                taskMonitoringMessage: editor.taskMonitoringMessage,
                preflightAcceptanceMessage: editor.preflightAcceptanceMessage,
                canRetryGeneratedCandidateChecker: editor.candidateCheckerRetrySourceJobID != nil,
                generatedCandidateCheckerUnavailable: editor.failedCandidateCheckerResult?.status == "unavailable",
                checkerTarget: editor.checkerTarget,
                isLastChapterInBook: V2DeskChapterPosition.isLastChapter(chapter.id, in: workspace.chapters)
            )
        )
    }

    private func performReaderAction(_ action: V2DeskPrimaryAction) {
        switch action {
        case .rerunChecker:
            actions.run(editor: editor) { _ = await editor.rerunChecker() }
        case .retryGeneratedCandidateChecker:
            actions.run(editor: editor) { if let chapter = await editor.retryGeneratedCandidateChecker() { workspace.upsert(chapter) } }
        case .retryArchive:
            actions.run(editor: editor) { if let chapter = await editor.retryArchive() { workspace.upsert(chapter) } }
        case .refreshTaskStatus:
            actions.run(editor: editor) { if let chapter = await editor.refreshTaskStatus() { workspace.upsert(chapter) } }
        case .openSettings:
            showingSettings = true
        default:
            break
        }
    }

    @ViewBuilder private var readerDock: some View {
        let previous = V2DeskReadingOrder.previous(after: chapter.id, in: workspace.chapters)
        let next = V2DeskReadingOrder.next(after: chapter.id, in: workspace.chapters)
        VStack(spacing: 8) {
            if commands.canRewrite || actions.preparing {
                V2IOSSecondaryButton(title: actions.preparing ? "正在读取重写影响…" : "重写") {
                    actions.startPreview(chapterID: chapter.id, bookID: summary.bookId,
                        editor: editor, session: session, workspace: workspace)
                }
                .disabled(actions.busy || !actions.canMutate(editor: editor) || !sync.networkActionsAvailable)
            }
            if let next {
                HStack(spacing: 10) {
                    if let previous {
                        Button("上一章") { replaceRoute(with: previous) }
                            .font(V2DeskType.control(12.5, weight: .medium))
                            .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                            .frame(width: 76, height: 48)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)))
                            .buttonStyle(.plain)
                            .disabled(isMoving)
                    }
                    switch next {
                    case .read(let nextChapter):
                        V2IOSPrimaryButton(title: displayTitle(nextChapter), disabled: isMoving) {
                            replaceRoute(with: nextChapter)
                        }
                    case .write(let nextChapter):
                        V2IOSPrimaryButton(title: "继续写《\(displayTitle(nextChapter))》", disabled: isMoving) {
                            replaceRoute(with: nextChapter)
                        }
                    case .startNewChapter:
                        V2IOSPrimaryButton(title: "开始新一章", disabled: isMoving) {
                            createNewChapter()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(V2DeskPalette.color(.rail, scheme: colorScheme))
        .overlay(alignment: .top) { Divider() }
    }

    private func replaceRoute(with chapter: ChapterSummary) {
        guard !isMoving else { return }
        isMoving = true
        workspace.replaceCurrentDestination(with: chapter)
    }

    private func createNewChapter() {
        guard !isMoving else { return }
        isMoving = true
        Task {
            await workspace.createChapter(replacingCurrentDestination: true)
            isMoving = false
        }
    }

    private func displayTitle(_ chapter: Chapter) -> String {
        chapter.title.v2IOSTrimmed.isEmpty ? "第 \(chapter.index) 章" : chapter.title
    }

    private func displayTitle(_ chapter: ChapterSummary) -> String {
        chapter.title.v2IOSTrimmed.isEmpty ? "第 \(chapter.index) 章" : chapter.title
    }
}

struct V2IOSChapterDeskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var face: V2DeskChapterFace = .intent
    @FocusState private var focusedField: V2IOSChapterField?
    @State private var showingSaveDetails = false
    @State private var showingInspiration = false
    @State private var inspirationDetent: PresentationDetent = V2IOSInspirationPresentation.compactDetent
    @State private var showingSettings = false
    @State private var showingAcceptWarning = false

    let summary: ChapterSummary
    @ObservedObject var actions: V2IOSChapterActionCoordinator

    var body: some View {
        let snapshot = V2DeskPresentation.make(source)
        VStack(spacing: 0) {
            if !sync.networkActionsAvailable {
                V2DeskOfflineExplanation()
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(V2DeskPalette.color(.taskWarning, scheme: colorScheme))
            }
            if let banner = snapshot.taskBanner {
                V2IOSTaskBanner(banner: banner, primaryAction: snapshot.primaryAction, perform: perform, networkActionsAvailable: sync.networkActionsAvailable && !actions.busy && !editor.isSaving)
            }
            if editor.isLoading && editor.currentChapter?.id != summary.id {
                Spacer(); ProgressView("读取章节"); Spacer()
            } else if editor.currentChapter?.id == summary.id {
                pageNavigation
                TabView(selection: $face) {
                    V2IOSIntentFace(focusedField: $focusedField).tag(V2DeskChapterFace.intent)
                    V2IOSManuscriptFace(snapshot: snapshot, focusedField: $focusedField).tag(V2DeskChapterFace.manuscript)
                    V2IOSEvidenceFace(snapshot: snapshot, actions: actions).tag(V2DeskChapterFace.evidence)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                saveStatus
                V2IOSActionDock(
                    primary: snapshot.primaryAction,
                    mergesRewrite: V2IOSChapterInteractionPolicy.mergesPrimaryIntoRewrite(snapshot.primaryAction, hasDraft: editor.currentChapter?.draftText.v2IOSTrimmed.isEmpty == false),
                    canRewrite: snapshot.commands.canRewrite && actions.canMutate(editor: editor),
                    rewritePreparing: actions.preparing,
                    rewriteAction: startRewrite,
                    busy: actions.busy || editor.isSaving,
                    primaryAction: { tapPrimary(snapshot.primaryAction) },
                    inspirationAction: {
                        focusedField = nil
                        inspirationDetent = V2IOSInspirationPresentation.compactDetent
                        showingInspiration = true
                    },
                    inspirationDisabled: snapshot.chapterState == .accepted,
                    networkActionsAvailable: sync.networkActionsAvailable
                )
            } else {
                VStack(spacing: 12) {
                    Text("这一章没有读到")
                        .font(V2DeskType.prose(19, weight: .semibold))
                    V2IOSSecondaryButton(title: "返回章节", action: dismiss.callAsFunction)
                }.padding(24)
                Spacer()
            }
        }
        .v2IOSPage()
        .navigationTitle(snapshot.title.v2IOSTrimmed.isEmpty ? "第 \(summary.index) 章" : snapshot.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onChange(of: face) { _, _ in focusedField = nil }
        .sheet(isPresented: $showingSaveDetails) {
            NoticeDetailSheet(title: editor.saveState.label, message: editor.saveState.failureMessage ?? "")
        }
        .v2IOSChapterActions(
            chapterID: summary.id,
            bookID: summary.bookId,
            commands: snapshot.commands,
            isAccepted: snapshot.chapterState == .accepted,
            coordinator: actions
        )
        .task(id: summary.id) {
            inspiration.clearIfChapterChanged(to: summary.id)
            if editor.currentChapter?.id != summary.id {
                await editor.load(summary)
            }
            if let book = session.currentBook { await characters.load(bookId: book.id) }
        }
        .onChange(of: editor.currentChapter) { _, chapter in
            if let chapter { workspace.upsert(chapter) }
        }
        .onDisappear { editor.persistLocalDraftIfNeeded(); focusedField = nil }
        .sheet(isPresented: $showingInspiration) {
            V2IOSInspirationSheet(selectedDetent: $inspirationDetent)
                .environmentObject(actions)
                .presentationDetents(
                    [V2IOSInspirationPresentation.compactDetent, .large],
                    selection: $inspirationDetent
                )
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
        .sheet(isPresented: $showingSettings) {
            V2IOSSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
        .confirmationDialog("这一章会被记为完成", isPresented: $showingAcceptWarning, titleVisibility: .visible) {
            Button("仍然接受", role: .destructive) {
                guard editor.currentChapter?.id == summary.id else { return }
                actions.run(editor: editor) {
                    let shortConfirmation = editor.preflightAcceptanceMessage != nil
                    if let chapter = await editor.accept(
                        overrideChecker: !shortConfirmation,
                        allowShortDraft: shortConfirmation
                    ) { workspace.upsert(chapter) }
                }
            }
            Button("返回", role: .cancel) {}
        } message: {
            Text(editor.preflightAcceptanceMessage ?? "检查发现的问题不会再提醒你；正文和本章意图会保留，随后会单独整理记忆。")
        }
        .confirmationDialog(
            "历史资料有待处理项",
            isPresented: Binding(
                get: { editor.pendingProductionContext != nil },
                set: { if !$0 { editor.dismissProductionContextConfirmation() } }
            ),
            titleVisibility: .visible
        ) {
            if let recovery = editor.pendingProductionContext?.readiness.recommendedRecovery,
               let target = workspace.chapters.first(where: { $0.id == recovery.chapterId }) {
                Button("查看第 \(recovery.index) 章") {
                    editor.dismissProductionContextConfirmation()
                    workspace.replaceCurrentDestination(with: target)
                    dismiss()
                }
            }
            Button("知情继续", role: .destructive) {
                guard let pending = editor.pendingProductionContext else { return }
                actions.run(editor: editor) { if let chapter = await editor.confirmProductionContextAndContinue(pending) { workspace.upsert(chapter) } }
            }
            Button("返回", role: .cancel) { editor.dismissProductionContextConfirmation() }
        } message: {
            Text(productionContextMessage)
        }
    }

    private var source: V2DeskEditorSource {
        V2DeskEditorSource(
            chapter: editor.currentChapter,
            writingPhase: editor.writingPhase,
            checkerResult: editor.checkerResult,
            checkerAppliesToVisibleDraft: editor.checkerAppliesToVisibleDraft,
            checkerRefreshing: editor.checkerRefreshing,
            staleCheckedSnapshot: editor.staleCheckedSnapshot,
            saveState: editor.saveState,
            connectionInterrupted: editor.pollingConnectionInterrupted,
            taskMonitoringMessage: editor.taskMonitoringMessage,
            preflightAcceptanceMessage: editor.preflightAcceptanceMessage,
            canRetryGeneratedCandidateChecker: editor.candidateCheckerRetrySourceJobID != nil,
                generatedCandidateCheckerUnavailable: editor.failedCandidateCheckerResult?.status == "unavailable",
            checkerTarget: editor.checkerTarget,
            isLastChapterInBook: V2DeskChapterPosition.isLastChapter(editor.currentChapter?.id, in: workspace.chapters)
        )
    }

    private var productionContextMessage: String {
        guard let pending = editor.pendingProductionContext else { return "" }
        let chapters = pending.readiness.limitations
            .sorted { $0.index < $1.index }
            .map { "第 \($0.index) 章：\($0.reason)" }
            .joined(separator: "\n")
        let action = pending.action.title
        return "\(chapters)\n\n这些资料尚不完整。你可以先恢复建议章节，或仅本次知情后继续\(action)。"
    }

    private var pageNavigation: some View {
        HStack(spacing: 0) {
            ForEach(V2DeskChapterFace.allCases, id: \.self) { item in
                Button {
                    focusedField = nil
                    face = item
                } label: {
                    Text(item == .evidence ? "检查结果" : item.title)
                        .font(V2DeskType.control(13, weight: item == face ? .semibold : .regular))
                        .foregroundStyle(V2DeskPalette.color(item == face ? .ink : .metadataInk, scheme: colorScheme))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            if item == face { Rectangle().fill(V2DeskPalette.color(.ink, scheme: colorScheme)).frame(height: 2) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == face ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 20)
    }

    private var saveStatus: some View {
        HStack(spacing: 8) {
            if editor.isSaving { ProgressView().controlSize(.small) }
            Text(editor.saveState.label)
                .font(V2DeskType.control(11.5))
                .foregroundStyle(V2DeskPalette.color(editor.saveState.needsRetry ? .danger : .metadataInk, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if editor.saveState.failureMessage != nil {
                Button("详情") { showingSaveDetails = true }
                    .font(V2DeskType.control(12))
                    .frame(minWidth: 44, minHeight: 44)
            }
            Spacer(minLength: 0)
            if let title = V2IOSChapterInteractionPolicy.saveTitle(state: editor.saveState, online: sync.networkActionsAvailable) {
                Button(title) {
                    focusedField = nil
                    if sync.networkActionsAvailable {
                        actions.run(editor: editor) { if let chapter = await editor.save() { workspace.upsert(chapter) } }
                    } else { editor.persistLocalDraftIfNeeded() }
                }
                .font(V2DeskType.control(12.5, weight: .medium))
                .frame(minWidth: 44, minHeight: 44)
                .disabled(sync.networkActionsAvailable
                    ? actions.busy || inspiration.isLoading || !actions.canMutate(editor: editor)
                    : !ChapterEditingPolicy.canEdit(editor.currentChapter))
            }
            if focusedField != nil {
                Button("完成") { focusedField = nil }
                    .font(V2DeskType.control(12.5, weight: .medium))
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)
                    .accessibilityHint("收起键盘，保留输入")
            }
        }
        .padding(.horizontal, 20)
        .background(V2DeskPalette.color(.rail, scheme: colorScheme))
    }

    private func startRewrite() {
        focusedField = nil
        actions.startPreview(chapterID: summary.id, bookID: summary.bookId,
            editor: editor, session: session, workspace: workspace)
    }

    private func tapPrimary(_ action: V2DeskPrimaryAction) {
        guard editor.currentChapter?.id == summary.id, !actions.busy, !editor.isSaving,
              !action.requiresNetwork || sync.networkActionsAvailable else { return }
        focusedField = nil
        if V2IOSChapterInteractionPolicy.mergesPrimaryIntoRewrite(action, hasDraft: editor.currentChapter?.draftText.v2IOSTrimmed.isEmpty == false) {
            startRewrite(); return
        }
        switch action {
        case .generate, .retryGeneration: actions.run(editor: editor) { if let chapter = await editor.generate() { workspace.upsert(chapter) } }
        case .cancelGeneration: actions.run(editor: editor) { if let chapter = await editor.cancelWriting() { workspace.upsert(chapter) } }
        case .rerunChecker: actions.run(editor: editor) { _ = await editor.rerunChecker() }
        case .retryGeneratedCandidateChecker: actions.run(editor: editor) { if let chapter = await editor.retryGeneratedCandidateChecker() { workspace.upsert(chapter) } }
        case .accept: actions.run(editor: editor) { if let chapter = await editor.accept() { workspace.upsert(chapter) } }
        case .acceptWithWarning: showingAcceptWarning = true
        case .startNewChapter: actions.run(editor: editor) { await workspace.createChapter() }
        case .retryArchive: actions.run(editor: editor) { if let chapter = await editor.retryArchive() { workspace.upsert(chapter) } }
        case .refreshTaskStatus: actions.run(editor: editor) { if let chapter = await editor.refreshTaskStatus() { workspace.upsert(chapter) } }
        case .openSettings: showingSettings = true
        case .none: break
        }
    }

    private func perform(_ action: V2DeskPrimaryAction) { tapPrimary(action) }
}

/// A single latch and receipt serve the menu, writing dock and reading dock.
/// A preview is author intent, so it must never survive a different visit.
@MainActor
final class V2IOSChapterActionCoordinator: ObservableObject {
    @Published var showingRewrite = false
    @Published var showingReopen = false
    @Published var showingDelete = false
    @Published private(set) var preparing = false
    @Published private(set) var running = false
    @Published private(set) var pendingImpact: RewriteImpactPreview?
    private var receipt: ChapterInteractionContext?
    private var requestID: UUID?
    private var previewWasAccepted = false

    var busy: Bool { preparing || running || showingRewrite || showingReopen || showingDelete }

    func invalidate() {
        requestID = nil
        receipt = nil
        preparing = false
        running = false
        showingRewrite = false
        showingReopen = false
        showingDelete = false
        pendingImpact = nil
    }

    func owns(_ context: ChapterInteractionContext, editor: ChapterEditorStore,
              session: AppSession, workspace: WorkspaceStore) -> Bool {
        context.owns(bookID: session.currentBook?.id, bookContextID: session.bookContextID,
                     chapterID: editor.currentChapter?.id, navigationID: workspace.chapterNavigationID,
                     editorContextID: editor.editingSessionID)
            && workspace.chapterPath.last?.id == context.chapterID
            && editor.currentChapter?.bookId == context.bookID
    }

    func context(chapterID: String, bookID: String, editor: ChapterEditorStore,
                 session: AppSession, workspace: WorkspaceStore) -> ChapterInteractionContext? {
        let context = ChapterInteractionContext(bookID: bookID, bookContextID: session.bookContextID,
            chapterID: chapterID, navigationID: workspace.chapterNavigationID,
            editorContextID: editor.editingSessionID)
        return owns(context, editor: editor, session: session, workspace: workspace) ? context : nil
    }

    func canMutate(editor: ChapterEditorStore) -> Bool {
        !V2IOSChapterInteractionPolicy.blocksChapterMutation(
            phase: editor.writingPhase, saving: editor.isSaving, checking: editor.checkerRefreshing)
    }

    func startPreview(reopen: Bool = false, chapterID: String, bookID: String,
                      editor: ChapterEditorStore, session: AppSession, workspace: WorkspaceStore) {
        guard !busy, editor.sync.networkActionsAvailable, canMutate(editor: editor),
              editor.currentChapter?.id == chapterID,
              let context = context(chapterID: chapterID, bookID: bookID,
                                    editor: editor, session: session, workspace: workspace),
              (reopen ? editor.currentChapter?.status == "finalized"
                : editor.currentChapter?.draftText.v2IOSTrimmed.isEmpty == false) else { return }
        let id = UUID()
        requestID = id
        receipt = context
        previewWasAccepted = editor.currentChapter?.status == "finalized"
        let wasAccepted = previewWasAccepted
        preparing = true
        Task {
            guard requestID == id else { return }
            guard owns(context, editor: editor, session: session, workspace: workspace),
                  canMutate(editor: editor),
                  (editor.currentChapter?.status == "finalized") == wasAccepted else { invalidate(); return }
            let impact = await editor.loadRewriteImpact()
            guard requestID == id else { return }
            preparing = false
            guard owns(context, editor: editor, session: session, workspace: workspace),
                  canMutate(editor: editor),
                  (editor.currentChapter?.status == "finalized") == wasAccepted else { invalidate(); return }
            pendingImpact = impact
            if reopen { showingReopen = true } else { showingRewrite = true }
        }
    }

    func confirm(reopen: Bool, editor: ChapterEditorStore, session: AppSession, workspace: WorkspaceStore) {
        guard !running, !preparing else { return }
        guard editor.sync.networkActionsAvailable, let context = receipt, canMutate(editor: editor),
              (editor.currentChapter?.status == "finalized") == previewWasAccepted,
              owns(context, editor: editor, session: session, workspace: workspace) else { invalidate(); return }
        showingRewrite = false
        showingReopen = false
        running = true
        let id = UUID()
        requestID = id
        Task {
            defer { if requestID == id { invalidate() } }
            guard requestID == id, owns(context, editor: editor, session: session, workspace: workspace),
                  canMutate(editor: editor),
                  (editor.currentChapter?.status == "finalized") == previewWasAccepted else { return }
            let refresh: Bool
            if reopen {
                let chapter = await editor.reopen()
                if let chapter { workspace.upsert(chapter) }
                refresh = chapter != nil
            } else {
                let outcome = await editor.rewrite {
                    requestID == id && owns(context, editor: editor, session: session, workspace: workspace)
                }
                if let chapter = outcome.chapter { workspace.upsert(chapter) }
                refresh = outcome.requiresChapterListRefresh
            }
            guard refresh, session.currentBook?.id == context.bookID,
                  session.bookContextID == context.bookContextID else { return }
            await workspace.refreshChapters(bookId: context.bookID)
        }
    }

    /// Lock synchronously before creating a Task, including explicit save.
    func run(editor: ChapterEditorStore, operation: @escaping @MainActor () async -> Void) {
        guard !busy, !editor.isSaving, editor.sync.networkActionsAvailable else { return }
        let id = UUID()
        requestID = id
        running = true
        let editingSessionID = editor.editingSessionID
        let chapterID = editor.currentChapter?.id
        Task {
            defer { if requestID == id { running = false; requestID = nil } }
            guard requestID == id, editor.editingSessionID == editingSessionID,
                  editor.currentChapter?.id == chapterID else { return }
            await operation()
        }
    }
}

extension View {
    /// Attaches the whole chapter-action surface — trigger, menu items,
    /// export sheet and all three confirmation dialogs — to a chapter screen.
    func v2IOSChapterActions(
        chapterID: String,
        bookID: String,
        commands: V2DeskChapterCommands,
        isAccepted: Bool,
        coordinator: V2IOSChapterActionCoordinator
    ) -> some View {
        modifier(V2IOSChapterActions(
            chapterID: chapterID,
            bookID: bookID,
            commands: commands,
            isAccepted: isAccepted,
            coordinator: coordinator
        ))
    }
}

/// Shared by the reader and the desk so the two surfaces can never grow
/// divergent chapter actions. The menu label carries visible text alongside
/// the icon: a bare `ellipsis.circle` was the direct reason "重写本章" could
/// not be found. The dialogs live here too rather than in each host — keeping
/// them per-host is what let the two surfaces drift apart in the first place,
/// and it is also what made the shared in-flight gate impossible to enforce.
private struct V2IOSChapterActions: ViewModifier {
    let chapterID: String
    let bookID: String
    let commands: V2DeskChapterCommands
    let isAccepted: Bool
    @ObservedObject var coordinator: V2IOSChapterActionCoordinator

    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var showingExport = false
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
            .sheet(isPresented: $showingExport) {
                V2IOSExportSheet(currentChapterID: chapterID)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
            }
            .confirmationDialog(
                V2DeskReopenConfirmation.title,
                isPresented: $coordinator.showingReopen,
                titleVisibility: .visible
            ) {
                Button("重新编辑", role: .destructive) { confirmReopen() }
                Button("取消", role: .cancel) { coordinator.invalidate() }
            } message: {
                Text(V2DeskReopenConfirmation.message(
                    affected: coordinator.pendingImpact?.affectedChapters ?? [],
                    previewUnavailable: coordinator.pendingImpact == nil
                ))
            }
            .confirmationDialog(
                V2DeskRewriteConfirmation.title,
                isPresented: $coordinator.showingRewrite,
                titleVisibility: .visible
            ) {
                Button("重写", role: .destructive) { confirmRewrite() }
                Button("取消", role: .cancel) { coordinator.invalidate() }
            } message: {
                Text(V2DeskRewriteConfirmation.message(
                    isAccepted: isAccepted,
                    affected: coordinator.pendingImpact?.affectedChapters ?? [],
                    previewUnavailable: coordinator.pendingImpact == nil
                ))
            }
            .confirmationDialog(
                V2DeskDeleteConfirmation.title,
                isPresented: $coordinator.showingDelete,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { confirmDelete() }
                Button("取消", role: .cancel) { coordinator.invalidate() }
            } message: {
                Text(V2DeskDeleteConfirmation.message)
            }
    }

    /// Menu and visible dock enter the same preview and confirmation flow.
    private var menu: some View {
        Menu {
            if commands.canRewrite {
                Button(coordinator.preparing ? "重写本章（正在读取影响范围）" : "重写本章") { startRewriteFlow() }
                    .disabled(coordinator.busy || !coordinator.canMutate(editor: editor))
            }
            if isAccepted {
                Button(
                    coordinator.preparing ? "重新编辑这一章（正在读取影响范围）" : "重新编辑这一章",
                    role: .destructive
                ) { startReopenFlow() }
                    .disabled(coordinator.busy || !coordinator.canMutate(editor: editor))
            }
            Button("导出这一章") { showingExport = true }
            if commands.canDelete {
                Divider()
                Button("删除这一章", role: .destructive) { coordinator.showingDelete = true }
                    .disabled(coordinator.busy || !coordinator.canMutate(editor: editor))
            }
        } label: {
            HStack(spacing: 4) {
                Text("更多")
                Image(systemName: "ellipsis.circle")
            }
        }
        .disabled(!sync.networkActionsAvailable || coordinator.running || editor.isSaving)
        .accessibilityHint(sync.networkActionsAvailable ? "" : "离线时不可用；已打开内容仍可阅读和编辑")
        .accessibilityLabel("更多章节操作")
    }

    private func startRewriteFlow() {
        coordinator.startPreview(chapterID: chapterID, bookID: bookID,
            editor: editor, session: session, workspace: workspace)
    }

    private func startReopenFlow() {
        coordinator.startPreview(reopen: true, chapterID: chapterID, bookID: bookID,
            editor: editor, session: session, workspace: workspace)
    }

    private func confirmRewrite() {
        coordinator.confirm(reopen: false, editor: editor, session: session, workspace: workspace)
    }

    private func confirmReopen() {
        coordinator.confirm(reopen: true, editor: editor, session: session, workspace: workspace)
    }

    /// Refreshing a deleted/rejected row never owns navigation. Returning to
    /// the rail additionally requires the original path and the Store's
    /// cleared editor; a late DELETE must leave a newer chapter in place.
    private func confirmDelete() {
        let receipt = V2ChapterDeletionNavigation(
            bookID: bookID, bookContextID: session.bookContextID,
            chapterID: chapterID, navigationID: workspace.chapterNavigationID
        )
        guard receipt.canBeginDeletion(
            currentBookID: session.currentBook?.id, currentBookContextID: session.bookContextID,
            currentNavigationID: workspace.chapterNavigationID,
            selectedChapterID: workspace.chapterPath.last?.id, editorChapterID: editor.currentChapter?.id
        ) else { return }
        coordinator.showingDelete = false
        coordinator.run(editor: editor) {
            guard !Task.isCancelled, receipt.canBeginDeletion(
                currentBookID: session.currentBook?.id, currentBookContextID: session.bookContextID,
                currentNavigationID: workspace.chapterNavigationID,
                selectedChapterID: workspace.chapterPath.last?.id, editorChapterID: editor.currentChapter?.id
            ) else { return }
            let deleted = await editor.deleteCurrentChapter()
            guard !Task.isCancelled, receipt.ownsBook(
                currentBookID: session.currentBook?.id, currentBookContextID: session.bookContextID
            ) else { return }
            if deleted { workspace.removeChapter(id: receipt.chapterID) }
            await workspace.refreshChapters(bookId: receipt.bookID)
            guard deleted, !Task.isCancelled, receipt.canNavigateAfterDeletion(
                currentBookID: session.currentBook?.id, currentBookContextID: session.bookContextID,
                currentNavigationID: workspace.chapterNavigationID,
                selectedChapterID: workspace.chapterPath.last?.id, editorChapterID: editor.currentChapter?.id
            ) else { return }
            workspace.chapterPath = []
        }
    }
}

private struct V2IOSTaskBanner: View {
    let banner: V2DeskTaskBanner
    let primaryAction: V2DeskPrimaryAction
    let perform: (V2DeskPrimaryAction) -> Void
    let networkActionsAvailable: Bool
    @Environment(\.colorScheme) private var colorScheme

    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 9) {
            V2DeskStatusMark(marker: marker, diameter: 7)
            Text(banner.text).font(V2DeskType.control(12.5)).lineLimit(2)
            Spacer(minLength: 6)
            if let detail = banner.detail, !detail.isEmpty {
                Button("查看原因") { showingDetails = true }
                    .buttonStyle(.plain)
                    .font(V2DeskType.control(12.5, weight: .medium))
                    .fixedSize()
                    .frame(minHeight: 32)
            }
            if let action = banner.action, action != primaryAction {
                Button(action.title) { perform(action) }
                    .font(V2DeskType.control(12.5, weight: .medium))
                    .foregroundStyle(banner.tone == .danger ? V2DeskPalette.color(.danger, scheme: colorScheme) : V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    .frame(minWidth: 44, minHeight: 32)
                    .buttonStyle(.plain)
                    .disabled(action.requiresNetwork && !networkActionsAvailable)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(background)
        .overlay(alignment: .bottom) { Rectangle().fill(markerColor.opacity(0.26)).frame(height: 1) }
        .sheet(isPresented: $showingDetails) { NoticeDetailSheet(title: banner.text, message: banner.detail ?? "") }
    }

    private var marker: V2DeskMarker { V2DeskMarker(kind: banner.kind == .cancelled ? .hollowRing : .solidDot, tone: banner.tone) }
    private var markerColor: Color { switch banner.tone { case .accent: V2DeskPalette.color(.accent, scheme: colorScheme); case .success: V2DeskPalette.color(.success, scheme: colorScheme); case .warning: V2DeskPalette.color(.warning, scheme: colorScheme); case .danger: V2DeskPalette.color(.danger, scheme: colorScheme); case .neutral, .stale: V2DeskPalette.color(.tertiaryInk, scheme: colorScheme) } }
    private var background: Color { switch banner.tone { case .accent: V2DeskPalette.color(.taskWriting, scheme: colorScheme); case .success: V2DeskPalette.color(.taskSuccess, scheme: colorScheme); case .warning: V2DeskPalette.color(.taskWarning, scheme: colorScheme); case .danger: V2DeskPalette.color(.taskFailure, scheme: colorScheme); case .neutral, .stale: V2DeskPalette.color(.card, scheme: colorScheme) } }
}

private struct V2IOSActionDock: View {
    let primary: V2DeskPrimaryAction
    let mergesRewrite: Bool
    let canRewrite: Bool
    let rewritePreparing: Bool
    let rewriteAction: () -> Void
    let busy: Bool
    let primaryAction: () -> Void
    let inspirationAction: () -> Void
    let inspirationDisabled: Bool
    let networkActionsAvailable: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            if primary != .none {
                V2IOSPrimaryButton(title: mergesRewrite ? "重写本章" : primary.title,
                    disabled: busy || (primary.requiresNetwork && !networkActionsAvailable),
                    action: primaryAction)
            }
            if !mergesRewrite && (canRewrite || rewritePreparing) {
                V2IOSSecondaryButton(title: rewritePreparing ? "读取影响…" : "重写", action: rewriteAction)
                    .frame(maxWidth: 100)
                    .disabled(busy || !networkActionsAvailable || !canRewrite)
            }
            Button(action: inspirationAction) {
                Text("✦").font(.system(size: 17)).foregroundStyle(V2DeskPalette.color(.accent, scheme: colorScheme)).frame(width: 48, height: 48).overlay(RoundedRectangle(cornerRadius: 12).stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)))
            }
            .buttonStyle(.plain)
            .disabled(inspirationDisabled || !networkActionsAvailable)
            .accessibilityLabel("找方向")
            .accessibilityHint(networkActionsAvailable ? "" : "离线时不可用")
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(V2DeskPalette.color(.rail, scheme: colorScheme))
        .overlay(alignment: .top) { Divider() }
    }
}
