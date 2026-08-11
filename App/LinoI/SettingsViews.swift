import SwiftUI

struct LinoIAgentSettingsPane: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var showingNewProfile = false

    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]

    var body: some View {
        VStack(spacing: 0) {
            LinoISecondaryHeader(title: "Agent 与模型", dismiss: dismiss.callAsFunction)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("五个现役 AGENT") {
                        VStack(spacing: 0) {
                            ForEach(Array(roles.enumerated()), id: \.element) { offset, role in
                                NavigationLink {
                                    LinoIAgentDetailView(role: role)
                                } label: {
                                    agentRow(role)
                                }
                                .buttonStyle(.plain)
                                if offset != roles.count - 1 {
                                    Divider().overlay(LinoTheme.line).padding(.leading, 14)
                                }
                            }
                        }
                    }

                    section("LLM PROFILE") {
                        VStack(spacing: 0) {
                            if agents.profiles.isEmpty {
                                Text("还没有模型 Profile。第一版使用 OpenAI-compatible 协议。")
                                    .font(LinoType.ui(12))
                                    .foregroundStyle(LinoTheme.faint)
                                    .padding(14)
                            } else {
                                ForEach(Array(agents.profiles.enumerated()), id: \.element.id) { offset, profile in
                                    LinoIProfileRow(profile: profile)
                                    if offset != agents.profiles.count - 1 {
                                        Divider().overlay(LinoTheme.line).padding(.leading, 14)
                                    }
                                }
                            }
                            Divider().overlay(LinoTheme.line).padding(.leading, 14)
                            Button { showingNewProfile = true } label: {
                                Label("新增 Profile", systemImage: "plus")
                                    .font(LinoType.ui(15, .medium))
                                    .foregroundStyle(LinoTheme.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: 52)
                                    .padding(.horizontal, 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .background(LinoTheme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await agents.load() }
        .sheet(isPresented: $showingNewProfile) {
            LinoIProfileEditorSheet(profile: nil)
                .presentationDetents([.large])
                .presentationCornerRadius(20)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LinoISectionLabel(title)
                .padding(.horizontal, 6)
            content()
                .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func agentRow(_ role: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(role.linoAgentName)
                    .font(LinoType.ui(15, .medium))
                    .foregroundStyle(LinoTheme.ink)
                Text(profileDescription(role))
                    .font(LinoType.caption)
                    .foregroundStyle(LinoTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(thinkingDescription(role))
                .font(LinoType.caption)
                .foregroundStyle(LinoTheme.faint)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LinoTheme.faint)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .contentShape(Rectangle())
    }

    private func profileDescription(_ role: String) -> String {
        guard let binding = agents.bindings.first(where: { $0.agentRole == role }),
              let id = binding.llmProfileId,
              let profile = agents.profiles.first(where: { $0.id == id }) else {
            return "未绑定模型"
        }
        return "\(profile.name) · \(profile.modelName)"
    }

    private func thinkingDescription(_ role: String) -> String {
        guard let binding = agents.bindings.first(where: { $0.agentRole == role }) else { return "模型默认" }
        let enabled = binding.effectiveThinkingEnabled ?? binding.thinkingEnabled
        guard enabled == true else { return enabled == false ? "思考 关" : "模型默认" }
        let effort = binding.effectiveReasoningEffort ?? binding.reasoningEffort
        return effort.map { "思考 \(effortName($0))" } ?? "思考 开"
    }
}

private struct LinoISecondaryHeader: View {
    let title: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LinoTheme.ink)
            Text(title)
                .font(LinoType.ui(16, .semibold))
                .foregroundStyle(LinoTheme.ink)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .overlay(alignment: .bottom) { Rectangle().fill(LinoTheme.line).frame(height: 1) }
    }
}

private struct LinoIAgentDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var agents: AgentSettingsStore
    let role: String

    var body: some View {
        VStack(spacing: 0) {
            LinoISecondaryHeader(title: role.linoAgentName, dismiss: dismiss.callAsFunction)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        LinoISectionLabel("模型与推理").padding(.horizontal, 6)
                        LinoIAgentBindingCard(role: role)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        LinoISectionLabel("人格").padding(.horizontal, 6)
                        if let persona = agents.personas.first(where: { $0.agentRole == role }) {
                            LinoIAgentPersonaEditor(persona: persona)
                        } else {
                            Text("当前服务未返回人格配置。")
                                .font(LinoType.ui(12))
                                .foregroundStyle(LinoTheme.faint)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .linoCard(cornerRadius: 16)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .background(LinoTheme.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct LinoIAgentBindingCard: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var temperatureDraft: Double?

    let role: String

    var body: some View {
        VStack(spacing: 0) {
            row("绑定模型") {
                Picker("绑定模型", selection: profileSelection) {
                    Text("未绑定").tag("")
                    ForEach(agents.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(LinoTheme.muted)
            }
            Divider().overlay(LinoTheme.line).padding(.leading, 14)
            row("启用思考") {
                Toggle("", isOn: thinkingSelection)
                    .labelsHidden()
                    .tint(LinoTheme.accent)
                    .disabled(!canToggleThinking)
            }
            Divider().overlay(LinoTheme.line).padding(.leading, 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("思考强度").font(LinoType.ui(15)).foregroundStyle(LinoTheme.ink)
                    Spacer()
                    if capabilities.reasoningEffortLevels.isEmpty {
                        Text("模型默认").font(LinoType.caption).foregroundStyle(LinoTheme.faint)
                    }
                }
                if !capabilities.reasoningEffortLevels.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(capabilities.reasoningEffortLevels, id: \.self) { effort in
                            let selected = (binding?.reasoningEffort ?? binding?.effectiveReasoningEffort) == effort
                            Button {
                                Task {
                                    await agents.configureThinking(
                                        role: role,
                                        enabled: binding?.thinkingEnabled ?? effectiveThinking,
                                        effort: effort
                                    )
                                }
                            } label: {
                                Text(effortName(effort))
                                    .font(LinoType.ui(12.5, .medium))
                                    .foregroundStyle(selected ? LinoTheme.ink : LinoTheme.muted)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .background(selected ? LinoTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(LinoTheme.bg2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .disabled(!canChooseEffort)
                }
            }
            .padding(14)
            Divider().overlay(LinoTheme.line).padding(.leading, 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Temperature").font(LinoType.ui(15)).foregroundStyle(LinoTheme.ink)
                    Spacer()
                    Text(temperatureValueLabel)
                        .font(.system(size: 14, weight: .semibold).monospaced())
                        .foregroundStyle(canAdjustTemperature ? LinoTheme.accent : LinoTheme.faint)
                    if binding?.temperature != nil {
                        Button("默认") {
                            temperatureDraft = nil
                            Task { await agents.configureTemperature(role: role, temperature: nil) }
                        }
                        .font(LinoType.ui(12, .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(LinoTheme.muted)
                    }
                }
                Slider(value: temperatureSelection, in: 0...2, step: 0.05) { editing in
                    if !editing { Task { await agents.configureTemperature(role: role, temperature: temperatureDraft) } }
                }
                .tint(LinoTheme.accent)
                .disabled(!canAdjustTemperature)
                Text(capabilityDescription)
                    .font(LinoType.ui(11.5))
                    .foregroundStyle(LinoTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: binding?.temperature) { _, _ in temperatureDraft = nil }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(LinoType.ui(15)).foregroundStyle(LinoTheme.ink)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private var binding: AgentBinding? { agents.bindings.first(where: { $0.agentRole == role }) }
    private var capabilities: ModelCapabilities { binding?.capabilities ?? .unsupported }
    private var effectiveThinking: Bool { binding?.effectiveThinkingEnabled ?? binding?.thinkingEnabled ?? capabilities.thinkingRequired }
    private var canToggleThinking: Bool {
        binding?.llmProfileId != nil && capabilities.thinkingToggleSupported && capabilities.thinkingCanDisable && !capabilities.thinkingRequired
    }
    private var canChooseEffort: Bool {
        binding?.llmProfileId != nil && effectiveThinking && !capabilities.reasoningEffortLevels.isEmpty
    }
    private var canAdjustTemperature: Bool { binding?.llmProfileId != nil && (binding?.temperatureAdjustable ?? false) }
    private var temperatureValueLabel: String {
        if let value = temperatureDraft ?? binding?.temperature { return String(format: "%.2f", value) }
        return "默认"
    }
    private var temperatureSelection: Binding<Double> {
        Binding(get: { temperatureDraft ?? binding?.temperature ?? 0.7 }, set: { temperatureDraft = ($0 * 100).rounded() / 100 })
    }
    private var profileSelection: Binding<String> {
        Binding(
            get: { binding?.llmProfileId ?? "" },
            set: { value in Task { await agents.bind(role: role, profileId: value.isEmpty ? nil : value) } }
        )
    }
    private var thinkingSelection: Binding<Bool> {
        Binding(
            get: { effectiveThinking },
            set: { value in
                Task { await agents.configureThinking(role: role, enabled: value, effort: value ? binding?.reasoningEffort : nil) }
            }
        )
    }
    private var capabilityDescription: String {
        guard binding?.llmProfileId != nil else { return "绑定模型后可查看推理能力。" }
        if capabilities.thinkingRequired { return "此模型锁定开启思考；当前实际生效：开启\(effectiveEffortText)。" }
        if !capabilities.thinkingToggleSupported && capabilities.reasoningEffortLevels.isEmpty {
            return "此模型未声明可调思考参数，后端不会发送额外参数。"
        }
        if binding?.effectiveThinkingEnabled == nil && binding?.thinkingEnabled == nil {
            return "当前实际生效：模型默认；后端不发送额外思考参数。"
        }
        let state = effectiveThinking ? "开启" : "关闭"
        let note = effectiveThinking && !capabilities.temperatureEffectiveWhenThinking ? "；开启思考时 temperature 不生效" : ""
        return "当前实际生效：\(state)\(effectiveEffortText)\(note)。"
    }
    private var effectiveEffortText: String {
        guard let effort = binding?.effectiveReasoningEffort, !effort.isEmpty else { return "" }
        return " / \(effortName(effort))"
    }
}

private struct LinoIAgentPersonaEditor: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var prompt = ""
    @State private var loadedPrompt = ""
    let persona: AgentPersona

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                LinoISectionLabel("可编辑人格词")
                TextEditor(text: $prompt)
                    .scrollContentBackground(.hidden)
                    .font(LinoType.serif(14))
                    .lineSpacing(12)
                    .foregroundStyle(LinoTheme.ink2)
                    .frame(minHeight: 210)
            }
            .padding(14)
            Divider().overlay(LinoTheme.line)
            VStack(alignment: .leading, spacing: 9) {
                Label("程序协议 · 只读，始终生效", systemImage: "lock")
                    .font(LinoType.ui(10.5, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(LinoTheme.faint)
                Text(persona.programProtocol.isEmpty ? "旧版服务未提供程序协议。" : persona.programProtocol)
                    .font(LinoType.ui(12.5))
                    .lineSpacing(7)
                    .foregroundStyle(LinoTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(LinoTheme.surface2)
            Divider().overlay(LinoTheme.line)
            HStack(spacing: 10) {
                Button("恢复默认") { Task { await agents.resetPersona(role: persona.agentRole) } }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                Spacer()
                Button("保存人格") {
                    var edited = persona
                    edited.systemPrompt = prompt
                    edited.editablePersona = prompt
                    Task { await agents.savePersona(edited) }
                }
                .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                .disabled(prompt == loadedPrompt)
            }
            .padding(12)
        }
        .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear { sync() }
        .onChange(of: persona.editablePersona) { _, _ in sync() }
    }

    private func sync() {
        loadedPrompt = persona.editablePersona
        prompt = persona.editablePersona
    }
}

struct LinoIConnectionSettingsSection: View {
    @State private var showingConnection = false
    var body: some View {
        Button("打开后端连接设置") { showingConnection = true }
            .buttonStyle(LinoITintButtonStyle())
            .sheet(isPresented: $showingConnection) { LinoIConnectionSheet().presentationDetents([.height(360)]) }
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
                Text("Token 保存到 Keychain，保存后会重新读取书架。")
                    .font(LinoType.ui(12))
                    .foregroundStyle(LinoTheme.muted)
                Spacer()
                Button("保存连接") {
                    session.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.saveConnection()
                    Task { await bookshelf.load(); dismiss() }
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
            }
            .padding(18)
            .navigationTitle("后端连接")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.foregroundStyle(LinoTheme.accent) }
            }
            .background(LinoTheme.bg.ignoresSafeArea())
            .onAppear { baseURL = session.baseURL; token = session.token }
        }
    }
}

private struct LinoIProfileRow: View {
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var editing = false
    @State private var confirmingDelete = false
    let profile: LLMProfile

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(LinoType.ui(15, .medium))
                    .foregroundStyle(LinoTheme.ink)
                Text("\(profile.modelName) · \(profile.baseURL)")
                    .font(LinoType.caption)
                    .foregroundStyle(LinoTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Menu {
                Button("测试连接", systemImage: "bolt.horizontal") { Task { await agents.testProfile(profile) } }
                Button("编辑", systemImage: "pencil") { editing = true }
                Button("删除", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(LinoTheme.muted)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .sheet(isPresented: $editing) {
            LinoIProfileEditorSheet(profile: profile).presentationDetents([.large]).presentationCornerRadius(20)
        }
        .confirmationDialog("删除这个 Profile？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await agents.deleteProfile(profile) } }
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
                    LinoITextField("Base URL", text: $baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LinoITextField("Model Name", text: $modelName).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LinoISecureField(profile == nil ? "API Key" : "新 API Key（不填则不替换）", text: $apiKey)
                    Text("协议固定为 OpenAI-compatible。编辑 Profile 时，密钥不会从后端回显。")
                        .font(LinoType.ui(12)).foregroundStyle(LinoTheme.muted)
                    Button(profile == nil ? "创建 Profile" : "保存 Profile") { Task { await save() } }
                        .buttonStyle(LinoIPrimaryButtonStyle()).disabled(!canSave)
                }
                .padding(18)
            }
            .navigationTitle(profile == nil ? "新增 Profile" : "编辑 Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .background(LinoTheme.bg.ignoresSafeArea())
            .onAppear {
                guard let profile else { return }
                name = profile.name; baseURL = profile.baseURL; modelName = profile.modelName
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
            profile.name = name; profile.baseURL = baseURL; profile.modelName = modelName
            await agents.updateProfile(profile, apiKey: apiKey)
        } else {
            await agents.createProfile(name: name, baseURL: baseURL, apiKey: apiKey, model: modelName)
        }
        dismiss()
    }
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
