import SwiftUI

struct V2IOSIntentFace: View {
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var session: AppSession
    @State private var showingCharacters = false
    @State private var showingWorld = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    V2IOSSectionLabel(title: "本章意图")
                    if canEditChapter {
                        TextEditor(text: intent)
                            .font(V2DeskType.prose(15))
                            .frame(minHeight: 154)
                            .padding(9)
                            .v2IOSPaper()
                            .accessibilityLabel("本章意图")
                    } else {
                        Text(editor.currentChapter?.userPrompt.v2IOSTrimmed.isEmpty == false ? editor.currentChapter!.userPrompt : "还没有本章意图")
                            .font(V2DeskType.prose(15))
                            .foregroundStyle(editor.currentChapter?.userPrompt.v2IOSTrimmed.isEmpty == false ? Color.primary : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
                            .padding(9)
                            .v2IOSPaper()
                            .accessibilityLabel("已接受的本章意图")
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    V2IOSSectionLabel(title: "本章出场人物")
                    V2IOSFlowLayout(spacing: 7) {
                        ForEach(characters.characters) { character in
                            Button { toggle(character) } label: {
                                Text(character.name)
                                    .font(V2DeskType.control(13))
                                    .padding(.horizontal, 16)
                                    .frame(minHeight: 44)
                                    .foregroundStyle(isLinked(character) ? Color.white : Color.primary)
                                    .background(isLinked(character) ? Color.primary : Color.clear, in: Capsule())
                                    .overlay(Capsule().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canEditChapter)
                        }
                        Button { showingCharacters = true } label: {
                            Text("＋ 新增人物")
                                .font(V2DeskType.control(13))
                                .foregroundStyle(Color.secondary)
                                .padding(.horizontal, 15)
                                .frame(minHeight: 44)
                                .overlay(Capsule().stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEditChapter)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    V2IOSSectionLabel(title: "世界观")
                    if session.currentBook?.worldSetting.v2IOSTrimmed.isEmpty != false {
                        HStack {
                            Text("还没有写").font(V2DeskType.control(12.5)).foregroundStyle(Color.secondary)
                            Spacer()
                            Button("去写") { showingWorld = true }.font(V2DeskType.control(12.5, weight: .medium)).buttonStyle(.plain)
                        }
                        .padding(13).v2IOSPaper(.desk)
                    } else {
                        Text(session.currentBook?.worldSetting ?? "")
                            .font(V2DeskType.prose(14.5)).lineSpacing(6).lineLimit(5)
                            .padding(13).v2IOSPaper(.desk)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
        }
        .sheet(isPresented: $showingCharacters) { V2IOSCharactersView().presentationCornerRadius(V2DeskMetric.sheetCornerRadius) }
        .sheet(isPresented: $showingWorld) { V2IOSWorldEditorView().presentationCornerRadius(V2DeskMetric.sheetCornerRadius) }
    }

    private var intent: Binding<String> {
        Binding(get: { editor.currentChapter?.userPrompt ?? "" }, set: { editor.editString(\.userPrompt, value: $0) })
    }
    private var canEditChapter: Bool { ChapterEditingPolicy.canEdit(editor.currentChapter) }
    private func isLinked(_ character: Character) -> Bool { editor.currentChapter?.characterLinks.contains(ChapterLink(characterId: character.id)) == true }
    private func toggle(_ character: Character) {
        guard let chapter = editor.currentChapter else { return }
        guard ChapterEditingPolicy.canEdit(chapter) else { return }
        var links = chapter.characterLinks
        if let index = links.firstIndex(of: ChapterLink(characterId: character.id)) { links.remove(at: index) } else { links.append(ChapterLink(characterId: character.id)) }
        editor.setCharacterLinks(links)
    }
}

struct V2IOSManuscriptFace: View {
    let snapshot: V2DeskSnapshot
    @EnvironmentObject private var editor: ChapterEditorStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if snapshot.isBodyReadOnly {
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        titleField(readOnly: true)
                        Text(editor.currentChapter?.draftText ?? "")
                            .font(V2DeskType.prose())
                            .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                            .lineSpacing(V2DeskType.proseLineSpacing)
                            .textSelection(.enabled)
                        Divider().overlay(Color.secondary.opacity(0.22)).padding(.top, 10)
                        Text("开始下一章").font(V2DeskType.control(12.5, weight: .medium)).foregroundStyle(Color.secondary)
                    }
                    .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 20)
                }
            } else {
                VStack(spacing: 0) {
                    titleField(readOnly: false).padding(.horizontal, 22).padding(.top, 18)
                    if editor.currentChapter?.draftText.v2IOSTrimmed.isEmpty != false {
                        HStack {
                            Text("还没有正文").font(V2DeskType.prose(16.5)).foregroundStyle(Color.secondary)
                            Rectangle().fill(V2DeskPalette.color(.accent, scheme: colorScheme)).frame(width: 1.5, height: 19)
                            Spacer()
                        }.padding(.horizontal, 22).padding(.top, 32)
                    }
                    TextEditor(text: draftTextBinding)
                        .font(V2DeskType.prose())
                        .lineSpacing(V2DeskType.proseLineSpacing)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16).padding(.top, 10)
                        .accessibilityLabel("正文")
                }
                .background(V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme))
            }
        }
    }

    @ViewBuilder private func titleField(readOnly: Bool) -> some View {
        if readOnly {
            Text(editor.currentChapter?.title.v2IOSTrimmed.isEmpty == false ? editor.currentChapter!.title : "第 \(editor.currentChapter?.index ?? 0) 章")
                .font(V2DeskType.prose(23, weight: .semibold))
        } else {
            TextField("章节标题", text: Binding(get: { editor.currentChapter?.title ?? "" }, set: { editor.editString(\.title, value: $0) }))
                .font(V2DeskType.prose(23, weight: .semibold))
                .textFieldStyle(.plain)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.24)).frame(height: 1) }
        }
    }

    private var draftTextBinding: Binding<String> { Binding(get: { editor.currentChapter?.draftText ?? "" }, set: { editor.editString(\.draftText, value: $0) }) }
}

struct V2IOSEvidenceFace: View {
    let snapshot: V2DeskSnapshot
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                V2IOSSectionLabel(title: "证据")
                evidence
                archive
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
        }
    }

    @ViewBuilder private var evidence: some View {
        switch snapshot.evidence {
        case .none:
            V2IOSEmptyEvidence(text: "还没有对应当前正文的结论")
        case .unavailable:
            V2IOSEmptyEvidence(text: "这次没能检查")
        case .current(let verdict, let issues):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    V2DeskStatusMark(marker: V2DeskMarker(kind: .hollowRing, tone: verdict == .passed ? .success : .warning))
                    Text(verdict == .passed ? "检查通过 · 对应当前正文" : "检查发现需要留意的地方")
                        .font(V2DeskType.control(13, weight: .medium))
                }
                ForEach(issues) { V2IOSEvidenceCard(item: $0) }
            }
        case .stale(let verdict, let issues, _):
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    V2DeskStatusMark(marker: .unreliable)
                    Text("正文已改，以下结论已失效")
                        .font(V2DeskType.control(13, weight: .medium))
                }
                .padding(11)
                .background { V2IOSStripedSurface().opacity(0.65).clipShape(RoundedRectangle(cornerRadius: 8)) }
                Text(verdict == .passed ? "此前检查通过" : "此前的检查结论")
                    .font(V2DeskType.control(12)).foregroundStyle(Color.secondary)
                ForEach(issues) { V2IOSEvidenceCard(item: $0).opacity(0.52).grayscale(1) }
            }
        }
    }

    @ViewBuilder private var archive: some View {
        switch snapshot.archive {
        case .notStarted: EmptyView()
        case .pending:
            HStack(spacing: 8) {
                V2DeskStatusMark(marker: V2DeskMarker(kind: .solidDot, tone: .accent))
                Text("正在整理这一章的记忆").font(V2DeskType.control(12.5))
            }.padding(.top, 12)
        case .complete(let facts, _):
            HStack(spacing: 8) {
                V2DeskStatusMark(marker: .confirmed)
                Text("这一章留下的 · \(facts) 条事实").font(V2DeskType.control(12.5))
            }.padding(.top, 12)
        case .attention(_, let preview):
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) { V2DeskStatusMark(marker: .unreliable); Text("记忆需要重新整理").font(V2DeskType.control(12.5, weight: .medium)) }
                if let preview { Text("第 \(preview.status) 个归档版本仅供预览，不进入后续写作。") .font(V2DeskType.control(11.5)).foregroundStyle(Color.secondary) }
            }.padding(.top, 12)
        }
    }
}

private struct V2IOSEmptyEvidence: View {
    let text: String
    var body: some View { Text(text).font(V2DeskType.control(13)).foregroundStyle(Color.secondary).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading).padding(14).v2IOSPaper(.card) }
}

private struct V2IOSEvidenceCard: View {
    let item: V2DeskEvidenceItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.reason).font(V2DeskType.control(13, weight: .medium))
            if !item.draftEvidence.v2IOSTrimmed.isEmpty { Text(item.draftEvidence).font(V2DeskType.prose(14)).lineSpacing(5) }
            if !item.bibleEvidence.v2IOSTrimmed.isEmpty { Text("意图：\(item.bibleEvidence)").font(V2DeskType.control(11.5)).foregroundStyle(Color.secondary) }
        }.padding(13).v2IOSPaper(.card)
    }
}

struct V2IOSFlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin; var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x + size.width > bounds.maxX, point.x > bounds.minX { point.x = bounds.minX; point.y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: point, proposal: ProposedViewSize(size)); point.x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
