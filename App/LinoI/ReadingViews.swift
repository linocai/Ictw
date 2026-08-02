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

    /// SwiftUI's lineSpacing is additive. Matching the type size produces the
    /// airy, approximately 2× reading rhythm used by the handoff.
    var lineSpacing: CGFloat { bodySize }

    var titleSize: CGFloat { 25 }

    var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

/// Native SwiftUI reading surface. Its three palettes intentionally stay
/// independent from the app's light/dark appearance.
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
    @State private var chromeVisible = true
    @State private var readerPanel = false

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
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if chromeVisible {
                    topBar
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                readingScrollView

                if chromeVisible {
                    controlBar
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            if readerPanel {
                settingsPanel
                    .padding(.horizontal, 14)
                    .padding(.top, 53)
                    .transition(.opacity.combined(with: .offset(y: -7)))
                    .zIndex(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background.ignoresSafeArea())
        .linoAnimation(LinoMotion.reader, value: theme)
        .linoAnimation(LinoMotion.reader, value: chromeVisible)
        .linoAnimation(LinoMotion.drawer, value: readerPanel)
        .onAppear {
            preparePositionRestore()
        }
        .onChange(of: chapter.id) { _, _ in
            readerPanel = false
            chromeVisible = true
            preparePositionRestore()
        }
        .onDisappear {
            positionSaveTask?.cancel()
            savePosition(latestMetrics.relativeOffset)
        }
    }

    private var readingScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                paragraphsView
                    // Whole-chapter text never participates in theme animation.
                    // This preserves the v1.4.1 reading performance fix.
                    .transaction { $0.animation = nil }
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 54)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            chromeVisible.toggle()
            readerPanel = false
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

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: onExit) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .accessibilityLabel("返回编辑器")

            Text("\(bookTitle) · 第 \(chapter.index) 章")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            Button {
                readerPanel.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("A").font(.system(size: 15, weight: .semibold))
                    Text("A").font(.system(size: 11, weight: .semibold))
                }
                .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .accessibilityLabel("阅读设置")
            .accessibilityHint("调整阅读主题和字号")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(theme.barBackground)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("第 \(chapter.index) 章")
                .font(.system(size: 11.5))
                .tracking(1.4)
                .foregroundStyle(theme.secondary)
            Text(chapter.title.isEmpty ? "第 \(chapter.index) 章" : chapter.title)
                .font(.custom("Songti SC", size: fontScale.titleSize).weight(.bold))
                .foregroundStyle(theme.text)
                .padding(.top, 10)
            Rectangle()
                .fill(theme.rule)
                .frame(width: 38, height: 1.5)
                .padding(.top, 20)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paragraphsView: some View {
        VStack(alignment: .leading, spacing: 22) {
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

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("阅读主题")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(theme.secondary)

            HStack(spacing: 10) {
                ForEach(LinoReadingTheme.allCases) { candidate in
                    Button {
                        storedTheme = candidate.rawValue
                    } label: {
                        VStack(spacing: 7) {
                            Text("文")
                                .font(.custom("Songti SC", size: 17))
                                .foregroundStyle(candidate.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(candidate.swatchFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(candidate == theme ? candidate.text : candidate.hairline, lineWidth: candidate == theme ? 2 : 1)
                                )
                            Text(candidate.label)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(candidate == theme ? theme.text : theme.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 11)

            Text("字号")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(theme.secondary)
                .padding(.top, 16)

            HStack(spacing: 8) {
                ForEach(ReaderFontScale.allCases) { scale in
                    Button {
                        storedFontScale = scale.rawValue
                    } label: {
                        Text(scale.label)
                            .font(.custom("Songti SC", size: scale.bodySize))
                            .foregroundStyle(scale == fontScale ? theme.text : theme.secondary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(scale == fontScale ? theme.chipBackground : Color.clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(scale == fontScale ? theme.rule : theme.hairline, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 11)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(theme.barBackground)
                )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(theme.hairline, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 18, y: 14)
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Text("读到 \(readingPercent)%")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(theme.barBackground))
        }
        .overlay(Capsule().stroke(theme.hairline, lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .padding(.top, 8)
    }

    private var readingPercent: Int {
        Int((latestMetrics.relativeOffset * 100).rounded())
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
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(target == nil ? theme.secondary.opacity(0.45) : theme.text)
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
