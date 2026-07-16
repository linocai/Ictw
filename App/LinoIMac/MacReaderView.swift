import SwiftUI
import AppKit

/// 全窗 overlay 阅读页。挂在 `MacWorkspaceView` 内部——工作台本身已经
/// 铺满整窗，阅读页作为它的顶层 ZStack 分支盖住标题栏+三栏内容，效果等同于
/// 「全窗 overlay」，同时不必新建共享状态：章节切换直接改写外部传入的
/// `selectedChapterId`（`MacWorkspaceView` 已有的 `onChange(of:) → editor.load`
/// 管线会自动取新章节全文），与 iOS `ChapterEditorViews.switchChapter` 的
/// 「原地翻页」语义一致。退出把 `isPresented` 置 false，交还给工作台。
///
/// 正文排版 port 自 `Archive/LinoWritingV2` 的 `ReaderView.ReaderBodyText`
/// （macOS 已验证稳定的 `NSTextView` 两端对齐方案）；三主题消费共享
/// `LinoReadingTheme`（`LinoTheme.swift`，v1.4.0 块① 从本文件上移，色值一字
/// 未改），与 App 品牌色 `LinoTheme` 无关——阅读页要的是纸感暖色调，不是
/// 工作台玻璃的蓝调。
struct MacReaderView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore

    /// 与 `MacWorkspaceView` 共享同一个 `@State`：翻页即改写它，触发既有加载
    /// 管线；不为阅读页单独维护一份章节状态。
    @Binding var selectedChapterId: String?
    @Binding var isPresented: Bool

    @AppStorage("linoi.mac.reader.theme") private var themeRaw: String = LinoReadingTheme.day.rawValue
    @AppStorage("linoi.mac.reader.fontSizeIndex") private var fontSizeIndex: Int = 2

    private static let fontLadder: [CGFloat] = [18, 19, 20, 21, 23]

    private var theme: LinoReadingTheme { LinoReadingTheme(rawValue: themeRaw) ?? .day }

    private var fontSize: CGFloat {
        let i = min(max(fontSizeIndex, 0), Self.fontLadder.count - 1)
        return Self.fontLadder[i]
    }

    private var bookTitle: String { session.currentBook?.title ?? "" }
    private var chapter: Chapter? { editor.currentChapter }

    /// 只在 finalized 章节之间翻页，按序号排序（不依赖后端返回顺序）。
    private var finalizedChapters: [ChapterSummary] {
        workspace.chapters
            .filter { $0.status == "finalized" }
            .sorted { $0.index < $1.index }
    }

    private var currentFinalizedIndex: Int? {
        guard let id = chapter?.id else { return nil }
        return finalizedChapters.firstIndex { $0.id == id }
    }

    private var prevChapter: ChapterSummary? {
        guard let i = currentFinalizedIndex, i > 0 else { return nil }
        return finalizedChapters[i - 1]
    }

    private var nextChapter: ChapterSummary? {
        guard let i = currentFinalizedIndex, i < finalizedChapters.count - 1 else { return nil }
        return finalizedChapters[i + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        // 整窗壳层背景——night 主题让整个覆盖层变暗，不只是文字列变暗。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    // MARK: - Top bar (52 高细玻璃条)

    private var topBar: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 70, height: 1) // 交通灯挡位，同 MacWorkspaceView 标题栏

            Button {
                withAnimation(LinoMotion.reader) { isPresented = false }
            } label: {
                Text("‹ 返回工作台")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { pointer($0) }

            Spacer(minLength: 8)

            Text("\(bookTitle) · 第 \(chapter?.index ?? 0) 章")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.26)
                .foregroundStyle(theme.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ForEach(LinoReadingTheme.allCases) { t in
                    themeSwatch(t)
                }

                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 4)

                fontStepButton(label: "A−", size: 13) {
                    fontSizeIndex = max(0, fontSizeIndex - 1)
                }
                fontStepButton(label: "A+", size: 16) {
                    fontSizeIndex = min(Self.fontLadder.count - 1, fontSizeIndex + 1)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(theme.barBackground.background(.ultraThinMaterial))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    private func themeSwatch(_ t: LinoReadingTheme) -> some View {
        let selected = t == theme
        return Button {
            themeRaw = t.rawValue
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(t.swatchFill)
                .frame(width: 30, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.background, lineWidth: 2)
                        .padding(-1)
                        .opacity(selected ? 1 : 0)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .padding(-3)
                        .opacity(selected ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .help(t.label)
        .onHover { pointer($0) }
    }

    private func fontStepButton(label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size))
                .foregroundStyle(theme.text)
                .frame(width: 30, height: 30)
                .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { pointer($0) }
    }

    // MARK: - Body column (max 720 居中)

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let chapter {
                    Text("第 \(chapter.index) 章")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(13 * 0.32)
                        .foregroundStyle(theme.accent)
                        .padding(.bottom, 16)

                    Text(chapter.title.isEmpty ? "第 \(chapter.index) 章" : chapter.title)
                        .font(.custom("Songti SC", size: 38).weight(.bold))
                        .foregroundStyle(theme.text)
                        .lineSpacing(38 * 0.3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 10)

                    HStack(spacing: 12) {
                        Text(bookTitle)
                        Text("·").opacity(0.4)
                        Text("\(wordCount(chapter)) 字")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondary)
                    .padding(.bottom, 4)

                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(theme.accent.opacity(0.5))
                        .frame(width: 44, height: 3)
                        .padding(.top, 32)
                        .padding(.bottom, 40)

                    MacReaderBodyText(
                        paragraphs: paragraphs(chapter.draftText),
                        fontSize: fontSize,
                        textColor: theme.text
                    )

                    chapterEndMark
                        .padding(.top, 64)

                    HStack(spacing: 12) {
                        navCard(leading: true, label: "‹ 上一章", subtitle: prevChapter.map(chapterNavLabel) ?? "已是开篇", target: prevChapter)
                        navCard(leading: false, label: "下一章 ›", subtitle: nextChapter.map(chapterNavLabel) ?? "敬请期待", target: nextChapter)
                    }
                    .padding(.top, 40)
                } else if editor.isLoading {
                    ProgressView()
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("章节不可读。")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.secondary)
                        .padding(.top, 60)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 78)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .id(chapter?.id)
    }

    private var chapterEndMark: some View {
        HStack(spacing: 16) {
            Rectangle().fill(theme.hairline).frame(width: 40, height: 0.5)
            Text("· 本章完 ·")
                .font(.custom("Songti SC", size: 15))
                .foregroundStyle(theme.secondary)
            Rectangle().fill(theme.hairline).frame(width: 40, height: 0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private func navCard(leading: Bool, label: String, subtitle: String, target: ChapterSummary?) -> some View {
        Button {
            guard let target else { return }
            selectedChapterId = target.id
        } label: {
            VStack(alignment: leading ? .leading : .trailing, spacing: 3) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                Text(subtitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .padding(.horizontal, 18)
            .frame(height: 60)
            .background(theme.chipBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0.6 : 1)
        .onHover { if target != nil { pointer($0) } }
    }

    // MARK: - Helpers

    private func chapterNavLabel(_ summary: ChapterSummary) -> String {
        summary.title.isEmpty ? "第\(summary.index)章" : "第\(summary.index)章 \(summary.title)"
    }

    private func paragraphs(_ text: String) -> [String] {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 铁律口径：去空白字符数。
    private func wordCount(_ chapter: Chapter) -> Int {
        chapter.draftText.filter { !$0.isWhitespace }.count
    }
}

// MARK: - 宋体两端对齐正文

/// SwiftUI `Text` 没有两端对齐也没有首行缩进，用 `NSAttributedString` 段落
/// 属性经 `NSTextView` 排版（macOS 已验证稳定，port 自老项目 `ReaderBodyText`）。
/// `GeometryReader` 量宽后交给 `NSViewRepresentable` 用 `layoutManager.usedRect`
/// 回填高度——`NSTextView` 自身没有可用的 intrinsic content size。
private struct MacReaderBodyText: View {
    let paragraphs: [String]
    let fontSize: CGFloat
    let textColor: Color

    @State private var measuredHeight: CGFloat = 1

    private var attributed: NSAttributedString {
        let font = NSFont(name: "Songti SC", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)

        let para = NSMutableParagraphStyle()
        para.alignment = .justified
        // line-height 2.05 → 字体自然行高的倍数。
        para.lineHeightMultiple = 2.05
        // text-indent: 2em → 首行缩进两个字号。
        para.firstLineHeadIndent = fontSize * 2
        // margin: 0 0 1.5em → 段落间距。
        para.paragraphSpacing = fontSize * 1.5
        para.baseWritingDirection = .leftToRight

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(textColor),
            .paragraphStyle: para
        ]

        let result = NSMutableAttributedString()
        for (i, p) in paragraphs.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: p, attributes: attrs))
        }
        return result
    }

    var body: some View {
        if paragraphs.isEmpty {
            Text("本章还没有正文。")
                .font(.custom("Songti SC", size: fontSize))
                .foregroundStyle(textColor.opacity(0.6))
        } else {
            let text = attributed
            GeometryReader { proxy in
                MacJustifiedTextRepresentable(
                    attributed: text,
                    width: proxy.size.width,
                    height: $measuredHeight
                )
            }
            .frame(height: measuredHeight)
        }
    }
}

/// `NSTextView` 宿主。把文本容器钉到可用 `width`，重新排版后把使用高度报回
/// SwiftUI。
private struct MacJustifiedTextRepresentable: NSViewRepresentable {
    let attributed: NSAttributedString
    let width: CGFloat
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard width > 0 else { return }
        textView.textStorage?.setAttributedString(attributed)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.frame.size.width = width

        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        if abs(used - height) > 0.5 {
            DispatchQueue.main.async { height = used }
        }
    }
}
