import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showingProjectPackage = false
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
                Section {
                    Button("备份或恢复完整项目") { showingProjectPackage = true }
                } header: {
                    Text("资料")
                } footer: {
                    Text("完整项目包可在另一台设备或隔离环境中恢复为一本新书，不包含访问密钥与内部生成过程文本。")
                }
            }
            .v2IOSNoticeOverlay()
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
        .sheet(isPresented: $showingProjectPackage) {
            V2IOSProjectPackageSheet()
                .presentationDetents([.medium, .large])
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
                    ForEach(roles, id: \.self) { key in
                        NavigationLink { V2IOSBookModelEditor(role: key) } label: {
                            HStack {
                                Text(roleName(key))
                                Spacer()
                                Text(modelSource(key)).font(V2DeskType.control(11)).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                } header: {
                    Text("本书模型")
                } footer: {
                    Text("本书覆盖是一整份模型配置；缺省即完整跟随全局。整理记忆与找方向始终由服务端以有界非思考方式运行。")
                }
                Section {
                    Button("全局模型与人格") { showingGlobal = true }
                } footer: { Text("模型、程序协议、绑定和参数始终是全局设置。") }
            }
            // Keep notices inside the navigation content so the toast starts
            // below the title bar. Hosting it outside NavigationStack makes
            // its close target overlap the trailing “完成” button.
            .v2IOSNoticeOverlay()
            .navigationTitle("书设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction) } }
        }
        .v2IOSPage()
        .task {
            if let id = session.currentBook?.id {
                _ = await agents.loadBookPersonas(bookID: id)
                _ = await agents.loadBookModelBindings(bookID: id)
            }
        }
        .sheet(isPresented: $showingGlobal) {
            V2IOSSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
    }

    private func source(_ role: String) -> String { agents.bookPersonas.first(where: { $0.agentRole == role })?.source == "book" ? "本书覆盖" : "跟随全局" }
    private func modelSource(_ role: String) -> String { agents.bookModelBindings.first(where: { $0.agentRole == role })?.source == "book" ? "本书覆盖" : "跟随全局" }
}

private struct V2IOSGlobalAgentRoleView: View {
    let role: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var text = ""
    @State private var savedText = ""
    @State private var saving = false
    @State private var showingDiscardConfirmation = false

    // Read the binding straight from the store. A @State mirror seeded in
    // onAppear would make `.onChange` fire on first layout and PATCH the
    // binding the user only came here to look at.
    private var profileID: Binding<String> {
        Binding(
            get: { agents.bindings.first(where: { $0.agentRole == role })?.llmProfileId ?? "" },
            set: { value in Task { await agents.bind(role: role, profileId: value.isEmpty ? nil : value) } }
        )
    }

    var body: some View {
        Form {
            Section("模型") {
                Picker("绑定模型", selection: profileID) {
                    Text("未绑定").tag("")
                    ForEach(agents.profiles) { Text($0.name).tag($0.id) }
                }
                if ["extractor", "inspiration_creator"].contains(role) {
                    LabeledContent("深度思考", value: "不可用")
                }
            }
            Section("全局人格") {
                TextEditor(text: $text).font(V2DeskType.prose(14.5)).frame(minHeight: 170)
                if saving { HStack { ProgressView(); Text("正在保存") } }
            }
        }
        .v2IOSNoticeOverlay()
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
        .v2IOSNoticeOverlay()
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

private struct V2IOSBookModelEditor: View {
    let role: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var profileID = ""
    @State private var thinking = false
    @State private var effort = ""
    @State private var temperature = 1.0
    @State private var saving = false
    @State private var confirmingRestore = false

    private var row: BookAgentModelBinding? { agents.bookModelBindings.first(where: { $0.agentRole == role }) }
    private var effective: AgentModelBindingValues? { row?.effectiveBinding }
    private var bounded: Bool { role == "extractor" || role == "inspiration_creator" }
    private var selectedProfileName: String {
        guard let id = effective?.llmProfileId,
              let profile = agents.profiles.first(where: { $0.id == id }) else { return "未绑定" }
        return "\(profile.name) · \(profile.modelName)"
    }

    var body: some View {
        Form {
            Section("实际生效") {
                LabeledContent("来源", value: row?.source == "book" ? "本书覆盖" : "跟随全局")
                LabeledContent("模型", value: selectedProfileName)
                LabeledContent("深度思考", value: effective?.effectiveThinkingEnabled == true ? "开启" : "关闭")
            }
            Section("本书覆盖") {
                Picker("模型", selection: $profileID) {
                    Text("未绑定").tag("")
                    ForEach(agents.profiles) { profile in Text("\(profile.name) · \(profile.modelName)").tag(profile.id) }
                }
                Toggle("启用思考", isOn: $thinking)
                    .disabled(bounded || !(row?.capabilities.thinkingToggleSupported ?? false))
                if bounded {
                    Text("这个角色的深度思考由服务端固定关闭。")
                        .font(V2DeskType.control(11.5)).foregroundStyle(Color.secondary)
                }
                if !bounded, let levels = row?.capabilities.reasoningEffortLevels, !levels.isEmpty {
                    Picker("思考强度", selection: $effort) {
                        Text("模型默认").tag("")
                        ForEach(levels, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(!thinking)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Temperature"); Spacer(); Text(String(format: "%.2f", temperature)).monospacedDigit().foregroundStyle(Color.secondary) }
                    Slider(value: $temperature, in: 0...2, step: 0.05)
                        .disabled(bounded || !(row?.capabilities.temperatureEffectiveWhenThinking ?? true) && !thinking)
                }
            }
            Section {
                Button(saving ? "正在保存" : "保存本书覆盖", action: save)
                    .disabled(saving || !sync.networkActionsAvailable)
                if row?.source == "book" {
                    Button("恢复跟随全局", role: .destructive) { confirmingRestore = true }
                        .disabled(saving || !sync.networkActionsAvailable)
                }
                if !sync.networkActionsAvailable { V2DeskOfflineExplanation() }
            }
        }
        .v2IOSNoticeOverlay()
        .navigationTitle(roleName(role))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction).disabled(saving) } }
        .onAppear(perform: loadDraft)
        .onChange(of: row) { _, _ in loadDraft() }
        .confirmationDialog("恢复跟随全局？", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("恢复跟随全局", role: .destructive) { restore() }
            Button("取消", role: .cancel) {}
        } message: { Text("这本书的完整模型覆盖会移除；以后启动的任务重新使用全局配置。") }
    }

    private func loadDraft() {
        let source = row?.bookBinding ?? row?.effectiveBinding
        profileID = source?.llmProfileId ?? ""
        thinking = bounded ? false : (source?.thinkingEnabled ?? false)
        effort = source?.reasoningEffort ?? ""
        temperature = source?.temperature ?? 1.0
    }

    private func save() {
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
        Task {
            if await agents.saveBookModelBinding(bookID: bookID, role: role, binding: binding) { loadDraft() }
            saving = false
        }
    }

    private func restore() {
        guard let bookID = session.currentBook?.id else { return }
        saving = true
        Task {
            if await agents.clearBookModelBinding(bookID: bookID, role: role) { loadDraft() }
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
        .v2IOSNoticeOverlay()
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
    @EnvironmentObject private var bookshelf: BookshelfStore
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
        .v2IOSNoticeOverlay()
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
                guard let data = await bookshelf.exportData(book) else { return }
                try Task.checkCancellation()
                guard isCurrentExportSession(sessionID) else { return }
                totalChapters = data.chapters.count
                completedChapters = totalChapters
                let selected = V2DeskExportComposer.chapters(for: scope, in: data, currentID: currentChapterID)
                guard !selected.isEmpty else {
                    if isCurrentExportSession(sessionID) { notices.publish("这个范围没有可导出的已保存章节。") }
                    return
                }
                let files = V2DeskExportComposer.compose(
                    data: data,
                    chapters: selected,
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

// MARK: - v2.1 search and project packages

/// Search is intentionally a server request rather than a download-and-filter
/// of cached manuscripts.  This keeps snippets within the Backend's visible
/// content boundary and makes the offline limitation explicit to the author.
struct V2IOSSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var notices: NoticeBus
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var openingID: String?
    @State private var characterDestinationID: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        TextField("搜索书名、章节、正文、人物或有效记忆", text: $query)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { startSearch() }
                        if isSearching { ProgressView() }
                    }
                    Button("搜索", action: startSearch)
                        .disabled(query.v2IOSTrimmed.isEmpty || isSearching || !sync.networkActionsAvailable)
                } footer: {
                    Text("只搜索作者当前可见的资料；内部生成过程文本和被拒证据不会进入结果。离线时不能搜索服务器。")
                    if !sync.networkActionsAvailable { V2DeskOfflineExplanation() }
                }

                if hasSearched {
                    Section(results.isEmpty ? "没有找到结果" : "结果") {
                        ForEach(results) { result in
                            Button { Task { await open(result) } } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 7) {
                                        Image(systemName: resultSymbol(result))
                                            .foregroundStyle(V2DeskPalette.color(.accent, scheme: .light))
                                            .frame(width: 16)
                                        Text(result.title.v2IOSTrimmed.isEmpty ? resultType(result) : result.title)
                                            .font(V2DeskType.control(14, weight: .medium))
                                            .lineLimit(1)
                                        Spacer()
                                        if openingID == result.id { ProgressView() }
                                    }
                                    if let snippet = result.snippet, !snippet.v2IOSTrimmed.isEmpty {
                                        Text(snippet)
                                            .font(V2DeskType.prose(12.5))
                                            .foregroundStyle(Color.secondary)
                                            .lineLimit(3)
                                    }
                                    Text(resultType(result))
                                        .font(V2DeskType.control(10.5))
                                        .foregroundStyle(Color.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                            .disabled(openingID != nil || !sync.networkActionsAvailable)
                        }
                    }
                }
            }
            .v2IOSNoticeOverlay()
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction) }
            }
        }
        .v2IOSPage()
        .sheet(isPresented: Binding(
            get: { characterDestinationID != nil },
            set: { if !$0 { characterDestinationID = nil } }
        )) {
            V2IOSCharactersView(initialCharacterID: characterDestinationID)
        }
    }

    private func startSearch() {
        guard !query.v2IOSTrimmed.isEmpty, !isSearching else { return }
        isSearching = true
        hasSearched = true
        Task {
            defer { isSearching = false }
            do {
                results = try await session.api.search(query: query.v2IOSTrimmed)
                    .items
            } catch {
                results = []
                notices.publish(error)
            }
        }
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
                workspace.replaceCurrentDestination(with: chapter)
            }
            dismiss()
        } catch {
            notices.publish(error)
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

struct V2IOSProjectPackageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var notices: NoticeBus
    @EnvironmentObject private var sync: ClientSyncStore
    @State private var preparingExport = false
    @State private var importing = false
    @State private var showingImporter = false
    @State private var sharingURL: URL?
    @State private var showingShare = false

    var body: some View {
        NavigationStack {
            List {
                Section("完整备份") {
                    Text("备份当前书的正文、人物、关联、有效记忆、人格和模型覆盖。访问密钥、全局模型设置和内部生成过程文本不会写入项目包。")
                        .font(V2DeskType.control(12.5))
                        .foregroundStyle(Color.secondary)
                    Button(preparingExport ? "正在准备备份" : "备份当前书") { Task { await exportCurrentBook() } }
                        .disabled(preparingExport || importing || session.currentBook == nil || !sync.networkActionsAvailable)
                }
                Section("恢复为新书") {
                    Text("恢复永远新建一本书，不会覆盖服务器上已有的内容。导入会先校验格式、清单和每个文件的完整性。")
                        .font(V2DeskType.control(12.5))
                        .foregroundStyle(Color.secondary)
                    Button(importing ? "正在验证并恢复" : "选择 .ictwbook 文件") { showingImporter = true }
                        .disabled(preparingExport || importing || !sync.networkActionsAvailable)
                }
                if preparingExport || importing {
                    Section { HStack { ProgressView(); Text(preparingExport ? "正在生成并校验项目包" : "正在验证并恢复项目") } }
                }
                if !sync.networkActionsAvailable {
                    Section { V2DeskOfflineExplanation() }
                }
            }
            .v2IOSNoticeOverlay()
            .navigationTitle("项目备份与恢复")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成", action: dismiss.callAsFunction).disabled(preparingExport || importing) } }
        }
        .v2IOSPage()
        .sheet(isPresented: $showingShare) {
            if let sharingURL { V2IOSShareSheet(urls: [sharingURL]) }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.ictwProjectPackage], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await importProject(from: url) }
        }
    }

    private func exportCurrentBook() async {
        guard let book = session.currentBook else {
            notices.publish("请先打开一本书再备份。")
            return
        }
        preparingExport = true
        defer { preparingExport = false }
        do {
            guard let data = await bookshelf.exportProject(book) else { return }
            let filename = sanitizedFilename(book.title) + ".ictwbook"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: .atomic)
            sharingURL = url
            showingShare = true
        } catch {
            notices.publish(error)
        }
    }

    private func importProject(from url: URL) async {
        importing = true
        defer { importing = false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let imported = await bookshelf.importProject(data) else { return }
            let warning = imported.warnings.isEmpty ? "" : "\n\(imported.warnings.map(\.message).joined(separator: "\n"))"
            notices.publish("已恢复《\(imported.title)》为新书。\(warning)")
            dismiss()
        } catch {
            notices.publish(error)
        }
    }

    private func sanitizedFilename(_ title: String) -> String {
        let trimmed = title.v2IOSTrimmed.isEmpty ? "ICTW-项目备份" : title.v2IOSTrimmed
        return trimmed.replacingOccurrences(of: "/", with: "-")
    }
}

private extension UTType {
    static let ictwProjectPackage = UTType(filenameExtension: "ictwbook") ?? .zip
}
