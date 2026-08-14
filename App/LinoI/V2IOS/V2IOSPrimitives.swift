import SwiftUI
import UIKit

// MARK: - Clean-room iOS controls

struct V2IOSPage: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(V2DeskType.control(14))
            .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
            .background(V2DeskPalette.color(.desk, scheme: colorScheme).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
    }
}

extension View {
    func v2IOSPage() -> some View { modifier(V2IOSPage()) }

    func v2IOSPaper(_ token: V2DeskColorToken = .manuscriptPaper, corner: CGFloat = V2DeskMetric.cardCornerRadius) -> some View {
        modifier(V2IOSPaper(token: token, corner: corner))
    }
}

private struct V2IOSPaper: ViewModifier {
    let token: V2DeskColorToken
    let corner: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(V2DeskPalette.color(token, scheme: colorScheme), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(V2DeskPalette.color(.line, scheme: colorScheme), lineWidth: 1)
            }
    }
}

struct V2IOSSectionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(V2DeskType.control(11, weight: .medium))
            .tracking(0.9)
            .foregroundStyle(Color.secondary)
    }
}

struct V2IOSBackButton: View {
    let action: () -> Void
    var label = "返回"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text("‹")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                .frame(width: V2DeskMetric.mobileTapTarget, height: V2DeskMetric.mobileTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct V2IOSPrimaryButton: View {
    let title: String
    var disabled = false
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(V2DeskType.control(14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(V2DeskPalette.color(.card, scheme: colorScheme))
                .background(V2DeskPalette.color(.ink, scheme: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityHint(disabled ? "当前不可用" : "")
    }
}

struct V2IOSSecondaryButton: View {
    let title: String
    var tone: V2DeskTone = .neutral
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(V2DeskType.control(13, weight: .medium))
                .foregroundStyle(toneColor)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(toneColor.opacity(0.42), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var toneColor: Color {
        switch tone {
        case .neutral: V2DeskPalette.color(.secondaryInk, scheme: colorScheme)
        case .accent: V2DeskPalette.color(.accent, scheme: colorScheme)
        case .success: V2DeskPalette.color(.success, scheme: colorScheme)
        case .warning: V2DeskPalette.color(.warning, scheme: colorScheme)
        case .danger: V2DeskPalette.color(.danger, scheme: colorScheme)
        case .stale: V2DeskPalette.color(.disabledInk, scheme: colorScheme)
        }
    }
}

struct V2IOSStripedSurface: View {
    var body: some View {
        V2DeskStripeFill(lineWidth: 2, spacing: 7)
            .allowsHitTesting(false)
    }
}

struct V2IOSShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum V2IOSExportFiles {
    static func write(_ files: [ExportFile]) throws -> [URL] {
        try files.map { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }
}

extension String {
    var v2IOSTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
