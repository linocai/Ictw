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
            .animation(.smooth(duration: 0.25), value: status)
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
            .frame(minHeight: compact ? 34 : 44)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(LinoTheme.accentGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: LinoTheme.accent.opacity(configuration.isPressed ? 0.12 : 0.24), radius: 10, y: 6)
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct LinoISuccessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(LinoTheme.successGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

struct LinoITintButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 14, weight: .semibold))
            .foregroundStyle(LinoTheme.accentDeep)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(minHeight: compact ? 34 : 42)
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
            .frame(minHeight: compact ? 34 : 42)
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
