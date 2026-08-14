import SwiftUI

struct V2IOSWorldEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var text = ""
    @State private var title = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            V2IOSSheetHeader(title: "世界观", dismiss: dismiss.callAsFunction, trailing: saving ? "保存中" : "保存") { save() }
            TextEditor(text: $text)
                .font(V2DeskType.prose(15.5))
                .lineSpacing(7)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 20).padding(.top, 12)
        }
        .v2IOSPage()
        .onAppear { title = session.currentBook?.title ?? ""; text = session.currentBook?.worldSetting ?? "" }
    }

    private func save() {
        saving = true
        Task { await workspace.saveBook(title: title, world: text); saving = false; dismiss() }
    }
}

struct V2IOSCharactersView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @State private var showingNew = false
    @State private var selected: Character?

    var body: some View {
        NavigationStack {
            List {
                ForEach(characters.characters) { character in
                    Button { selected = character } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(character.name).font(V2DeskType.prose(15.5, weight: .medium))
                                Text(character.events.isEmpty ? "还没有归档记录" : "\(character.events.count) 章有归档记录")
                                    .font(V2DeskType.control(11)).foregroundStyle(Color.secondary)
                            }
                            Spacer(); Text("›").foregroundStyle(Color.secondary)
                        }.padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationDestination(item: $selected) { V2IOSCharacterDetailView(character: $0) }
            .safeAreaInset(edge: .top) {
                V2IOSSheetHeader(title: "人物", dismiss: dismiss.callAsFunction, trailing: "＋ 新增") { showingNew = true }
                    .background(.thinMaterial)
            }
        }
        .v2IOSPage()
        .sheet(isPresented: $showingNew) { V2IOSNewCharacterSheet().presentationDetents([.medium]).presentationCornerRadius(V2DeskMetric.sheetCornerRadius) }
    }
}

private struct V2IOSCharacterDetailView: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var edited: Character
    @State private var showingDelete = false

    init(character: Character) { _edited = State(initialValue: character) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                V2IOSCharacterField(label: "姓名", text: $edited.name, multiline: false)
                V2IOSCharacterField(label: "身份", text: $edited.role, multiline: false)
                V2IOSCharacterField(label: "人物设定", text: $edited.fixedProfile, multiline: true)
                VStack(alignment: .leading, spacing: 9) {
                    V2IOSSectionLabel(title: "整理自正文 · 只读")
                    if edited.events.isEmpty {
                        Text("还没有归档记录").font(V2DeskType.control(12.5)).foregroundStyle(Color.secondary).padding(13).v2IOSPaper(.rail)
                    } else {
                        ForEach(edited.events) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.eventText).font(V2DeskType.prose(14))
                                Text(event.chapterIndex.map { "第 \($0) 章" } ?? "来源章节") .font(V2DeskType.control(11)).foregroundStyle(Color.secondary)
                            }
                            .padding(13).v2IOSPaper(.rail)
                            .overlay { if event.editable == false { V2IOSStripedSurface().opacity(0.24) } }
                        }
                    }
                }
                V2IOSSecondaryButton(title: "删除人物", tone: .danger) { showingDelete = true }
            }
            .padding(20)
        }
        .v2IOSPage()
        .navigationTitle(edited.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("保存") { Task { await characters.update(edited) } } } }
        .confirmationDialog("删除“\(edited.name)”？", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("删除人物", role: .destructive) { Task { await characters.delete(edited) } }
            Button("取消", role: .cancel) {}
        } message: { Text("人物设定和从正文整理出的归档记录都会从这本书移除；章节正文不会改变。") }
    }
}

private struct V2IOSCharacterField: View {
    let label: String
    @Binding var text: String
    let multiline: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            V2IOSSectionLabel(title: label)
            if multiline {
                TextEditor(text: $text).font(V2DeskType.prose(14.5)).frame(minHeight: 110).padding(8).v2IOSPaper()
            } else {
                TextField(label, text: $text).font(V2DeskType.prose(15)).textFieldStyle(.plain).padding(13).v2IOSPaper()
            }
        }
    }
}

private struct V2IOSNewCharacterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var characters: CharactersStore
    @State private var name = ""
    @State private var role = ""
    @State private var profile = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            V2IOSSheetHeader(title: "新增人物", dismiss: dismiss.callAsFunction)
            V2IOSCharacterField(label: "姓名", text: $name, multiline: false)
            V2IOSCharacterField(label: "身份", text: $role, multiline: false)
            V2IOSCharacterField(label: "性格", text: $profile, multiline: true)
            V2IOSPrimaryButton(title: "创建", disabled: name.v2IOSTrimmed.isEmpty) {
                Task {
                    await characters.create(name: name.v2IOSTrimmed)
                    if var created = characters.selected { created.role = role; created.fixedProfile = profile; await characters.update(created) }
                    dismiss()
                }
            }
        }.padding(20).v2IOSPage()
    }
}

struct V2IOSInspirationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @State private var addingID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                V2IOSSheetHeader(title: "找方向", dismiss: dismiss.callAsFunction)
                TextField("本章推进边界（可选）", text: $inspiration.pacingBoundary)
                    .font(V2DeskType.prose(14)).textFieldStyle(.plain).padding(13).v2IOSPaper()
                    .disabled(!canEditChapter)
                if inspiration.isLoading { ProgressView("正在找方向").frame(maxWidth: .infinity, minHeight: 120) }
                if let error = inspiration.errorMessage { Text(error).font(V2DeskType.control(13)).foregroundStyle(Color.red).padding(13).v2IOSPaper(.card) }
                ForEach(inspiration.cards) { card in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(card.body).font(V2DeskType.prose(14.5)).lineSpacing(6)
                        V2IOSSecondaryButton(title: inspiration.adoptedCardIDs.contains(card.id) || addingID == card.id ? "已加入意图" : "加入意图") { add(card) }
                            .disabled(!canEditChapter || inspiration.adoptedCardIDs.contains(card.id) || addingID == card.id)
                    }.padding(14).v2IOSPaper(.manuscriptPaper)
                }
                if inspiration.canUndo(chapterID: editor.currentChapter?.id ?? "", currentBible: editor.currentChapter?.userPrompt ?? "") {
                    V2IOSSecondaryButton(title: "撤销这次加入", tone: .accent) { undo() }
                        .disabled(!canEditChapter)
                }
                V2IOSPrimaryButton(title: inspiration.cards.isEmpty ? "开始找灵感" : "换三个", disabled: inspiration.isLoading || !canEditChapter) {
                    if let chapter = editor.currentChapter { inspiration.generate(for: chapter) }
                }
            }.padding(20)
        }.v2IOSPage()
    }

    private var canEditChapter: Bool { ChapterEditingPolicy.canEdit(editor.currentChapter) }

    private func add(_ card: InspirationCard) {
        guard let chapter = editor.currentChapter else { return }
        guard ChapterEditingPolicy.canEdit(chapter) else { return }
        addingID = card.id
        defer { addingID = nil }
        let before = chapter.userPrompt
        let after = before.v2IOSTrimmed.isEmpty ? card.body : "\(before)\n\n\(card.body)"
        editor.editString(\.userPrompt, value: after)
        inspiration.recordAdoption(card: card, chapterID: chapter.id, before: before, after: after)
    }
    private func undo() {
        guard let chapter = editor.currentChapter else { return }
        guard ChapterEditingPolicy.canEdit(chapter) else { return }
        guard let before = inspiration.consumeUndo(chapterID: chapter.id, currentBible: chapter.userPrompt) else { return }
        editor.editString(\.userPrompt, value: before)
    }
}

struct V2IOSSheetHeader: View {
    let title: String
    let dismiss: () -> Void
    var trailing: String? = nil
    var trailingAction: (() -> Void)? = nil
    var body: some View {
        HStack {
            Text(title).font(V2DeskType.prose(20, weight: .semibold))
            Spacer()
            if let trailing, let trailingAction { Button(trailing, action: trailingAction).font(V2DeskType.control(13, weight: .medium)).frame(minHeight: 44).buttonStyle(.plain) }
            else { Button("取消", action: dismiss).font(V2DeskType.control(13)).frame(minHeight: 44).buttonStyle(.plain) }
        }
    }
}
