import SwiftUI

struct LinoIChapterEditorScreen: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @State private var confirmingDelete = false
    @State private var isDeleting = false

    let summary: ChapterSummary

    var body: some View {
        ZStack {
            LinoTheme.background.ignoresSafeArea()
            if editor.isLoading && editor.currentChapter?.id != summary.id {
                ProgressView("读取章节")
                    .foregroundStyle(LinoTheme.muted)
            } else if editor.currentChapter?.id == summary.id {
                LinoIChapterEditor()
            } else {
                LinoIEmptyCard(title: "章节读取失败", subtitle: "返回章节列表后再试一次。", actionTitle: nil)
                    .padding(18)
            }
        }
        .navigationTitle("第 \(summary.index) 章")
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
            await editor.load(summary)
            if let book = session.currentBook {
                await characters.load(bookId: book.id)
            }
        }
    }

    private var deleteDialogTitle: String {
        let title = editor.currentChapter?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty
            ? "删除第 \(summary.index) 章？"
            : "删除第 \(summary.index) 章《\(title)》？"
    }

    private var deleteDialogMessage: String {
        if editor.currentChapter?.status == "finalized" {
            return "此操作不可撤销。本章记忆和人物事件会被删除，但不会回滚人物当前动态状态，也不会重新提取后续章节。"
        }
        return "此操作不可撤销。本章正文、人物关联与本章事件都会被删除，后续章节序号将自动收拢。"
    }

    private func deleteChapter() {
        isDeleting = true
        Task {
            let deleted = await editor.deleteCurrentChapter()
            if deleted {
                workspace.removeChapter(id: summary.id)
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
    @State private var draftMode: DraftMode = .preview

    enum DraftMode: String, CaseIterable, Identifiable {
        case preview = "预览"
        case edit = "编辑"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollViewReader { pageProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if editor.restoredLocalDraft {
                        restoredBanner
                    }
                    header
                    inputSection
                    characterSection
                    handoffSection
                    if let chapter = editor.currentChapter, (!chapter.summary.isEmpty || !chapter.headline.isEmpty) {
                        extractionSection(chapter)
                    }
                    Color.clear.frame(height: 1).id("page-bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 34)
            }
            .onChange(of: editor.draftCharCount) { _, _ in
                guard editor.writingPhase.isActive else { return }
                withAnimation(.smooth(duration: 0.25)) {
                    pageProxy.scrollTo("draft-bottom", anchor: .bottom)
                }
            }
        }
        .sheet(isPresented: $showingImport) {
            LinoIImportDraftSheet()
                .presentationDetents([.large])
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(chapterTitle)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(LinoTheme.ink)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let chapter = editor.currentChapter {
                        LinoIStatusPill(text: chapter.status.linoStatusLabel, status: chapter.status)
                    }
                    if let phase = editor.writingPhase.label {
                        LinoIStatusPill(text: phase, status: editor.writingPhase.isActive ? "writing" : "failed")
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
                    .frame(width: 38, height: 38)
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
            VStack(alignment: .leading, spacing: 8) {
                LinoISectionLabel("目标字数")
                LinoINumberField("目标字数", value: targetWordBinding)
            }
            LinoIEditor(
                title: "作者对本章的备注",
                text: chapterBinding(\.authorNote),
                minHeight: 120,
                placeholder: "可填写节奏、视角、氛围、禁区或其他只针对本章的要求。"
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
            stageHeader(index: "3", title: "正文与交稿", subtitle: "记忆选择后由 Writer 写作；仅在程序校验不通过时交给 Reviser，最多两次。")
            writingControlPanel
            Picker("正文模式", selection: $draftMode) {
                ForEach(DraftMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if draftMode == .preview {
                draftPreview
            } else {
                LinoIEditor(
                    title: "正文编辑",
                    text: chapterBinding(\.draftText),
                    minHeight: 480,
                    placeholder: "可以在这里直接修订正文。"
                )
                .disabled(editor.writingPhase.isActive)
            }

            actionBar
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
    }

    private var writingControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if editor.writingPhase.isActive {
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
                    .disabled(editor.currentChapter?.status == "finalized")
                }

                Button {
                    showingImport = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(LinoITintButtonStyle())
                .disabled(editor.writingPhase.isActive)
            }

            HStack(spacing: 10) {
                ProgressView(value: progressValue)
                    .tint(LinoTheme.accent)
                Text(progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(LinoTheme.muted)
            }

            if case .revising(let attempt, _) = editor.writingPhase {
                Text("程序校验未通过，Reviser 正在进行第 \(attempt)/2 次修订。修订不会自行增加新剧情。")
                    .font(.caption)
                    .foregroundStyle(LinoTheme.warning)
            } else if editor.currentChapter?.status == "finalized" {
                Text("已完成章节必须先“重新编辑本章”，才能重新生成。")
                    .font(.caption)
                    .foregroundStyle(LinoTheme.muted)
            }
        }
    }

    private var draftPreview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LinoIDraftPreview(text: editor.currentChapter?.draftText ?? "", isStreaming: editor.writingPhase.isActive)
                    .padding(14)
                Color.clear.frame(height: 1).id("draft-bottom")
            }
            .frame(minHeight: 360, maxHeight: 560)
            .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
            .onChange(of: editor.draftCharCount) { _, _ in
                guard editor.writingPhase.isActive else { return }
                withAnimation(.smooth(duration: 0.22)) {
                    proxy.scrollTo("draft-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if editor.currentChapter?.status == "finalized" {
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
                    Label(editor.isAccepting ? "Extractor 提取中" : "接受本章", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(LinoISuccessButtonStyle())
                .disabled(!canAccept)
            }
        }
    }

    private func extractionSection(_ chapter: Chapter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stageHeader(index: "✓", title: "Extractor 结果", subtitle: "接受章节后生成，重新接受会覆盖本章旧提取结果。")
            if !chapter.headline.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    LinoISectionLabel("大事记")
                    Text(chapter.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LinoTheme.ink)
                }
            }
            if !chapter.summary.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    LinoISectionLabel("本章梗概")
                    Text(chapter.summary)
                        .font(.footnote)
                        .foregroundStyle(LinoTheme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
    }

    private func stageHeader(index: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(LinoTheme.accentGradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
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

    private var canAccept: Bool {
        hasDraft && !editor.writingPhase.isActive && !editor.writingPhase.isFailed && !editor.isAccepting
    }

    private var progressValue: Double {
        guard let target = editor.currentChapter?.targetWordCount, target > 0 else { return 0 }
        return min(Double(editor.draftCharCount) / Double(target), 1)
    }

    private var progressLabel: String {
        guard let target = editor.currentChapter?.targetWordCount else { return "\(editor.draftCharCount) 字" }
        return "\(editor.draftCharCount) / \(target) 字"
    }

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

    private func acceptTapped() {
        Task {
            if let result = await editor.accept() {
                workspace.upsert(result.chapter)
                if let book = session.currentBook {
                    await characters.load(bookId: book.id)
                }
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
