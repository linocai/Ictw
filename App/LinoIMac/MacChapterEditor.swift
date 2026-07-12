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
    /// 打开阅读 overlay 的回调，由 `MacWorkspaceView` 注入（阅读页挂在它那一
    /// 层，本视图不持有阅读状态）。
    let onOpenReader: () -> Void

    @State private var draftMode: DraftMode = .preview
    @State private var showingImport = false
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
                        .font(.custom("Songti SC", size: 18).weight(.bold))
                        .foregroundStyle(LinoTheme.ink)
                        .lineLimit(1)
                    if let chapter = editor.currentChapter {
                        LinoIStatusPill(text: chapter.status.linoStatusLabel, status: chapter.status)
                    }
                    if let phase = editor.writingPhase.label {
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
                if editor.restoredLocalDraft { restoredBanner }
                inputCard
                characterCard
                handoffCard
                if let chapter = editor.currentChapter, showExtraction(chapter) {
                    extractionCard
                }
            }
            .frame(maxWidth: LinoMacMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 60)
        }
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
            VStack(alignment: .leading, spacing: 8) {
                LinoISectionLabel("目标字数")
                LinoINumberField("目标字数", value: targetWordBinding)
            }
            LinoIEditor(
                title: "作者对本章的备注",
                text: chapterBinding(\.authorNote),
                minHeight: 110,
                placeholder: "节奏、视角、氛围、禁区或其他只针对本章的要求。"
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
                    .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        Capsule().fill(LinoTheme.accentGradient)
                    } else {
                        Capsule().fill(Color.white.opacity(0.68))
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
            stageHeader(index: "3", title: "正文与交稿", subtitle: "字数不足由 Writer 扩写；超长或其他程序违规交给 Reviser。")
            writingControlPanel
            LinoMacSegmented(
                options: DraftMode.allCases,
                label: { $0.rawValue },
                selection: $draftMode
            )
            if draftMode == .preview {
                draftPreview
            } else {
                LinoIEditor(
                    title: "正文编辑",
                    text: chapterBinding(\.draftText),
                    minHeight: 360,
                    placeholder: "可以在这里直接修订正文。"
                )
                .disabled(editor.writingPhase.isActive)
            }
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

            if editor.writingPhase.isActive, let label = editor.writingPhase.label {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(LinoTheme.accent)
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LinoTheme.muted)
                }
            }

            if case .expanding(let attempt) = editor.writingPhase {
                VStack(alignment: .leading, spacing: 4) {
                    Text("程序校验发现篇幅不足，Writer 正在进行第 \(attempt)/2 次有机扩写。")
                    if let reason = editor.currentValidationReason {
                        Text("未通过验证：\(reason)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(LinoTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if case .revising(let attempt) = editor.writingPhase {
                VStack(alignment: .leading, spacing: 4) {
                    Text("程序校验未通过，Reviser 正在进行第 \(attempt)/2 次修订。修订不会自行增加新剧情。")
                    if let reason = editor.currentValidationReason {
                        Text("未通过验证：\(reason)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(LinoTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if editor.writingPhase.isFailed, let reason = editor.currentValidationReason {
                Text("未通过验证：\(reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(LinoTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if editor.currentChapter?.status == "finalized" {
                Text("已完成章节必须先「重新编辑本章」，才能重新生成。")
                    .font(.system(size: 11))
                    .foregroundStyle(LinoTheme.muted)
            }

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
        .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth))
    }

    private var actionBar: some View {
        Group {
            if editor.currentChapter?.status == "finalized" {
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
                    Task {
                        if let chapter = await editor.accept() { workspace.upsert(chapter) }
                    }
                } label: {
                    Label(editor.writingPhase == .extracting ? "Extractor 提取中" : "接受本章", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(LinoISuccessButtonStyle())
                .disabled(!canAccept)
                .onHover { pointer($0 && canAccept) }
            }
        }
    }

    // MARK: - Extractor 结果段

    private var extractionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stageHeader(index: "✓", title: "Extractor 结果", subtitle: "接受章节后生成，重新接受会覆盖旧提取结果，也可以手动修改。")
            VStack(alignment: .leading, spacing: 8) {
                LinoISectionLabel("大事记")
                LinoITextField("大事记", text: chapterBinding(\.headline))
            }
            LinoIEditor(
                title: "本章梗概",
                text: chapterBinding(\.summary),
                minHeight: 110,
                placeholder: "本章梗概会作为后续章节 Memory Selector 的候选记忆。"
            )
            Text("修改会影响后续章节的候选记忆。")
                .font(.system(size: 11))
                .foregroundStyle(LinoTheme.warning)
            Button {
                Task {
                    if let saved = await editor.save() { workspace.upsert(saved) }
                }
            } label: {
                Text(editor.isSaving ? "保存中" : "保存梗概与大事记")
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
            .disabled(editor.writingPhase.isActive)
            .onHover { pointer($0 && !editor.writingPhase.isActive) }
        }
        .padding(16)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    // MARK: - Stage header

    private func stageHeader(index: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(LinoTheme.accentGradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
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

    private var canAccept: Bool {
        hasDraft && !editor.writingPhase.isActive && !editor.writingPhase.isFailed
    }

    private func showExtraction(_ chapter: Chapter) -> Bool {
        chapter.status == "finalized" || !chapter.summary.isEmpty || !chapter.headline.isEmpty
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

    private var targetWordBinding: Binding<Int> {
        Binding(
            get: { editor.currentChapter?.targetWordCount ?? 3000 },
            set: { editor.editTargetWordCount($0) }
        )
    }

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
