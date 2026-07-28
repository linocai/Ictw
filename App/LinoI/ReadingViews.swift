import SwiftUI

private struct ReaderScrollMetrics: Equatable {
    let offset: CGFloat
    let maximumOffset: CGFloat

    var relativeOffset: Double {
        guard maximumOffset > 0 else { return 0 }
        return Double(min(max(offset / maximumOffset, 0), 1))
    }
}

private struct ReaderPositionContext {
    let bookID: String
    let chapterID: String
    let text: String
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
/// (back + title + reading-settings menu) mirrors macOS
/// `MacReaderView.topBar`; the menu keeps iOS's existing 3-level 小/中/大
/// semantics instead of porting Mac's continuous ladder.
struct LinoIReadingView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @AppStorage("linoi.reader.fontScale") private var storedFontScale = ReaderFontScale.medium.rawValue
    @AppStorage("linoi.reader.theme") private var storedTheme = LinoReadingTheme.day.rawValue

    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var pendingRestoreOffset: Double?
    @State private var latestMetrics = ReaderScrollMetrics(offset: 0, maximumOffset: 0)
    @State private var positionSaveTask: Task<Void, Never>?
    @State private var positionContext: ReaderPositionContext?

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
                        // 正文排除出隐式动画（同 Mac，v1.4.1 性能修复）：整章
                        // 段落逐帧插值文字颜色/重排代价高，主题渐变只留 chrome。
                        .transaction { $0.animation = nil }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 130)
            }
            .safeAreaInset(edge: .bottom) {
                controlBar
            }
            .id(chapter.id)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ReaderScrollMetrics.self) { geometry in
                ReaderScrollMetrics(
                    offset: geometry.contentOffset.y,
                    maximumOffset: max(geometry.contentSize.height - geometry.containerSize.height, 0)
                )
            } action: { _, metrics in
                latestMetrics = metrics
                if let pendingRestoreOffset, metrics.maximumOffset > 0 {
                    self.pendingRestoreOffset = nil
                    scrollPosition.scrollTo(y: CGFloat(pendingRestoreOffset) * metrics.maximumOffset)
                } else {
                    schedulePositionSave(metrics)
                }
            }
            .transition(.opacity)
            .linoAnimation(LinoMotion.reader, value: chapter.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .linoAnimation(LinoMotion.reader, value: theme)
        .onAppear {
            preparePositionRestore()
        }
        .onChange(of: chapter.id) { _, _ in
            preparePositionRestore()
        }
        .onDisappear {
            positionSaveTask?.cancel()
            savePosition(latestMetrics.relativeOffset)
        }
    }

    // MARK: - Top bar（自绘，替代隐藏的系统 nav 栏；结构对齐 Mac topBar）

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(action: onExit) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .background(theme.chipBackground, in: Circle())

            Text("\(bookTitle) · 第 \(chapter.index) 章")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            Menu {
                Section("阅读主题") {
                    ForEach(LinoReadingTheme.allCases) { candidate in
                        Button {
                            storedTheme = candidate.rawValue
                        } label: {
                            Label(
                                candidate.label,
                                systemImage: candidate == theme ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                }
                Section("字号") {
                    ForEach(ReaderFontScale.allCases) { scale in
                        Button {
                            storedFontScale = scale.rawValue
                        } label: {
                            Label(
                                scale.label,
                                systemImage: scale == fontScale ? "checkmark.circle.fill" : "circle"
                            )
                        }
                    }
                }
            } label: {
                Image(systemName: "textformat.size")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .background(theme.chipBackground, in: Circle())
            .accessibilityLabel("阅读设置")
            .accessibilityHint("调整阅读主题和字号")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(theme.barBackground.background(.ultraThinMaterial))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
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

    private func preparePositionRestore() {
        positionSaveTask?.cancel()
        savePosition(latestMetrics.relativeOffset)
        latestMetrics = ReaderScrollMetrics(offset: 0, maximumOffset: 0)
        positionContext = ReaderPositionContext(
            bookID: chapter.bookId,
            chapterID: chapter.id,
            text: chapter.draftText
        )
        pendingRestoreOffset = ReaderPositionStore.load(
            bookID: chapter.bookId,
            chapterID: chapter.id,
            text: chapter.draftText
        )
        scrollPosition.scrollTo(edge: .top)
    }

    private func schedulePositionSave(_ metrics: ReaderScrollMetrics) {
        positionSaveTask?.cancel()
        let relativeOffset = metrics.relativeOffset
        positionSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            savePosition(relativeOffset)
        }
    }

    private func savePosition(_ relativeOffset: Double) {
        guard let positionContext else { return }
        ReaderPositionStore.save(
            bookID: positionContext.bookID,
            chapterID: positionContext.chapterID,
            text: positionContext.text,
            relativeOffset: relativeOffset
        )
    }

    // MARK: - Bottom control bar（翻章）

    private var controlBar: some View {
        HStack {
            Spacer()
            HStack(spacing: 14) {
                navButton(
                    target: adjacentSummary(direction: -1),
                    systemImage: "chevron.left",
                    accessibilityLabel: "上一章"
                )
                navButton(
                    target: adjacentSummary(direction: 1),
                    systemImage: "chevron.right",
                    accessibilityLabel: "下一章"
                )
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

    private func navButton(
        target: ChapterSummary?,
        systemImage: String,
        accessibilityLabel: String
    ) -> some View {
        Button {
            guard let target else { return }
            onSwitchChapter(target)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? theme.secondary.opacity(0.5) : theme.text)
        .background(theme.chipBackground, in: Capsule())
        .disabled(target == nil || editor.isLoading)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(target == nil ? "不可用" : "可用")
    }

    private func adjacentSummary(direction: Int) -> ChapterSummary? {
        let targetIndex = chapter.index + direction
        guard let candidate = workspace.chapters.first(where: { $0.index == targetIndex }) else { return nil }
        return candidate.status == "finalized" ? candidate : nil
    }
}
