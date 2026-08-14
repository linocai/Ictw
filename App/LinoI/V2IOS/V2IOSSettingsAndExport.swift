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
    @State private var savedBaseURL = ""
    @State private var accessToken = ""
    @State private var savingConnection = false
    @State private var showingConnectionDiscardConfirmation = false
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: attemptDismiss)
                        .disabled(savingConnection)
                }
            }
        }
        .v2IOSPage()
        .onAppear {
            baseURL = session.baseURL
            savedBaseURL = session.baseURL
        }
        .interactiveDismissDisabled(hasUnsavedConnectionChanges || savingConnection)
        .confirmationDialog("放弃未保存的连接修改？", isPresented: $showingConnectionDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive, action: dismiss.callAsFunction)
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("后端地址或新输入的访问密钥尚未保存。")
        }
        .task(id: session.token) {
            if !session.token.v2IOSTrimmed.isEmpty { await agents.load() }
        }
        .sheet(isPresented: $showingNewProfile) {
            NavigationStack { V2IOSProfileEditor(profile: nil) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
    }

    private func bindingLabel(_ role: String) -> String {
        guard let binding = agents.bindings.first(where: { $0.agentRole == role }),
              let id = binding.llmProfileId,
              let profile = agents.profiles.first(where: { $0.id == id }) else { return "未绑定" }
        return profile.name
    }

    private var hasUnsavedConnectionChanges: Bool {
        baseURL.v2IOSTrimmed != savedBaseURL.v2IOSTrimmed || !accessToken.v2IOSTrimmed.isEmpty
    }

    private func attemptDismiss() {
        if hasUnsavedConnectionChanges { showingConnectionDiscardConfirmation = true }
        else { dismiss() }
    }

    private func saveConnection() {
        guard !baseURL.v2IOSTrimmed.isEmpty else { return }
        let tokenToSave = accessToken.v2IOSTrimmed.isEmpty ? session.token : accessToken.v2IOSTrimmed
        guard !tokenToSave.v2IOSTrimmed.isEmpty else {
            notices.publish("请输入访问密钥后再连接。", critical: true)
            return
        }
        savingConnection = true
        session.baseURL = baseURL.v2IOSTrimmed
        session.token = tokenToSave
        session.saveConnection()
        Task {
            accessToken = ""
            savedBaseURL = session.baseURL
            notices.publish("连接设置已保存。")
            await bookshelf.load()
            savingConnection = false
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction) } }
        }
        .v2IOSPage()
        .task { if let id = session.currentBook?.id { _ = await agents.loadBookPersonas(bookID: id) } }
        .sheet(isPresented: $showingGlobal) {
            V2IOSSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
    }

    private func source(_ role: String) -> String { agents.bookPersonas.first(where: { $0.agentRole == role })?.source == "book" ? "本书覆盖" : "跟随全局" }
}

private struct V2IOSGlobalAgentRoleView: View {
    let role: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var text = ""
    @State private var savedText = ""
    @State private var profileID = ""
    @State private var saving = false
    @State private var showingDiscardConfirmation = false

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
                if saving { HStack { ProgressView(); Text("正在保存") } }
            }
        }
        .navigationTitle(roleName(role))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if hasUnsavedChanges { Button("取消", action: attemptDismiss).disabled(saving) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存人格", action: save).disabled(!hasUnsavedChanges || saving)
            }
        }
        .onAppear {
            text = agents.personas.first(where: { $0.agentRole == role })?.editablePersona ?? ""
            savedText = text
            profileID = agents.bindings.first(where: { $0.agentRole == role })?.llmProfileId ?? ""
        }
        .interactiveDismissDisabled(hasUnsavedChanges || saving)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .confirmationDialog("放弃未保存的人格修改？", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { text = savedText; dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("这些修改尚未写入服务器。")
        }
    }

    private var hasUnsavedChanges: Bool { text != savedText }

    private func attemptDismiss() { showingDiscardConfirmation = true }

    private func save() {
        guard var persona = agents.personas.first(where: { $0.agentRole == role }) else { return }
        saving = true
        persona.editablePersona = text
        Task {
            await agents.savePersona(persona)
            if agents.personas.first(where: { $0.agentRole == role })?.editablePersona == text {
                savedText = text
            }
            saving = false
        }
    }
}

private struct V2IOSBookPersonaEditor: View {
    let role: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var text = ""
    @State private var savedText = ""
    @State private var source = "global"
    @State private var confirmingRestore = false
    @State private var showingDiscardConfirmation = false
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                Text(source == "book" ? "正在使用这本书的覆盖人格。" : "跟随全局人格。编辑并保存后才会建立本书覆盖。")
                    .font(V2DeskType.control(12.5)).foregroundStyle(Color.secondary)
            }
            Section("人格") { TextEditor(text: $text).font(V2DeskType.prose(14.5)).frame(minHeight: 200) }
            Section {
                if saving { HStack { ProgressView(); Text("正在保存") } }
                if source == "book" {
                    Button("恢复跟随全局", role: .destructive) { confirmingRestore = true }
                        .disabled(saving)
                }
            }
        }
        .navigationTitle(roleName(role))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if hasUnsavedChanges { Button("取消", action: attemptDismiss).disabled(saving) }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).disabled(!hasUnsavedChanges || saving)
            }
        }
        .onAppear { loadDraft() }
        .interactiveDismissDisabled(hasUnsavedChanges || saving)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .confirmationDialog("恢复跟随全局？", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("恢复跟随全局", role: .destructive) { restore() }
            Button("取消", role: .cancel) {}
        } message: { Text("这本书的自定义人格会移除，之后使用当前全局人格。") }
        .confirmationDialog("放弃未保存的人格修改？", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { text = savedText; dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("这些修改尚未写入服务器。")
        }
    }

    private func loadDraft() {
        guard let persona = agents.bookPersonas.first(where: { $0.agentRole == role }) else { return }
        text = persona.effectivePersona
        savedText = text
        source = persona.source
    }
    private var hasUnsavedChanges: Bool { text != savedText }
    private func attemptDismiss() { showingDiscardConfirmation = true }
    private func save() {
        guard let id = session.currentBook?.id else { return }
        saving = true
        Task {
            if await agents.saveBookPersona(bookID: id, role: role, editablePersona: text) { loadDraft() }
            saving = false
        }
    }
    private func restore() {
        guard let id = session.currentBook?.id else { return }
        saving = true
        Task {
            if await agents.resetBookPersona(bookID: id, role: role) { loadDraft() }
            saving = false
        }
    }
}

private struct V2IOSProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    let profile: LLMProfile?
    @State private var name = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var saving = false
    @State private var showingDiscardConfirmation = false

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                TextField("服务地址", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(profile == nil ? "API Key" : "更换 API Key（可留空）", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if saving {
                Section { HStack { ProgressView(); Text("正在保存") } }
            }
        }
        .v2IOSPage()
        .navigationTitle(profile == nil ? "新增模型" : "模型")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if profile == nil || hasUnsavedChanges {
                    Button("取消") { attemptDismiss() }
                        .disabled(saving)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(!canSave || saving)
            }
        }
        .onAppear { name = profile?.name ?? ""; baseURL = profile?.baseURL ?? ""; model = profile?.modelName ?? "" }
        .interactiveDismissDisabled(hasUnsavedChanges || saving)
        .navigationBarBackButtonHidden(profile != nil && hasUnsavedChanges)
        .confirmationDialog("放弃未保存的模型修改？", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive, action: dismiss.callAsFunction)
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("这些修改尚未写入服务器。")
        }
    }

    private var canSave: Bool {
        !name.v2IOSTrimmed.isEmpty && !baseURL.v2IOSTrimmed.isEmpty && !model.v2IOSTrimmed.isEmpty
    }

    private var hasUnsavedChanges: Bool {
        name != (profile?.name ?? "") || baseURL != (profile?.baseURL ?? "") || model != (profile?.modelName ?? "") || !apiKey.v2IOSTrimmed.isEmpty
    }

    private func attemptDismiss() {
        if hasUnsavedChanges { showingDiscardConfirmation = true }
        else { dismiss() }
    }

    private func save() {
        guard canSave else { return }
        saving = true
        Task {
            let saved: Bool
            if let profile {
                var value = profile
                value.name = name.v2IOSTrimmed
                value.baseURL = baseURL.v2IOSTrimmed
                value.modelName = model.v2IOSTrimmed
                saved = await agents.updateProfile(value, apiKey: apiKey.v2IOSTrimmed.isEmpty ? nil : apiKey)
            } else {
                saved = await agents.createProfile(
                    name: name.v2IOSTrimmed,
                    baseURL: baseURL.v2IOSTrimmed,
                    apiKey: apiKey,
                    model: model.v2IOSTrimmed
                )
            }
            saving = false
            if saved { dismiss() }
        }
    }
}

struct V2IOSExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var notices: NoticeBus
    @Environment(\.colorScheme) private var colorScheme
    let currentChapterID: String?
    @State private var scope: ExportScope = .accepted
    @State private var format: ExportFormat = .plainText
    @State private var separate = false
    @State private var includeWorld = true
    @State private var includeCharacters = true
    @State private var isExporting = false
    @State private var completedChapters = 0
    @State private var totalChapters = 0
    @State private var urls: [URL] = []
    @State private var sharing = false
    @State private var exportSessionID: UUID?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    V2IOSChoiceRow(
                        title: "范围",
                        options: ExportPresentationPolicy.availableScopes(currentChapterID: currentChapterID),
                        selection: $scope
                    ) { Text($0.label) }
                    V2IOSChoiceRow(title: "格式", options: Array(ExportFormat.allCases), selection: $format) { Text($0.label) }
                    VStack(alignment: .leading, spacing: 6) {
                        exportToggle("每章一个文件", isOn: $separate, hint: "将每个章节分别写入文件")
                        exportToggle("附世界观", isOn: $includeWorld, hint: "将本书世界观写入导出文件")
                        exportToggle("附人物设定", isOn: $includeCharacters, hint: "将人物固定设定写入导出文件")
                    }
                    if isExporting {
                        exportProgress
                        V2IOSSecondaryButton(title: "取消准备", action: cancelExport)
                    } else {
                        V2IOSPrimaryButton(title: "导出", action: startExport)
                    }
                    Text("只导出服务器已保存的版本；当前未保存的本地修改不会写入文件。")
                        .font(V2DeskType.control(11.5))
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .v2IOSPage()
        .onDisappear(perform: cancelExport)
        .sheet(isPresented: $sharing) { V2IOSShareSheet(urls: urls) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("导出")
                .font(V2DeskType.prose(20, weight: .semibold))
            Spacer()
            Button(isExporting ? "停止" : "取消", action: close)
                .font(V2DeskType.control(13, weight: .medium))
                .frame(minWidth: V2DeskMetric.mobileTapTarget, minHeight: V2DeskMetric.mobileTapTarget)
                .buttonStyle(.plain)
                .accessibilityLabel(isExporting ? "停止准备导出" : "取消导出")
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 56)
    }

    private var exportProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("正在准备")
                    .font(V2DeskType.control(13, weight: .medium))
                Spacer()
                Text(progressLabel)
                    .font(V2DeskType.control(12))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(completedChapters), total: Double(max(totalChapters, 1)))
                .tint(V2DeskPalette.color(.accent, scheme: colorScheme))
        }
        .padding(14)
        .v2IOSPaper(.card, corner: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在准备导出，\(progressLabel)")
    }

    private var progressLabel: String {
        totalChapters == 0 ? "正在读取章节" : "\(completedChapters) / \(totalChapters) 章"
    }

    private func exportToggle(_ title: String, isOn: Binding<Bool>, hint: String) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(V2DeskType.control(13.5))
        }
        .tint(V2DeskPalette.color(.accent, scheme: colorScheme))
        .frame(minHeight: V2DeskMetric.mobileTapTarget)
        .accessibilityHint(hint)
    }

    private func startExport() {
        guard let book = session.currentBook else { return }
        cancelExport()
        let sessionID = UUID()
        exportSessionID = sessionID
        isExporting = true
        completedChapters = 0
        totalChapters = 0
        exportTask = Task {
            defer { finishExport(sessionID: sessionID) }
            do {
                let summaries: [ChapterSummary] = try await session.api.request("/books/\(book.id)/chapters")
                try Task.checkCancellation()
                guard isCurrentExportSession(sessionID) else { return }
                totalChapters = summaries.count
                var details: [Chapter] = []
                details.reserveCapacity(summaries.count)
                for summary in summaries {
                    try Task.checkCancellation()
                    let chapter: Chapter = try await session.api.request("/chapters/\(summary.id)")
                    try Task.checkCancellation()
                    guard isCurrentExportSession(sessionID) else { return }
                    details.append(chapter)
                    completedChapters = details.count
                }
                let selected = ExportComposer.chapters(for: scope, chapters: details, currentID: currentChapterID)
                guard !selected.isEmpty else {
                    if isCurrentExportSession(sessionID) { notices.publish("这个范围没有可导出的已保存章节。") }
                    return
                }
                let files = ExportComposer.compose(
                    book: book,
                    chapters: selected,
                    characters: characters.characters,
                    format: format,
                    includeWorld: includeWorld,
                    includeCharacters: includeCharacters,
                    separateChapters: separate
                )
                let preparedURLs = try V2IOSExportFiles.write(files)
                try Task.checkCancellation()
                guard isCurrentExportSession(sessionID) else { return }
                urls = preparedURLs
                sharing = true
            } catch is CancellationError {
                return
            } catch {
                if isCurrentExportSession(sessionID) { notices.publish(error) }
            }
        }
    }

    private func close() {
        cancelExport()
        dismiss()
    }

    private func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportSessionID = nil
        isExporting = false
    }

    private func isCurrentExportSession(_ sessionID: UUID) -> Bool {
        exportSessionID == sessionID && !Task.isCancelled
    }

    private func finishExport(sessionID: UUID) {
        guard exportSessionID == sessionID else { return }
        isExporting = false
        exportTask = nil
    }
}

private struct V2IOSChoiceRow<Value: Identifiable & Hashable, Label: View>: View {
    let title: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> Label
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            V2IOSSectionLabel(title: title)
            V2IOSFlowLayout(spacing: 8) {
                ForEach(options, id: \.id) { option in
                    Button { selection = option } label: {
                        label(option)
                            .font(V2DeskType.control(13, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(minHeight: V2DeskMetric.mobileTapTarget)
                            .foregroundStyle(option == selection ? V2DeskPalette.color(.accent, scheme: colorScheme) : V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                            .background(option == selection ? V2DeskPalette.color(.accent, scheme: colorScheme).opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(option == selection ? V2DeskPalette.color(.accent, scheme: colorScheme).opacity(0.6) : V2DeskPalette.color(.line, scheme: colorScheme), lineWidth: 1)
                            }
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(option == selection ? .isSelected : [])
                }
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
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
