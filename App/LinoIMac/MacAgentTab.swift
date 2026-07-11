import SwiftUI

/// 右栏「Agent」tab：LLM Profiles（增/改/删/测）+ Agent 模型绑定（模型 Picker /
/// 启用思考 Toggle / 思考强度 Picker / temperature 滑杆 0–2 step 0.05，按
/// `temperatureAdjustable` 置灰）+ Agent 人格（DisclosureGroup 编辑 / 恢复默认）。
/// 连接段不放这里（⌘, / `MacSettingsSheet` 的事）。全部复用 `AgentSettingsStore`，capability
/// 语义逐条对齐 iOS `LinoIAgentSettingsPane`。
struct MacAgentTab: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var showingNewProfile = false

    private let roles = ["memory_selector", "writer", "reviser", "extractor"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                LinoISectionLabel("Agent / 模型")
                Text("四个 Agent 可分别绑定模型、人格与推理参数。")
                    .font(.system(size: 12))
                    .foregroundStyle(LinoTheme.muted)
            }

            profilesSection
            bindingsSection
            personasSection
        }
        .sheet(isPresented: $showingNewProfile) {
            MacProfileEditorSheet(profile: nil)
        }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LinoISectionLabel("LLM PROFILE")
                Spacer()
                LinoMacIconButton(systemName: "plus", size: 26, fontSize: 12, help: "新增 Profile") {
                    showingNewProfile = true
                }
            }

            if agents.profiles.isEmpty {
                emptyHint("还没有模型 Profile。第一版使用 OpenAI-compatible 协议。")
            } else {
                VStack(spacing: 10) {
                    ForEach(agents.profiles) { profile in
                        MacProfileRow(profile: profile)
                    }
                }
            }
        }
        .padding(14)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private var bindingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinoISectionLabel("AGENT 模型绑定")
            ForEach(roles, id: \.self) { role in
                MacAgentBindingCard(role: role)
            }
        }
        .padding(14)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private var personasSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LinoISectionLabel("Agent 人格")
            ForEach(personasInRoleOrder) { persona in
                MacPersonaCard(persona: persona)
            }
        }
        .padding(14)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private var personasInRoleOrder: [AgentPersona] {
        roles.compactMap { role in agents.personas.first(where: { $0.agentRole == role }) }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(LinoTheme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Profile row

private struct MacProfileRow: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var editing = false
    @State private var confirmingDelete = false

    let profile: LLMProfile

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinoTheme.accentDeep)
                .frame(width: 32, height: 32)
                .background(LinoTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(LinoTheme.ink)
                Text(profile.modelName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LinoTheme.accentDeep)
                Text(profile.baseURL)
                    .font(.system(size: 10.5, design: .monospaced))
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
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(LinoTheme.muted)
            .onHover { pointer($0) }
        }
        .padding(12)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $editing) {
            MacProfileEditorSheet(profile: profile)
        }
        .confirmationDialog("删除这个 Profile？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await agents.deleteProfile(profile) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - Profile editor sheet

private struct MacProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelName = ""

    let profile: LLMProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(profile == nil ? "新增 Profile" : "编辑 Profile")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LinoTheme.ink)

            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("PROFILE 名称")
                LinoITextField("Profile 名称", text: $name)
            }
            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("BASE URL")
                LinoITextField("https://api.example.com/v1", text: $baseURL)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("MODEL NAME")
                LinoITextField("model-name", text: $modelName)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel(profile == nil ? "API KEY" : "新 API KEY（不填则不替换）")
                LinoISecureField(profile == nil ? "API Key" : "新 API Key（不填则不替换）", text: $apiKey)
            }
            Text("协议固定为 OpenAI-compatible。编辑 Profile 时，密钥不会从后端回显。")
                .font(.system(size: 11.5))
                .foregroundStyle(LinoTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    .onHover { pointer($0) }
                Button(profile == nil ? "创建 Profile" : "保存 Profile") {
                    Task { await save() }
                }
                .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                .disabled(!canSave)
                .onHover { pointer($0 && canSave) }
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(LinoTheme.background)
        .onAppear {
            guard let profile else { return }
            name = profile.name
            baseURL = profile.baseURL
            modelName = profile.modelName
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

// MARK: - Agent binding card

/// 模型绑定卡。capability 判定（是否可切换思考 / 可选强度 / 可调 temperature /
/// 生效说明文案）逐字照 iOS `LinoIAgentBindingCard`，只把控件换成桌面外观。
private struct MacAgentBindingCard: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var temperatureDraft: Double?

    let role: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.linoAgentName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LinoTheme.ink)
                    Text(profileDescription)
                        .font(.system(size: 11))
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
                .fixedSize()
            }

            Divider().overlay(LinoTheme.hairline)

            Toggle("启用思考", isOn: thinkingSelection)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LinoTheme.body)
                .disabled(!canToggleThinking)

            HStack {
                Text("思考强度")
                    .font(.system(size: 12, weight: .semibold))
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
                .fixedSize()
                .disabled(!canChooseEffort)
            }

            temperatureRow

            Text(capabilityDescription)
                .font(.system(size: 10.5))
                .foregroundStyle(LinoTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onChange(of: binding?.temperature) { _, _ in
            temperatureDraft = nil
        }
    }

    private var temperatureRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Temperature")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LinoTheme.body)
                Spacer()
                Text(temperatureValueLabel)
                    .font(.system(size: 12).monospacedDigit().weight(.semibold))
                    .foregroundStyle(canAdjustTemperature ? LinoTheme.accentDeep : LinoTheme.faint)
                if binding?.temperature != nil {
                    Button("默认") {
                        temperatureDraft = nil
                        Task { await agents.configureTemperature(role: role, temperature: nil) }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(LinoTheme.accentDeep)
                    .onHover { pointer($0) }
                }
            }
            Slider(
                value: temperatureSelection,
                in: 0.0...2.0,
                step: 0.05
            ) { editing in
                if !editing {
                    Task { await agents.configureTemperature(role: role, temperature: temperatureDraft) }
                }
            }
            .disabled(!canAdjustTemperature)
        }
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

    private var canAdjustTemperature: Bool {
        binding?.llmProfileId != nil && (binding?.temperatureAdjustable ?? false)
    }

    private var temperatureValueLabel: String {
        if let value = temperatureDraft ?? binding?.temperature {
            return String(format: "%.2f", value)
        }
        return "模型默认"
    }

    private var temperatureSelection: Binding<Double> {
        Binding(
            get: { temperatureDraft ?? binding?.temperature ?? 0.7 },
            set: { temperatureDraft = ($0 * 100).rounded() / 100 }
        )
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

// MARK: - Persona card

private struct MacPersonaCard: View {
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
                    minHeight: 200,
                    placeholder: "填写这个 Agent 的人格、边界和写作偏好。"
                )
                HStack(spacing: 10) {
                    Button("恢复默认") {
                        Task { await agents.resetPersona(role: persona.agentRole) }
                    }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                    .onHover { pointer($0) }
                    Spacer()
                    Button("保存人格") {
                        var edited = persona
                        edited.systemPrompt = prompt
                        Task { await agents.savePersona(edited) }
                    }
                    .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                    .disabled(prompt == loadedPrompt)
                    .onHover { pointer($0 && prompt != loadedPrompt) }
                }
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(persona.agentRole.linoAgentName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LinoTheme.ink)
                Text(prompt.isEmpty ? "未设置人格" : "\(prompt.count) 字")
                    .font(.system(size: 11))
                    .foregroundStyle(LinoTheme.muted)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
