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
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书籍" : title
        let created = await bookshelf.createBook(title: resolvedTitle)
        creating = false
        // A failed create leaves the sheet open with the typed title intact.
        guard created != nil else { return }
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
        let didSave = await workspace.saveBook(title: title, world: world)
        saving = false
        // The world setting never reaches the local draft cache, so dismissing
        // on failure would drop everything the author just wrote.
        guard didSave else { return }
        if let book = session.currentBook { bookshelf.upsert(book) }
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
        // One request carries all three fields. The old two-step form fell back
        // to `characters.selected` when create failed, which resolves to the
        // first character in the list and overwrote that person's canon.
        let created = await characters.create(name: name, role: role, fixedProfile: traits)
        guard created != nil else { return }
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
            if let id = session.currentBook?.id {
                _ = await agents.loadBookPersonas(bookID: id)
                _ = await agents.loadBookModelBindings(bookID: id)
            }
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
            V2MacDeskHairline()
            V2MacBookModelSettings()
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

private struct V2MacBookModelSettings: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var selectedRole = "writer"
    @State private var profileID = ""
    @State private var thinking = false
    @State private var effort = ""
    @State private var temperature = 1.0
    @State private var saving = false
    @State private var confirmRestore = false
    @Environment(\.colorScheme) private var colorScheme
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]

    private var row: BookAgentModelBinding? { agents.bookModelBindings.first { $0.agentRole == selectedRole } }
    private var bounded: Bool { selectedRole == "extractor" || selectedRole == "inspiration_creator" }
    private var effectiveName: String {
        guard let id = row?.effectiveBinding?.llmProfileId,
              let profile = agents.profiles.first(where: { $0.id == id }) else { return "未绑定" }
        return "\(profile.name) · \(profile.modelName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            V2MacDeskSectionLabel(text: "本书模型覆盖")
            Text("缺省时完整跟随全局；这里保存的是一整份本书配置，而不是字段拼接。")
                .font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            Picker("角色", selection: $selectedRole) { ForEach(roles, id: \.self) { Text($0.v2AgentLabel).tag($0) } }
                .pickerStyle(.segmented)
            HStack {
                Text(row?.source == "book" ? "本书覆盖" : "跟随全局").font(V2DeskType.control(11.5, weight: .medium))
                Spacer()
                Text("实际：\(effectiveName)").font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme)).lineLimit(1)
            }
            Picker("模型", selection: $profileID) {
                Text("未绑定").tag("")
                ForEach(agents.profiles) { profile in Text("\(profile.name) · \(profile.modelName)").tag(profile.id) }
            }
            HStack {
                Toggle("启用思考", isOn: $thinking)
                    .disabled(bounded || !(row?.capabilities.thinkingToggleSupported ?? false))
                if bounded { Text("服务端固定关闭").font(V2DeskType.control(10.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme)) }
            }
            if !bounded, let levels = row?.capabilities.reasoningEffortLevels, !levels.isEmpty {
                Picker("思考强度", selection: $effort) {
                    Text("模型默认").tag("")
                    ForEach(levels, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!thinking)
            }
            HStack(spacing: 10) {
                Text("Temperature \(String(format: "%.2f", temperature))").font(V2DeskType.control(11.5))
                Slider(value: $temperature, in: 0...2, step: 0.05)
                    .disabled(bounded || (!(row?.capabilities.temperatureEffectiveWhenThinking ?? true) && !thinking))
            }
            if !sync.networkActionsAvailable { V2DeskOfflineExplanation() }
            HStack {
                if row?.source == "book" {
                    Button("恢复跟随全局") { confirmRestore = true }.buttonStyle(V2MacDeskButton(kind: .danger, compact: true)).disabled(saving || !sync.networkActionsAvailable)
                }
                Spacer()
                Button(saving ? "正在保存" : "保存本书覆盖") { Task { await save() } }
                    .buttonStyle(V2MacDeskButton(kind: .primary)).disabled(saving || !sync.networkActionsAvailable)
            }
        }
        .onAppear(perform: loadDraft)
        .onChange(of: selectedRole) { _, _ in loadDraft() }
        .onChange(of: row) { _, _ in loadDraft() }
        .confirmationDialog("恢复跟随全局？", isPresented: $confirmRestore) {
            Button("恢复跟随全局", role: .destructive) { Task { await restore() } }
            Button("取消", role: .cancel) {}
        } message: { Text("本书的完整模型覆盖会移除；以后启动的任务重新使用全局配置。") }
    }

    private func loadDraft() {
        let values = row?.bookBinding ?? row?.effectiveBinding
        profileID = values?.llmProfileId ?? ""
        thinking = bounded ? false : (values?.thinkingEnabled ?? false)
        effort = values?.reasoningEffort ?? ""
        temperature = values?.temperature ?? 1
    }

    private func save() async {
        guard let bookID = session.currentBook?.id else { return }
        saving = true
        let binding = AgentModelBindingValues(
            llmProfileId: profileID.isEmpty ? nil : profileID,
            thinkingEnabled: bounded ? false : thinking,
            reasoningEffort: effort.isEmpty ? nil : effort,
            temperature: temperature,
            effectiveThinkingEnabled: nil,
            effectiveReasoningEffort: nil,
            effectiveTemperature: nil,
            contentRevision: nil
        )
        _ = await agents.saveBookModelBinding(bookID: bookID, role: selectedRole, binding: binding)
        saving = false
        loadDraft()
    }

    private func restore() async {
        guard let bookID = session.currentBook?.id else { return }
        saving = true
        _ = await agents.clearBookModelBinding(bookID: bookID, role: selectedRole)
        saving = false
        loadDraft()
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
    @EnvironmentObject private var bookshelf: BookshelfStore
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
        await MacExportSaver.exportComposed(book: book, session: session, bookshelf: bookshelf, scope: scope, currentChapterID: currentChapterID, format: format, includeWorld: includeWorld, includeCharacters: includeCharacters, separateChapters: separate)
        exporting = false; dismiss()
    }
}

private struct V2MacSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var hasSearched = false
    @State private var openingID: String?
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
        openingID = result.id
        defer { openingID = nil }
        do {
            let book: Book = try await session.api.request("/books/\(result.bookId)")
            session.currentBook = book
            await workspace.load(bookId: book.id)
            await characters.load(bookId: book.id)
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
            }
            dismiss()
        } catch { session.notices.publish(error) }
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
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var working = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        V2MacSheetFrame(title: "项目备份与恢复", width: 520) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    V2MacDeskSectionLabel(text: "完整备份")
                    Text("备份当前书的正文、人物、关联、有效记忆、人格和模型覆盖。项目包不包含访问密钥、全局模型设置或内部生成过程文本。")
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
        working = true
        if let book = session.currentBook { await MacExportSaver.exportProject(book, session: session, bookshelf: bookshelf) }
        working = false
    }

    private func importProject() async {
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
