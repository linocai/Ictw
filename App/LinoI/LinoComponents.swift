import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct LinoISectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(LinoTheme.faint)
    }
}

struct LinoIStatusPill: View {
    let text: String
    let status: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .contentTransition(.numericText())
            .foregroundStyle(palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .linoAnimation(LinoMotion.status, value: status)
            // 双 key：status 不变但 label 变化时（如「写作中」→「修订中」）也要 morph，对齐老项目 StatusBadge。
            .linoAnimation(LinoMotion.status, value: text)
    }

    private var palette: (text: Color, background: Color) {
        switch status {
        case "finalized":
            return (LinoTheme.success, LinoTheme.success.opacity(0.14))
        case "draft_ready":
            return (LinoTheme.cyan, LinoTheme.cyan.opacity(0.14))
        case "writing":
            return (LinoTheme.accentDeep, LinoTheme.accent.opacity(0.14))
        case "extracting":
            return (LinoTheme.warning, LinoTheme.warning.opacity(0.14))
        case "failed":
            return (LinoTheme.danger, LinoTheme.danger.opacity(0.14))
        default:
            return (LinoTheme.muted, LinoTheme.muted.opacity(0.13))
        }
    }
}

struct LinoIGenerationStatusPanel: View {
    let state: ChapterEditorPresentationState
    var onRetry: (() -> Void)?
    var onRetrySave: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("生成进度")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LinoTheme.ink)
                    Text(statusHeadline)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                saveBadge
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.steps) { step in
                    generationStep(step)
                }
            }

            if state.connectionInterrupted {
                explanationRow(
                    systemImage: "wifi.exclamationmark",
                    title: "连接暂时中断",
                    detail: LinoErrorPresenter.connectionInterrupted,
                    color: LinoTheme.warning
                )
            }

            if let failureStep {
                explanationRow(
                    systemImage: "exclamationmark.octagon.fill",
                    title: "\(failureStep.stage.label)未完成",
                    detail: state.headline ?? "任务没有完成，原因暂时未知。",
                    color: LinoTheme.danger
                )
                if let reason = state.validationReason, !reason.isEmpty {
                    Text("程序校验：\(reason)")
                        .font(.caption)
                        .foregroundStyle(LinoTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let code = state.failureCode, !code.isEmpty {
                    Text("错误代码：\(code)")
                        .font(.caption.monospaced())
                        .foregroundStyle(LinoTheme.muted)
                        .textSelection(.enabled)
                }
                if let action = state.recoveryAction, let onRetry {
                    Button(action: onRetry) {
                        Label(action.title, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                }
            } else if let cancelledStep {
                explanationRow(
                    systemImage: "stop.circle.fill",
                    title: "\(cancelledStep.stage.label)已停止",
                    detail: state.headline ?? "任务已停止，当前草稿仍保留。",
                    color: LinoTheme.muted
                )
            }

            if let saveFailure = state.saveState.failureMessage {
                explanationRow(
                    systemImage: "externaldrive.badge.exclamationmark",
                    title: state.saveState.label,
                    detail: saveFailure,
                    color: LinoTheme.danger
                )
                if let onRetrySave {
                    Button(action: onRetrySave) {
                        Label("重试保存", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(LinoITintButtonStyle(compact: true))
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(LinoTheme.hairline, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("生成进度，\(statusHeadline)，\(state.saveState.label)")
    }

    private var failureStep: ChapterGenerationStep? {
        state.steps.first { $0.state == .failed }
    }

    private var cancelledStep: ChapterGenerationStep? {
        state.steps.first { $0.state == .cancelled }
    }

    private var activeStep: ChapterGenerationStep? {
        state.steps.first { $0.state == .active }
    }

    private var statusHeadline: String {
        if failureStep != nil {
            return "生成未完成，原因和下一步见下方"
        }
        if cancelledStep != nil {
            return "任务已停止"
        }
        if state.connectionInterrupted {
            return "任务仍在服务器执行，App 正在自动重连"
        }
        if let headline = state.headline {
            return headline
        }
        if state.steps.allSatisfy({ $0.state == .completed }) {
            return "本章流程已完成"
        }
        if state.steps.first(where: { $0.stage == .bibleChecking })?.state == .completed {
            return "正文已就绪，等待接受并提取"
        }
        return "尚未开始生成"
    }

    private var statusColor: Color {
        if failureStep != nil { return LinoTheme.danger }
        if state.connectionInterrupted { return LinoTheme.warning }
        if activeStep != nil { return LinoTheme.accentDeep }
        return LinoTheme.muted
    }

    private var saveBadge: some View {
        Label(state.saveState.label, systemImage: saveSystemImage)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(state.saveState.failureMessage == nil ? LinoTheme.muted : LinoTheme.danger)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("保存状态：\(state.saveState.label)")
    }

    private var saveSystemImage: String {
        switch state.saveState {
        case .synced: return "checkmark.icloud"
        case .unsaved: return "pencil"
        case .savingLocally, .savingRemotely: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .localDraft, .restoredLocalDraft: return "externaldrive"
        case .localSaveFailed, .remoteSaveFailed: return "externaldrive.badge.exclamationmark"
        }
    }

    private func generationStep(_ step: ChapterGenerationStep) -> some View {
        HStack(spacing: 9) {
            Group {
                if step.state == .active {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: stepSystemImage(step.state))
                        .foregroundStyle(stepColor(step.state))
                }
            }
            .frame(width: 18, height: 18)

            Text(step.stage.label)
                .font(.system(size: 12, weight: step.state == .active ? .semibold : .regular))
                .foregroundStyle(step.state == .pending ? LinoTheme.faint : LinoTheme.body)
            Spacer()
            Text(stepStateLabel(step.state))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(stepColor(step.state))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.stage.label)，\(stepStateLabel(step.state))")
    }

    private func explanationRow(
        systemImage: String,
        title: String,
        detail: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LinoTheme.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(LinoTheme.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func stepSystemImage(_ state: ChapterGenerationStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .active: return "circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    private func stepColor(_ state: ChapterGenerationStepState) -> Color {
        switch state {
        case .pending: return LinoTheme.faint
        case .active: return LinoTheme.accent
        case .completed: return LinoTheme.success
        case .failed: return LinoTheme.danger
        case .cancelled: return LinoTheme.muted
        }
    }

    private func stepStateLabel(_ state: ChapterGenerationStepState) -> String {
        switch state {
        case .pending: return "待进行"
        case .active: return "进行中"
        case .completed: return "已完成"
        case .failed: return "未完成"
        case .cancelled: return "已停止"
        }
    }
}

struct LinoIAvatar: View {
    let name: String
    var size: CGFloat
    var rounded = false

    var body: some View {
        Group {
            if rounded {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(LinoTheme.logoGradient)
            } else {
                Circle().fill(LinoTheme.logoGradient)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Text(String(name.prefix(1)).uppercased())
                .font(.custom("Songti SC", size: size * 0.42).weight(.semibold))
                .foregroundStyle(.white)
        )
    }
}

struct LinoITextField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .foregroundStyle(LinoTheme.body)
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
    }
}

struct LinoISecureField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .foregroundStyle(LinoTheme.body)
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
    }
}

struct LinoINumberField: View {
    let placeholder: String
    @Binding var value: Int

    init(_ placeholder: String, value: Binding<Int>) {
        self.placeholder = placeholder
        _value = value
    }

    var body: some View {
        TextField(placeholder, value: $value, format: .number)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .textFieldStyle(.plain)
            .foregroundStyle(LinoTheme.body)
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
    }
}

struct LinoIEditor: View {
    let title: String
    @Binding var text: String
    var minHeight: CGFloat
    var placeholder: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LinoISectionLabel(title)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .frame(minHeight: minHeight)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(LinoTheme.body)
                    .padding(10)
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 15))
                        .foregroundStyle(LinoTheme.faint)
                        .padding(.horizontal, 15)
                        .padding(.top, 17)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LinoTheme.hairline, lineWidth: 0.5))
        }
    }
}

struct LinoIDraftPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("还没有正文。完成本章输入后点「生成」。")
                    .font(.custom("Songti SC", size: 15))
                    .foregroundStyle(LinoTheme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.custom("Songti SC", size: 16))
                        .foregroundStyle(LinoTheme.ink)
                        .lineSpacing(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paragraphs: [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

#if os(iOS)
/// Wraps `UIActivityViewController` so book export can hand a file straight
/// to the system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

struct LinoIEmptyCard: View {
    let title: String
    let subtitle: String
    var actionTitle: String? = "开始"
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(LinoTheme.faint)
            Text(title)
                .font(.headline)
                .foregroundStyle(LinoTheme.ink)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(LinoTheme.muted)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(LinoITintButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 24)
        .linoCard()
    }
}

struct LinoIPrimaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 18)
            .frame(minHeight: compact ? LinoControlMetrics.compactHeight : 44)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(LinoTheme.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: LinoTheme.accent.opacity(configuration.isPressed ? 0.12 : 0.24), radius: 10, y: 6)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct LinoISuccessButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(LinoTheme.successGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.42)
    }
}

struct LinoITintButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(LinoTheme.accentDeep)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? LinoControlMetrics.compactHeight : LinoControlMetrics.regularHeight)
            .background(LinoTheme.accentSoft.opacity(configuration.isPressed ? 0.70 : 0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LinoTheme.accent.opacity(0.18), lineWidth: 0.5))
    }
}

struct LinoIDangerButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(LinoTheme.danger)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? LinoControlMetrics.compactHeight : LinoControlMetrics.regularHeight)
            .background(LinoTheme.danger.opacity(configuration.isPressed ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LinoTheme.danger.opacity(0.24), lineWidth: 0.5))
    }
}

struct LinoIDashedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(LinoTheme.accentDeep)
            .background(LinoTheme.accentSoft.opacity(configuration.isPressed ? 0.48 : 0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 0.7, dash: [4]))
                    .foregroundStyle(LinoTheme.accent.opacity(0.36))
            )
    }
}

// MARK: - LinoISegmented（自绘玻璃分段，matchedGeometryEffect 滑动选中底）

/// iOS 自绘分段控件：`matchedGeometryEffect` 移动一个白色选中底（廉价，只动
/// `opacity`/位置），视觉与 macOS `LinoMacSegmented` 同构。块③ 起用它替换
/// iOS 侧系统 `Picker(.segmented)`。
struct LinoISegmented<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        LinoSegmentedCore(
            options: options,
            label: label,
            selection: $selection
        )
    }
}

/// Shared visual and interaction core used by both platform wrappers. macOS
/// adds pointer feedback conditionally; geometry, type, selection background,
/// animation and accessibility stay byte-identical across targets.
struct LinoSegmentedCore<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option
    var enablesPointerFeedback = false

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isSelected ? LinoTheme.ink : LinoTheme.muted)
                        .padding(.horizontal, 14)
                        .frame(height: LinoControlMetrics.segmentedHeight)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white)
                                    .shadow(color: LinoTheme.hex(0x143052, opacity: 0.14), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityValue(isSelected ? "已选择" : "未选择")
                #if os(macOS)
                .onHover { inside in
                    if enablesPointerFeedback {
                        pointer(inside)
                    }
                }
                #endif
            }
        }
        .padding(3)
        .background(LinoTheme.hairline, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(LinoTheme.hairline, lineWidth: 0.5)
        )
        .linoAnimation(LinoMotion.selection, value: selection)
    }
}

// MARK: - LinoICardButtonStyle（书卡/章节行/人物 chip 按压反馈）

/// 按下时 `scale 0.97`，动画 `LinoMotion.press`。iOS 书卡/章节行/人物 chip
/// 复用（块③ 起接入，补齐 press 态）。阴影恒定且置于 `scaleEffect` 之前——
/// 阴影随内容一次光栅化后只做 GPU 变换；按压期间逐帧重算阴影是 v1.4.0
/// 卡顿的主因之一（v1.4.1 性能修复），不要改回按压联动阴影。
struct LinoICardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .shadow(color: LinoTheme.hex(0x143052, opacity: 0.10), radius: 18, y: 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .linoAnimation(LinoMotion.press, value: configuration.isPressed)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var size = CGSize.zero
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let item = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + item.width > maxWidth {
                size.width = max(size.width, rowWidth)
                size.height += rowHeight + spacing
                rowWidth = item.width
                rowHeight = item.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + item.width
                rowHeight = max(rowHeight, item.height)
            }
        }
        size.width = max(size.width, rowWidth)
        size.height += rowHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let item = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + item.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item))
            x += item.width + spacing
            rowHeight = max(rowHeight, item.height)
        }
    }
}
