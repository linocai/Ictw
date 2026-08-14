import SwiftUI

// MARK: - Clean-room macOS primitives

/// The macOS v2 surface deliberately has its own primitives.  It consumes the
/// shared v2 tokens, but none of the v1 card, toolbar, or control styles.
struct V2MacDeskSurface<Content: View>: View {
    let token: V2DeskColorToken
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content.background(V2DeskPalette.color(token, scheme: colorScheme))
    }
}

struct V2MacDeskHairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(V2DeskPalette.color(.line, scheme: colorScheme))
            .frame(height: 1)
    }
}

struct V2MacDeskButton: ButtonStyle {
    enum Kind { case primary, secondary, danger, quiet }
    let kind: Kind
    var compact = false

    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let palette = V2MacDeskButtonPalette(kind: kind, scheme: colorScheme)
        configuration.label
            .font(V2DeskType.control(compact ? 11.5 : 12.5, weight: .medium))
            .foregroundStyle(palette.foreground)
            .padding(.horizontal, compact ? 11 : 15)
            .frame(minHeight: compact ? 28 : 32)
            .background(palette.background.opacity(configuration.isPressed ? 0.82 : 1))
            .overlay {
                RoundedRectangle(cornerRadius: V2DeskMetric.smallCornerRadius, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: V2DeskMetric.smallCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: V2DeskMetric.smallCornerRadius, style: .continuous))
    }
}

private struct V2MacDeskButtonPalette {
    let foreground: Color
    let background: Color
    let border: Color

    init(kind: V2MacDeskButton.Kind, scheme: ColorScheme) {
        let ink = V2DeskPalette.color(.ink, scheme: scheme)
        let paper = V2DeskPalette.color(.manuscriptPaper, scheme: scheme)
        let danger = V2DeskPalette.color(.danger, scheme: scheme)
        switch kind {
        case .primary:
            foreground = paper; background = ink; border = ink
        case .secondary:
            foreground = V2DeskPalette.color(.secondaryInk, scheme: scheme)
            background = .clear; border = V2DeskPalette.color(.strongLine, scheme: scheme)
        case .danger:
            foreground = danger; background = .clear; border = danger.opacity(0.38)
        case .quiet:
            foreground = V2DeskPalette.color(.secondaryInk, scheme: scheme)
            background = .clear; border = .clear
        }
    }
}

struct V2MacDeskIconButton: View {
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(disabled
                    ? V2DeskPalette.color(.disabledInk, scheme: colorScheme)
                    : V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct V2MacDeskStripeBackground: View {
    var body: some View {
        V2DeskStripeFill(lineWidth: 1.5, spacing: 6)
    }
}

struct V2MacDeskSectionLabel: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text.uppercased())
            .font(V2DeskType.control(10, weight: .medium))
            .tracking(1.3)
            .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
    }
}

struct V2MacDeskEmptyPrompt: View {
    let title: String
    let actionTitle: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 13) {
            Text(title)
                .font(V2DeskType.prose(16))
                .foregroundStyle(V2DeskPalette.color(.tertiaryInk, scheme: colorScheme))
            Button(actionTitle, action: action)
                .buttonStyle(V2MacDeskButton(kind: .secondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
    }
}

struct V2MacFlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth > 0 && rowWidth + spacing + size.width > width {
                totalHeight += rowHeight + spacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? rowWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if point.x > bounds.minX && point.x + spacing + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            if point.x > bounds.minX { point.x += spacing }
            view.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension V2DeskTone {
    func v2MacColor(scheme: ColorScheme) -> Color {
        switch self {
        case .neutral: V2DeskPalette.color(.tertiaryInk, scheme: scheme)
        case .accent: V2DeskPalette.color(.accent, scheme: scheme)
        case .success: V2DeskPalette.color(.success, scheme: scheme)
        case .warning: V2DeskPalette.color(.warning, scheme: scheme)
        case .danger: V2DeskPalette.color(.danger, scheme: scheme)
        case .stale: V2DeskPalette.color(.disabledInk, scheme: scheme)
        }
    }
}

extension String {
    var v2AgentLabel: String {
        switch self {
        case "memory_selector": return "记忆选择"
        case "writer": return "写作"
        case "checker": return "检查"
        case "extractor": return "整理记忆"
        case "inspiration_creator": return "找方向"
        default: return self
        }
    }
}
