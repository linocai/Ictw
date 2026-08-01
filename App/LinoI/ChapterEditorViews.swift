import SwiftUI

struct LinoIChapterEditorScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var notices: NoticeBus
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var readerPresented = false
    @State private var activeChapterId: String
    @State private var activeIndex: Int
    @State private var editorScrollPosition = ScrollPosition(edge: .top)

    let summary: ChapterSummary

    init(summary: ChapterSummary) {
        self.summary = summary
        _activeChapterId = State(initialValue: summary.id)
        _activeIndex = State(initialValue: summary.index)
    }

    var body: some View {
        ZStack {
            LinoTheme.background.ignoresSafeArea()
            if editor.isLoading && editor.currentChapter?.id != activeChapterId {
                ProgressView("读取章节")
                    .foregroundStyle(LinoTheme.muted)
                    .tint(LinoTheme.accent)
            } else if editor.currentChapter?.id == activeChapterId {
                LinoIChapterEditor(
                    scrollPosition: $editorScrollPosition,
                    onOpenReader: openReader
                )
            } else {
                LinoIEmptyCard(title: "章节读取失败", subtitle: "返回章节列表后再试一次。", actionTitle: nil)
                    .padding(18)
            }
        }
        .navigationTitle("第 \(activeIndex) 章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("删除本章", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(isDeleting)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(isDeleting ? "正在删除" : "永久删除本章", role: .destructive) {
                deleteChapter()
            }
            .disabled(isDeleting)
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
        .task(id: summary.id) {
            activeChapterId = summary.id
            activeIndex = summary.index
            readerPresented = false
            await editor.load(summary)
            if editor.currentChapter?.id == summary.id, editor.currentChapter?.status == "finalized" {
                readerPresented = true
            }
            if let book = session.currentBook {
                await characters.load(bookId: book.id)
            }
        }
        .onChange(of: editor.currentChapter?.status) { old, new in
            guard let chapter = editor.currentChapter, chapter.id == activeChapterId else { return }
            workspace.upsert(chapter)
            if new == "finalized", old != nil, old != "finalized" {
                readerPresented = true
                if let book = session.currentBook {
                    Task { await characters.load(bookId: book.id) }
                }
            }
        }
        .fullScreenCover(isPresented: $readerPresented) {
            readerCover
        }
    }

    private var deleteDialogTitle: String {
        let title = editor.currentChapter?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty
            ? "删除第 \(activeIndex) 章？"
            : "删除第 \(activeIndex) 章《\(title)》？"
    }

    private var deleteDialogMessage: String {
        if editor.currentChapter?.status == "finalized" {
            return "此操作不可撤销。本章记忆、人物事件与本章造成的动态字段更新都会被删除回滚（已被后续章节覆盖的字段以后续章节为准），不会重新提取后续章节。"
        }
        return "此操作不可撤销。本章正文、人物关联与本章事件都会被删除，后续章节序号将自动收拢。"
    }

    /// Loads an adjacent finalized chapter in place (no new navigation push)
    /// so the "上一章/下一章" controls in reading mode feel like a page flip.
    private func switchChapter(_ target: ChapterSummary) {
        Task {
            activeChapterId = target.id
            activeIndex = target.index
            editorScrollPosition.scrollTo(edge: .top)
            await editor.load(target)
        }
    }

    private func openReader() {
        guard
            let chapter = editor.currentChapter,
            chapter.status == "finalized",
            chapter.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            notices.publish("本章尚未定稿，暂时不能进入阅读。")
            return
        }
        readerPresented = true
    }

    @ViewBuilder
    private var readerCover: some View {
        if let chapter = editor.currentChapter, chapter.id == activeChapterId, chapter.status == "finalized" {
            LinoIReadingView(
                chapter: chapter,
                onExit: { readerPresented = false },
                onSwitchChapter: switchChapter
            )
        } else {
            ZStack {
                LinoTheme.background.ignoresSafeArea()
                ProgressView("读取章节")
                    .foregroundStyle(LinoTheme.muted)
                    .tint(LinoTheme.accent)
            }
        }
    }

    private func deleteChapter() {
        isDeleting = true
        Task {
            let deleted = await editor.deleteCurrentChapter()
            if deleted {
                workspace.removeChapter(id: activeChapterId)
                if let book = session.currentBook {
                    await workspace.load(bookId: book.id)
                }
                dismiss()
            }
            isDeleting = false
        }
    }
}

private struct LinoIChapterEditor: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @State private var showingImport = false
    @State private var confirmingCheckerOverride = false
    @State private var draftMode: DraftMode = .preview

    @Binding var scrollPosition: ScrollPosition
    let onOpenReader: () -> Void

    enum DraftMode: String, CaseIterable, Identifiable {
        case preview = "预览"
        case edit = "编辑"
        var id: String { rawValue }
    }

    var body: some View {
        editingContent
        .sheet(isPresented: $showingImport) {
            LinoIImportDraftSheet()
                .presentationDetents([.large])
        }
        .confirmationDialog("忽略 Bible 检查并接受？", isPresented: $confirmingCheckerOverride, titleVisibility: .visible) {
            Button("确认忽略并接受", role: .destructive) { acceptTapped(overrideChecker: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会保留当前候选稿，并以你的明确决定继续提取归档。")
        }
    }

    private var editingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if editor.restoredLocalDraft {
                    restoredBanner
                        .transition(.opacity)
                }
                header
                inputSection
                characterSection
                handoffSection
                writingTransparencySection
                if let chapter = editor.currentChapter, showExtraction(chapter) {
                    extractionSection(chapter)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .linoAnimation(LinoMotion.content, value: editor.restoredLocalDraft)
            .linoAnimation(LinoMotion.content, value: editor.currentChapter.map(showExtraction) ?? false)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 34)
        }
        .scrollPosition($scrollPosition)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(chapterTitle)
                    .font(LinoType.rounded(25, .bold))
                    .foregroundStyle(LinoTheme.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let chapter = editor.currentChapter {
                        LinoIStatusPill(text: chapter.status.linoStatusLabel, status: chapter.status)
                    }
                    if let phase = editor.writingPhase.compactLabel {
                        LinoIStatusPill(text: phase, status: editor.writingPhase.pillStatus)
                    }
                    Text("\(editor.draftCharCount) 字")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LinoTheme.muted)
                }
            }
            Spacer()
            Button {
                Task {
                    if let saved = await editor.save() {
                        workspace.upsert(saved)
                    }
                }
            } label: {
                Image(systemName: editor.isSaving ? "hourglass" : "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(editor.writingPhase.isActive)
            .foregroundStyle(LinoTheme.accentDeep)
            .background(Color.white.opacity(0.7), in: Circle())
            .overlay(Circle().stroke(LinoTheme.hairline, lineWidth: 0.5))
        }
    }

    private var restoredBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(LinoTheme.accentDeep)
            Text("已恢复本地草稿")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LinoTheme.accentDeep)
            Spacer()
        }
        .padding(11)
        .background(LinoTheme.accentSoft.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader(index: "1", title: "本章输入", subtitle: "这些内容会进入 Writer 的本章任务区。")
            LinoITextField("章节标题", text: chapterBinding(\.title))
            LinoIEditor(
                title: "本章剧情 Bible",
                text: chapterBinding(\.userPrompt),
                minHeight: 220,
                placeholder: "本章节 Bible，情节最高权威。"
            )
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
        .disabled(editor.writingPhase.isActive)
    }

    private var characterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader(index: "2", title: "本章允许人物", subtitle: "选择代表允许出现，不代表 Writer 必须使用；未选的已知人物不得出现或被提到。")
            if characters.characters.isEmpty {
                Text("还没有人物。可以回到人物页新建或导入人物卡。")
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(characters.characters) { character in
                        Button {
                            toggleCharacter(character)
                        } label: {
                            Text(characterChipTitle(character))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isSelected(character) ? .white : LinoTheme.accentDeep)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 200, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background {
                                    if isSelected(character) {
                                        Capsule().fill(LinoTheme.accentGradient)
                                    } else {
                                        Capsule().fill(Color.white.opacity(0.68))
                                    }
                                }
                                .overlay(Capsule().stroke(LinoTheme.accent.opacity(isSelected(character) ? 0 : 0.22), lineWidth: 0.6))
                        }
                        .buttonStyle(.plain)
                        .linoAnimation(LinoMotion.selection, value: isSelected(character))
                    }
                }
            }
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
        .disabled(editor.writingPhase.isActive)
    }

    private var handoffSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader(index: "3", title: "正文与交稿", subtitle: "Writer 一次完成整章；正文需至少 4000 字且正常结束，不设产品上限。")
            writingControlPanel
            LinoISegmented(
                options: DraftMode.allCases,
                label: { $0.rawValue },
                selection: $draftMode
            )

            Group {
                if draftMode == .preview {
                    draftPreview
                        .transition(.opacity)
                } else {
                    LinoIEditor(
                        title: "正文编辑",
                        text: chapterBinding(\.draftText),
                        minHeight: 480,
                        placeholder: "可以在这里直接修订正文。"
                    )
                    .disabled(editor.writingPhase.isActive)
                    .transition(.opacity)
                }
            }
            .linoAnimation(LinoMotion.content, value: draftMode)

            actionBar
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
    }

    private var writingControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if editor.writingPhase.isGenerating {
                    Button {
                        Task {
                            if let chapter = await editor.cancelWriting() {
                                workspace.upsert(chapter)
                            }
                        }
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(LinoIDangerButtonStyle())
                } else {
                    Button {
                        Task {
                            if let chapter = await editor.generate() {
                                workspace.upsert(chapter)
                            }
                        }
                    } label: {
                        Label(generateTitle, systemImage: hasDraft ? "arrow.clockwise" : "sparkles")
                    }
                    .buttonStyle(LinoIPrimaryButtonStyle())
                    .disabled(editor.currentChapter?.status == "finalized" || editor.writingPhase == .extracting)
                }

                Button {
                    showingImport = true
                } label: {
                    Label("导入正文", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(LinoITintButtonStyle())
                .disabled(editor.writingPhase.isActive)
            }

            LinoIGenerationStatusPanel(
                state: editor.presentationState,
                onRetry: retryFailureAction,
                onRetrySave: retrySaveAction
            )

            if editor.writingPhase.isFailed, !editor.pendingExemptionNames.isEmpty {
                exemptionPrompt
            }
        }
    }

    private var exemptionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("以下人物未被选中，但出现在正文或 Bible 中：\(editor.pendingExemptionNames.joined(separator: "、"))")
                .font(.caption)
                .foregroundStyle(LinoTheme.warning)
            Button {
                Task {
                    if let chapter = await editor.exemptAndRetry() {
                        workspace.upsert(chapter)
                    }
                }
            } label: {
                Label("本章豁免并重试", systemImage: "checkmark.shield")
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
        }
        .padding(10)
        .background(LinoTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var draftPreview: some View {
        ScrollView {
            LinoIDraftPreview(text: editor.currentChapter?.draftText ?? "")
                .padding(14)
        }
        .frame(minHeight: 360, maxHeight: 560)
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if editor.currentChapter?.status == "finalized" {
                Button(action: onOpenReader) {
                    Label("进入阅读", systemImage: "book.pages")
                }
                .buttonStyle(LinoIPrimaryButtonStyle())

                Button {
                    Task {
                        if let chapter = await editor.reopen() {
                            workspace.upsert(chapter)
                        }
                    }
                } label: {
                    Label("重新编辑本章", systemImage: "pencil")
                }
                .buttonStyle(LinoITintButtonStyle())
            } else {
                Button {
                    acceptTapped()
                } label: {
                    Label(editor.writingPhase == .extracting ? "Extractor 提取中" : "接受本章", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(LinoISuccessButtonStyle())
                .disabled(!canAccept)
                if hasDraft && !editor.writingPhase.isActive && !checkerAllowsAcceptance {
                    Button("忽略检查并接受") { confirmingCheckerOverride = true }
                        .buttonStyle(LinoITintButtonStyle())
                }
            }
        }
    }

    private var writingTransparencySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("本次写作上下文") {
                if let context = editor.memoryContext {
                    Text(context.brief.isEmpty ? "没有采用历史记忆。" : context.brief)
                        .font(.footnote).foregroundStyle(LinoTheme.body).fixedSize(horizontal: false, vertical: true)
                    if !context.previousTail.isEmpty { labeledText("上一章尾段", context.previousTail) }
                    if let count = context.characterCount { Text("实际上下文：\(count) 字符 · \(context.sources.count) 条来源").font(.caption).foregroundStyle(LinoTheme.muted) }
                    ForEach(context.sources) { source in
                        labeledText("来源\(source.chapterIndex.map { " · 第 \($0) 章" } ?? "")", source.excerpt ?? "来源内容不可用")
                    }
                    ForEach(context.conflicts) { conflict in
                        labeledText("Bible 冲突提示", [conflict.memoryEvidence, conflict.bibleEvidence, conflict.reason].compactMap { $0 }.joined(separator: "\n"))
                    }
                } else { Text("等待本次生成完成后显示实际采用的记忆。") .font(.caption).foregroundStyle(LinoTheme.muted) }
            }
            DisclosureGroup("候选稿（\(editor.draftCandidates.count)）") {
                if editor.candidatesLoading { ProgressView() }
                ForEach(editor.draftCandidates) { candidate in
                    DisclosureGroup {
                        Text(candidate.draftText)
                            .font(.caption)
                            .foregroundStyle(LinoTheme.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !candidate.isCurrent {
                            Button("选择这份候选稿") { Task { if let chapter = await editor.selectCandidate(candidate) { workspace.upsert(chapter) } } }
                                .buttonStyle(LinoITintButtonStyle(compact: true))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(candidate.displaySource) · \(candidate.nonWhitespaceCount) 字\(candidate.isCurrent ? " · 当前" : "")").font(.footnote.weight(.semibold))
                            Text(candidate.checkerResult?.displayVerdict.checkerLabel ?? "等待检查").font(.caption).foregroundStyle(LinoTheme.muted)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !editor.draftCandidates.isEmpty { Button("刷新候选") { Task { await editor.loadCandidates() } }.buttonStyle(LinoITintButtonStyle(compact: true)) }
            }
            DisclosureGroup("Bible 检查结果") {
                checkerPanel
            }
        }
        .padding(14).linoGlass(cornerRadius: 20)
    }

    @ViewBuilder private var checkerPanel: some View {
        let result = editor.checkerResult
        Text((result?.displayVerdict ?? "unavailable").checkerLabel).font(.footnote.weight(.semibold)).foregroundStyle(result?.isPassed == true ? LinoTheme.success : LinoTheme.warning)
        if let issues = result?.issues, !issues.isEmpty {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 3) { labeledText("正文证据", issue.draftEvidence); labeledText("Bible 证据", issue.bibleEvidence); Text(issue.reason).font(.caption).foregroundStyle(LinoTheme.muted) }
            }
        } else { Text(result?.displayVerdict == "unavailable" ? "正文已生成，Bible 检查尚不可用。" : "Checker 只检查剧情边界，不评价文风。").font(.caption).foregroundStyle(LinoTheme.muted) }
        HStack { Button(editor.checkerRefreshing ? "检查中" : "重新检查") { Task { _ = await editor.rerunChecker() } }.buttonStyle(LinoITintButtonStyle(compact: true)).disabled(editor.checkerRefreshing || !hasDraft); Button("编辑后检查") { draftMode = .edit }.buttonStyle(LinoITintButtonStyle(compact: true)) }
    }

    private func labeledText(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption2.weight(.semibold)).foregroundStyle(LinoTheme.muted); Text(value).font(.caption).foregroundStyle(LinoTheme.body).fixedSize(horizontal: false, vertical: true) }
    }

    private func extractionSection(_ chapter: Chapter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stageHeader(index: "✓", title: "Extractor 结果", subtitle: "接受章节后生成，重新接受会覆盖本章旧提取结果，也可以手动修改。")
            VStack(alignment: .leading, spacing: 8) {
                LinoISectionLabel("大事记")
                LinoITextField("大事记", text: chapterBinding(\.headline))
            }
            LinoIEditor(
                title: "本章梗概",
                text: chapterBinding(\.summary),
                minHeight: 120,
                placeholder: "本章梗概会作为后续章节 Memory Selector 的候选记忆。"
            )
            LinoIEditor(
                title: "章节长摘要",
                text: chapterBinding(\.longSummary),
                minHeight: 160,
                placeholder: "记录更完整的情节经过，供后续 Memory Selector 压缩使用。"
            )
            archiveItems("状态变化", chapter.stateChanges)
            archiveItems("未决事项", chapter.unresolvedItems)
            archiveItems("原子记忆", chapter.atomicMemories)
            Text("修改会影响后续章节的候选记忆。")
                .font(.caption)
                .foregroundStyle(LinoTheme.warning)
            Button {
                Task {
                    if let saved = await editor.save() {
                        workspace.upsert(saved)
                    }
                }
            } label: {
                Text(editor.isSaving ? "保存中" : "保存归档记忆")
            }
            .buttonStyle(LinoITintButtonStyle())
            .disabled(editor.writingPhase.isActive)
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
    }

    @ViewBuilder private func archiveItems(_ title: String, _ items: [JSONValue]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                LinoISectionLabel(title)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item.description)")
                        .font(.caption)
                        .foregroundStyle(LinoTheme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stageHeader(index: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index)
                .font(LinoType.rounded(13, .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(LinoTheme.accentGradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LinoType.rowTitle)
                    .foregroundStyle(LinoTheme.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(LinoTheme.muted)
            }
            Spacer()
        }
    }

    private var chapterTitle: String {
        guard let chapter = editor.currentChapter else { return "章节" }
        return chapter.title.isEmpty ? "第 \(chapter.index) 章" : chapter.title
    }

    private var hasDraft: Bool {
        !(editor.currentChapter?.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var generateTitle: String {
        hasDraft ? "重新生成" : "生成"
    }

    private var checkerAllowsAcceptance: Bool { editor.checkerResult?.isPassed == true }
    private var canAccept: Bool {
        guard hasDraft, !editor.writingPhase.isActive else { return false }
        if editor.writingPhase.isFailed {
            return editor.writingPhase.currentStage == .extraction
        }
        return checkerAllowsAcceptance
    }

    private var retryFailureAction: (() -> Void)? {
        guard let action = editor.presentationState.recoveryAction else { return nil }
        return {
            Task {
                let chapter: Chapter?
                switch action {
                case .retryGeneration:
                    chapter = await editor.generate()
                case .retryExtraction:
                    chapter = await editor.accept()
                }
                if let chapter {
                    workspace.upsert(chapter)
                }
            }
        }
    }

    private var retrySaveAction: (() -> Void)? {
        guard editor.presentationState.saveState.needsRetry else { return nil }
        return {
            Task {
                if let chapter = await editor.save() {
                    workspace.upsert(chapter)
                }
            }
        }
    }

    private func showExtraction(_ chapter: Chapter) -> Bool {
        chapter.status == "finalized" || !chapter.summary.isEmpty || !chapter.headline.isEmpty
    }

    private func chapterBinding(_ keyPath: WritableKeyPath<Chapter, String>) -> Binding<String> {
        Binding(
            get: { editor.currentChapter?[keyPath: keyPath] ?? "" },
            set: { editor.editString(keyPath, value: $0) }
        )
    }

    private func isSelected(_ character: Character) -> Bool {
        editor.currentChapter?.characterLinks.contains(where: { $0.characterId == character.id }) ?? false
    }

    private func toggleCharacter(_ character: Character) {
        guard var links = editor.currentChapter?.characterLinks else { return }
        if let idx = links.firstIndex(where: { $0.characterId == character.id }) {
            links.remove(at: idx)
        } else {
            links.append(ChapterLink(characterId: character.id))
        }
        editor.setCharacterLinks(links)
    }

    private func characterChipTitle(_ character: Character) -> String {
        if character.role.isEmpty {
            return character.name
        }
        return "\(character.name) · \(character.role)"
    }

    private func acceptTapped(overrideChecker: Bool = false) {
        Task {
            if let chapter = await editor.accept(overrideChecker: overrideChecker) {
                workspace.upsert(chapter)
            }
        }
    }
}

private struct LinoIImportDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                LinoIEditor(
                    title: "导入正文",
                    text: $text,
                    minHeight: 430,
                    placeholder: "粘贴本章正文。导入后章节进入待接受状态。"
                )
                Button("导入正文") {
                    Task {
                        if let chapter = await editor.importDraft(text) {
                            workspace.upsert(chapter)
                            dismiss()
                        }
                    }
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
            .navigationTitle("导入正文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .background(LinoTheme.background.ignoresSafeArea())
        }
    }
}
