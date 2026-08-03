import SwiftUI
import AppKit

/// 桌面交互控件——玻璃图标钮 / 玻璃分段控件 / hover 手型 / 连接状态点。
/// 仅 Mac target 编译（无需 `#if os(macOS)` 守卫），样式结构参照
/// `Archive/LinoWritingV2` 的 `GlassControls.swift`，色值改走共享 `LinoTheme`。

// MARK: - 玻璃图标钮（34×34）

struct LinoMacIconButton: View {
    enum Style {
        case normal
        case danger
        case warning

        var foreground: Color {
            switch self {
            case .normal: return LinoTheme.body
            case .danger: return LinoTheme.danger
            case .warning: return LinoTheme.warning
            }
        }

        func background(hovered: Bool) -> Color {
            switch self {
            case .normal: return hovered ? LinoTheme.surface2 : LinoTheme.surface
            case .danger: return LinoTheme.danger.opacity(hovered ? 0.16 : 0.10)
            case .warning: return LinoTheme.warning.opacity(hovered ? 0.16 : 0.10)
            }
        }

        var stroke: Color {
            switch self {
            case .normal: return LinoMacMetrics.hairline
            case .danger: return LinoTheme.danger.opacity(0.28)
            case .warning: return LinoTheme.warning.opacity(0.28)
            }
        }
    }

    let systemName: String
    var style: Style = .normal
    var size: CGFloat = 34
    var fontSize: CGFloat = 14
    var help: String?
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(style.foreground)
                .frame(width: size, height: size)
                .background(
                    style.background(hovered: hovered),
                    in: RoundedRectangle(cornerRadius: LinoMacMetrics.controlRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: LinoMacMetrics.controlRadius, style: .continuous)
                        .stroke(style.stroke, lineWidth: LinoMacMetrics.hairlineWidth)
                )
                .brightness(hovered && !isDisabled ? 0.05 : 0)
                .linoAnimation(LinoMotion.hover, value: hovered)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .help(help ?? "")
        .accessibilityLabel(help ?? systemName)
        .onHover { inside in
            hovered = inside && !isDisabled
            pointer(hovered)
        }
    }
}

// MARK: - 玻璃分段控件（右栏 tab / 预览-编辑 切换）

struct LinoMacSegmented<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        LinoSegmentedCore(
            options: options,
            label: label,
            selection: $selection,
            enablesPointerFeedback: true
        )
    }
}

// MARK: - hover 手型 helper

/// 切换指针为「手型」，macOS hover 态统一入口。
@MainActor
func pointer(_ inside: Bool) {
    if inside {
        NSCursor.pointingHand.push()
    } else {
        NSCursor.pop()
    }
}

// MARK: - 连接状态点

/// 三态连接状态：未配置 / 已连接 / 未连接（401 单独呈现为「Token 失效」文案，
/// 视觉上仍归为未连接的红点）。探测方式=一次 `session.api.request("/books")`：
/// 2xx→已连接，401→Token 失效，其余（含 transport error）→未连接。
struct LinoMacConnectionChip: View {
    enum ConnectionState: Equatable {
        case notConfigured
        case connected
        case tokenInvalid
        case unreachable

        var dotColor: Color {
            switch self {
            case .notConfigured: return LinoTheme.faint
            case .connected: return LinoTheme.success
            case .tokenInvalid, .unreachable: return LinoTheme.danger
            }
        }

        var label: String {
            switch self {
            case .notConfigured: return "未配置"
            case .connected: return "已连接"
            case .tokenInvalid: return "Token 失效"
            case .unreachable: return "未连接"
            }
        }
    }

    @EnvironmentObject private var session: AppSession
    @State private var state: ConnectionState = .notConfigured

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.dotColor)
                .frame(width: 7, height: 7)
            Text(state.label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LinoTheme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(LinoTheme.surface, in: Capsule())
        .overlay(Capsule().stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth))
        .linoAnimation(LinoMotion.content, value: state)
        .task(id: session.baseURL + "\u{0}" + session.token) {
            await probe()
        }
    }

    private func probe() async {
        guard !session.baseURL.isEmpty, !session.token.isEmpty else {
            state = .notConfigured
            return
        }
        do {
            let _: [Book] = try await session.api.request("/books")
            state = .connected
        } catch APIError.http(401, _) {
            state = .tokenInvalid
        } catch {
            state = .unreachable
        }
    }
}
