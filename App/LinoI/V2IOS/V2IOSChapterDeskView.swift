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
    @State private var resolvedChapter: Chapter?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let resolvedChapter {
                if resolvedChapter.status == "finalized" {
                    V2IOSChapterReaderView(summary: summary, resolvedChapter: resolvedChapter)
                } else {
                    V2IOSChapterDeskView(summary: summary)
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
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var isMoving = false

    let summary: ChapterSummary
    let resolvedChapter: Chapter

    var body: some View {
        VStack(spacing: 0) {
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
            onSave: nil
        )
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
                isLastChapterInBook: V2DeskChapterPosition.isLastChapter(chapter.id, in: workspace.chapters)
            )
        ).commands
    }

    @ViewBuilder private var readerDock: some View {
        let previous = V2DeskReadingOrder.previous(after: chapter.id, in: workspace.chapters)
        let next = V2DeskReadingOrder.next(after: chapter.id, in: workspace.chapters)
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
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
            .background(V2DeskPalette.color(.rail, scheme: colorScheme))
            .overlay(alignment: .top) { Divider() }
        }
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
    @State private var showingInspiration = false
    @State private var inspirationDetent: PresentationDetent = V2IOSInspirationPresentation.compactDetent
    @State private var showingSettings = false
    @State private var showingAcceptWarning = false

    let summary: ChapterSummary

    var body: some View {
        let snapshot = V2DeskPresentation.make(source)
        VStack(spacing: 0) {
            if !sync.networkActionsAvailable {
                V2DeskOfflineExplanation()
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(V2DeskPalette.color(.taskWarning, scheme: colorScheme))
            }
            if let banner = snapshot.taskBanner {
                V2IOSTaskBanner(banner: banner, primaryAction: snapshot.primaryAction, perform: perform, networkActionsAvailable: sync.networkActionsAvailable)
            }
            if editor.isLoading && editor.currentChapter?.id != summary.id {
                Spacer(); ProgressView("读取章节"); Spacer()
            } else if editor.currentChapter?.id == summary.id {
                TabView(selection: $face) {
                    V2IOSIntentFace().tag(V2DeskChapterFace.intent)
                    V2IOSManuscriptFace(snapshot: snapshot).tag(V2DeskChapterFace.manuscript)
                    V2IOSEvidenceFace(snapshot: snapshot).tag(V2DeskChapterFace.evidence)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                pageIndicator
                V2IOSActionDock(
                    face: $face,
                    primary: snapshot.primaryAction,
                    primaryAction: { tapPrimary(snapshot.primaryAction) },
                    inspirationAction: {
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
        .v2IOSChapterActions(
            chapterID: summary.id,
            bookID: summary.bookId,
            commands: snapshot.commands,
            isAccepted: snapshot.chapterState == .accepted,
            onSave: {
                Task {
                    if let chapter = await editor.save() {
                        workspace.upsert(chapter)
                    }
                }
            }
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
        .onDisappear { editor.persistLocalDraftIfNeeded() }
        .sheet(isPresented: $showingInspiration) {
            V2IOSInspirationSheet(selectedDetent: $inspirationDetent)
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
            Button("仍然接受", role: .destructive) { Task { if let chapter = await editor.accept(overrideChecker: true) { workspace.upsert(chapter) } } }
            Button("返回", role: .cancel) {}
        } message: {
            Text("检查发现的问题不会再提醒你；正文和本章意图会保留，随后会单独整理记忆。")
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
            isLastChapterInBook: V2DeskChapterPosition.isLastChapter(editor.currentChapter?.id, in: workspace.chapters)
        )
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(V2DeskChapterFace.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == face ? V2DeskPalette.color(.ink, scheme: colorScheme) : V2DeskPalette.color(.ink, scheme: colorScheme).opacity(0.15))
                    .frame(width: 22, height: 3)
                    .accessibilityLabel(item.title)
            }
        }
        .padding(.vertical, 12)
    }

    private func tapPrimary(_ action: V2DeskPrimaryAction) {
        guard sync.networkActionsAvailable else { return }
        switch action {
        case .generate, .retryGeneration: Task { if let chapter = await editor.generate() { workspace.upsert(chapter) } }
        case .cancelGeneration: Task { if let chapter = await editor.cancelWriting() { workspace.upsert(chapter) } }
        case .rerunChecker: Task { _ = await editor.rerunChecker() }
        case .accept: Task { if let chapter = await editor.accept() { workspace.upsert(chapter) } }
        case .acceptWithWarning: showingAcceptWarning = true
        case .startNewChapter: Task { await workspace.createChapter() }
        case .retryArchive: Task { if let chapter = await editor.retryArchive() { workspace.upsert(chapter) } }
        case .openSettings: showingSettings = true
        case .none: break
        }
    }

    private func perform(_ action: V2DeskPrimaryAction) { tapPrimary(action) }
}

extension View {
    /// Attaches the whole chapter-action surface — trigger, menu items,
    /// export sheet and all three confirmation dialogs — to a chapter screen.
    func v2IOSChapterActions(
        chapterID: String,
        bookID: String,
        commands: V2DeskChapterCommands,
        isAccepted: Bool,
        onSave: (() -> Void)?
    ) -> some View {
        modifier(V2IOSChapterActions(
            chapterID: chapterID,
            bookID: bookID,
            commands: commands,
            isAccepted: isAccepted,
            onSave: onSave
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
    let onSave: (() -> Void)?

    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var showingExport = false
    @State private var showingReopen = false
    @State private var showingRewrite = false
    @State private var showingDelete = false
    /// One gate for every chapter-scope action. Rewrite and reopen each wait
    /// on a `rewrite-preview` round trip before their dialog appears; with a
    /// gate per flow, tapping one and then the other on a slow network raised
    /// both dialogs at once. Delete opens instantly and joins the same gate so
    /// it cannot stack on top of an in-flight preview either.
    @State private var preparingChapterAction = false
    /// `nil` means the preview failed, not "not yet fetched" — no dialog is
    /// raised until the fetch has resolved one way or the other.
    @State private var pendingImpact: RewriteImpactPreview?

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
                isPresented: $showingReopen,
                titleVisibility: .visible
            ) {
                Button("重新编辑", role: .destructive) { confirmReopen() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(V2DeskReopenConfirmation.message(
                    affected: pendingImpact?.affectedChapters ?? [],
                    previewUnavailable: pendingImpact == nil
                ))
            }
            .confirmationDialog(
                V2DeskRewriteConfirmation.title,
                isPresented: $showingRewrite,
                titleVisibility: .visible
            ) {
                Button("重写", role: .destructive) { confirmRewrite() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(V2DeskRewriteConfirmation.message(
                    isAccepted: isAccepted,
                    affected: pendingImpact?.affectedChapters ?? [],
                    previewUnavailable: pendingImpact == nil
                ))
            }
            .confirmationDialog(
                V2DeskDeleteConfirmation.title,
                isPresented: $showingDelete,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { confirmDelete() }
                Button("取消", role: .cancel) {}
            } message: {
                Text(V2DeskDeleteConfirmation.message)
            }
    }

    /// The waiting label is the only feedback available here: tapping an item
    /// closes the menu, so a disabled state alone would be invisible until the
    /// author reopens the menu — which is exactly the moment they need to see
    /// that the first tap did register.
    private var menu: some View {
        Menu {
            if commands.canRewrite {
                Button(preparingChapterAction ? "重写本章（正在读取影响范围）" : "重写本章") { startRewriteFlow() }
                    .disabled(preparingChapterAction)
            }
            if isAccepted {
                Button(
                    preparingChapterAction ? "重新编辑这一章（正在读取影响范围）" : "重新编辑这一章",
                    role: .destructive
                ) { startReopenFlow() }
                    .disabled(preparingChapterAction)
            } else if let onSave {
                Button("保存到服务器", action: onSave)
            }
            Button("导出这一章") { showingExport = true }
            if commands.canDelete {
                Divider()
                Button("删除这一章", role: .destructive) { showingDelete = true }
                    .disabled(preparingChapterAction)
            }
        } label: {
            HStack(spacing: 4) {
                Text("更多")
                Image(systemName: "ellipsis.circle")
            }
        }
        .disabled(!sync.networkActionsAvailable)
        .accessibilityHint(sync.networkActionsAvailable ? "" : "离线时不可用；已打开内容仍可阅读和编辑")
        .accessibilityLabel("更多章节操作")
    }

    private func startRewriteFlow() {
        guard !preparingChapterAction, editor.currentChapter?.id == chapterID else { return }
        preparingChapterAction = true
        Task {
            defer { preparingChapterAction = false }
            pendingImpact = await editor.loadRewriteImpact()
            // The preview is a network round trip and the edge-swipe stays
            // live throughout it. Leaving during that window must not raise a
            // dialog describing the chapter we left about the chapter we are
            // now on -- confirming it would rewrite the wrong chapter.
            guard editor.currentChapter?.id == chapterID else { return }
            showingRewrite = true
        }
    }

    /// Reopen fires the identical server-side cascade a rewrite's first step
    /// does, so it takes the identical preview and the identical copy.
    private func startReopenFlow() {
        guard !preparingChapterAction, editor.currentChapter?.id == chapterID else { return }
        preparingChapterAction = true
        Task {
            defer { preparingChapterAction = false }
            pendingImpact = await editor.loadRewriteImpact()
            guard editor.currentChapter?.id == chapterID else { return }
            showingReopen = true
        }
    }

    /// Refreshes the chapter list whenever the reopen landed — which includes
    /// the case where the write job then failed to start. The confirmation
    /// promised those downstream chapters would be marked unreliable, and that
    /// promise falls due even when no new prose is coming. `refreshChapters`
    /// rather than `load`: the author stays on this chapter to watch the
    /// generation instead of being thrown back to the rail.
    private func confirmRewrite() {
        guard editor.currentChapter?.id == chapterID else { return }
        Task {
            let outcome = await editor.rewrite()
            if let chapter = outcome.chapter { workspace.upsert(chapter) }
            guard outcome.requiresChapterListRefresh else { return }
            await workspace.refreshChapters(bookId: bookID)
        }
    }

    private func confirmReopen() {
        guard editor.currentChapter?.id == chapterID else { return }
        Task {
            guard let reopened = await editor.reopen() else { return }
            workspace.upsert(reopened)
            await workspace.refreshChapters(bookId: bookID)
        }
    }

    /// A rejected delete must cost the author nothing: the refresh corrects
    /// the stale "this is the last chapter" belief that produced the 409 while
    /// leaving `chapterPath` — and therefore their place in the book —
    /// untouched. Only a delete that actually happened uses `load`, whose
    /// clearing of `chapterPath` is what returns them to the rail.
    private func confirmDelete() {
        guard editor.currentChapter?.id == chapterID else { return }
        Task {
            guard await editor.deleteCurrentChapter() else {
                await workspace.refreshChapters(bookId: bookID)
                return
            }
            workspace.removeChapter(id: chapterID)
            await workspace.load(bookId: bookID)
        }
    }
}

private struct V2IOSTaskBanner: View {
    let banner: V2DeskTaskBanner
    let primaryAction: V2DeskPrimaryAction
    let perform: (V2DeskPrimaryAction) -> Void
    let networkActionsAvailable: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 9) {
            V2DeskStatusMark(marker: marker, diameter: 7)
            Text(banner.text).font(V2DeskType.control(12.5)).lineLimit(2)
            Spacer(minLength: 6)
            if let action = banner.action, action != primaryAction {
                Button(action.title) { perform(action) }
                    .font(V2DeskType.control(12.5, weight: .medium))
                    .foregroundStyle(banner.tone == .danger ? V2DeskPalette.color(.danger, scheme: colorScheme) : V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    .frame(minWidth: 44, minHeight: 32)
                    .buttonStyle(.plain)
                    .disabled(!networkActionsAvailable)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(background)
        .overlay(alignment: .bottom) { Rectangle().fill(markerColor.opacity(0.26)).frame(height: 1) }
    }

    private var marker: V2DeskMarker { V2DeskMarker(kind: banner.kind == .cancelled ? .hollowRing : .solidDot, tone: banner.tone) }
    private var markerColor: Color { switch banner.tone { case .accent: V2DeskPalette.color(.accent, scheme: colorScheme); case .success: V2DeskPalette.color(.success, scheme: colorScheme); case .warning: V2DeskPalette.color(.warning, scheme: colorScheme); case .danger: V2DeskPalette.color(.danger, scheme: colorScheme); case .neutral, .stale: V2DeskPalette.color(.tertiaryInk, scheme: colorScheme) } }
    private var background: Color { switch banner.tone { case .accent: V2DeskPalette.color(.taskWriting, scheme: colorScheme); case .success: V2DeskPalette.color(.taskSuccess, scheme: colorScheme); case .warning: V2DeskPalette.color(.taskWarning, scheme: colorScheme); case .danger: V2DeskPalette.color(.taskFailure, scheme: colorScheme); case .neutral, .stale: V2DeskPalette.color(.card, scheme: colorScheme) } }
}

private struct V2IOSActionDock: View {
    @Binding var face: V2DeskChapterFace
    let primary: V2DeskPrimaryAction
    let primaryAction: () -> Void
    let inspirationAction: () -> Void
    let inspirationDisabled: Bool
    let networkActionsAvailable: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Button { face = alternateFace } label: {
                Text(alternateFace.title)
                    .font(V2DeskType.control(12, weight: .medium))
                    .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    .frame(width: 48, height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)))
            }.buttonStyle(.plain).accessibilityLabel("查看\(alternateFace.title)")
            V2IOSPrimaryButton(title: primary.title, disabled: primary == .none || !networkActionsAvailable, action: primaryAction)
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

    private var alternateFace: V2DeskChapterFace {
        switch face { case .intent: .manuscript; case .manuscript: .intent; case .evidence: .manuscript }
    }
}
