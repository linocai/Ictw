import SwiftUI

/// 中栏章节编辑器：卡片式三阶段（① 本章输入 / ② 允许人物 / ③ 正文与交稿）+
/// Extractor 结果段，内容居中于 `contentMaxWidth`。**写作逻辑一行不新增**，
/// 全部调 `ChapterEditorStore` 现有方法（generate/accept/cancelWriting/reopen/
/// exemptAndRetry/importDraft/save）。语义（三阶段、豁免重试、字数=去空白、删章
/// 两套文案）逐条对齐 iOS `ChapterEditorViews`。
struct MacChapterEditor: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var editor: ChapterEditorStore

    @Binding var selectedChapterId: String?
    @Binding var scrollPosition: ScrollPosition
    /// 打开阅读 overlay 的回调，由 `MacWorkspaceView` 注入（阅读页挂在它那一
    /// 层，本视图不持有阅读状态）。
    let onOpenReader: () -> Void

    @State private var draftMode: DraftMode = .preview
    @State private var showingImport = false
    @State private var confirmingCheckerOverride = false
    @State private var confirmingDelete = false
    @State private var isDeleting = false

    enum DraftMode: String, CaseIterable, Identifiable {
        case preview = "预览"
        case edit = "编辑"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if editor.currentChapter != nil {
                VStack(spacing: 0) {
                    toolbar
                    flow
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingImport) { MacImportDraftSheet() }
        .confirmationDialog(deleteDialogTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(isDeleting ? "正在删除" : "永久删除本章", role: .destructive) { deleteChapter() }
                .disabled(isDeleting)
            Button("取消", role: .cancel) {}
        } message: {
            Text(deleteDialogMessage)
        }
        .confirmationDialog("强制接受当前正文？", isPresented: $confirmingCheckerOverride, titleVisibility: .visible) {
            Button("确认强制接受", role: .destructive) { accept(overrideChecker: true) }
            Button("取消", role: .cancel) {}
        } message: { Text("这会忽略 Bible 检查并继续提取；即使 Extractor 失败，本次接受决定也会保留。") }
        .onChange(of: draftMode) { old, new in
            if old == .edit, new == .preview {
                editor.persistLocalDraftIfNeeded()
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(LinoTheme.faint)
            Text("从左侧选择一章，或新建一章开始。")
                .font(.system(size: 14))
                .foregroundStyle(LinoTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("第 \(editor.currentChapter?.index ?? 0) 章")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LinoTheme.muted)
                HStack(spacing: 8) {
                    Text(chapterTitle)
                        .font(LinoType.rounded(18, .bold))
                        .foregroundStyle(LinoTheme.ink)
                        .lineLimit(1)
                    if let chapter = editor.currentChapter {
                        LinoIStatusPill(text: chapter.status.linoStatusLabel, status: chapter.status)
                    }
                    if let phase = editor.writingPhase.compactLabel {
                        LinoIStatusPill(text: phase, status: editor.writingPhase.pillStatus)
                    }
                    Text("\(editor.draftCharCount) 字")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LinoTheme.muted)
                }
            }
            Spacer(minLength: 8)

            LinoMacIconButton(
                systemName: editor.isSaving ? "hourglass" : "square.and.arrow.down",
                fontSize: 13,
                help: "保存本章",
                isDisabled: editor.writingPhase.isActive
            ) {
                Task {
                    if let saved = await editor.save() { workspace.upsert(saved) }
                }
            }
            LinoMacIconButton(
                systemName: "book",
                fontSize: 13,
                help: "阅读",
                isDisabled: editor.currentChapter?.status != "finalized"
            ) {
                onOpenReader()
            }
            LinoMacIconButton(systemName: "trash", style: .danger, fontSize: 13, help: "删除本章") {
                confirmingDelete = true
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LinoMacMetrics.hairline).frame(height: LinoMacMetrics.hairlineWidth)
        }
    }

    // MARK: - Flow

    private var flow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if editor.restoredLocalDraft {
                    restoredBanner
                        .transition(.opacity)
                }
                inputCard
                characterCard
                handoffCard
                writingTransparencyCard
                if let chapter = editor.currentChapter, showExtraction(chapter) {
                    extractionCard
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .linoAnimation(LinoMotion.content, value: editor.restoredLocalDraft)
            .linoAnimation(LinoMotion.content, value: editor.currentChapter.map(showExtraction) ?? false)
            .frame(maxWidth: LinoMacMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 60)
        }
        .scrollPosition($scrollPosition)
    }

    private var restoredBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(LinoTheme.accentDeep)
            Text("已恢复本地草稿")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LinoTheme.accentDeep)
            Spacer()
        }
        .padding(11)
        .background(LinoTheme.accentSoft.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - ① 本章输入

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader(index: "1", title: "本章输入", subtitle: "这些内容会进入 Writer 的本章任务区。")
            LinoITextField("章节标题", text: chapterBinding(\.title))
            LinoIEditor(
                title: "本章剧情 Bible",
                text: chapterBinding(\.userPrompt),
                minHeight: 200,
                placeholder: "本章节 Bible，情节最高权威。"
            )
        }
        .padding(16)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
        .disabled(editor.writingPhase.isActive)
    }

    // MARK: - ② 允许人物

    private var characterCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader(index: "2", title: "本章允许人物", subtitle: "选择=允许出现的上限，被提及也算出现；未选的已知人物不得出现或被提到。")
            if characters.characters.isEmpty {
                Text("还没有人物。可以在右栏「角色」新建或导入人物卡。")
                    .font(.system(size: 12))
                    .foregroundStyle(LinoTheme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(LinoTheme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(characters.characters) { character in
                        characterChip(character)
                    }
                }
            }
        }
        .padding(16)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
        .disabled(editor.writingPhase.isActive)
    }

    private func characterChip(_ character: Character) -> some View {
        let selected = isSelected(character)
        return Button {
            toggleCharacter(character)
        } label: {
            Text(characterChipTitle(character))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? .white : LinoTheme.accentDeep)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 200, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        Capsule().fill(LinoTheme.accentGradient)
                    } else {
                        Capsule().fill(LinoTheme.surface2)
                    }
                }
                .overlay(Capsule().stroke(LinoTheme.accent.opacity(selected ? 0 : 0.22), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }

    // MARK: - ③ 正文与交稿

    private var handoffCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            stageHeader(index: "3", title: "正文与交稿", subtitle: "Writer 一次完成整章；正文需至少 4000 字且正常结束，不设产品上限。")
            writingControlPanel
            LinoMacSegmented(
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
                        minHeight: 360,
                        placeholder: "可以在这里直接修订正文。"
                    )
                    .disabled(editor.writingPhase.isActive)
                    .transition(.opacity)
                }
            }
            .linoAnimation(LinoMotion.content, value: draftMode)
            actionBar
        }
        .padding(16)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private var writingControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if editor.writingPhase.isGenerating {
                    Button {
                        Task {
                            if let chapter = await editor.cancelWriting() { workspace.upsert(chapter) }
                        }
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(LinoIDangerButtonStyle(compact: true))
                    .onHover { pointer($0) }
                } else {
                    Button {
                        Task {
                            if let chapter = await editor.generate() { workspace.upsert(chapter) }
                        }
                    } label: {
                        Label(generateTitle, systemImage: hasDraft ? "arrow.clockwise" : "sparkles")
                    }
                    .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                    .disabled(editor.currentChapter?.status == "finalized" || editor.writingPhase == .extracting)
                    .onHover { pointer($0 && editor.currentChapter?.status != "finalized" && editor.writingPhase != .extracting) }
                }

                Button {
                    showingImport = true
                } label: {
                    Label("导入正文", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(LinoITintButtonStyle(compact: true))
                .disabled(editor.writingPhase.isActive)
                .onHover { pointer($0 && !editor.writingPhase.isActive) }
                Spacer()
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
                .font(.system(size: 11))
                .foregroundStyle(LinoTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    if let chapter = await editor.exemptAndRetry() { workspace.upsert(chapter) }
                }
            } label: {
                Label("本章豁免并重试", systemImage: "checkmark.shield")
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
            .onHover { pointer($0) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinoTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var draftPreview: some View {
        ScrollView {
            LinoIDraftPreview(text: editor.currentChapter?.draftText ?? "")
                .padding(14)
        }
        .frame(minHeight: 280, maxHeight: 520)
        .background(LinoTheme.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth))
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if editor.currentChapter?.status == "finalized" {
                Button(action: onOpenReader) {
                    Label("进入阅读", systemImage: "book.pages")
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
                .onHover { pointer($0) }

                Button {
                    Task {
                        if let chapter = await editor.reopen() { workspace.upsert(chapter) }
                    }
                } label: {
                    Label("重新编辑本章", systemImage: "pencil")
                }
                .buttonStyle(LinoITintButtonStyle())
                .onHover { pointer($0) }
            } else {
                Button {
                    accept()
                } label: {
                    Label(
                        editor.writingPhase == .extracting
                            ? "Extractor 提取中"
                            : (isExtractionRetry ? "重试 Extractor" : "接受本章"),
                        systemImage: "checkmark.seal.fill"
                    )
                }
                .buttonStyle(LinoISuccessButtonStyle())
                .disabled(!canAccept)
                .onHover { pointer($0 && canAccept) }
                if CheckerOverrideActionPolicy.shouldOffer(
                    hasDraft: hasDraft,
                    phase: editor.writingPhase,
                    checkerAllowsAcceptance: checkerAllowsAcceptance
                ) {
                    Button("忽略检查并接受") { confirmingCheckerOverride = true }
                        .buttonStyle(LinoITintButtonStyle())
                        .onHover { pointer($0) }
                }
            }
        }
    }

    private var writingTransparencyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("本次写作上下文") {
                if let context = editor.memoryContext {
                    Text("Writer 实际记忆简报")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(LinoTheme.muted)
                    Text(context.brief.isEmpty ? "没有采用历史记忆。" : context.brief)
                        .font(.system(size: 12)).foregroundStyle(LinoTheme.body).fixedSize(horizontal: false, vertical: true)
                    if !context.previousTail.isEmpty { labeledText("上一章尾段", context.previousTail) }
                    if let count = context.characterCount { Text("简报占用：\(count) 字符 · \(context.sources.count) 条审计来源").font(.system(size: 11)).foregroundStyle(LinoTheme.muted) }
                    if !context.sources.isEmpty {
                        DisclosureGroup("审计来源（\(context.sources.count) 条）") {
                            ForEach(context.sources) { source in labeledText("来源\(source.chapterIndex.map { " · 第 \($0) 章" } ?? "")", source.excerpt ?? "来源内容不可用") }
                        }
                        .font(.system(size: 11))
                    }
                    ForEach(context.conflicts) { conflict in labeledText("Bible 冲突提示", [conflict.memoryEvidence, conflict.bibleEvidence, conflict.reason].compactMap { $0 }.joined(separator: "\n")) }
                } else { Text("等待本次生成完成后显示实际采用的记忆。").font(.system(size: 11)).foregroundStyle(LinoTheme.muted) }
            }
            DisclosureGroup("Bible 检查结果") { checkerPanel }
        }
        .padding(16).linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    @ViewBuilder private var checkerPanel: some View {
        if let failed = editor.failedCandidateCheckerResult {
            Text("本次候选未通过，正文区仍保留生成前草稿。")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(LinoTheme.warning)
            if let issues = failed.issues, !issues.isEmpty {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.reason).font(.system(size: 11, weight: .semibold)).foregroundStyle(LinoTheme.warning)
                        labeledText("候选稿证据", issue.draftEvidence)
                        labeledText("Bible 证据", issue.bibleEvidence)
                    }
                }
            } else {
                Text("Checker 没有返回可展示的逐项证据，具体错误见本次失败提示。")
                    .font(.system(size: 11)).foregroundStyle(LinoTheme.warning)
            }
            Divider()
        }
        let result = editor.checkerResult
        Text("当前正文 · \((result?.displayVerdict ?? "unavailable").checkerLabel)").font(.system(size: 12, weight: .semibold)).foregroundStyle(result?.isPassed == true ? LinoTheme.success : LinoTheme.warning)
        if let issues = result?.issues, !issues.isEmpty { ForEach(issues) { issue in VStack(alignment: .leading, spacing: 3) { labeledText("正文证据", issue.draftEvidence); labeledText("Bible 证据", issue.bibleEvidence); Text(issue.reason).font(.system(size: 11)).foregroundStyle(LinoTheme.muted) } } } else { Text(result?.displayVerdict == "unavailable" ? "当前正文尚无可用的 Bible 检查结果。" : "Checker 只检查剧情边界，不评价文风。").font(.system(size: 11)).foregroundStyle(LinoTheme.muted) }
        if editor.writingPhase.isFailed && !editor.checkerAppliesToVisibleDraft {
            Text("这次失败稿只在后端留档，没有进入正文区。请调整输入后重新生成。")
                .font(.system(size: 11))
                .foregroundStyle(LinoTheme.warning)
        }
        HStack {
            Button(editor.checkerRefreshing ? "检查中" : "重新检查") {
                Task { _ = await editor.rerunChecker() }
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
            .disabled(editor.checkerRefreshing || !VisibleDraftActionPolicy.canCheck(hasDraft: hasDraft, phase: editor.writingPhase))

            Button(draftMode == .edit ? "保存并检查" : "编辑后检查") {
                if draftMode == .edit {
                    Task {
                        if await editor.rerunChecker() != nil {
                            draftMode = .preview
                        }
                    }
                } else {
                    draftMode = .edit
                }
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
            .disabled(editor.writingPhase.isActive || editor.checkerRefreshing)
        }
    }

    private func labeledText(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 2) { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(LinoTheme.muted); Text(value).font(.system(size: 11)).foregroundStyle(LinoTheme.body).fixedSize(horizontal: false, vertical: true) } }

    // MARK: - Extractor 结果段

    private var extractionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stageHeader(index: "✓", title: "Extractor 结果", subtitle: "接受章节后生成，重新接受会覆盖旧提取结果，也可以手动修改。")
            VStack(alignment: .leading, spacing: 8) {
                LinoISectionLabel("大事记")
                LinoITextField("大事记", text: chapterBinding(\.headline))
            }
            LinoIEditor(
                title: "章节摘要",
                text: chapterBinding(\.longSummary),
                minHeight: 150,
                placeholder: "记录本章情节经过，供后续 Memory Selector 压缩使用。"
            )
            archiveItems("状态变化", editor.currentChapter?.stateChanges ?? [])
            archiveItems("未决事项", editor.currentChapter?.unresolvedItems ?? [])
            archiveItems("原子记忆", editor.currentChapter?.atomicMemories ?? [])
            Text("修改会影响后续章节的候选记忆。")
                .font(.system(size: 11))
                .foregroundStyle(LinoTheme.warning)
            Button {
                Task {
                    if let saved = await editor.save() { workspace.upsert(saved) }
                }
            } label: {
                Text(editor.isSaving ? "保存中" : "保存归档记忆")
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
            .disabled(editor.writingPhase.isActive)
            .onHover { pointer($0 && !editor.writingPhase.isActive) }
        }
        .padding(16)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    @ViewBuilder private func archiveItems(_ title: String, _ items: [JSONValue]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                LinoISectionLabel(title)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item.description)")
                        .font(.system(size: 11))
                        .foregroundStyle(LinoTheme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Stage header

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
                    .font(.system(size: 11))
                    .foregroundStyle(LinoTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Derived values

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

    private var checkerAllowsAcceptance: Bool {
        editor.checkerAppliesToVisibleDraft && editor.checkerResult?.isPassed == true
    }
    private var isExtractionRetry: Bool {
        editor.writingPhase.isFailed && editor.writingPhase.currentStage == .extraction
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

    private var deleteDialogTitle: String {
        guard let chapter = editor.currentChapter else { return "删除本章？" }
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? "删除第 \(chapter.index) 章？"
            : "删除第 \(chapter.index) 章《\(title)》？"
    }

    private var deleteDialogMessage: String {
        if editor.currentChapter?.status == "finalized" {
            return "此操作不可撤销。本章记忆、人物事件与本章造成的动态字段更新都会被删除回滚（已被后续章节覆盖的字段以后续章节为准），不会重新提取后续章节。"
        }
        return "此操作不可撤销。本章正文、人物关联与本章事件都会被删除，后续章节序号将自动收拢。"
    }

    // MARK: - Bindings

    private func chapterBinding(_ keyPath: WritableKeyPath<Chapter, String>) -> Binding<String> {
        Binding(
            get: { editor.currentChapter?[keyPath: keyPath] ?? "" },
            set: { editor.editString(keyPath, value: $0) }
        )
    }

    // MARK: - Helpers

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

    private func deleteChapter() {
        guard let deletingId = editor.currentChapter?.id else { return }
        isDeleting = true
        Task {
            let ok = await editor.deleteCurrentChapter()
            if ok {
                workspace.removeChapter(id: deletingId)
                if let book = session.currentBook { await workspace.load(bookId: book.id) }
                selectedChapterId = workspace.chapters.first?.id
            }
            isDeleting = false
        }
    }

    private func accept(overrideChecker: Bool = false) {
        Task { if let chapter = await editor.accept(overrideChecker: overrideChecker) { workspace.upsert(chapter) } }
    }
}

// MARK: - Import draft sheet

private struct MacImportDraftSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入正文")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LinoTheme.ink)
            LinoIEditor(
                title: "导入正文",
                text: $text,
                minHeight: 320,
                placeholder: "粘贴本章正文。导入后章节进入待接受状态。"
            )
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    .onHover { pointer($0) }
                Button("导入正文") {
                    Task {
                        if let chapter = await editor.importDraft(text) {
                            workspace.upsert(chapter)
                            dismiss()
                        }
                    }
                }
                .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .onHover { pointer($0 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .background(LinoTheme.background)
    }
}
