import SwiftUI

/// 连接配置：首启（`firstRun: true`，`MacShell` 在 `session.token.isEmpty`
/// 时整屏展示，多一段引导文案 + logo）与设置 sheet 内嵌（`firstRun: false`，
/// 块⑤的 `MacSettingsSheet` 用）共用同一张卡片。样式参考
/// `Archive/LinoWritingV2` 的 `MacConnectionSettingsSection`（服务器状态行 +
/// 等宽地址栏 + 密钥栏 + 保存按钮 + 提示语），语义与颜色一律走本项目
/// `LinoTheme`/`LinoMacMetrics`，不搬老项目的 KeychainStore/AppStore。
///
/// 保存流程：写入 `session.baseURL`/`session.token` → `session.saveConnection()`
/// （落 UserDefaults + Keychain）→ `bookshelf.load()` 刷新书架。保存成功后
/// `session.token` 立即非空，`MacShell` 的状态机会自动路由离开本页——这与
/// 保存的 token 是否真的有效无关，真实连通性由卡片内的 `LinoMacConnectionChip`
/// （一次 `/books` 探测）持续反馈。
struct MacConnectionView: View {
    let firstRun: Bool

    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore

    @State private var baseURL = ""
    @State private var token = ""
    @State private var isSaving = false
    @State private var feedback: Feedback?

    private enum Feedback: Equatable {
        case success
        case failure(String)

        var text: String {
            switch self {
            case .success: return "已保存，正在连接…"
            case .failure(let message): return message
            }
        }

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: return LinoTheme.success
            case .failure: return LinoTheme.danger
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if firstRun { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 22) {
                if firstRun { header }
                card
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity, alignment: firstRun ? .center : .leading)
            if firstRun { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, firstRun ? 0 : 20)
        .frame(maxWidth: .infinity, maxHeight: firstRun ? .infinity : nil)
        .onAppear {
            baseURL = session.baseURL
            token = session.token
        }
    }

    // MARK: - 首启引导

    private var header: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinoTheme.logoGradient)
                .frame(width: 52, height: 52)
                .overlay(
                    Text("L")
                        .font(.custom("Songti SC", size: 24).weight(.bold))
                        .foregroundStyle(.white)
                )
                .shadow(color: LinoTheme.accent.opacity(0.35), radius: 14, y: 8)
            Text("配置连接")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(LinoTheme.ink)
            Text("填写后端地址和 Bearer Token 即可开始使用 LinoI for Mac；两项都保存在本机 Keychain。")
                .font(.system(size: 12.5))
                .foregroundStyle(LinoTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 连接卡片

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("服务器")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(LinoTheme.body)
                Spacer()
                LinoMacConnectionChip()
            }

            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("后端地址")
                LinoITextField("https://your-server.com", text: $baseURL)
                    .font(.system(size: 13, design: .monospaced))
                    .onChange(of: baseURL) { _, _ in feedback = nil }
            }

            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("访问密钥 · Bearer Token")
                LinoISecureField("粘贴你的 Token", text: $token)
                    .onChange(of: token) { _, _ in feedback = nil }
                    .onSubmit { Task { await save() } }
            }

            if let feedback {
                Label(feedback.text, systemImage: feedback.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(feedback.color)
            }

            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }
                    Text("保存并连接")
                }
            }
            .buttonStyle(LinoIPrimaryButtonStyle())
            .disabled(!canSave || isSaving)
            .onHover { pointer($0 && canSave && !isSaving) }

            Text("这把 Token 用于访问你自己的 LinoI 后端。Mac 与 iOS 是不同的沙盒容器，Keychain 不共享，需要在每台设备各保存一次。")
                .font(.system(size: 11.5))
                .foregroundStyle(LinoTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    // MARK: - 保存

    private var canSave: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        guard canSave, !isSaving else { return }
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmedURL)?.scheme != nil else {
            feedback = .failure("后端地址无效，请包含 http(s):// 前缀")
            return
        }
        isSaving = true
        session.baseURL = trimmedURL
        session.token = trimmedToken
        session.saveConnection()
        await bookshelf.load()
        isSaving = false
        feedback = .success
    }
}
