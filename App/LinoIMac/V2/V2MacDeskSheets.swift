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
        }
    }
}

private struct V2MacSheetFrame<Content: View>: View {
    let title: String
    var width: CGFloat = 520
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(V2DeskType.prose(17, weight: .semibold))
                Spacer()
                V2MacDeskIconButton(symbol: "xmark", label: "关闭") { dismiss() }
            }
            .padding(.horizontal, 22).frame(height: 48)
            .background(V2DeskPalette.color(.titleBar, scheme: colorScheme))
            V2MacDeskHairline()
            content
        }
        .frame(width: width)
        .background(V2DeskPalette.color(.card, scheme: colorScheme))
    }
}

// MARK: - Book and world

private struct V2MacNewBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var title = ""
    @State private var creating = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "新建一本", width: 440) {
            VStack(alignment: .leading, spacing: 18) {
                V2MacDeskSectionLabel(text: "书名")
                TextField("", text: $title)
                    .textFieldStyle(.plain)
                    .font(V2DeskType.prose(17))
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(V2DeskPalette.color(.strongLine, scheme: colorScheme)).frame(height: 1) }
                    .focused($focused)
                    .onSubmit { Task { await create() } }
                Text("世界观可以稍后再写。")
                    .font(V2DeskType.control(12))
                    .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                HStack { Spacer(); Button(creating ? "正在创建" : "创建") { Task { await create() } }.buttonStyle(V2MacDeskButton(kind: .primary)).disabled(creating) }
            }
            .padding(24)
        }
        .onAppear { focused = true }
    }

    private func create() async {
        guard !creating else { return }
        creating = true
        await bookshelf.createBook(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书籍" : title)
        creating = false
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
    @State private var saving = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "世界观", width: 700) {
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
                    Button(saving ? "正在保存" : "保存") { Task { await save() } }
                        .buttonStyle(V2MacDeskButton(kind: .primary)).disabled(saving)
                }
            }
            .padding(22)
        }
        .onAppear { sync() }
    }

    private func sync() {
        guard let book = session.currentBook, book.id != loadedID else { return }
        loadedID = book.id; title = book.title; world = book.worldSetting
    }
    private func save() async {
        saving = true
        await workspace.saveBook(title: title, world: world)
        if let book = session.currentBook { bookshelf.upsert(book) }
        saving = false
        dismiss()
    }
}

// MARK: - People

private struct V2MacPeopleSheet: View {
    @EnvironmentObject private var characters: CharactersStore
    @State private var newPerson = false
    @State private var deleteTarget: Character?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "人物", width: 760) {
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
                                }.buttonStyle(.plain)
                                V2MacDeskHairline()
                            }
                        }
                    }
                    Button("新增人物") { newPerson = true }
                        .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true)).padding(12)
                }
                .frame(width: 236)
                .background(V2DeskPalette.color(.rail, scheme: colorScheme))
                V2MacDeskHairline().frame(width: 1, height: nil)
                if let person = characters.selected {
                    V2MacPersonEditor(person: person, delete: { deleteTarget = person })
                } else {
                    V2MacDeskEmptyPrompt(title: "添加第一个人物", actionTitle: "新增人物") { newPerson = true }
                }
            }
            .frame(height: 560)
        }
        .sheet(isPresented: $newPerson) { V2MacNewPersonSheet() }
        .confirmationDialog("删除这个人物？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除人物", role: .destructive) { if let deleteTarget { Task { await characters.delete(deleteTarget) }; self.deleteTarget = nil } }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { Text("这个人物的固定设定和归档记录都会从本书移除。") }
    }
}

private struct V2MacPersonEditor: View {
    @EnvironmentObject private var characters: CharactersStore
    let person: Character
    let delete: () -> Void
    @State private var name = ""
    @State private var role = ""
    @State private var profile = ""
    @State private var loadedID: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            V2MacDeskSectionLabel(text: "我设定的")
            TextField("姓名", text: $name).textFieldStyle(.plain).font(V2DeskType.prose(17))
                .overlay(alignment: .bottom) { Rectangle().fill(V2DeskPalette.color(.line, scheme: colorScheme)).frame(height: 1) }
            TextField("身份", text: $role).textFieldStyle(.plain).font(V2DeskType.control(13))
                .overlay(alignment: .bottom) { Rectangle().fill(V2DeskPalette.color(.line, scheme: colorScheme)).frame(height: 1) }
            TextEditor(text: $profile).scrollContentBackground(.hidden).font(V2DeskType.prose(13)).frame(minHeight: 120).padding(7)
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
            HStack { Spacer(); Button("保存设定") { Task { await save() } }.buttonStyle(V2MacDeskButton(kind: .primary, compact: true)) }
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
        .onAppear { sync() }.onChange(of: person.id) { _, _ in sync() }
    }
    private func sync() { guard loadedID != person.id else { return }; loadedID = person.id; name = person.name; role = person.role; profile = person.fixedProfile }
    private func save() async { var updated = person; updated.name = name; updated.role = role; updated.fixedProfile = profile; await characters.update(updated) }
}

private struct V2MacNewPersonSheet: View {
    @EnvironmentObject private var characters: CharactersStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var traits = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        V2MacSheetFrame(title: "新增人物", width: 480) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("姓名", text: $name).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).focused($focused)
                TextField("身份", text: $role).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                TextField("性格", text: $traits).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                HStack { Spacer(); Button("创建") { Task { await create() } }.buttonStyle(V2MacDeskButton(kind: .primary)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(22)
        }.onAppear { focused = true }
    }
    private func create() async {
        await characters.create(name: name)
        if var created = characters.selected { created.role = role; created.fixedProfile = traits; await characters.update(created) }
        dismiss()
    }
}

// MARK: - Inspiration

private struct V2MacInspirationSheet: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var boundary = ""

    var body: some View {
        V2MacSheetFrame(title: "找方向", width: 760) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("本章推进边界（可选）", text: $boundary)
                    .textFieldStyle(.plain).font(V2DeskType.control(12.5)).padding(10)
                    .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
                HStack {
                    Text(inspiration.isLoading ? "正在找方向" : "")
                        .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                    Spacer()
                    Button(inspiration.cards.isEmpty ? "开始找灵感" : "换三个") { generate() }
                        .buttonStyle(V2MacDeskButton(kind: .primary)).disabled(editor.currentChapter == nil || inspiration.isLoading)
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
        .onAppear { boundary = inspiration.pacingBoundary }
    }
    private var cards: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(inspiration.cards) { card in
                VStack(alignment: .leading, spacing: 10) {
                    Text(card.body).font(V2DeskType.prose(13.5)).lineSpacing(6).foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button(inspiration.adoptedCardIDs.contains(card.id) ? "已写入意图" : "用这个") { add(card) }
                        .buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
                        .disabled(inspiration.adoptedCardIDs.contains(card.id) || editor.currentChapter?.status == "finalized")
                }
                .padding(14).frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 8).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
            }
        }
    }
    private func generate() { guard let chapter = editor.currentChapter else { return }; inspiration.pacingBoundary = boundary; inspiration.generate(for: chapter) }
    private func add(_ card: InspirationCard) {
        guard let chapter = editor.currentChapter else { return }
        let before = chapter.userPrompt
        let after = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? card.body : before + "\n\n" + card.body
        editor.editString(\.userPrompt, value: after)
        inspiration.recordAdoption(card: card, chapterID: chapter.id, before: before, after: after)
    }
}

// MARK: - Settings and personas

private struct V2MacSettingsSheet: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var session: AppSession
    @State private var section: V2MacSettingsSection = .personas
    @Environment(\.colorScheme) private var colorScheme

    private enum V2MacSettingsSection: String, CaseIterable, Identifiable {
        case connection, model, personas, writing, appearance
        var id: String { rawValue }
        var title: String { switch self { case .connection: "连接"; case .model: "模型"; case .personas: "人格"; case .writing: "写作"; case .appearance: "外观" } }
    }

    var body: some View {
        V2MacSheetFrame(title: "设置", width: 800) {
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
                    }
                    Spacer()
                }
                .padding(.top, 14).frame(width: 168)
                .background(V2DeskPalette.color(.rail, scheme: colorScheme))
                V2MacDeskHairline().frame(width: 1, height: nil)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch section {
                        case .connection: V2MacConnectionSettings()
                        case .model: V2MacModelSettings()
                        case .personas: V2MacPersonaSettings()
                        case .writing: V2MacWritingSettings()
                        case .appearance: V2MacAppearanceSettings()
                        }
                    }.padding(22)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 560)
        }
        .task {
            await agents.load()
            if let id = session.currentBook?.id { _ = await agents.loadBookPersonas(bookID: id) }
        }
    }
}

private struct V2MacConnectionSettings: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var endpoint = ""
    @State private var token = ""
    @State private var loaded = false
    @State private var saving = false
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
        .onAppear {
            guard !loaded else { return }
            loaded = true
            endpoint = session.baseURL
            token = session.token
        }
    }

    private var canSave: Bool {
        !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: normalizedEndpoint)?.scheme != nil else {
            session.notices.publish("后端地址需要包含 http(s)://")
            return
        }
        saving = true
        session.baseURL = normalizedEndpoint
        session.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        session.saveConnection()
        await bookshelf.load()
        saving = false
    }
}

private struct V2MacModelSettings: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var addProfile = false
    @Environment(\.colorScheme) private var colorScheme
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            V2MacDeskSectionLabel(text: "模型")
            Text("模型、绑定和参数始终是全局设置。")
                .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            HStack { Text("PROFILE").font(V2DeskType.control(11, weight: .medium)); Spacer(); Button("新增 Profile") { addProfile = true }.buttonStyle(V2MacDeskButton(kind: .secondary, compact: true)) }
            if agents.profiles.isEmpty {
                Text("还没有可用的模型。")
                    .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            } else {
                ForEach(agents.profiles) { profile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name).font(V2DeskType.control(12.5, weight: .medium))
                        Text("\(profile.modelName) · \(profile.baseURL)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme)).lineLimit(1)
                    }.padding(10).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
                }
            }
            V2MacDeskHairline()
            ForEach(roles, id: \.self) { role in V2MacBindingRow(role: role) }
        }
        .sheet(isPresented: $addProfile) { V2MacNewProfileSheet() }
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

private struct V2MacNewProfileSheet: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""; @State private var endpoint = ""; @State private var key = ""; @State private var model = ""
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        V2MacSheetFrame(title: "新增 Profile", width: 480) {
            VStack(alignment: .leading, spacing: 10) {
                V2MacProfileField("名称", text: $name)
                V2MacProfileField("Base URL", text: $endpoint)
                SecureField("API Key", text: $key).textFieldStyle(.plain).padding(8).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                V2MacProfileField("模型名称", text: $model)
                HStack { Spacer(); Button("创建") { Task { await agents.createProfile(name: name, baseURL: endpoint, apiKey: key, model: model); dismiss() } }.buttonStyle(V2MacDeskButton(kind: .primary)).disabled([name, endpoint, key, model].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }
            }.padding(22)
        }
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
    @State private var bookMode = true
    @State private var draft = ""
    @State private var resetBookConfirmation = false
    @Environment(\.colorScheme) private var colorScheme
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]
    private var bookPersona: BookAgentPersona? { agents.bookPersonas.first { $0.agentRole == selectedRole } }
    private var globalPersona: AgentPersona? { agents.personas.first { $0.agentRole == selectedRole } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            V2MacDeskSectionLabel(text: "人格")
            Text("五个角色可继承全局人格，或只为当前书覆盖。模型与程序协议不在这里改变。")
                .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            Picker("角色", selection: $selectedRole) { ForEach(roles, id: \.self) { Text($0.v2AgentLabel).tag($0) } }
                .pickerStyle(.segmented)
            Picker("范围", selection: $bookMode) { Text("本书人格").tag(true); Text("全局人格").tag(false) }
                .pickerStyle(.segmented)
            Text(bookMode ? (bookPersona?.source == "book" ? "当前书正在使用自定义人格" : "当前书跟随全局人格") : "全局人格会影响之后启动的所有任务")
                .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            TextEditor(text: $draft).scrollContentBackground(.hidden).font(V2DeskType.prose(13)).frame(minHeight: 220).padding(8)
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme)).overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
            HStack {
                if bookMode, bookPersona?.source == "book" { Button("恢复跟随全局") { resetBookConfirmation = true }.buttonStyle(V2MacDeskButton(kind: .danger, compact: true)) }
                Spacer()
                Button("保存人格") { Task { await save() } }.buttonStyle(V2MacDeskButton(kind: .primary))
            }
        }
        .onAppear { syncDraft() }
        .onChange(of: selectedRole) { _, _ in syncDraft() }
        .onChange(of: bookMode) { _, _ in syncDraft() }
        .confirmationDialog("恢复跟随全局？", isPresented: $resetBookConfirmation) {
            Button("恢复跟随全局", role: .destructive) { Task { await resetBook() } }
            Button("取消", role: .cancel) {}
        } message: { Text("本书对 \(selectedRole.v2AgentLabel) 的覆盖会移除；之后的新任务使用当前全局人格。") }
    }
    private func syncDraft() { draft = bookMode ? (bookPersona?.effectivePersona ?? "") : (globalPersona?.editablePersona ?? "") }
    private func save() async {
        if bookMode, let bookID = session.currentBook?.id { _ = await agents.saveBookPersona(bookID: bookID, role: selectedRole, editablePersona: draft) }
        else if var persona = globalPersona { persona.editablePersona = draft; await agents.savePersona(persona) }
        syncDraft()
    }
    private func resetBook() async { if let id = session.currentBook?.id { _ = await agents.resetBookPersona(bookID: id, role: selectedRole) }; syncDraft() }
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
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
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
        V2MacSheetFrame(title: "导出正文", width: 520) {
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
                Text("只读取已保存版本；当前编辑器中未保存的本地修改不会纳入。记忆导出保持独立。")
                    .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                HStack {
                    Button("导出记忆") { Task { if let book = session.currentBook { await MacExportSaver.exportMemories(book, session: session) } } }.buttonStyle(V2MacDeskButton(kind: .secondary))
                    Spacer()
                    Button(exporting ? "正在导出" : "导出") { Task { await export() } }.buttonStyle(V2MacDeskButton(kind: .primary)).disabled(exporting || (scope == .current && currentChapterID == nil))
                }
            }.padding(22)
        }
    }
    private func export() async {
        guard let book = session.currentBook else { return }
        exporting = true
        await MacExportSaver.exportComposed(book: book, session: session, chapterSummaries: workspace.chapters, characters: characters.characters, scope: scope, currentChapterID: currentChapterID, format: format, includeWorld: includeWorld, includeCharacters: includeCharacters, separateChapters: separate)
        exporting = false; dismiss()
    }
}

struct V2MacReaderSheet: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        V2MacSheetFrame(title: editor.currentChapter?.title.isEmpty == false ? (editor.currentChapter?.title ?? "") : "正文", width: 760) {
            ScrollView {
                Text(editor.currentChapter?.draftText ?? "")
                    .font(V2DeskType.prose()).lineSpacing(V2DeskType.proseLineSpacing)
                    .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme)).textSelection(.enabled)
                    .frame(maxWidth: 600, alignment: .leading).padding(38)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}
