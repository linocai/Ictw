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
        VStack(spacing: 0) {
            editorTopBar

            ZStack {
                LinoTheme.background.ignoresSafeArea()
                if editor.isLoading && editor.currentChapter?.id != activeChapterId {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(LinoTheme.accent)
                        Text("读取章节")
                            .font(.system(size: 13))
                            .foregroundStyle(LinoTheme.muted)
                    }
                } else if editor.currentChapter?.id == activeChapterId {
                    LinoIChapterEditor(
                        scrollPosition: $editorScrollPosition,
                        onOpenReader: openReader
                    )
                } else {
                    LinoIEmptyCard(
                        title: "章节读取失败",
                        subtitle: "返回章节列表后再试一次。",
                        actionTitle: "返回章节",
                        action: { dismiss() }
                    )
                    .padding(20)
                }
            }
        }
        .background(LinoTheme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
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
        .onDisappear {
            editor.persistLocalDraftIfNeeded()
        }
    }

    private var editorTopBar: some View {
        HStack(spacing: 7) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LinoTheme.ink)
            .accessibilityLabel("返回稿件")

            HStack(spacing: 8) {
                Text("第 \(activeIndex) 章")
                    .font(LinoType.serif(15, .semibold))
                    .foregroundStyle(LinoTheme.ink)
                Circle()
                    .fill(topStatusColor)
                    .frame(width: 5, height: 5)
                Text(topStatusLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(topStatusColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                saveChapter()
            } label: {
                Text(saveLabel)
                    .font(.system(size: 11.5))
                    .foregroundStyle(saveColor)
                    .frame(minWidth: 45, minHeight: 38, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(editor.isSaving || editor.writingPhase.isActive)
            .accessibilityLabel("保存章节，\(editor.saveState.label)")

            Menu {
                Button("删除本章", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(isDeleting)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 38, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LinoTheme.muted)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 46)
        .background(LinoTheme.bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LinoTheme.line).frame(height: 1)
        }
    }

    private var topStatusLabel: String {
        if editor.writingPhase.isActive {
            return editor.writingPhase.currentStage?.label ?? "处理中"
        }
        if editor.writingPhase.isFailed { return "未完成" }
        return editor.currentChapter?.status.linoStatusLabel ?? summary.status.linoStatusLabel
    }

    private var topStatusColor: Color {
        if editor.writingPhase.isFailed { return LinoTheme.danger }
        if editor.writingPhase.isActive {
            return editor.writingPhase == .extracting ? LinoTheme.warning : LinoTheme.accent
        }
        switch editor.currentChapter?.status ?? summary.status {
        case "finalized": return LinoTheme.success
        case "draft_ready", "extracting": return LinoTheme.warning
        case "writing": return LinoTheme.accent
        case "failed": return LinoTheme.danger
        default: return LinoTheme.muted
        }
    }

    private var saveLabel: String {
        switch editor.saveState {
        case .synced: return "已同步"
        case .unsaved: return "未保存"
        case .savingLocally, .savingRemotely: return "保存中"
        case .localDraft: return "已存本机"
        case .restoredLocalDraft: return "待同步"
        case .localSaveFailed, .remoteSaveFailed: return "保存失败"
        }
    }

    private var saveColor: Color {
        editor.saveState.failureMessage == nil ? LinoTheme.faint : LinoTheme.danger
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

    private func saveChapter() {
        Task {
            if let saved = await editor.save() {
                workspace.upsert(saved)
            }
        }
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

private struct EditorFlowStep: Identifiable {
    let id: String
    let title: String
    let state: ChapterGenerationStepState
}

private struct LinoIChapterEditor: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @State private var showingImport = false
    @State private var confirmingCheckerOverride = false
    @State private var draftMode: DraftMode = .preview
    @State private var contextExpanded = false
    @State private var checkerExpanded = false
    @State private var hidesRestoredBanner = false

    @Binding var scrollPosition: ScrollPosition
    let onOpenReader: () -> Void

    enum DraftMode: String, CaseIterable, Identifiable {
        case preview = "预览"
        case edit = "编辑"
        var id: String { rawValue }
    }

    var body: some View {
        editingContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomActionBar
            }
            .sheet(isPresented: $showingImport) {
                LinoIImportDraftSheet()
                    .presentationDetents([.large])
            }
            .confirmationDialog("忽略 Bible 检查并接受？", isPresented: $confirmingCheckerOverride, titleVisibility: .visible) {
                Button("确认忽略并接受", role: .destructive) { acceptTapped(overrideChecker: true) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会保留当前正文，并以你的明确决定继续提取归档。")
            }
            .onChange(of: draftMode) { old, new in
                if old == .edit, new == .preview {
                    editor.persistLocalDraftIfNeeded()
                }
            }
            .onChange(of: editor.currentChapter?.id) { _, _ in
                hidesRestoredBanner = false
                contextExpanded = false
                checkerExpanded = false
            }
    }

    private var editingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if editor.restoredLocalDraft && !hidesRestoredBanner {
                    restoredBanner
                        .padding(.bottom, 20)
                        .transition(.opacity.combined(with: .offset(y: 7)))
                }

                titleBlock
                sectionHeader("本章剧情 BIBLE")
                    .padding(.top, 22)
                bibleCard
                    .padding(.top, 11)

                sectionHeader("本章允许人物") {
                    Text("已选 \(selectedCharacterCount) / \(characters.characters.count)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LinoTheme.faint)
                }
                .padding(.top, 22)
                characterChips
                    .padding(.top, 11)

                sectionHeader("流程")
                    .padding(.top, 22)
                flowCard
                    .padding(.top, 11)

                bodyHeader
                    .padding(.top, 22)
                draftSurface
                    .padding(.top, 11)

                sectionHeader("留痕")
                    .padding(.top, 22)
                traceCard
                    .padding(.top, 11)

                if let chapter = editor.currentChapter, showExtraction(chapter) {
                    sectionHeader("EXTRACTOR 结果") {
                        Text("可编辑")
                            .font(.system(size: 11.5))
                            .foregroundStyle(LinoTheme.faint)
                    }
                    .padding(.top, 22)
                    extractionCard(chapter)
                        .padding(.top, 11)
                        .transition(.opacity.combined(with: .offset(y: 7)))
                }
            }
            .linoAnimation(LinoMotion.content, value: editor.restoredLocalDraft && !hidesRestoredBanner)
            .linoAnimation(LinoMotion.content, value: editor.currentChapter.map(showExtraction) ?? false)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 30)
        }
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
    }

    private var restoredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LinoTheme.accent)
            Text("已恢复本地草稿")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(LinoTheme.accent)
            Spacer()
            Button("知道了") {
                hidesRestoredBanner = true
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(LinoTheme.muted)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 48)
        .background(LinoTheme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("章节标题", text: chapterBinding(\.title), axis: .vertical)
                .textFieldStyle(.plain)
                .font(LinoType.editorTitle)
                .foregroundStyle(LinoTheme.ink)
                .lineLimit(1...2)
                .disabled(editor.writingPhase.isActive)
            HStack(spacing: 8) {
                Text("\(editor.draftCharCount.formatted()) 字")
                Text("·")
                Text("最低 4000 字")
            }
            .font(.system(size: 12))
            .foregroundStyle(LinoTheme.faint)
        }
    }

    private var bibleCard: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: chapterBinding(\.userPrompt))
                .scrollContentBackground(.hidden)
                .font(LinoType.serif(14.5))
                .lineSpacing(12.9)
                .foregroundStyle(LinoTheme.ink2)
                .frame(minHeight: 150)
                .padding(9)
            if editor.currentChapter?.userPrompt.isEmpty != false {
                Text("本章节 Bible，情节最高权威。")
                    .font(LinoType.serif(14.5))
                    .foregroundStyle(LinoTheme.faint)
                    .padding(.horizontal, 14)
                    .padding(.top, 17)
                    .allowsHitTesting(false)
            }
        }
        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(cardStroke(14))
        .disabled(editor.writingPhase.isActive)
    }

    @ViewBuilder
    private var characterChips: some View {
        if characters.characters.isEmpty {
            Text("还没有人物。可以回到人物页新建或导入人物卡。")
                .font(.system(size: 12.5))
                .foregroundStyle(LinoTheme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(cardStroke(14))
        } else {
            FlowLayout(spacing: 8) {
                ForEach(characters.characters) { character in
                    Button {
                        toggleCharacter(character)
                    } label: {
                        Text(characterChipTitle(character))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSelected(character) ? LinoTheme.accentText : LinoTheme.ink2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(
                                isSelected(character) ? LinoTheme.accent : LinoTheme.surface,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().stroke(isSelected(character) ? Color.clear : LinoTheme.line2, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .linoAnimation(LinoMotion.selection, value: isSelected(character))
                }
            }
            .disabled(editor.writingPhase.isActive)
        }
    }

    private var flowCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 11) {
                ForEach(flowSteps) { step in
                    flowStepRow(step)
                }
            }

            if hasFlowNotice {
                Divider()
                    .overlay(LinoTheme.line)
                    .padding(.vertical, 12)
                flowNotice
            }
        }
        .padding(14)
        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(cardStroke(14))
        .shadow(color: Color.black.opacity(0.035), radius: 2, y: 1)
    }

    private var flowSteps: [EditorFlowStep] {
        let state = editor.presentationState
        let memory = state.steps.first { $0.stage == .memorySelection }?.state ?? .pending
        let drafting = state.steps.first { $0.stage == .drafting }?.state ?? .pending
        let validation = state.steps.first { $0.stage == .deterministicValidation }?.state ?? .pending
        let checker = state.steps.first { $0.stage == .bibleChecking }?.state ?? .pending
        let extraction = state.steps.first { $0.stage == .extraction }?.state ?? .pending
        return [
            EditorFlowStep(id: "memory", title: "Memory Selector", state: memory),
            EditorFlowStep(id: "writer", title: "Writer", state: mergedWriterState(drafting, validation)),
            EditorFlowStep(id: "checker", title: "Bible 检查", state: checker),
            EditorFlowStep(id: "extractor", title: "Extractor", state: extraction),
        ]
    }

    private func mergedWriterState(
        _ drafting: ChapterGenerationStepState,
        _ validation: ChapterGenerationStepState
    ) -> ChapterGenerationStepState {
        switch validation {
        case .failed, .cancelled, .active, .completed:
            return validation
        case .pending:
            return drafting
        }
    }

    private func flowStepRow(_ step: EditorFlowStep) -> some View {
        HStack(spacing: 10) {
            flowDot(step.state)
            Text(step.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(step.state == .pending ? LinoTheme.faint : LinoTheme.ink)
            Spacer()
            Text(flowStateLabel(step.state))
                .font(.system(size: 11.5))
                .foregroundStyle(flowStateColor(step.state))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title)，\(flowStateLabel(step.state))")
    }

    @ViewBuilder
    private func flowDot(_ state: ChapterGenerationStepState) -> some View {
        switch state {
        case .completed:
            Circle()
                .fill(LinoTheme.success)
                .frame(width: 16, height: 16)
                .overlay(Circle().fill(LinoTheme.surface).frame(width: 5, height: 5))
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(LinoTheme.accent)
                .frame(width: 16, height: 16)
        case .failed:
            Circle()
                .fill(LinoTheme.danger)
                .frame(width: 16, height: 16)
                .overlay(Circle().fill(LinoTheme.surface).frame(width: 5, height: 5))
        case .cancelled:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinoTheme.muted)
                .frame(width: 10, height: 10)
                .frame(width: 16, height: 16)
        case .pending:
            Circle()
                .stroke(LinoTheme.faint, lineWidth: 1.4)
                .frame(width: 16, height: 16)
        }
    }

    private var hasFlowNotice: Bool {
        editor.presentationState.steps.contains { $0.state == .failed || $0.state == .cancelled }
            || editor.presentationState.connectionInterrupted
            || editor.presentationState.saveState.failureMessage != nil
    }

    @ViewBuilder
    private var flowNotice: some View {
        if let failed = editor.presentationState.steps.first(where: { $0.state == .failed }) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(LinoTheme.danger)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(failed.stage.label)未完成")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LinoTheme.danger)
                    Text(failureDetail)
                        .font(.system(size: 12.5))
                        .lineSpacing(6)
                        .foregroundStyle(LinoTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let code = editor.presentationState.failureCode, !code.isEmpty {
                        Text("错误代码：\(code)")
                            .font(.system(size: 11.5).monospaced())
                            .foregroundStyle(LinoTheme.muted)
                            .textSelection(.enabled)
                    }
                }
            }

            if !editor.pendingExemptionNames.isEmpty {
                exemptionPrompt
                    .padding(.top, 12)
            } else if let retryFailureAction {
                Button(action: retryFailureAction) {
                    Text(editor.presentationState.recoveryAction?.title ?? "重试")
                }
                .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                .padding(.top, 10)
            }
        } else if editor.presentationState.connectionInterrupted {
            noticeText("连接暂时中断。任务仍在服务器执行，App 正在自动重连。", color: LinoTheme.warning)
        } else if let cancelled = editor.presentationState.steps.first(where: { $0.state == .cancelled }) {
            noticeText("\(cancelled.stage.label)已停止。当前草稿仍保留。", color: LinoTheme.muted)
        }

        if let saveFailure = editor.presentationState.saveState.failureMessage {
            noticeText(saveFailure, color: LinoTheme.danger)
                .padding(.top, 8)
            if let retrySaveAction {
                Button("重试保存", action: retrySaveAction)
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    .padding(.top, 8)
            }
        }
    }

    private var failureDetail: String {
        let values = [editor.presentationState.headline, editor.presentationState.validationReason]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? "任务没有完成，系统没有返回更具体的原因。当前正文区保留生成前的草稿。" : values.joined(separator: "\n")
    }

    private func noticeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .lineSpacing(5)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var exemptionPrompt: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("以下人物未被选中，但出现在正文或 Bible 中：\(editor.pendingExemptionNames.joined(separator: "、"))")
                .font(.system(size: 12, weight: .medium))
                .lineSpacing(4)
                .foregroundStyle(LinoTheme.warning)
            HStack(spacing: 9) {
                Button("重新生成") { generateTapped() }
                    .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                Button("本章豁免并重试") {
                    Task {
                        if let chapter = await editor.exemptAndRetry() {
                            workspace.upsert(chapter)
                        }
                    }
                }
                .buttonStyle(LinoITintButtonStyle(compact: true))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinoTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var bodyHeader: some View {
        HStack(spacing: 8) {
            LinoISectionLabel("正文")
            Rectangle().fill(LinoTheme.line).frame(height: 1)
            Button("导入") { showingImport = true }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(LinoTheme.accent)
                .buttonStyle(.plain)
                .disabled(editor.writingPhase.isActive)
            draftModeControl
        }
    }

    private var draftModeControl: some View {
        HStack(spacing: 2) {
            ForEach(DraftMode.allCases) { mode in
                Button(mode.rawValue) {
                    draftMode = mode
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(draftMode == mode ? LinoTheme.ink : LinoTheme.muted)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(draftMode == mode ? LinoTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(LinoTheme.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .linoAnimation(LinoMotion.selection, value: draftMode)
    }

    @ViewBuilder
    private var draftSurface: some View {
        if draftMode == .preview {
            LinoIDraftPreview(text: editor.currentChapter?.draftText ?? "")
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(cardStroke(14))
                .shadow(color: Color.black.opacity(0.035), radius: 2, y: 1)
                .transition(.opacity)
        } else {
            ZStack(alignment: .topLeading) {
                TextEditor(text: chapterBinding(\.draftText))
                    .scrollContentBackground(.hidden)
                    .font(LinoType.bodyText)
                    .lineSpacing(15)
                    .foregroundStyle(LinoTheme.ink2)
                    .frame(minHeight: 520)
                    .padding(7)
                if !hasDraft {
                    Text("可以在这里直接修订正文。")
                        .font(LinoType.bodyText)
                        .foregroundStyle(LinoTheme.faint)
                        .padding(.horizontal, 13)
                        .padding(.top, 15)
                        .allowsHitTesting(false)
                }
            }
            .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(cardStroke(14))
            .disabled(editor.writingPhase.isActive)
            .transition(.opacity)
        }
    }

    private var traceCard: some View {
        VStack(spacing: 0) {
            traceRow(
                title: "本次写作上下文",
                summary: contextSummary,
                color: LinoTheme.muted,
                expanded: $contextExpanded
            )
            if contextExpanded {
                contextPanel
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }

            Divider().overlay(LinoTheme.line)

            traceRow(
                title: "Bible 检查结果",
                summary: checkerSummary,
                color: checkerColor,
                showsDot: true,
                expanded: $checkerExpanded
            )
            if checkerExpanded {
                checkerPanel
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(cardStroke(14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 2, y: 1)
        .linoAnimation(LinoMotion.drawer, value: contextExpanded)
        .linoAnimation(LinoMotion.drawer, value: checkerExpanded)
    }

    private func traceRow(
        title: String,
        summary: String,
        color: Color,
        showsDot: Bool = false,
        expanded: Binding<Bool>
    ) -> some View {
        Button {
            expanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LinoTheme.ink)
                Spacer()
                if showsDot {
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(color)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LinoTheme.faint)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 180 : 0))
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var contextSummary: String {
        guard let context = editor.memoryContext else { return "等待生成" }
        if let count = context.characterCount {
            return "\(count) 字符 · 来源 \(context.sources.count)"
        }
        return "来源 \(context.sources.count)"
    }

    @ViewBuilder
    private var contextPanel: some View {
        if let context = editor.memoryContext {
            VStack(alignment: .leading, spacing: 12) {
                labeledText("WRITER 实际记忆简报", context.brief.isEmpty ? "没有采用历史记忆。" : context.brief, serif: true)

                if !context.previousTail.isEmpty {
                    labeledText("上一章尾段", context.previousTail, serif: true)
                        .padding(11)
                        .background(LinoTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }

                if let count = context.characterCount {
                    Text("简报占用：\(count) 字符 · \(context.sources.count) 条审计来源")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LinoTheme.muted)
                }

                if !context.sources.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(context.sources.enumerated()), id: \.element.id) { index, source in
                            HStack(alignment: .top, spacing: 10) {
                                Text(source.chapterIndex.map { "第 \($0) 章" } ?? "来源")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(LinoTheme.muted)
                                    .frame(width: 52, alignment: .leading)
                                Text(source.excerpt ?? "来源内容不可用")
                                    .font(LinoType.serif(13))
                                    .lineSpacing(8)
                                    .foregroundStyle(LinoTheme.ink2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 10)
                            if index < context.sources.count - 1 {
                                Divider().overlay(LinoTheme.line)
                            }
                        }
                    }
                }

                ForEach(context.conflicts) { conflict in
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(LinoTheme.warning)
                            .frame(width: 3)
                        labeledText(
                            "BIBLE 冲突提示",
                            [conflict.memoryEvidence, conflict.bibleEvidence, conflict.reason]
                                .compactMap { $0 }
                                .joined(separator: "\n"),
                            serif: false
                        )
                    }
                    .padding(11)
                    .background(LinoTheme.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("等待本次生成完成后显示实际采用的记忆。")
                .font(.system(size: 12.5))
                .foregroundStyle(LinoTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var checkerSummary: String {
        if editor.failedCandidateCheckerResult != nil { return "候选未通过" }
        return (editor.checkerResult?.displayVerdict ?? "unavailable").checkerLabel
    }

    private var checkerColor: Color {
        if editor.failedCandidateCheckerResult != nil { return LinoTheme.danger }
        return editor.checkerResult?.isPassed == true ? LinoTheme.success : LinoTheme.warning
    }

    @ViewBuilder
    private var checkerPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let failed = editor.failedCandidateCheckerResult {
                Text("本次候选未通过，正文区仍保留生成前草稿。")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(LinoTheme.danger)
                if let issues = failed.issues, !issues.isEmpty {
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(issue.reason)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(LinoTheme.danger)
                            evidenceBlock("候选稿证据", issue.draftEvidence)
                            evidenceBlock("BIBLE 证据", issue.bibleEvidence)
                        }
                    }
                } else {
                    Text("Checker 没有返回可展示的逐项证据，具体原因见上方流程失败提示。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LinoTheme.warning)
                }
                Divider().overlay(LinoTheme.line)
            }

            let result = editor.checkerResult
            Text("当前正文 · \((result?.displayVerdict ?? "unavailable").checkerLabel)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(result?.isPassed == true ? LinoTheme.success : LinoTheme.warning)

            if let issues = result?.issues, !issues.isEmpty {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(issue.reason)
                            .font(.system(size: 12.5))
                            .foregroundStyle(LinoTheme.ink2)
                        evidenceBlock("正文证据", issue.draftEvidence)
                        evidenceBlock("BIBLE 证据", issue.bibleEvidence)
                    }
                }
            } else {
                Text(result?.displayVerdict == "unavailable" ? "当前正文尚无可用的 Bible 检查结果。" : "Checker 只检查剧情边界，不评价文风。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(LinoTheme.muted)
            }

            if editor.writingPhase.isFailed && !editor.checkerAppliesToVisibleDraft {
                Text("这次失败稿只在后端留档，没有进入正文区。请调整输入后重新生成。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(LinoTheme.warning)
            }

            HStack(spacing: 9) {
                Button(editor.checkerRefreshing ? "检查中" : "重新检查") {
                    Task { _ = await editor.rerunChecker() }
                }
                .buttonStyle(LinoITintButtonStyle(compact: true))
                .disabled(editor.checkerRefreshing || !VisibleDraftActionPolicy.canCheck(hasDraft: hasDraft, phase: editor.writingPhase))

                Button("编辑后检查") { draftMode = .edit }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    .disabled(editor.writingPhase.isActive)
            }

            if hasDraft && !editor.writingPhase.isActive && editor.checkerAppliesToVisibleDraft && !checkerAllowsAcceptance {
                Button("忽略检查并接受") { confirmingCheckerOverride = true }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LinoTheme.warning)
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func evidenceBlock(_ title: String, _ value: String?) -> some View {
        labeledText(title, value?.isEmpty == false ? value! : "未提供", serif: true)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinoTheme.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func labeledText(_ title: String, _ value: String, serif: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LinoISectionLabel(title)
            Text(value)
                .font(serif ? LinoType.serif(13.5) : .system(size: 12.5))
                .lineSpacing(serif ? 11.5 : 6)
                .foregroundStyle(LinoTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func extractionCard(_ chapter: Chapter) -> some View {
        VStack(spacing: 0) {
            archiveEditableRow("大事记") {
                TextField("大事记", text: chapterBinding(\.headline), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(LinoType.serif(15.5, .semibold))
                    .foregroundStyle(LinoTheme.ink)
            }

            archiveEditableRow("章节摘要") {
                TextEditor(text: chapterBinding(\.longSummary))
                    .scrollContentBackground(.hidden)
                    .font(LinoType.serif(14))
                    .lineSpacing(12.6)
                    .foregroundStyle(LinoTheme.ink2)
                    .frame(minHeight: 150)
                    .padding(.horizontal, -5)
            }

            archiveItems("状态变化", chapter.stateChanges)
            archiveItems("未决事项", chapter.unresolvedItems)
            archiveItems("原子记忆", chapter.atomicMemories)

            HStack(spacing: 10) {
                Text("修改会影响后续章节的候选记忆。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LinoTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(editor.isSaving ? "保存中" : "保存归档") {
                    Task {
                        if let saved = await editor.save() {
                            workspace.upsert(saved)
                        }
                    }
                }
                .buttonStyle(LinoITintButtonStyle(compact: true))
                .disabled(editor.writingPhase.isActive)
            }
            .padding(14)
        }
        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(cardStroke(14))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 2, y: 1)
    }

    private func archiveEditableRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LinoISectionLabel(title)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LinoTheme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private func archiveItems(_ title: String, _ items: [JSONValue]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                LinoISectionLabel(title)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 9) {
                        Text("—")
                            .foregroundStyle(LinoTheme.faint)
                        Text(item.description)
                            .foregroundStyle(LinoTheme.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 13))
                    .lineSpacing(7.8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(LinoTheme.line).frame(height: 1)
            }
        }
    }

    private var bottomActionBar: some View {
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LinoTheme.danger)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LinoTheme.danger, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if editor.currentChapter?.status == "finalized" {
                        reopenTapped()
                    } else {
                        generateTapped()
                    }
                } label: {
                    Image(systemName: editor.currentChapter?.status == "finalized" ? "pencil" : "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(LinoTheme.ink)
                        .frame(width: 48, height: 48)
                        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LinoTheme.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(editor.writingPhase == .extracting)
                .accessibilityLabel(editor.currentChapter?.status == "finalized" ? "重新编辑本章" : generateTitle)
            }

            Button {
                if editor.currentChapter?.status == "finalized" {
                    onOpenReader()
                } else {
                    acceptTapped()
                }
            } label: {
                HStack(spacing: 7) {
                    if editor.writingPhase.isActive {
                        ProgressView().controlSize(.small).tint(LinoTheme.muted)
                    } else {
                        Image(systemName: editor.currentChapter?.status == "finalized" ? "book.pages" : "checkmark")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(primaryActionLabel)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(primaryActionForeground)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(primaryActionBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(primaryActionDisabled)

            Button(action: onOpenReader) {
                Image(systemName: "book")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(editor.currentChapter?.status == "finalized" ? LinoTheme.ink : LinoTheme.faint)
                    .frame(width: 48, height: 48)
                    .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LinoTheme.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(editor.currentChapter?.status != "finalized")
            .accessibilityLabel("进入阅读")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(LinoTheme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(LinoTheme.line).frame(height: 1)
        }
    }

    private var primaryActionLabel: String {
        if editor.writingPhase == .extracting { return "Extractor 提取中" }
        if editor.writingPhase.isActive { return "生成中…" }
        if editor.currentChapter?.status == "finalized" { return "进入阅读" }
        return "接受本章"
    }

    private var primaryActionBackground: Color {
        if editor.writingPhase.isActive { return LinoTheme.bg2 }
        if editor.currentChapter?.status == "finalized" { return LinoTheme.success }
        return canAccept ? LinoTheme.accent : LinoTheme.bg2
    }

    private var primaryActionForeground: Color {
        if editor.writingPhase.isActive || (!canAccept && editor.currentChapter?.status != "finalized") {
            return LinoTheme.muted
        }
        return LinoTheme.accentText
    }

    private var primaryActionDisabled: Bool {
        editor.writingPhase.isActive || (editor.currentChapter?.status != "finalized" && !canAccept)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            LinoISectionLabel(title)
            Rectangle().fill(LinoTheme.line).frame(height: 1)
        }
    }

    private func sectionHeader<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            LinoISectionLabel(title)
            Rectangle().fill(LinoTheme.line).frame(height: 1)
            trailing()
        }
    }

    private func cardStroke(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(LinoTheme.line, lineWidth: 1)
    }

    private var selectedCharacterCount: Int {
        editor.currentChapter?.characterLinks.count ?? 0
    }

    private var hasDraft: Bool {
        !(editor.currentChapter?.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private var generateTitle: String {
        hasDraft ? "重新生成" : "生成"
    }

    private var checkerAllowsAcceptance: Bool {
        editor.checkerAppliesToVisibleDraft && editor.checkerResult?.isPassed == true
    }

    private var canAccept: Bool {
        VisibleDraftActionPolicy.canAccept(
            hasDraft: hasDraft,
            phase: editor.writingPhase,
            checkerApplies: editor.checkerAppliesToVisibleDraft,
            checkerPassed: editor.checkerResult?.isPassed == true
        )
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
        chapter.status == "finalized" || !chapter.longSummary.isEmpty || !chapter.headline.isEmpty
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
        character.role.isEmpty ? character.name : "\(character.name) · \(character.role)"
    }

    private func generateTapped() {
        Task {
            if let chapter = await editor.generate() {
                workspace.upsert(chapter)
            }
        }
    }

    private func reopenTapped() {
        Task {
            if let chapter = await editor.reopen() {
                workspace.upsert(chapter)
            }
        }
    }

    private func acceptTapped(overrideChecker: Bool = false) {
        Task {
            if let chapter = await editor.accept(overrideChecker: overrideChecker) {
                workspace.upsert(chapter)
            }
        }
    }

    private func flowStateLabel(_ state: ChapterGenerationStepState) -> String {
        switch state {
        case .pending: return "待进行"
        case .active: return "进行中"
        case .completed: return "已完成"
        case .failed: return "未完成"
        case .cancelled: return "已停止"
        }
    }

    private func flowStateColor(_ state: ChapterGenerationStepState) -> Color {
        switch state {
        case .pending: return LinoTheme.faint
        case .active: return LinoTheme.accent
        case .completed: return LinoTheme.success
        case .failed: return LinoTheme.danger
        case .cancelled: return LinoTheme.muted
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
                Text("导入的正文同样要过 Bible 检查，检查通过后才能接受。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LinoTheme.muted)
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
                        .foregroundStyle(LinoTheme.accent)
                }
            }
            .background(LinoTheme.background.ignoresSafeArea())
        }
    }
}
