import SwiftUI

// MARK: - Sheet router

struct V2MacDeskSheetHost: View {
    let sheet: V2MacDeskSheet
    var currentChapterID: String? = nil

    var body: some View {
        switch sheet {
        case .newBook: V2MacNewBookSheet()
        case .world: V2MacWorldSheet()
        case .people: V2MacPeopleSheet()
        case .inspiration: V2MacInspirationSheet()
        case .settings: V2MacSettingsSheet()
        case .export: V2MacExportSheet(currentChapterID: currentChapterID)
        case .search: V2MacSearchSheet()
        case .projectPackage: V2MacProjectPackageSheet()
        }
    }
}

struct V2MacSheetFrame<Content: View>: View {
    let title: String
    var width: CGFloat = 520
    var dismissDisabled = false
    var hasUnsavedChanges = false
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(V2DeskType.prose(17, weight: .semibold))
                Spacer()
                V2MacDeskIconButton(symbol: "xmark", label: "关闭", action: requestDismiss)
                    .disabled(dismissDisabled)
            }
            .padding(.horizontal, 22).frame(height: 48)
            .background(V2DeskPalette.color(.titleBar, scheme: colorScheme))
            V2MacDeskHairline()
            V2MacDeskToast().padding(.horizontal, 12)
            content
        }
        .frame(width: width)
        .background(V2DeskPalette.color(.card, scheme: colorScheme))
        .interactiveDismissDisabled(dismissDisabled || hasUnsavedChanges)
        .onExitCommand(perform: requestDismiss)
    }

    private func requestDismiss() {
        guard !dismissDisabled else { return }
        if let onDismiss { onDismiss() } else { dismiss() }
    }
}

// MARK: - Book and world

private struct V2MacNewBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @State private var title = ""
    @State private var creating = false
    @State private var showingLeaveConfirmation = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "新建一本", width: 440, dismissDisabled: creating, hasUnsavedChanges: !title.isEmpty, onDismiss: requestDismiss) {
            VStack(alignment: .leading, spacing: 18) {
                V2MacDeskSectionLabel(text: "书名")
                TextField("", text: $title)
                    .textFieldStyle(.plain)
                    .font(V2DeskType.prose(17))
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(V2DeskPalette.color(.strongLine, scheme: colorScheme)).frame(height: 1) }
                    .focused($focused)
                    .disabled(creating)
                    .onSubmit { Task { await create() } }
                Text("世界观可以稍后再写。")
                    .font(V2DeskType.control(12))
                    .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                HStack { Spacer(); Button(creating ? "正在创建" : "创建") { Task { await create() } }.buttonStyle(V2MacDeskButton(kind: .primary)).disabled(creating) }
            }
            .padding(24)
        }
        .onAppear { focused = true }
        .interactiveDismissDisabled(creating || !title.isEmpty)
        .confirmationDialog("放弃新书输入？", isPresented: $showingLeaveConfirmation) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    private func requestDismiss() {
        guard !creating else { return }
        if !title.isEmpty { showingLeaveConfirmation = true } else { dismiss() }
    }

    private func create() async {
        guard !creating, editor.persistLocalDraftIfNeeded() else { return }
        creating = true
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书籍" : title
        let created = await bookshelf.createBook(title: resolvedTitle)
        creating = false
        // A failed create leaves the sheet open with the typed title intact.
        guard let created, session.currentBook?.id == created.id else { return }
        guard V2MacBookNavigation.prepare(editor: editor, workspace: workspace, characters: characters, inspiration: inspiration) else { return }
        dismiss()
    }
}

private struct V2MacWorldSheet: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var bookshelf: BookshelfStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var world = ""
    @State private var loadedID: String?
    @State private var loadedContextID: UUID?
    @State private var originalTitle = ""
    @State private var originalWorld = ""
    @State private var saving = false
    @State private var showingLeaveConfirmation = false
    @State private var submissionID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "世界观", width: 700, dismissDisabled: saving, hasUnsavedChanges: isDirty, onDismiss: requestDismiss) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("书名", text: $title)
                    .textFieldStyle(.plain)
                    .font(V2DeskType.prose(18))
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(V2DeskPalette.color(.line, scheme: colorScheme)).frame(height: 1) }
                TextEditor(text: $world)
                    .scrollContentBackground(.hidden)
                    .font(V2DeskType.prose(15.5))
                    .lineSpacing(10)
                    .frame(minHeight: 430)
                    .padding(12)
                    .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
                    .accessibilityLabel("世界观")
                HStack {
                    Text("一篇长文本；标题和空行由你自己书写。")
                        .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                    Spacer()
                    Button(saving ? "正在保存" : "保存", action: save)
                        .buttonStyle(V2MacDeskButton(kind: .primary)).disabled(saving || !isDirty || !ownsBook)
                }
            }
            .padding(22)
            .disabled(saving)
        }
        .onAppear { sync() }
        .onDisappear { submissionID = nil }
        .confirmationDialog("放弃世界观修改？", isPresented: $showingLeaveConfirmation) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("未保存的书名和世界观将被放弃。") }
    }

    private var isDirty: Bool { title != originalTitle || world != originalWorld }
    private var ownsBook: Bool { session.currentBook?.id == loadedID && session.bookContextID == loadedContextID }

    private func requestDismiss() {
        guard !saving else { return }
        if isDirty { showingLeaveConfirmation = true } else { dismiss() }
    }

    private func sync() {
        guard let book = session.currentBook, book.id != loadedID else { return }
        loadedID = book.id; loadedContextID = session.bookContextID
        title = book.title; world = book.worldSetting
        originalTitle = title; originalWorld = world
    }
    private func save() {
        guard !saving, ownsBook else { return }
        let submittedTitle = title
        let submittedWorld = world
        let id = UUID()
        submissionID = id
        saving = true
        Task {
            guard submissionID == id, ownsBook else { saving = false; submissionID = nil; return }
            let didSave = await workspace.saveBook(title: submittedTitle, world: submittedWorld)
            guard submissionID == id else { return }
            saving = false
            submissionID = nil
            guard didSave, ownsBook else { return }
            originalTitle = submittedTitle; originalWorld = submittedWorld
            if let book = session.currentBook { bookshelf.upsert(book) }
            if !isDirty { dismiss() }
        }
    }
}

// MARK: - People

private struct V2MacPeopleSheet: View {
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var newPerson = false
    @State private var deleteTarget: Character?
    @State private var drafts = V2MacCharacterDrafts()
    @State private var deleting = false
    @State private var showingLeaveConfirmation = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "人物", width: 760, dismissDisabled: isBusy, hasUnsavedChanges: drafts.hasUnsavedChanges, onDismiss: requestDismiss) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(characters.characters) { person in
                                Button {
                                    characters.selectedCharacterId = person.id
                                } label: {
                                    HStack(spacing: 9) {
                                        V2DeskStatusMark(marker: person.events.isEmpty ? .notYetHappened : .confirmed, diameter: 7)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(person.name.isEmpty ? "未命名" : person.name).font(V2DeskType.prose(13.5))
                                            Text(person.events.isEmpty ? "还没有归档记录" : "\(person.events.count) 章有归档记录")
                                                .font(V2DeskType.control(10.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 13).frame(minHeight: 48)
                                    .background(characters.selectedCharacterId == person.id ? V2DeskPalette.color(.desk, scheme: colorScheme) : .clear)
                                }.buttonStyle(.plain).disabled(isBusy)
                                V2MacDeskHairline()
                            }
                        }
                    }
                    Button("新增人物") { newPerson = true }
                        .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true)).padding(12).disabled(isBusy)
                }
                .frame(width: 236)
                .background(V2DeskPalette.color(.rail, scheme: colorScheme))
                V2MacDeskHairline().frame(width: 1, height: nil)
                if let person = characters.selected, let bookID = session.currentBook?.id {
                    V2MacPersonEditor(person: person, bookID: bookID, drafts: $drafts, delete: { deleteTarget = person })
                        .disabled(deleting)
                } else {
                    V2MacDeskEmptyPrompt(title: "添加第一个人物", actionTitle: "新增人物") { newPerson = true }
                }
            }
            .frame(height: 560)
        }
        .sheet(isPresented: $newPerson) { V2MacNewPersonSheet() }
        .confirmationDialog("删除这个人物？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除人物", role: .destructive, action: deletePerson)
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { Text("这个人物的固定设定和归档记录都会从本书移除。") }
        .confirmationDialog("放弃人物修改？", isPresented: $showingLeaveConfirmation) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("这次编辑中尚未保存的人物设定将被放弃。") }
    }

    private var isBusy: Bool { drafts.isSaving || deleting }

    private func requestDismiss() {
        guard !isBusy else { return }
        if drafts.hasUnsavedChanges { showingLeaveConfirmation = true } else { dismiss() }
    }

    private func deletePerson() {
        guard !isBusy, let person = deleteTarget, let bookID = session.currentBook?.id else { return }
        let context = session.bookContextID
        deleteTarget = nil
        deleting = true
        Task {
            let deleted = await characters.delete(person)
            deleting = false
            if deleted, session.currentBook?.id == bookID, session.bookContextID == context {
                drafts.remove(.init(bookID: bookID, characterID: person.id))
            }
        }
    }
}

private struct V2MacPersonEditor: View {
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var session: AppSession
    let person: Character
    let bookID: String
    @Binding var drafts: V2MacCharacterDrafts
    let delete: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            V2MacDeskSectionLabel(text: "我设定的")
            TextField("姓名", text: field(\.name)).textFieldStyle(.plain).font(V2DeskType.prose(17)).accessibilityLabel("人物姓名")
                .overlay(alignment: .bottom) { Rectangle().fill(V2DeskPalette.color(.line, scheme: colorScheme)).frame(height: 1) }
            TextField("身份", text: field(\.role)).textFieldStyle(.plain).font(V2DeskType.control(13)).accessibilityLabel("人物身份")
                .overlay(alignment: .bottom) { Rectangle().fill(V2DeskPalette.color(.line, scheme: colorScheme)).frame(height: 1) }
            TextEditor(text: field(\.fixedProfile)).scrollContentBackground(.hidden).font(V2DeskType.prose(13)).frame(minHeight: 120).padding(7).accessibilityLabel("人物设定")
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
            HStack { Spacer(); Button(drafts.isSaving ? "正在保存" : "保存设定", action: save).buttonStyle(V2MacDeskButton(kind: .primary, compact: true)) }
            V2MacDeskHairline()
            V2MacDeskSectionLabel(text: "整理自正文 · 只读")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if person.events.isEmpty {
                        Text("还没有归档记录。")
                            .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                    }
                    ForEach(person.events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.eventText).font(V2DeskType.prose(12)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                            Text(event.chapterIndex.map { "第 \($0) 章" } ?? "来源章节")
                                .font(V2DeskType.control(10)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                        }
                        .padding(9).background(V2DeskPalette.color(.rail, scheme: colorScheme)).overlay { if event.editable == false { V2MacDeskStripeBackground().opacity(0.25).clipShape(RoundedRectangle(cornerRadius: 6)) } }
                    }
                }
            }
            Spacer()
            Button("删除人物", action: delete).buttonStyle(V2MacDeskButton(kind: .danger, compact: true))
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .disabled(drafts.isSaving)
        .onAppear { sync() }.onChange(of: key) { _, _ in sync() }
        .onChange(of: person) { _, _ in sync() }
    }
    private var key: V2MacCharacterDrafts.Key { .init(bookID: bookID, characterID: person.id) }
    private func field(_ keyPath: WritableKeyPath<Character, String>) -> Binding<String> {
        Binding(get: { drafts.value(for: key, fallback: person)[keyPath: keyPath] },
                set: { drafts.edit(key, fallback: person, field: keyPath, value: $0) })
    }
    private func sync() { drafts.load(person, for: key) }
    private func save() {
        guard session.currentBook?.id == bookID, let submission = drafts.beginSubmit(key, fallback: person) else { return }
        let context = session.bookContextID
        Task {
            guard session.currentBook?.id == bookID, session.bookContextID == context else {
                drafts.complete(submission, succeeded: false)
                return
            }
            let saved = await characters.update(submission.character)
            drafts.complete(submission, succeeded: saved && session.currentBook?.id == bookID && session.bookContextID == context)
        }
    }
}

private struct V2MacNewPersonSheet: View {
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var traits = ""
    @State private var creating = false
    @State private var showingLeaveConfirmation = false
    @State private var submissionID: UUID?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        V2MacSheetFrame(title: "新增人物", width: 480, dismissDisabled: creating, hasUnsavedChanges: isDirty, onDismiss: requestDismiss) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("姓名", text: $name).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).focused($focused)
                TextField("身份", text: $role).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                TextField("性格", text: $traits).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                HStack { Spacer(); Button(creating ? "正在创建" : "创建", action: create).buttonStyle(V2MacDeskButton(kind: .primary)).disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(22).disabled(creating)
        }.onAppear { focused = true }
        .onDisappear { submissionID = nil }
        .confirmationDialog("放弃新增人物？", isPresented: $showingLeaveConfirmation) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("输入的姓名、身份和设定不会保存。") }
    }
    private var isDirty: Bool { !name.isEmpty || !role.isEmpty || !traits.isEmpty }
    private func requestDismiss() {
        guard !creating else { return }
        if isDirty { showingLeaveConfirmation = true } else { dismiss() }
    }
    private func create() {
        guard !creating, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let bookID = session.currentBook?.id else { return }
        let context = session.bookContextID
        let submittedName = name, submittedRole = role, submittedTraits = traits
        let id = UUID()
        submissionID = id
        creating = true
        Task {
            guard submissionID == id, session.currentBook?.id == bookID, session.bookContextID == context else {
                creating = false; submissionID = nil; return
            }
            let created = await characters.create(name: submittedName, role: submittedRole, fixedProfile: submittedTraits)
            guard submissionID == id else { return }
            creating = false
            submissionID = nil
            guard created != nil, session.currentBook?.id == bookID, session.bookContextID == context else { return }
            guard name == submittedName, role == submittedRole, traits == submittedTraits else { return }
            dismiss()
        }
    }
}

// MARK: - Inspiration

private struct V2MacInspirationSheet: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @Environment(\.colorScheme) private var colorScheme
    private var canEditChapter: Bool { ChapterEditingPolicy.canEdit(editor.currentChapter) }
    private var isStale: Bool { inspiration.isStale(comparedTo: editor.currentChapter) }

    var body: some View {
        V2MacSheetFrame(title: "找方向", width: 760) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("本章推进边界（可选）", text: $inspiration.pacingBoundary)
                    .textFieldStyle(.plain).font(V2DeskType.control(12.5)).padding(10)
                    .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
                    .disabled(!canEditChapter)
                HStack {
                    Text(inspiration.isLoading ? "正在找方向" : "")
                        .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                    Spacer()
                    Button(isStale ? "按最新内容重想" : (inspiration.cards.isEmpty ? "开始找灵感" : "换三个")) { generate() }
                        .buttonStyle(V2MacDeskButton(kind: .primary)).disabled(!canEditChapter || inspiration.isLoading)
                }
                if isStale, !inspiration.cards.isEmpty {
                    Text("这些方向基于修改前内容；仍可主动采用，也可按最新内容重想。")
                        .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.taskWarning, scheme: colorScheme))
                }
                if let error = inspiration.errorMessage {
                    Text(error).font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.danger, scheme: colorScheme))
                }
                if inspiration.isLoading { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40) }
                else if !inspiration.cards.isEmpty { cards }
                else { Text("从已有意图、人物和有效历史出发，给这一章三条不同方向。")
                    .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme)).padding(.vertical, 24) }
            }.padding(22)
        }
    }
    private var cards: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(inspiration.cards) { card in
                VStack(alignment: .leading, spacing: 10) {
                    Text(card.body).font(V2DeskType.prose(13.5)).lineSpacing(6).foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(inspiration.adoptedCardIDs.contains(card.id) ? "已写入意图" : (isStale ? "仍用这个" : "用这个")) { add(card) }
                        .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
                        .disabled(inspiration.adoptedCardIDs.contains(card.id) || !canEditChapter)
                }
                .padding(14).frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 8).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
            }
        }
    }
    private func generate() { guard let chapter = editor.currentChapter, canEditChapter else { return }; inspiration.generate(for: chapter) }
    private func add(_ card: InspirationCard) {
        guard let chapter = editor.currentChapter, canEditChapter else { return }
        let before = chapter.userPrompt
        let after = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.body : before + "\n\n" + card.body
        editor.editString(\.userPrompt, value: after)
        inspiration.recordAdoption(card: card, chapterID: chapter.id, before: before, after: after)
    }
}

// MARK: - Settings and personas

@MainActor
private final class V2MacSettingsEditingState: ObservableObject {
    @Published private(set) var dirtyForms: Set<String> = []
    @Published private(set) var busyForms: Set<String> = []
    var isDirty: Bool { !dirtyForms.isEmpty }
    var isBusy: Bool { !busyForms.isEmpty }
    func update(_ id: String, dirty: Bool, busy: Bool) {
        if dirty { dirtyForms.insert(id) } else { dirtyForms.remove(id) }
        if busy { busyForms.insert(id) } else { busyForms.remove(id) }
    }
}

private struct V2MacSettingsSheet: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var session: AppSession
    @State private var section: V2MacSettingsSection = .personas
    @State private var personaDraft = V2MacPersonaDraft()
    @State private var showingLeaveConfirmation = false
    @StateObject private var editing = V2MacSettingsEditingState()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private enum V2MacSettingsSection: String, CaseIterable, Identifiable {
        case connection, model, personas, writing, appearance, notifications
        var id: String { rawValue }
        var title: String { switch self { case .connection: "连接"; case .model: "模型"; case .personas: "人格"; case .writing: "写作"; case .appearance: "外观"; case .notifications: "通知" } }
    }

    var body: some View {
        V2MacSheetFrame(title: "设置", width: 800, dismissDisabled: editing.isBusy || personaDraft.isSaving, hasUnsavedChanges: editing.isDirty || personaDraft.hasUnsavedChanges, onDismiss: requestDismiss) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(V2MacSettingsSection.allCases) { item in
                        Button(item.title) { section = item }
                            .buttonStyle(.plain)
                            .font(V2DeskType.control(12.5, weight: section == item ? .medium : .regular))
                            .foregroundStyle(section == item ? V2DeskPalette.color(.ink, scheme: colorScheme) : V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(.horizontal, 15)
                            .background(section == item ? V2DeskPalette.color(.desk, scheme: colorScheme) : .clear)
                            .disabled(editing.isBusy || personaDraft.isSaving)
                    }
                    Spacer()
                }
                .padding(.top, 14).frame(width: 168)
                .background(V2DeskPalette.color(.rail, scheme: colorScheme))
                V2MacDeskHairline().frame(width: 1, height: nil)
                ZStack(alignment: .topLeading) {
                    ForEach(V2MacSettingsSection.allCases.filter { $0 != .notifications }) { item in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                switch item {
                                case .connection: V2MacConnectionSettings()
                                case .model: V2MacModelSettings()
                                case .personas: V2MacPersonaSettings(draft: $personaDraft)
                                case .writing: V2MacWritingSettings()
                                case .appearance: V2MacAppearanceSettings()
                                case .notifications: EmptyView()
                                }
                            }.padding(22)
                        }
                        .opacity(section == item ? 1 : 0)
                        .allowsHitTesting(section == item)
                        .accessibilityHidden(section != item)
                    }
                    NoticeHistoryList()
                        .opacity(section == .notifications ? 1 : 0)
                        .allowsHitTesting(section == .notifications)
                        .accessibilityHidden(section != .notifications)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 560)
        }
        .environmentObject(editing)
        .confirmationDialog("放弃设置修改？", isPresented: $showingLeaveConfirmation) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("尚未保存的设置和各角色人格输入将被放弃。") }
        .task(id: session.currentBook?.id) {
            await agents.load()
            if let id = session.currentBook?.id {
                _ = await agents.loadBookPersonas(bookID: id)
            }
        }
    }

    private func requestDismiss() {
        guard !editing.isBusy, !personaDraft.isSaving else { return }
        if editing.isDirty || personaDraft.hasUnsavedChanges { showingLeaveConfirmation = true } else { dismiss() }
    }
}

private struct V2MacConnectionSettings: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var editing: V2MacSettingsEditingState
    @State private var endpoint = ""
    @State private var token = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var originalEndpoint = ""
    @State private var originalToken = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            V2MacDeskSectionLabel(text: "后端连接")
            Text("连接属于本机基础设施，不是模型 Profile。修改后仅在你明确保存时写入本机 Keychain。")
                .font(V2DeskType.control(12))
                .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            V2MacProfileField("后端地址", text: $endpoint)
                .font(.system(size: 12.5, design: .monospaced))
            SecureField("访问密钥", text: $token)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(8)
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
            HStack {
                Text(saving ? "正在重新连接" : "")
                    .font(V2DeskType.control(11.5))
                    .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                Spacer()
                Button(saving ? "正在保存" : "保存并重新加载书架") { Task { await save() } }
                    .buttonStyle(V2MacDeskButton(kind: .primary))
                    .disabled(saving || !canSave)
            }
        }
        .disabled(saving)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            endpoint = session.baseURL
            token = session.token
            originalEndpoint = endpoint
            originalToken = token
            updateEditingState()
        }
        .onChange(of: endpoint) { _, _ in updateEditingState() }
        .onChange(of: token) { _, _ in updateEditingState() }
    }

    private var canSave: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        guard !saving else { return }
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: normalizedEndpoint)?.scheme != nil else {
            session.notices.publish("后端地址需要包含 http(s)://")
            return
        }
        saving = true
        updateEditingState()
        session.baseURL = normalizedEndpoint
        session.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        session.saveConnection()
        originalEndpoint = endpoint
        originalToken = token
        await bookshelf.load()
        saving = false
        updateEditingState()
    }

    private func updateEditingState() {
        editing.update("connection", dirty: loaded && (endpoint != originalEndpoint || token != originalToken), busy: saving)
    }
}

private struct V2MacModelSettings: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var addProfile = false
    @State private var editingProfile: LLMProfile?
    @Environment(\.colorScheme) private var colorScheme
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            V2MacDeskSectionLabel(text: "模型")
            Text("下方是各角色的全局模型配置。打开一本书后，可为该书单独设置。")
                .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            HStack { Text("PROFILE").font(V2DeskType.control(11, weight: .medium)); Spacer(); Button("新增 Profile") { addProfile = true }.buttonStyle(V2MacDeskButton(kind: .secondary, compact: true)) }
            if agents.profiles.isEmpty {
                Text("还没有可用的模型。")
                    .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            } else {
                ForEach(agents.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(V2DeskType.control(12.5, weight: .medium))
                            Text("\(profile.modelName) · \(profile.baseURL)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme)).lineLimit(1)
                        }
                        Spacer()
                        Button("编辑") { editingProfile = profile }
                            .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
                    }.padding(10).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
                }
            }
            V2MacDeskHairline()
            ForEach(roles, id: \.self) { role in V2MacBindingRow(role: role) }
            if let bookID = session.currentBook?.id {
                V2MacDeskHairline()
                V2MacBookModelSettings(bookID: bookID)
                    .id(bookID)
            }
        }
        .sheet(isPresented: $addProfile) { V2MacProfileSheet(profile: nil) }
        .sheet(item: $editingProfile) { V2MacProfileSheet(profile: $0) }
    }
}

private struct V2MacBindingRow: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    let role: String
    @Environment(\.colorScheme) private var colorScheme
    private var binding: AgentBinding? { agents.bindings.first { $0.agentRole == role } }
    private var selected: Binding<String> {
        Binding(get: { binding?.llmProfileId ?? "" }, set: { value in Task { await agents.bind(role: role, profileId: value.isEmpty ? nil : value) } })
    }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.v2AgentLabel).font(V2DeskType.control(12.5, weight: .medium))
                if role == "extractor" || role == "inspiration_creator" { Text("深度思考 · 不可用").font(V2DeskType.control(10.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme)) }
            }
            Spacer()
            Picker(role, selection: selected) {
                Text("未绑定").tag("")
                ForEach(agents.profiles) { profile in Text(profile.name).tag(profile.id) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 150)
        }
        .padding(.vertical, 5)
    }
}

private struct V2MacBookModelSettings: View {
    let bookID: String
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var sync: ClientSyncStore
    @EnvironmentObject private var editing: V2MacSettingsEditingState
    @State private var selectedRole = "writer"
    @State private var draft = BookModelSettingsDraft(role: "writer")
    @State private var retainedDrafts: [String: BookModelSettingsDraft] = [:]
    @State private var baselines: [String: BookModelSettingsDraft] = [:]
    @State private var saving = false
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var confirmRestore = false
    @Environment(\.colorScheme) private var colorScheme
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]

    private var row: BookAgentModelBinding? {
        guard session.currentBook?.id == bookID, agents.bookModelBindingsBookID == bookID else { return nil }
        return agents.bookModelBindings.first { $0.agentRole == selectedRole }
    }
    private var selectedProfile: Binding<String> {
        Binding(get: { draft.profileID }, set: { draft.selectProfile($0, profiles: agents.profiles, row: row) })
    }
    private var thinking: Binding<Bool> {
        Binding(get: { draft.thinkingEnabled }, set: { draft.thinking = $0 })
    }
    private var temperature: Binding<Double> {
        Binding(get: { draft.temperature ?? 1 }, set: { draft.temperature = $0 })
    }
    private var effectiveName: String {
        guard let id = row?.effectiveBinding?.llmProfileId else { return "未绑定" }
        guard let profile = agents.profiles.first(where: { $0.id == id }) else { return "模型资料未载入" }
        return "\(profile.name) · \(profile.modelName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            V2MacDeskSectionLabel(text: "本书模型覆盖")
            Text("缺省时完整跟随全局；这里保存的是一整份本书配置，而不是字段拼接。")
                .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            if isLoading {
                ProgressView("正在读取本书模型")
            } else if loadFailed || row == nil {
                Text("本书模型配置未能载入。")
                    .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                Button("重新加载") { Task { await loadBindings() } }
                    .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
            } else {
                bindingControls
            }
        }
        .task { await loadBindings() }
        .onChange(of: selectedRole) { oldRole, _ in retainedDrafts[oldRole] = draft; loadDraft() }
        .onChange(of: draftInput) { _, _ in
            if draft.role == selectedRole { retainedDrafts[selectedRole] = draft; updateEditingState() }
        }
        .onChange(of: agents.profiles) { _, _ in draft.refreshCapabilities(profiles: agents.profiles, row: row) }
        .confirmationDialog("恢复跟随全局？", isPresented: $confirmRestore) {
            Button("恢复跟随全局", role: .destructive) { Task { await restore() } }
            Button("取消", role: .cancel) {}
        } message: { Text("本书的完整模型覆盖会移除；以后启动的任务重新使用全局配置。") }
    }

    private var bindingControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Picker("角色", selection: $selectedRole) { ForEach(roles, id: \.self) { Text($0.v2AgentLabel).tag($0) } }
                .pickerStyle(.segmented).disabled(saving)
            HStack {
                Text(row?.source == "book" ? "本书覆盖" : "跟随全局").font(V2DeskType.control(11.5, weight: .medium))
                Spacer()
                Text("实际：\(effectiveName)").font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme)).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 10) {
                Picker("模型", selection: selectedProfile) {
                    Text("请选择模型").tag("")
                    ForEach(agents.profiles) { profile in Text("\(profile.name) · \(profile.modelName)").tag(profile.id) }
                }
                Toggle("深度思考", isOn: thinking).disabled(!draft.thinkingAdjustable)
                if let explanation = draft.thinkingExplanation { Text(explanation).font(.footnote).foregroundStyle(.secondary) }
                if !draft.effortLevels.isEmpty {
                    Picker("思考强度", selection: $draft.effort) {
                        Text("模型默认").tag("")
                        ForEach(draft.effortLevels, id: \.self) { Text($0).tag($0) }
                    }.disabled(!draft.effortAdjustable)
                }
                HStack(spacing: 10) {
                    Text("温度 " + (draft.temperatureAdjustable ? draft.temperature.map { String(format: "%.2f", $0) } ?? "模型默认" : "不生效"))
                        .font(V2DeskType.control(11.5))
                    Slider(value: temperature, in: 0...2, step: 0.05).disabled(!draft.temperatureAdjustable)
                }
                if let explanation = draft.temperatureExplanation { Text(explanation).font(.footnote).foregroundStyle(.secondary) }
                if draft.temperatureAdjustable && draft.temperature != nil {
                    Button("温度使用模型默认") { draft.temperature = nil }.buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
                }
                if let reason = draft.blockingReason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
            }.disabled(saving)
            if !sync.networkActionsAvailable { V2DeskOfflineExplanation() }
            HStack {
                if row?.source == "book" {
                    Button("恢复跟随全局") { confirmRestore = true }.buttonStyle(V2MacDeskButton(kind: .danger, compact: true)).disabled(saving || !sync.networkActionsAvailable)
                }
                Spacer()
                Button(saving ? "正在保存" : "保存本书覆盖") { Task { await save() } }
                    .buttonStyle(V2MacDeskButton(kind: .primary)).disabled(saving || draft.payload == nil || !sync.networkActionsAvailable)
            }
        }
    }

    private func loadBindings() async {
        isLoading = true
        loadFailed = false
        let loaded = await agents.loadBookModelBindings(bookID: bookID)
        guard !Task.isCancelled else { return }
        loadFailed = !loaded
        if loaded { loadDraft() }
        isLoading = false
    }

    private func loadDraft(force: Bool = false) {
        let fresh = BookModelSettingsDraft(role: selectedRole, row: row, profiles: agents.profiles)
        if !force, let retained = retainedDrafts[selectedRole], let baseline = baselines[selectedRole], differs(retained, from: baseline) {
            draft = retained
            draft.refreshCapabilities(profiles: agents.profiles, row: row)
        } else {
            draft = fresh
            baselines[selectedRole] = fresh
        }
        retainedDrafts[selectedRole] = draft
        updateEditingState()
    }

    private func save() async {
        guard !saving, session.currentBook?.id == bookID, row != nil, let binding = draft.payload else { return }
        let role = selectedRole
        saving = true
        updateEditingState()
        if await agents.saveBookModelBinding(bookID: bookID, role: role, binding: binding) {
            loadDraft(force: true)
            session.notices.publish("本书模型设置已保存。")
        }
        saving = false
        updateEditingState()
    }

    private func restore() async {
        guard !saving, session.currentBook?.id == bookID, row != nil else { return }
        saving = true
        updateEditingState()
        if await agents.clearBookModelBinding(bookID: bookID, role: selectedRole) { loadDraft(force: true) }
        saving = false
        updateEditingState()
    }

    private func updateEditingState() {
        let isDirty = retainedDrafts.contains { role, value in
            guard let baseline = baselines[role] else { return false }
            return differs(value, from: baseline)
        }
        editing.update("book-model-\(bookID)", dirty: isDirty, busy: saving)
    }

    private func differs(_ value: BookModelSettingsDraft, from baseline: BookModelSettingsDraft) -> Bool {
        value.profileID != baseline.profileID || value.thinking != baseline.thinking
            || value.effort != baseline.effort || value.temperature != baseline.temperature
    }

    private var draftInput: [String] {
        [draft.profileID, draft.thinking.map { String($0) } ?? "default",
         draft.effort, draft.temperature.map { String($0) } ?? "default"]
    }
}

private struct V2MacProfileSheet: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @Environment(\.dismiss) private var dismiss
    let profile: LLMProfile?
    @State private var name: String
    @State private var endpoint: String
    @State private var model: String
    // Secrets live only in this form, and are never read from the server.
    @State private var key = ""
    @State private var saving = false
    @State private var showingLeaveConfirmation = false
    @Environment(\.colorScheme) private var colorScheme

    init(profile: LLMProfile?) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _endpoint = State(initialValue: profile?.baseURL ?? "")
        _model = State(initialValue: profile?.modelName ?? "")
    }

    private var canSave: Bool {
        ![name, endpoint, model].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (profile != nil || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var isDirty: Bool {
        name != (profile?.name ?? "") || endpoint != (profile?.baseURL ?? "")
            || model != (profile?.modelName ?? "") || !key.isEmpty
    }

    var body: some View {
        V2MacSheetFrame(title: profile == nil ? "新增 Profile" : "编辑 Profile", width: 480, dismissDisabled: saving, hasUnsavedChanges: isDirty, onDismiss: requestDismiss) {
            VStack(alignment: .leading, spacing: 10) {
                V2MacProfileField("名称", text: $name)
                V2MacProfileField("Base URL", text: $endpoint)
                SecureField(profile == nil ? "API Key" : "更换 API Key（留空保留）", text: $key).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                V2MacProfileField("模型名称", text: $model)
                if profile != nil {
                    Text("留空保留现有密钥；输入新密钥后更新当前配置，角色绑定继续沿用。")
                        .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                }
                HStack {
                    if saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(saving ? "正在保存" : (profile == nil ? "创建" : "保存")) { Task { await save() } }
                        .buttonStyle(V2MacDeskButton(kind: .primary)).disabled(!canSave || saving)
                }
            }.padding(22)
                .disabled(saving)
        }
        .interactiveDismissDisabled(saving || isDirty)
        .confirmationDialog("放弃 Profile 修改？", isPresented: $showingLeaveConfirmation) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("未保存的模型资料和本次输入的密钥将被放弃。") }
    }

    private func requestDismiss() {
        guard !saving else { return }
        if isDirty { showingLeaveConfirmation = true } else { dismiss() }
    }

    private func save() async {
        guard canSave, !saving else { return }
        saving = true
        defer { saving = false }
        let saved: Bool
        if var value = profile {
            value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            value.baseURL = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            value.modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
            saved = await agents.updateProfile(value, apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : key)
        } else {
            saved = await agents.createProfile(name: name, baseURL: endpoint, apiKey: key, model: model)
        }
        if saved { dismiss() }
    }
}

private struct V2MacProfileField: View {
    let label: String; @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme
    init(_ label: String, text: Binding<String>) { self.label = label; _text = text }
    var body: some View { TextField(label, text: $text).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)) }
}

private struct V2MacPersonaSettings: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var session: AppSession
    @State private var selectedRole = "writer"
    @State private var bookMode = false
    @State private var bookID: String?
    @Binding var draft: V2MacPersonaDraft
    @State private var initialized = false
    @State private var resetBookConfirmation = false
    @Environment(\.colorScheme) private var colorScheme
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]
    private var bookPersona: BookAgentPersona? {
        guard bookID != nil, agents.bookPersonasBookID == bookID else { return nil }
        return agents.bookPersonas.first { $0.agentRole == selectedRole }
    }
    private var globalPersona: AgentPersona? { agents.personas.first { $0.agentRole == selectedRole } }
    private var selectedContext: V2MacPersonaDraft.Context? {
        if bookMode {
            guard let bookID else { return nil }
            return .init(role: selectedRole, scope: .book(bookID))
        }
        return .init(role: selectedRole, scope: .global)
    }
    private var currentContext: V2MacPersonaDraft.Context? {
        guard !bookMode || (bookID != nil && session.currentBook?.id == bookID && agents.bookPersonasBookID == bookID) else { return nil }
        return selectedContext
    }
    private var sourceText: String? { bookMode ? bookPersona?.effectivePersona : globalPersona?.editablePersona }
    private var draftText: Binding<String> { Binding(get: { draft.text }, set: { draft.edit($0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            V2MacDeskSectionLabel(text: "人格")
            Text("五个角色可继承全局人格，或只为当前书覆盖。模型与程序协议不在这里改变。")
                .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            Picker("角色", selection: $selectedRole) { ForEach(roles, id: \.self) { Text($0.v2AgentLabel).tag($0) } }
                .pickerStyle(.segmented)
                .disabled(draft.isSaving)
            Picker("范围", selection: $bookMode) {
                Text("本书人格").tag(true).disabled(session.currentBook == nil)
                Text("全局人格").tag(false)
            }
                .pickerStyle(.segmented)
                .disabled(draft.isSaving)
            Text(bookMode ? (bookPersona?.source == "book" ? "当前书正在使用自定义人格" : "当前书跟随全局人格") : "全局人格会影响之后启动的所有任务")
                .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            if bookMode, currentContext == nil {
                Text("当前书已变化，输入仍保留。请重新选择范围后保存。")
                    .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.danger, scheme: colorScheme))
            }
            TextEditor(text: draftText).scrollContentBackground(.hidden).font(V2DeskType.prose(13)).frame(minHeight: 220).padding(8)
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
                .disabled(draft.isSaving)
            HStack {
                if bookMode, bookPersona?.source == "book" {
                    Button("恢复跟随全局") { resetBookConfirmation = true }.buttonStyle(V2MacDeskButton(kind: .danger, compact: true))
                        .disabled(!draft.canSubmit(in: currentContext, requiresText: false))
                }
                if draft.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(draft.isSaving ? "正在保存" : "保存人格") { Task { await save() } }.buttonStyle(V2MacDeskButton(kind: .primary))
                    .disabled(!draft.canSubmit(in: currentContext))
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            bookMode = session.currentBook != nil
            bookID = session.currentBook?.id
            selectDraft()
        }
        .onChange(of: selectedRole) { _, _ in selectDraft() }
        .onChange(of: bookMode) { _, _ in bookID = bookMode ? session.currentBook?.id : nil; selectDraft() }
        .onChange(of: agents.personas) { _, _ in syncDraft() }
        .onChange(of: agents.bookPersonas) { _, _ in syncDraft() }
        .onChange(of: agents.bookPersonasBookID) { _, _ in syncDraft() }
        .onChange(of: session.currentBook?.id) { _, id in
            guard !draft.isEdited, !draft.isSaving, bookMode else { return }
            bookID = id
            if id == nil { bookMode = false }
            selectDraft()
        }
        .confirmationDialog("恢复跟随全局？", isPresented: $resetBookConfirmation) {
            Button("恢复跟随全局", role: .destructive) { Task { await resetBook() } }
            Button("取消", role: .cancel) {}
        } message: { Text("本书对 \(selectedRole.v2AgentLabel) 的覆盖会移除；之后的新任务使用当前全局人格。") }
    }
    private func selectDraft() {
        guard let context = selectedContext else { return }
        draft.select(context)
        syncDraft()
    }
    private func syncDraft() {
        guard let context = currentContext else { return }
        draft.load(sourceText, for: context)
    }
    private func save() async {
        guard let submission = draft.beginSubmit(in: currentContext) else { return }
        let saved: Bool
        switch submission.context.scope {
        case .book(let id):
            saved = await agents.saveBookPersona(bookID: id, role: submission.context.role, editablePersona: submission.text)
        case .global:
            if var persona = globalPersona {
                persona.editablePersona = submission.text
                saved = await agents.savePersona(persona)
            } else { saved = false }
        }
        draft.complete(submission, succeeded: saved, currentContext: currentContext, savedValue: sourceText)
    }
    private func resetBook() async {
        guard let submission = draft.beginSubmit(in: currentContext, requiresText: false) else { return }
        guard case .book(let id) = submission.context.scope else {
            draft.complete(submission, succeeded: false, currentContext: currentContext, savedValue: nil)
            return
        }
        let saved = await agents.resetBookPersona(bookID: id, role: submission.context.role)
        draft.complete(submission, succeeded: saved, currentContext: currentContext, savedValue: sourceText)
    }
}

private struct V2MacWritingSettings: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            V2MacDeskSectionLabel(text: "写作")
            Text("正文完成条件由后端强制；这里不提供可调节的长度选项。")
                .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            Text("正文生成、复查与接受的实际状态始终以当前章节和服务器任务为准。")
                .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
        }
    }
}

private struct V2MacAppearanceSettings: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            V2MacDeskSectionLabel(text: "外观")
            Text("外观跟随系统。减少动态效果时，状态仍通过形状和文案表达。")
                .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
        }
    }
}

// MARK: - Export and reader

private struct V2MacExportSheet: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @Environment(\.dismiss) private var dismiss
    let currentChapterID: String?
    @State private var scope: ExportScope = .accepted
    @State private var format: ExportFormat = .plainText
    @State private var separate = false
    @State private var includeWorld = true
    @State private var includeCharacters = true
    @State private var exporting = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        V2MacSheetFrame(title: "导出正文", width: 520, dismissDisabled: exporting) {
            VStack(alignment: .leading, spacing: 15) {
                V2MacDeskSectionLabel(text: "范围")
                Picker("范围", selection: $scope) {
                    Text("已接受的章节").tag(ExportScope.accepted)
                    Text("全部章节").tag(ExportScope.all)
                    Text("本章").tag(ExportScope.current)
                }.pickerStyle(.segmented)
                V2MacDeskSectionLabel(text: "格式")
                Picker("格式", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
                Toggle("每章一个文件", isOn: $separate)
                Toggle("附世界观", isOn: $includeWorld)
                Toggle("附人物设定", isOn: $includeCharacters)
                Text("导出前会核对本机修改。未保存的正文可在“更多章节操作”中保存到服务器；待同步或冲突内容请先在同步中心处理。记忆导出保持独立。")
                    .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                HStack {
                    Button("导出记忆") { Task { if let book = session.currentBook { await MacExportSaver.exportMemories(book, session: session) } } }.buttonStyle(V2MacDeskButton(kind: .secondary))
                    Spacer()
                    Button(exporting ? "正在导出" : "导出") { Task { await export() } }.buttonStyle(V2MacDeskButton(kind: .primary)).disabled(exporting || (scope == .current && currentChapterID == nil))
                }
            }.padding(22).disabled(exporting)
        }
    }
    private func export() async {
        guard !exporting, let book = session.currentBook else { return }
        exporting = true
        let succeeded = await MacExportSaver.exportComposed(book: book, session: session, bookshelf: bookshelf, editor: editor, scope: scope, currentChapterID: currentChapterID, format: format, includeWorld: includeWorld, includeCharacters: includeCharacters, separateChapters: separate)
        exporting = false
        if succeeded { dismiss() }
    }
}

private struct V2MacSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var hasSearched = false
    @State private var openingID: String?
    @State private var openingToken = UUID()
    @State private var characterDestinationID: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "搜索", width: 640) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    TextField("搜索书名、章节、正文、人物或有效记忆", text: $query)
                        .textFieldStyle(.plain)
                        .font(V2DeskType.control(13))
                        .padding(9)
                        .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
                        .onSubmit { Task { await search() } }
                    Button(searching ? "正在搜索" : "搜索") { Task { await search() } }
                        .buttonStyle(V2MacDeskButton(kind: .primary))
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching || !sync.networkActionsAvailable)
                }
                Text("只搜索作者当前可见的资料；内部生成过程文本和被拒证据不会进入结果。离线时不能搜索服务器。")
                    .font(V2DeskType.control(11.5))
                    .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                if !sync.networkActionsAvailable { V2DeskOfflineExplanation() }
                V2MacDeskHairline()
                if searching {
                    ProgressView("正在搜索").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hasSearched && results.isEmpty {
                    Text("没有找到结果")
                        .font(V2DeskType.prose(16))
                        .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(results) { result in
                                Button { Task { await open(result) } } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Label(result.title.isEmpty ? resultType(result) : result.title, systemImage: resultSymbol(result))
                                                .font(V2DeskType.control(13, weight: .medium))
                                                .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
                                            Spacer()
                                            if openingID == result.id { ProgressView().controlSize(.small) }
                                        }
                                        if let snippet = result.snippet, !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(snippet).font(V2DeskType.prose(12.5)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme)).lineLimit(3)
                                        }
                                        Text(resultType(result)).font(V2DeskType.control(10.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                .disabled(openingID != nil || !sync.networkActionsAvailable)
                                V2MacDeskHairline()
                            }
                        }
                    }
                }
            }
            .padding(22)
            .frame(minHeight: 420)
        }
        .sheet(isPresented: Binding(
            get: { characterDestinationID != nil },
            set: { if !$0 { characterDestinationID = nil } }
        )) {
            V2MacPeopleSheet()
        }
        .onDisappear { openingToken = UUID() }
    }

    private func search() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !searching else { return }
        searching = true; hasSearched = true
        defer { searching = false }
        do { results = try await session.api.search(query: needle).items }
        catch { results = []; session.notices.publish(error) }
    }

    private func open(_ result: SearchResult) async {
        guard openingID == nil else { return }
        let token = UUID()
        openingToken = token
        let previousContext = session.bookContextID
        var ownedContext = previousContext
        openingID = result.id
        defer { if openingToken == token { openingID = nil } }
        do {
            let book: Book = try await session.api.request("/books/\(result.bookId)")
            guard !Task.isCancelled, openingToken == token, session.bookContextID == previousContext else { return }
            if session.currentBook?.id != book.id {
                guard V2MacBookNavigation.prepare(editor: editor, workspace: workspace, characters: characters, inspiration: inspiration) else { return }
            }
            session.currentBook = book
            let contextID = session.bookContextID
            ownedContext = contextID
            await workspace.load(bookId: book.id)
            guard !Task.isCancelled, openingToken == token, session.bookContextID == contextID, session.currentBook?.id == book.id else { return }
            await characters.load(bookId: book.id)
            guard !Task.isCancelled, openingToken == token, session.bookContextID == contextID, session.currentBook?.id == book.id else { return }
            if let characterID = result.characterId {
                guard characters.characters.contains(where: { $0.id == characterID }) else {
                    throw APIError.http(404, "人物已不存在")
                }
                characters.selectedCharacterId = characterID
                characterDestinationID = characterID
                return
            }
            if let chapterID = result.chapterId,
               let chapter = workspace.chapters.first(where: { $0.id == chapterID }) {
                await editor.load(chapter)
                guard !Task.isCancelled, openingToken == token, session.bookContextID == contextID else { return }
            }
            dismiss()
        } catch {
            guard openingToken == token, session.bookContextID == ownedContext else { return }
            session.notices.publish(error)
        }
    }

    private func resultType(_ result: SearchResult) -> String {
        switch result.type {
        case "book": "书籍"
        case "chapter": "章节"
        case "character": "人物详情"
        case "archive": "有效记忆"
        default: "搜索结果"
        }
    }

    private func resultSymbol(_ result: SearchResult) -> String {
        switch result.type {
        case "book": "books.vertical"
        case "chapter": "doc.text"
        case "character": "person"
        case "archive": "sparkles"
        default: "magnifyingglass"
        }
    }
}

private struct V2MacProjectPackageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var working = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "项目备份与恢复", width: 520, dismissDisabled: working) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    V2MacDeskSectionLabel(text: "完整备份")
                    Text("备份当前书的正文、人物、关联、有效记忆、人格和模型覆盖。项目包不包含访问密钥、全局模型设置或内部生成过程文本。")
                        .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    Text("备份前须保存本书修改、完成同步并处理冲突。正文可在“更多章节操作”中保存到服务器。")
                        .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    HStack { Spacer(); Button(working ? "正在准备" : "备份当前书") { Task { await export() } }.buttonStyle(V2MacDeskButton(kind: .primary)).disabled(working || session.currentBook == nil || !sync.networkActionsAvailable) }
                }
                V2MacDeskHairline()
                VStack(alignment: .leading, spacing: 6) {
                    V2MacDeskSectionLabel(text: "恢复为新书")
                    Text("恢复会先验证格式、清单和文件完整性，随后创建一本新书；绝不覆盖已有书籍。")
                        .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    HStack { Spacer(); Button(working ? "正在恢复" : "选择 .ictwbook 文件") { Task { await importProject() } }.buttonStyle(V2MacDeskButton(kind: .secondary)).disabled(working || !sync.networkActionsAvailable) }
                }
                if !sync.networkActionsAvailable { V2DeskOfflineExplanation() }
                if working { HStack { ProgressView(); Text("正在与服务器核验项目包") }.font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme)) }
            }
            .padding(22)
        }
    }

    private func export() async {
        guard !working else { return }
        working = true
        if let book = session.currentBook { await MacExportSaver.exportProject(book, session: session, bookshelf: bookshelf, editor: editor) }
        working = false
    }

    private func importProject() async {
        guard !working else { return }
        working = true
        await MacExportSaver.importProject(session: session, bookshelf: bookshelf)
        working = false
        dismiss()
    }
}

struct V2MacReaderSheet: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @Binding var selectedChapterID: String?
    let onReadChapter: (ChapterSummary) async -> Void
    let onOpenWriting: (ChapterSummary) async -> Void
    let onStartNewChapter: () -> Void
    @State private var navigationInFlight = false
    @Environment(\.colorScheme) private var colorScheme

    private var currentChapterID: String? {
        editor.currentChapter?.id ?? selectedChapterID
    }

    private var previousChapter: ChapterSummary? {
        guard let currentChapterID else { return nil }
        return V2DeskReadingOrder.previous(after: currentChapterID, in: workspace.chapters)
    }

    private var nextStep: V2DeskReadingNextStep? {
        guard let currentChapterID else { return nil }
        return V2DeskReadingOrder.next(after: currentChapterID, in: workspace.chapters)
    }

    var body: some View {
        V2MacSheetFrame(title: editor.currentChapter?.title.isEmpty == false ? (editor.currentChapter?.title ?? "") : "正文", width: 760) {
            VStack(spacing: 0) {
                ScrollView {
                    Text(editor.currentChapter?.draftText ?? "")
                        .font(V2DeskType.prose()).lineSpacing(V2DeskType.proseLineSpacing)
                        .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme)).textSelection(.enabled)
                        .frame(maxWidth: 600, alignment: .leading).padding(38)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                V2MacDeskHairline()
                HStack(spacing: 8) {
                    if let previousChapter {
                        Button("上一章") { moveBack(to: previousChapter) }
                            .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
                            .disabled(navigationInFlight)
                    }
                    Spacer()
                    nextButton
                }
                .padding(.horizontal, 22)
                .frame(height: V2DeskMetric.actionBarHeight)
                .background(V2DeskPalette.color(.acceptedPaper, scheme: colorScheme))
            }
        }
    }

    @ViewBuilder private var nextButton: some View {
        switch nextStep {
        case .read(let chapter):
            Button(chapter.title.isEmpty ? "未命名" : chapter.title) { read(chapter) }
                .buttonStyle(V2MacDeskButton(kind: .primary))
                .disabled(navigationInFlight)
                .help("继续阅读第 \(chapter.index) 章")
        case .write(let chapter):
            Button("继续写《\(chapter.title.isEmpty ? "未命名" : chapter.title)》") { write(chapter) }
                .buttonStyle(V2MacDeskButton(kind: .primary))
                .disabled(navigationInFlight)
        case .startNewChapter:
            Button("开始新一章", action: onStartNewChapter)
                .buttonStyle(V2MacDeskButton(kind: .primary))
                .disabled(navigationInFlight)
        case .none:
            EmptyView()
        }
    }

    private func moveBack(to chapter: ChapterSummary) {
        chapter.status == "finalized" ? read(chapter) : write(chapter)
    }

    private func read(_ chapter: ChapterSummary) {
        guard !navigationInFlight else { return }
        navigationInFlight = true
        Task {
            await onReadChapter(chapter)
            navigationInFlight = false
        }
    }

    private func write(_ chapter: ChapterSummary) {
        guard !navigationInFlight else { return }
        navigationInFlight = true
        Task {
            await onOpenWriting(chapter)
            navigationInFlight = false
        }
    }
}
