import SwiftUI

/// Whether the chapter screen shows the distraction-free reader or the
/// full editing surface. Finalized chapters open straight into `.reading`;
/// the top bar's back chevron flips back to `.editing` without reopening
/// the chapter.
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

/// Distraction-free reading surface for a finalized chapter: day/sepia/night
/// themes (shared `LinoReadingTheme`, persisted), serif type, generous
/// line/paragraph spacing, and in-place prev/next navigation across adjacent
/// finalized chapters.
///
/// Self-draws its own top bar because the parent screen hides the system
/// nav bar while in reading mode (`.toolbar(.hidden, for: .navigationBar)`
/// in `LinoIChapterEditorScreen`) — under the app-wide locked-light-mode
/// constraint a system nav bar would stay bright even when the night theme
/// is active, which is exactly the "阴阳脸" this is meant to avoid. Structure
/// (back + title + theme swatches + font control) mirrors macOS
/// `MacReaderView.topBar`; the font control keeps iOS's existing 3-level
/// 小/中/大 semantics instead of porting Mac's continuous ladder.
struct LinoIReadingView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @AppStorage("linoi.reader.fontScale") private var storedFontScale = ReaderFontScale.medium.rawValue
    @AppStorage("linoi.reader.theme") private var storedTheme = LinoReadingTheme.day.rawValue

    @Namespace private var fontNamespace

    let chapter: Chapter
    let onExit: () -> Void
    let onSwitchChapter: (ChapterSummary) -> Void

    private var fontScale: ReaderFontScale {
        ReaderFontScale(rawValue: storedFontScale) ?? .medium
    }

    private var theme: LinoReadingTheme {
        LinoReadingTheme(rawValue: storedTheme) ?? .day
    }

    private var bookTitle: String { session.currentBook?.title ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Rectangle()
                        .fill(theme.hairline)
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
            .transition(.opacity)
            .animation(LinoMotion.reader, value: chapter.id)
            .animation(LinoMotion.reader, value: fontScale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .animation(LinoMotion.reader, value: theme)
    }

    // MARK: - Top bar（自绘，替代隐藏的系统 nav 栏；结构对齐 Mac topBar）

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onExit) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .background(theme.chipBackground, in: Circle())

            Text("\(bookTitle) · 第 \(chapter.index) 章")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 6) {
                ForEach(LinoReadingTheme.allCases) { t in
                    themeSwatch(t)
                }
                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 2)
                fontScalePicker
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(theme.barBackground.background(.ultraThinMaterial))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    private func themeSwatch(_ t: LinoReadingTheme) -> some View {
        let selected = t == theme
        return Button {
            storedTheme = t.rawValue
        } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(t.swatchFill)
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .padding(-2)
                        .opacity(selected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .animation(LinoMotion.selection, value: theme)
    }

    /// 字号 pill：iOS 既有 小/中/大 三级语义不变，滑动选中底换
    /// `matchedGeometryEffect`（对齐 Mac 分段控件的廉价滑动机制）。
    private var fontScalePicker: some View {
        HStack(spacing: 2) {
            ForEach(ReaderFontScale.allCases) { scale in
                let selected = fontScale == scale
                Button {
                    withAnimation(LinoMotion.reader) { storedFontScale = scale.rawValue }
                } label: {
                    Text(scale.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? theme.accent : theme.secondary)
                        .frame(width: 26, height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(theme.background)
                                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "fontScale", in: fontNamespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Body content

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("第 \(chapter.index) 章")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondary)
            Text(chapter.title.isEmpty ? "第 \(chapter.index) 章" : chapter.title)
                .font(.custom("Songti SC", size: fontScale.titleSize).weight(.bold))
                .foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
    }

    private var paragraphsView: some View {
        VStack(alignment: .leading, spacing: fontScale.lineSpacing + 8) {
            if paragraphs.isEmpty {
                Text("本章还没有正文。")
                    .font(.custom("Songti SC", size: fontScale.bodySize))
                    .foregroundStyle(theme.secondary)
            } else {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.custom("Songti SC", size: fontScale.bodySize))
                        .lineSpacing(fontScale.lineSpacing)
                        .foregroundStyle(theme.text)
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

    // MARK: - Bottom control bar（翻章）

    private var controlBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 14) {
                navButton(target: adjacentSummary(direction: -1), systemImage: "chevron.left")
                navButton(target: adjacentSummary(direction: 1), systemImage: "chevron.right")
            }
            .padding(10)
            .background(theme.barBackground, in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(theme.hairline, lineWidth: 0.5))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func navButton(target: ChapterSummary?, systemImage: String) -> some View {
        Button {
            guard let target else { return }
            onSwitchChapter(target)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 44, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? theme.secondary.opacity(0.5) : theme.text)
        .background(theme.chipBackground, in: Capsule())
        .disabled(target == nil || editor.isLoading)
    }

    private func adjacentSummary(direction: Int) -> ChapterSummary? {
        let targetIndex = chapter.index + direction
        guard let candidate = workspace.chapters.first(where: { $0.index == targetIndex }) else { return nil }
        return candidate.status == "finalized" ? candidate : nil
    }
}
