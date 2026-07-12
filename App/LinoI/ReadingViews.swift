import SwiftUI

/// Whether the chapter screen shows the distraction-free reader or the
/// full editing surface. Finalized chapters open straight into `.reading`;
/// "退出阅读模式" flips back to `.editing` without reopening the chapter.
enum ChapterViewMode {
    case editing
    case reading
}

enum ReaderFontScale: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var bodySize: CGFloat {
        switch self {
        case .small: return 16
        case .medium: return 19
        case .large: return 22
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .small: return 10
        case .medium: return 13
        case .large: return 16
        }
    }

    var titleSize: CGFloat {
        switch self {
        case .small: return 22
        case .medium: return 25
        case .large: return 28
        }
    }

    var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

/// Distraction-free reading surface for a finalized chapter: serif type,
/// generous line/paragraph spacing, a persisted font-size preference, and
/// in-place prev/next navigation across adjacent finalized chapters.
struct LinoIReadingView: View {
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @AppStorage("linoi.reader.fontScale") private var storedFontScale = ReaderFontScale.medium.rawValue

    let chapter: Chapter
    let onExit: () -> Void
    let onSwitchChapter: (ChapterSummary) -> Void

    private var fontScale: ReaderFontScale {
        ReaderFontScale(rawValue: storedFontScale) ?? .medium
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle()
                    .fill(LinoTheme.hairline)
                    .frame(height: 0.5)
                    .padding(.bottom, 22)
                paragraphsView
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 130)
        }
        .safeAreaInset(edge: .bottom) {
            controlBar
        }
        .id(chapter.id)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("第 \(chapter.index) 章")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LinoTheme.muted)
            Text(chapter.title.isEmpty ? "第 \(chapter.index) 章" : chapter.title)
                .font(.custom("Songti SC", size: fontScale.titleSize).weight(.bold))
                .foregroundStyle(LinoTheme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
    }

    private var paragraphsView: some View {
        VStack(alignment: .leading, spacing: fontScale.lineSpacing + 8) {
            if paragraphs.isEmpty {
                Text("本章还没有正文。")
                    .font(.custom("Songti SC", size: fontScale.bodySize))
                    .foregroundStyle(LinoTheme.faint)
            } else {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.custom("Songti SC", size: fontScale.bodySize))
                        .lineSpacing(fontScale.lineSpacing)
                        .foregroundStyle(LinoTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var paragraphs: [String] {
        chapter.draftText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var controlBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                fontScalePicker
                Spacer()
                navButton(target: adjacentSummary(direction: -1), systemImage: "chevron.left")
                navButton(target: adjacentSummary(direction: 1), systemImage: "chevron.right")
            }
            Button(action: onExit) {
                Label("退出阅读模式", systemImage: "arrow.uturn.left")
            }
            .buttonStyle(LinoITintButtonStyle())
        }
        .padding(12)
        .linoGlass(cornerRadius: 22)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var fontScalePicker: some View {
        HStack(spacing: 6) {
            ForEach(ReaderFontScale.allCases) { scale in
                Button {
                    storedFontScale = scale.rawValue
                } label: {
                    Text(scale.label)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 30)
                        .foregroundStyle(fontScale == scale ? .white : LinoTheme.accentDeep)
                        .background {
                            if fontScale == scale {
                                Capsule().fill(LinoTheme.accentGradient)
                            } else {
                                Capsule().fill(Color.white.opacity(0.7))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func navButton(target: ChapterSummary?, systemImage: String) -> some View {
        Button {
            guard let target else { return }
            onSwitchChapter(target)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? LinoTheme.faint : LinoTheme.accentDeep)
        .background(Color.white.opacity(0.7), in: Capsule())
        .disabled(target == nil || editor.isLoading)
    }

    private func adjacentSummary(direction: Int) -> ChapterSummary? {
        let targetIndex = chapter.index + direction
        guard let candidate = workspace.chapters.first(where: { $0.index == targetIndex }) else { return nil }
        return candidate.status == "finalized" ? candidate : nil
    }
}
