import SwiftUI

struct LinoIAgentSettingsPane: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var showingNewProfile = false

    private let roles = ["memory_selector", "writer", "reviser", "extractor"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent / 模型")
                    .font(.title3.bold())
                    .foregroundStyle(LinoTheme.ink)
                Text("四个 Agent 可分别绑定模型、人格与推理参数。")
                    .font(.caption)
                    .foregroundStyle(LinoTheme.muted)
            }

            LinoIConnectionSettingsSection()
            profilesSection
            bindingsSection
            personasSection
        }
        .padding(.top, 8)
        .sheet(isPresented: $showingNewProfile) {
            LinoIProfileEditorSheet(profile: nil)
                .presentationDetents([.large])
        }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LinoISectionLabel("LLM PROFILE")
                Spacer()
                Button {
                    showingNewProfile = true
                } label: {
                    Label("Profile", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(LinoITintButtonStyle(compact: true))
            }

            if agents.profiles.isEmpty {
                Text("还没有模型 Profile。第一版使用 OpenAI-compatible 协议。")
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(agents.profiles) { profile in
                        LinoIProfileRow(profile: profile)
                    }
                }
            }
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
    }

    private var bindingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinoISectionLabel("AGENT 模型绑定")
            ForEach(roles, id: \.self) { role in
                LinoIAgentBindingCard(role: role)
            }
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
    }

    private var personasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinoISectionLabel("Agent 人格")
            ForEach(personasInRoleOrder) { persona in
                LinoIPersonaCard(persona: persona)
            }
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
    }

    private var personasInRoleOrder: [AgentPersona] {
        roles.compactMap { role in agents.personas.first(where: { $0.agentRole == role }) }
    }

}

private struct LinoIAgentBindingCard: View {
    @EnvironmentObject private var agents: AgentSettingsStore

    let role: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.linoAgentName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LinoTheme.ink)
                    Text(profileDescription)
                        .font(.caption)
                        .foregroundStyle(LinoTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
                Picker(role.linoAgentName, selection: profileSelection) {
                    Text("未绑定").tag("")
                    ForEach(agents.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 150)
            }

            Divider().overlay(LinoTheme.hairline)

            Toggle("启用思考", isOn: thinkingSelection)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(LinoTheme.body)
                .disabled(!canToggleThinking)

            HStack {
                Text("思考强度")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LinoTheme.body)
                Spacer()
                Picker("思考强度", selection: effortSelection) {
                    Text("模型默认").tag("")
                    ForEach(capabilities.reasoningEffortLevels, id: \.self) { level in
                        Text(effortName(level)).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!canChooseEffort)
            }

            Text(capabilityDescription)
                .font(.caption2)
                .foregroundStyle(LinoTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var binding: AgentBinding? {
        agents.bindings.first(where: { $0.agentRole == role })
    }

    private var capabilities: ModelCapabilities {
        binding?.capabilities ?? .unsupported
    }

    private var effectiveThinking: Bool {
        binding?.effectiveThinkingEnabled
            ?? binding?.thinkingEnabled
            ?? capabilities.thinkingRequired
    }

    private var canToggleThinking: Bool {
        binding?.llmProfileId != nil &&
        capabilities.thinkingToggleSupported &&
        capabilities.thinkingCanDisable &&
        !capabilities.thinkingRequired
    }

    private var canChooseEffort: Bool {
        binding?.llmProfileId != nil &&
        effectiveThinking &&
        !capabilities.reasoningEffortLevels.isEmpty
    }

    private var profileDescription: String {
        guard let id = binding?.llmProfileId,
              let profile = agents.profiles.first(where: { $0.id == id }) else {
            return "未绑定模型"
        }
        return "\(profile.name) · \(profile.modelName)"
    }

    private var capabilityDescription: String {
        guard binding?.llmProfileId != nil else { return "绑定模型后可查看推理能力。" }
        if capabilities.thinkingRequired {
            return "此模型锁定开启思考；当前实际生效：开启\(effectiveEffortText)。"
        }
        if !capabilities.thinkingToggleSupported && capabilities.reasoningEffortLevels.isEmpty {
            return "此模型未声明可调思考参数，后端不会发送额外参数。"
        }
        if binding?.effectiveThinkingEnabled == nil && binding?.thinkingEnabled == nil {
            return "当前实际生效：模型默认；后端不发送额外思考参数。"
        }
        let state = effectiveThinking ? "开启" : "关闭"
        let temperatureNote = effectiveThinking && !capabilities.temperatureEffectiveWhenThinking
            ? "；开启思考时 temperature 不生效"
            : ""
        return "当前实际生效：\(state)\(effectiveEffortText)\(temperatureNote)。"
    }

    private var effectiveEffortText: String {
        guard let effort = binding?.effectiveReasoningEffort, !effort.isEmpty else { return "" }
        return " / \(effortName(effort))"
    }

    private var profileSelection: Binding<String> {
        Binding(
            get: { binding?.llmProfileId ?? "" },
            set: { value in
                Task { await agents.bind(role: role, profileId: value.isEmpty ? nil : value) }
            }
        )
    }

    private var thinkingSelection: Binding<Bool> {
        Binding(
            get: { effectiveThinking },
            set: { value in
                Task {
                    await agents.configureThinking(
                        role: role,
                        enabled: value,
                        effort: value ? binding?.reasoningEffort : nil
                    )
                }
            }
        )
    }

    private var effortSelection: Binding<String> {
        Binding(
            get: { binding?.reasoningEffort ?? "" },
            set: { value in
                Task {
                    await agents.configureThinking(
                        role: role,
                        enabled: binding?.thinkingEnabled ?? effectiveThinking,
                        effort: value.isEmpty ? nil : value
                    )
                }
            }
        )
    }

    private func effortName(_ effort: String) -> String {
        switch effort {
        case "minimal": return "极低"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "max": return "最高"
        default: return effort
        }
    }
}

struct LinoIConnectionSettingsSection: View {
    @EnvironmentObject private var session: AppSession
    @State private var baseURL = ""
    @State private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinoISectionLabel("连接")
            LinoITextField("后端地址", text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            LinoISecureField("Bearer Token", text: $token)
            HStack {
                Text("Token 保存到 Keychain；本地调试也可通过 LINOI_DEBUG_TOKEN 注入。")
                    .font(.caption)
                    .foregroundStyle(LinoTheme.muted)
                Spacer()
                Button("保存") {
                    session.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.saveConnection()
                }
                .buttonStyle(LinoITintButtonStyle(compact: true))
            }
        }
        .padding(14)
        .linoGlass(cornerRadius: 20)
        .onAppear {
            baseURL = session.baseURL
            token = session.token
        }
    }
}

struct LinoIConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var baseURL = ""
    @State private var token = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                LinoITextField("后端地址", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LinoISecureField("Bearer Token", text: $token)
                Text("保存后会重新读取书架。")
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.muted)
                Spacer()
                Button("保存连接") {
                    session.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.saveConnection()
                    Task {
                        await bookshelf.load()
                        dismiss()
                    }
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
            }
            .padding(18)
            .navigationTitle("连接设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .background(LinoTheme.background.ignoresSafeArea())
            .onAppear {
                baseURL = session.baseURL
                token = session.token
            }
        }
    }
}

private struct LinoIProfileRow: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var editing = false
    @State private var confirmingDelete = false

    let profile: LLMProfile

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LinoTheme.accentDeep)
                .frame(width: 34, height: 34)
                .background(LinoTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(profile.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LinoTheme.ink)
                Text(profile.modelName)
                    .font(.caption)
                    .foregroundStyle(LinoTheme.accentDeep)
                Text(profile.baseURL)
                    .font(.caption2)
                    .foregroundStyle(LinoTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("测试连接", systemImage: "bolt.horizontal") {
                    Task { await agents.testProfile(profile) }
                }
                Button("编辑", systemImage: "pencil") { editing = true }
                Button("删除", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LinoTheme.muted)
        }
        .padding(12)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $editing) {
            LinoIProfileEditorSheet(profile: profile)
                .presentationDetents([.large])
        }
        .confirmationDialog("删除这个 Profile？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await agents.deleteProfile(profile) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

private struct LinoIProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelName = ""

    let profile: LLMProfile?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LinoITextField("Profile 名称", text: $name)
                    LinoITextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LinoITextField("Model Name", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LinoISecureField(profile == nil ? "API Key" : "新 API Key（不填则不替换）", text: $apiKey)
                    Text("协议固定为 OpenAI-compatible。编辑 Profile 时，密钥不会从后端回显。")
                        .font(.footnote)
                        .foregroundStyle(LinoTheme.muted)
                    Button(profile == nil ? "创建 Profile" : "保存 Profile") {
                        Task { await save() }
                    }
                    .buttonStyle(LinoIPrimaryButtonStyle())
                    .disabled(!canSave)
                }
                .padding(18)
            }
            .navigationTitle(profile == nil ? "新增 Profile" : "编辑 Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .background(LinoTheme.background.ignoresSafeArea())
            .onAppear {
                guard let profile else { return }
                name = profile.name
                baseURL = profile.baseURL
                modelName = profile.modelName
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (profile != nil || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func save() async {
        if var profile {
            profile.name = name
            profile.baseURL = baseURL
            profile.modelName = modelName
            await agents.updateProfile(profile, apiKey: apiKey)
        } else {
            await agents.createProfile(name: name, baseURL: baseURL, apiKey: apiKey, model: modelName)
        }
        dismiss()
    }
}

private struct LinoIPersonaCard: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var prompt = ""
    @State private var loadedRole = ""
    @State private var loadedPrompt = ""

    let persona: AgentPersona

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                LinoIEditor(
                    title: "\(persona.agentRole.linoAgentName) System Prompt",
                    text: $prompt,
                    minHeight: 260,
                    placeholder: "填写这个 Agent 的人格、边界和写作偏好。"
                )
                HStack(spacing: 10) {
                    Button("恢复默认") {
                        Task { await agents.resetPersona(role: persona.agentRole) }
                    }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    Spacer()
                    Button("保存人格") {
                        var edited = persona
                        edited.systemPrompt = prompt
                        Task { await agents.savePersona(edited) }
                    }
                    .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                    .disabled(prompt == loadedPrompt)
                }
            }
            .padding(.top, 12)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(persona.agentRole.linoAgentName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LinoTheme.ink)
                    Text(prompt.isEmpty ? "未设置人格" : "\(prompt.count) 字")
                        .font(.caption)
                        .foregroundStyle(LinoTheme.muted)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { sync() }
        .onChange(of: persona.systemPrompt) { _, _ in sync(force: true) }
    }

    private func sync(force: Bool = false) {
        guard force || loadedRole != persona.agentRole else { return }
        loadedRole = persona.agentRole
        loadedPrompt = persona.systemPrompt
        prompt = persona.systemPrompt
    }
}
