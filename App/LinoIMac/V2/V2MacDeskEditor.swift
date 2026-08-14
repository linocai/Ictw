import SwiftUI

// MARK: - Manuscript desk

struct V2MacManuscriptDesk: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    let snapshot: V2DeskSnapshot
    let onOpenContext: () -> Void
    let onOpenReader: () -> Void
    let performAction: (V2DeskPrimaryAction) -> Void
    let onPrimary: () -> Void
    let onReopen: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if let banner = snapshot.taskBanner {
                V2MacDeskTaskBanner(banner: banner, primaryAction: snapshot.primaryAction, perform: performAction)
            }
            if editor.currentChapter == nil {
                V2MacDeskEmptyPrompt(title: "选择一章，或新建一章开始。", actionTitle: "新的一章") {}
            } else {
                GeometryReader { proxy in
                    let layout = V2MacManuscriptMeasure(availableWidth: proxy.size.width)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            V2MacChapterHeading(snapshot: snapshot)
                            V2MacManuscriptText(snapshot: snapshot)
                            if snapshot.chapterState == .accepted {
                                HStack(spacing: 12) {
                                    Rectangle().fill(V2DeskPalette.color(.strongLine, scheme: colorScheme)).frame(height: 1)
                                    Button("开始下一章", action: onPrimary)
                                        .buttonStyle(V2MacDeskButton(kind: .secondary))
                                    Spacer()
                                }
                                .padding(.top, 30)
                            }
                        }
                        .frame(width: layout.measure, alignment: .leading)
                        .padding(.horizontal, layout.horizontalPadding)
                        .padding(.top, 34)
                        .padding(.bottom, 44)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .frame(minWidth: V2DeskMetric.manuscriptMinimum + 32)
            }
            V2MacDeskActionBar(snapshot: snapshot, onOpenContext: onOpenContext, onOpenReader: onOpenReader, onPrimary: onPrimary, onReopen: onReopen)
        }
        .background(snapshot.chapterState == .accepted ? V2DeskPalette.color(.acceptedPaper, scheme: colorScheme) : V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
    }
}

/// Keeps the manuscript's readable measure inside the width left after the
/// chapter/context rails.  At a 600pt window the two 44pt rails leave 512pt:
/// this resolves to the contractual 480pt measure plus 16pt padding per side.
private struct V2MacManuscriptMeasure {
    let availableWidth: CGFloat

    var horizontalPadding: CGFloat {
        let progress = min(1, max(0, (availableWidth - 512) / 168))
        return 16 + 24 * progress
    }

    var measure: CGFloat {
        min(
            V2DeskMetric.manuscriptMeasure,
            max(V2DeskMetric.manuscriptMinimum, availableWidth - horizontalPadding * 2)
        )
    }
}

private struct V2MacChapterHeading: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    let snapshot: V2DeskSnapshot
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("第 \(editor.currentChapter?.index ?? 0) 章")
                    .font(V2DeskType.control(11.5))
                    .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                if snapshot.chapterState == .accepted {
                    Text("已接受")
                        .font(V2DeskType.control(11, weight: .medium))
                        .foregroundStyle(V2DeskPalette.color(.success, scheme: colorScheme))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(V2DeskPalette.color(.success, scheme: colorScheme).opacity(0.35)) }
                } else if snapshot.chapterState == .needsRecheck {
                    Text("已改动")
                        .font(V2DeskType.control(11))
                        .foregroundStyle(V2DeskPalette.color(.accent, scheme: colorScheme))
                }
                Spacer()
                if snapshot.showsUnsavedLocalDraft {
                    Text("本地草稿")
                        .font(V2DeskType.control(10.5))
                        .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                }
            }
            if snapshot.isBodyReadOnly {
                Text(editor.currentChapter?.title.isEmpty == false ? (editor.currentChapter?.title ?? "") : "未命名")
                    .font(V2DeskType.prose(24, weight: .semibold))
                    .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
            } else {
                TextField("", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(V2DeskType.prose(24, weight: .semibold))
                    .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
                    .focused($titleFocused)
                    .padding(.vertical, 4)
                    .frame(minHeight: 42, alignment: .center)
                    .overlay(alignment: .bottom) { Rectangle().fill(V2DeskPalette.color(.line, scheme: colorScheme)).frame(height: 1) }
                    .accessibilityLabel("章节标题")
            }
        }
        .padding(.bottom, 25)
    }

    private var titleBinding: Binding<String> {
        Binding(get: { editor.currentChapter?.title ?? "" }, set: { editor.editString(\.title, value: $0) })
    }
}

private struct V2MacManuscriptText: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    let snapshot: V2DeskSnapshot
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var bodyFocused: Bool

    var body: some View {
        Group {
            if snapshot.isBodyReadOnly {
                Text(editor.currentChapter?.draftText.isEmpty == false ? (editor.currentChapter?.draftText ?? "") : "")
                    .font(V2DeskType.prose())
                    .lineSpacing(V2DeskType.proseLineSpacing)
                    .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: bodyBinding)
                        .scrollContentBackground(.hidden)
                        .font(V2DeskType.prose())
                        .lineSpacing(V2DeskType.proseLineSpacing)
                        .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
                        .frame(minHeight: 390)
                        .focused($bodyFocused)
                    if editor.currentChapter?.draftText.isEmpty != false {
                        Text("还没有正文")
                            .font(V2DeskType.prose())
                            .foregroundStyle(V2DeskPalette.color(.disabledInk, scheme: colorScheme))
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityLabel(snapshot.isBodyReadOnly ? "已接受的正文" : "正文")
    }

    private var bodyBinding: Binding<String> {
        Binding(get: { editor.currentChapter?.draftText ?? "" }, set: { editor.editString(\.draftText, value: $0) })
    }
}

private struct V2MacDeskTaskBanner: View {
    let banner: V2DeskTaskBanner
    let primaryAction: V2DeskPrimaryAction
    let perform: (V2DeskPrimaryAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            V2DeskStatusMark(marker: V2DeskMarker(kind: banner.tone == .neutral ? .hollowRing : .solidDot, tone: banner.tone), diameter: 7)
            Text(banner.text)
                .font(V2DeskType.control(12.5))
                .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
            Spacer(minLength: 8)
            if let action = banner.action, action != primaryAction {
                Button(action.title) { perform(action) }
                    .buttonStyle(V2MacDeskButton(kind: banner.tone == .danger ? .secondary : .quiet, compact: true))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
        .background(background)
        .overlay(alignment: .bottom) { Rectangle().fill(banner.tone.v2MacColor(scheme: colorScheme).opacity(0.28)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    private var background: Color {
        switch banner.kind {
        case .writing, .checking, .archiving: V2DeskPalette.color(.taskWriting, scheme: colorScheme)
        case .proseUpdated: V2DeskPalette.color(.taskSuccess, scheme: colorScheme)
        case .checkerUnavailable, .archiveFailed, .connectionInterrupted: V2DeskPalette.color(.taskWarning, scheme: colorScheme)
        case .generationFailed: V2DeskPalette.color(.taskFailure, scheme: colorScheme)
        case .cancelled, .localSaveNeedsAttention: V2DeskPalette.color(.card, scheme: colorScheme)
        }
    }
}

private struct V2MacDeskActionBar: View {
    let snapshot: V2DeskSnapshot
    let onOpenContext: () -> Void
    let onOpenReader: () -> Void
    let onPrimary: () -> Void
    let onReopen: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Button("意图与证据", action: onOpenContext)
                .buttonStyle(V2MacDeskButton(kind: .quiet, compact: true))
            Spacer()
            if snapshot.chapterState == .accepted {
                Button("阅读", action: onOpenReader).buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
                Button("重新编辑", action: onReopen).buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
            }
            if snapshot.primaryAction != .none {
                primaryButton
            }
        }
        .padding(.horizontal, 24)
        .frame(height: V2DeskMetric.actionBarHeight)
        .background(V2DeskPalette.color(.acceptedPaper, scheme: colorScheme))
        .overlay(alignment: .top) { V2MacDeskHairline() }
    }

    @ViewBuilder private var primaryButton: some View {
        switch snapshot.primaryAction {
        case .generate:
            Button(snapshot.primaryAction.title, action: onPrimary).buttonStyle(V2MacDeskButton(kind: .primary)).keyboardShortcut(.return, modifiers: [.command])
        case .rerunChecker:
            Button(snapshot.primaryAction.title, action: onPrimary).buttonStyle(V2MacDeskButton(kind: .primary)).keyboardShortcut("r", modifiers: [.command])
        case .accept, .acceptWithWarning:
            Button(snapshot.primaryAction.title, action: onPrimary).buttonStyle(V2MacDeskButton(kind: .primary)).keyboardShortcut("a", modifiers: [.command, .shift])
        default:
            Button(snapshot.primaryAction.title, action: onPrimary).buttonStyle(V2MacDeskButton(kind: .primary))
        }
    }
}

// MARK: - Context, evidence and archive

struct V2MacContextPanel: View {
    @Binding var face: V2MacContextFace
    let onOpenSheet: (V2MacDeskSheet) -> Void
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ForEach(V2MacContextFace.allCases) { candidate in
                    V2MacContextTab(candidate: candidate, selected: face == candidate) { face = candidate }
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            V2MacDeskHairline()
            ScrollView {
                Group {
                    switch face {
                    case .intent: V2MacIntentFace(onOpenSheet: onOpenSheet)
                    case .evidence: V2MacEvidenceFace()
                    case .memory: V2MacArchiveFace()
                    }
                }
                .padding(20)
            }
        }
        .background(V2DeskPalette.color(.intentPanel, scheme: colorScheme))
    }
}

struct V2MacCollapsedContextRail: View {
    let needsAttention: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "sidebar.right")
                    if needsAttention {
                        V2DeskStatusMark(marker: V2DeskMarker(kind: .solidDot, tone: .accent), diameter: 5)
                            .offset(x: 4, y: -3)
                    }
                }
                Text("意图")
                    .font(V2DeskType.control(10.5))
                    .rotationEffect(.degrees(90))
                    .padding(.top, 24)
            }
            .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 18)
        }
        .buttonStyle(.plain)
        .background(V2DeskPalette.color(.intentPanel, scheme: colorScheme))
    }
}

struct V2MacFloatingContext: View {
    @Binding var face: V2MacContextFace
    let dismiss: () -> Void
    let onOpenSheet: (V2MacDeskSheet) -> Void
    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.16).onTapGesture(perform: dismiss)
            VStack(spacing: 0) {
                HStack { Spacer(); V2MacDeskIconButton(symbol: "xmark", label: "关闭") { dismiss() } }.padding(8)
                V2MacContextPanel(face: $face, onOpenSheet: onOpenSheet)
            }
            .frame(width: V2DeskMetric.contextPanel)
            .frame(maxHeight: .infinity)
            .shadow(color: .black.opacity(0.16), radius: 14, x: -4)
        }
    }
}

private struct V2MacContextTab: View {
    let candidate: V2MacContextFace
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Button(candidate.title, action: action)
            .buttonStyle(.plain)
            .font(V2DeskType.control(11.5, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? V2DeskPalette.color(.ink, scheme: colorScheme) : V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            .overlay(alignment: .bottom) {
                if selected {
                    Rectangle()
                        .fill(candidate == .evidence ? V2DeskPalette.color(.success, scheme: colorScheme) : V2DeskPalette.color(.accent, scheme: colorScheme))
                        .frame(height: 2)
                        .offset(y: 7)
                }
            }
    }
}

private struct V2MacIntentFace: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @Environment(\.colorScheme) private var colorScheme
    let onOpenSheet: (V2MacDeskSheet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            V2MacDeskSectionLabel(text: "本章意图")
            TextEditor(text: Binding(get: { editor.currentChapter?.userPrompt ?? "" }, set: { editor.editString(\.userPrompt, value: $0) }))
                .scrollContentBackground(.hidden)
                .font(V2DeskType.prose(12.5))
                .lineSpacing(8)
                .frame(minHeight: 132)
                .padding(8)
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
                .disabled(editor.currentChapter?.status == "finalized")
            Button("✦ 找方向") { onOpenSheet(.inspiration) }
                .buttonStyle(V2MacDeskButton(kind: .secondary))
            V2MacDeskSectionLabel(text: "本章出场人物")
            if characters.characters.isEmpty {
                Button("添加人物") { onOpenSheet(.people) }.buttonStyle(V2MacDeskButton(kind: .secondary, compact: true))
            } else {
                V2MacCharacterChips()
            }
        }
    }
}

private struct V2MacCharacterChips: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        V2MacFlowLayout(spacing: 7) {
            ForEach(characters.characters) { person in
                let selected = editor.currentChapter?.characterLinks.contains(where: { $0.characterId == person.id }) == true
                Button(person.name) {
                    guard var current = editor.currentChapter else { return }
                    if selected { current.characterLinks.removeAll { $0.characterId == person.id } }
                    else { current.characterLinks.append(ChapterLink(characterId: person.id)) }
                    editor.setCharacterLinks(current.characterLinks)
                }
                .buttonStyle(.plain)
                .font(V2DeskType.control(11.5))
                .foregroundStyle(selected ? V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme) : V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? V2DeskPalette.color(.ink, scheme: colorScheme) : .clear, in: Capsule())
                .overlay { Capsule().stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)) }
                .disabled(editor.currentChapter?.status == "finalized")
            }
        }
    }
}

private struct V2MacEvidenceFace: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @Environment(\.colorScheme) private var colorScheme

    private var snapshot: V2DeskSnapshot {
        V2DeskPresentation.make(V2DeskEditorSource(chapter: editor.currentChapter, writingPhase: editor.writingPhase, checkerResult: editor.checkerResult, checkerAppliesToVisibleDraft: editor.checkerAppliesToVisibleDraft, checkerRefreshing: editor.checkerRefreshing, staleCheckedSnapshot: editor.staleCheckedSnapshot, saveState: editor.saveState, connectionInterrupted: editor.pollingConnectionInterrupted))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch snapshot.evidence {
            case .none:
                Text("复查后，结论会留在这里。")
                    .font(V2DeskType.control(12))
                    .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            case .unavailable:
                Text("这次没能检查。正文仍保留在这里。")
                    .font(V2DeskType.control(12))
                    .foregroundStyle(V2DeskPalette.color(.warning, scheme: colorScheme))
            case .current(let verdict, let issues):
                V2MacEvidenceHeadline(verdict: verdict, stale: false)
                V2MacEvidenceCards(issues: issues, stale: false)
            case .stale(let verdict, let issues, _):
                HStack(spacing: 8) {
                    V2MacDeskStripeBackground().frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("正文已改，以下结论已失效")
                        .font(V2DeskType.control(12, weight: .medium))
                        .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                }
                V2MacEvidenceHeadline(verdict: verdict, stale: true)
                V2MacEvidenceCards(issues: issues, stale: true)
            }
        }
    }
}

private struct V2MacEvidenceHeadline: View {
    let verdict: V2DeskCheckerVerdict
    let stale: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Text(verdict == .passed ? "检查通过 · 对应当前正文" : (verdict == .unavailable ? "检查暂不可用" : "需要留意"))
            .font(V2DeskType.control(12.5, weight: .medium))
            .foregroundStyle(stale ? V2DeskPalette.color(.metadataInk, scheme: colorScheme) : (verdict == .passed ? V2DeskPalette.color(.success, scheme: colorScheme) : V2DeskPalette.color(.warning, scheme: colorScheme)))
    }
}

private struct V2MacEvidenceCards: View {
    let issues: [V2DeskEvidenceItem]
    let stale: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        if issues.isEmpty && !stale {
            EmptyView()
        } else {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 7) {
                    Text(issue.kind).font(V2DeskType.control(10.5)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                    Text(issue.draftEvidence).font(V2DeskType.prose(12)).foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
                    if !issue.bibleEvidence.isEmpty { Text(issue.bibleEvidence).font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme)) }
                    Text(issue.reason).font(V2DeskType.control(11.5)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                }
                .padding(11)
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
                .opacity(stale ? 0.5 : 1)
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
            }
        }
    }
}

private struct V2MacArchiveFace: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let archive = editor.currentChapter?.archive {
                switch archive.status {
                case "pending", "extracting":
                    HStack(spacing: 8) { V2DeskStatusMark(marker: V2DeskMarker(kind: .solidDot, tone: .accent), diameter: 7); Text("正在整理这一章的记忆") }
                        .font(V2DeskType.control(12.5)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                case "complete":
                    if !archive.summary.isEmpty { V2MacArchiveCard(text: archive.summary, label: "章节摘要") }
                    ForEach(archive.facts) { fact in V2MacArchiveCard(text: fact.text, label: "关键事实 · 第 \(editor.currentChapter?.index ?? 0) 章") }
                default:
                    VStack(alignment: .leading, spacing: 9) {
                        V2MacDeskStripeBackground().frame(height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
                        Text("这份记忆不再可靠，只保留为只读预览。")
                            .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                        if let preview = archive.inactivePreview, !preview.summary.isEmpty { V2MacArchiveCard(text: preview.summary, label: "第 \(editor.currentChapter?.index ?? 0) 章 · 不再可靠", stale: true) }
                    }
                }
            } else {
                Text("接受这一章后，记忆会在这里整理。")
                    .font(V2DeskType.control(12)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            }
        }
    }
}

private struct V2MacArchiveCard: View {
    let text: String
    let label: String
    var stale = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(text).font(V2DeskType.prose(12)).lineSpacing(5).foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
            Text(label).font(V2DeskType.control(10)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
        }
        .padding(11).background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
        .opacity(stale ? 0.58 : 1)
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(V2DeskPalette.color(.line, scheme: colorScheme)) }
    }
}
