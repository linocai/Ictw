import SwiftUI

/// Reusable state marks and stripes. Builders should use these rather than
/// inventing color-only status indicators on either platform.
struct V2DeskStatusMark: View {
    let marker: V2DeskMarker
    var diameter: CGFloat = 7

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch marker.kind {
        case .hidden:
            Color.clear.frame(width: diameter, height: diameter)
        case .solidDot:
            Circle()
                .fill(toneColor)
                .frame(width: diameter, height: diameter)
        case .hollowRing:
            Circle()
                .stroke(toneColor, lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
        case .striped:
            V2DeskStripeFill()
                .frame(width: diameter, height: diameter)
                .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }

    private var toneColor: Color {
        switch marker.tone {
        case .neutral: V2DeskPalette.color(.tertiaryInk, scheme: colorScheme)
        case .accent: V2DeskPalette.color(.accent, scheme: colorScheme)
        case .success: V2DeskPalette.color(.success, scheme: colorScheme)
        case .warning: V2DeskPalette.color(.warning, scheme: colorScheme)
        case .danger: V2DeskPalette.color(.danger, scheme: colorScheme)
        case .stale: V2DeskPalette.color(.disabledInk, scheme: colorScheme)
        }
    }
}

struct V2DeskStripeFill: View {
    var lineWidth: CGFloat = 2
    var spacing: CGFloat = 4

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(V2DeskPalette.color(.staleStripeBase, scheme: colorScheme))
            )
            var x = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(
                    path,
                    with: .color(V2DeskPalette.color(.staleStripeLine, scheme: colorScheme)),
                    lineWidth: lineWidth
                )
                x += spacing
            }
        }
    }
}
