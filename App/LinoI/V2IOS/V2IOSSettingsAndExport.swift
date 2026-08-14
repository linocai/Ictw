import SwiftUI

struct V2IOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var notices: NoticeBus
    @State private var selectedRole: String?
    @State private var showingNewProfile = false
    @State private var baseURL = ""
    @State private var accessToken = ""
    @State private var savingConnection = false
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    TextField("后端地址", text: $baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("访问密钥（留空则保留当前密钥）", text: $accessToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(savingConnection ? "正在保存" : "保存并重新连接") { saveConnection() }
                        .disabled(savingConnection || baseURL.v2IOSTrimmed.isEmpty)
                }
                Section("模型") {
                    ForEach(agents.profiles) { profile in
                        NavigationLink { V2IOSProfileEditor(profile: profile) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).font(V2DeskType.control(14, weight: .medium))
                                Text(profile.modelName).font(V2DeskType.control(11)).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                    Button("新增模型") { showingNewProfile = true }
                }
                Section("全局人格") {
                    ForEach(roles, id: \.self) { role in
                        NavigationLink { V2IOSGlobalAgentRoleView(role: role) } label: {
                            HStack {
                                Text(roleName(role))
                                Spacer()
                                Text(bindingLabel(role)).font(V2DeskType.control(11)).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction) } }
        }
        .v2IOSPage()
        .onAppear { baseURL = session.baseURL }
        .task(id: session.token) {
            if !session.token.v2IOSTrimmed.isEmpty { await agents.load() }
        }
        .sheet(isPresented: $showingNewProfile) { V2IOSProfileEditor(profile: nil).presentationDetents([.large]).presentationCornerRadius(V2DeskMetric.sheetCornerRadius) }
    }

    private func bindingLabel(_ role: String) -> String {
        guard let binding = agents.bindings.first(where: { $0.agentRole == role }),
              let id = binding.llmProfileId,
              let profile = agents.profiles.first(where: { $0.id == id }) else { return "未绑定" }
        return profile.name
    }

    private func saveConnection() {
        guard !baseURL.v2IOSTrimmed.isEmpty else { return }
        savingConnection = true
        session.baseURL = baseURL.v2IOSTrimmed
        if !accessToken.v2IOSTrimmed.isEmpty { session.token = accessToken.v2IOSTrimmed }
        session.saveConnection()
        Task {
            await bookshelf.load()
            savingConnection = false
            if session.token.v2IOSTrimmed.isEmpty { notices.publish("请输入访问密钥后再连接。", critical: true) }
            else { notices.publish("连接设置已保存。") }
        }
    }
}

struct V2IOSBookSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var role: String?
    @State private var showingGlobal = false
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]

    var body: some View {
        NavigationStack {
            List {
                Section("本书人格") {
                    ForEach(roles, id: \.self) { key in
                        NavigationLink { V2IOSBookPersonaEditor(role: key) } label: {
                            HStack {
                                Text(roleName(key))
                                Spacer()
                                Text(source(key)).font(V2DeskType.control(11)).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button("全局模型与人格") { showingGlobal = true }
                } footer: { Text("模型、程序协议、绑定和参数始终是全局设置。") }
            }
            .navigationTitle("书设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction) } }
        }
        .v2IOSPage()
        .task { if let id = session.currentBook?.id { _ = await agents.loadBookPersonas(bookID: id) } }
        .sheet(isPresented: $showingGlobal) { V2IOSSettingsView().presentationCornerRadius(V2DeskMetric.sheetCornerRadius) }
    }

    private func source(_ role: String) -> String { agents.bookPersonas.first(where: { $0.agentRole == role })?.source == "book" ? "本书覆盖" : "跟随全局" }
}

private struct V2IOSGlobalAgentRoleView: View {
    let role: String
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var text = ""
    @State private var profileID = ""

    var body: some View {
        Form {
            Section("模型") {
                Picker("绑定模型", selection: $profileID) {
                    Text("未绑定").tag("")
                    ForEach(agents.profiles) { Text($0.name).tag($0.id) }
                }
                .onChange(of: profileID) { _, id in Task { await agents.bind(role: role, profileId: id.isEmpty ? nil : id) } }
                if ["extractor", "inspiration_creator"].contains(role) {
                    LabeledContent("深度思考", value: "不可用")
                }
            }
            Section("全局人格") {
                TextEditor(text: $text).font(V2DeskType.prose(14.5)).frame(minHeight: 170)
                Button("保存人格") { Task { if var persona = agents.personas.first(where: { $0.agentRole == role }) { persona.editablePersona = text; await agents.savePersona(persona) } } }
            }
        }
        .navigationTitle(roleName(role))
        .onAppear {
            text = agents.personas.first(where: { $0.agentRole == role })?.editablePersona ?? ""
            profileID = agents.bindings.first(where: { $0.agentRole == role })?.llmProfileId ?? ""
        }
    }
}

private struct V2IOSBookPersonaEditor: View {
    let role: String
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var text = ""
    @State private var source = "global"
    @State private var confirmingRestore = false

    var body: some View {
        Form {
            Section {
                Text(source == "book" ? "正在使用这本书的覆盖人格。" : "跟随全局人格。编辑并保存后才会建立本书覆盖。")
                    .font(V2DeskType.control(12.5)).foregroundStyle(Color.secondary)
            }
            Section("人格") { TextEditor(text: $text).font(V2DeskType.prose(14.5)).frame(minHeight: 200) }
            Section {
                Button("保存为本书覆盖") { save() }
                if source == "book" { Button("恢复跟随全局", role: .destructive) { confirmingRestore = true } }
            }
        }
        .navigationTitle(roleName(role))
        .onAppear { loadDraft() }
        .confirmationDialog("恢复跟随全局？", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("恢复跟随全局", role: .destructive) { restore() }
            Button("取消", role: .cancel) {}
        } message: { Text("这本书的自定义人格会移除，之后使用当前全局人格。") }
    }

    private func loadDraft() {
        guard let persona = agents.bookPersonas.first(where: { $0.agentRole == role }) else { return }
        text = persona.effectivePersona; source = persona.source
    }
    private func save() { guard let id = session.currentBook?.id else { return }; Task { _ = await agents.saveBookPersona(bookID: id, role: role, editablePersona: text); loadDraft() } }
    private func restore() { guard let id = session.currentBook?.id else { return }; Task { _ = await agents.resetBookPersona(bookID: id, role: role); loadDraft() } }
}

private struct V2IOSProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    let profile: LLMProfile?
    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("名称", text: $name); TextField("服务地址", text: $baseURL); TextField("模型", text: $model); SecureField(profile == nil ? "API Key" : "更换 API Key（可留空）", text: $apiKey) }
                Section { Button("保存") { save() }.disabled(name.v2IOSTrimmed.isEmpty || baseURL.v2IOSTrimmed.isEmpty || model.v2IOSTrimmed.isEmpty) }
            }
            .navigationTitle(profile == nil ? "新增模型" : "模型")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消", action: dismiss.callAsFunction) } }
        }
        .v2IOSPage()
        .onAppear { name = profile?.name ?? ""; baseURL = profile?.baseURL ?? ""; model = profile?.modelName ?? "" }
    }

    private func save() {
        Task {
            if let profile { var value = profile; value.name = name; value.baseURL = baseURL; value.modelName = model; await agents.updateProfile(value, apiKey: apiKey.v2IOSTrimmed.isEmpty ? nil : apiKey) }
            else { await agents.createProfile(name: name, baseURL: baseURL, apiKey: apiKey, model: model) }
            dismiss()
        }
    }
}

struct V2IOSExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var notices: NoticeBus
    let currentChapterID: String?
    @State private var scope: ExportScope = .accepted
    @State private var format: ExportFormat = .plainText
    @State private var separate = false
    @State private var includeWorld = true
    @State private var includeCharacters = true
    @State private var isExporting = false
    @State private var urls: [URL] = []
    @State private var sharing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            V2IOSSheetHeader(title: "导出", dismiss: dismiss.callAsFunction)
            V2IOSChoiceRow(title: "范围", options: ExportScope.allCases, selection: $scope) { Text($0.label) }
            V2IOSChoiceRow(title: "格式", options: ExportFormat.allCases, selection: $format) { Text($0.label) }
            Toggle("每章一个文件", isOn: $separate).tint(Color.primary)
            Toggle("附世界观", isOn: $includeWorld).tint(Color.primary)
            Toggle("附人物设定", isOn: $includeCharacters).tint(Color.primary)
            V2IOSPrimaryButton(title: isExporting ? "正在准备导出" : "导出", disabled: isExporting, action: export)
            Text("只导出服务器已保存的版本；当前未保存的本地修改不会写入文件。")
                .font(V2DeskType.control(11.5)).foregroundStyle(Color.secondary)
        }
        .padding(20).v2IOSPage()
        .sheet(isPresented: $sharing) { V2IOSShareSheet(urls: urls) }
    }

    private func export() {
        guard let book = session.currentBook else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let summaries: [ChapterSummary] = try await session.api.request("/books/\(book.id)/chapters")
                var details: [Chapter] = []
                for summary in summaries { let chapter: Chapter = try await session.api.request("/chapters/\(summary.id)"); details.append(chapter) }
                let selected = ExportComposer.chapters(for: scope, chapters: details, currentID: currentChapterID)
                guard !selected.isEmpty else { notices.publish("这个范围没有可导出的已保存章节。"); return }
                urls = try V2IOSExportFiles.write(ExportComposer.compose(book: book, chapters: selected, characters: characters.characters, format: format, includeWorld: includeWorld, includeCharacters: includeCharacters, separateChapters: separate))
                sharing = true
            } catch { notices.publish(error) }
        }
    }
}

private struct V2IOSChoiceRow<Value: CaseIterable & Identifiable & Hashable, Label: View>: View where Value.AllCases: RandomAccessCollection {
    let title: String
    let options: Value.AllCases
    @Binding var selection: Value
    let label: (Value) -> Label
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            V2IOSSectionLabel(title: title)
            V2IOSFlowLayout(spacing: 8) {
                ForEach(Array(options), id: \.id) { option in
                    Button { selection = option } label: {
                        label(option).font(V2DeskType.control(13)).padding(.horizontal, 15).frame(minHeight: 44)
                            .foregroundStyle(option == selection ? Color.white : Color.primary)
                            .background(option == selection ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.2)))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

func roleName(_ role: String) -> String {
    switch role {
    case "memory_selector": "记忆选择"
    case "writer": "写作"
    case "checker": "复查"
    case "extractor": "整理记忆"
    case "inspiration_creator": "找方向"
    default: role
    }
}
