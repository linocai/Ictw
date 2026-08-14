import SwiftUI

struct V2IOSChapterDeskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var inspiration: InspirationCreatorStore
    @State private var face: V2DeskChapterFace = .intent
    @State private var showingInspiration = false
    @State private var showingExport = false
    @State private var showingSettings = false
    @State private var showingReopen = false
    @State private var showingAcceptWarning = false

    let summary: ChapterSummary

    var body: some View {
        let snapshot = V2DeskPresentation.make(source)
        VStack(spacing: 0) {
            header(snapshot: snapshot)
            if let banner = snapshot.taskBanner {
                V2IOSTaskBanner(banner: banner, primaryAction: snapshot.primaryAction, perform: perform)
            }
            if editor.isLoading && editor.currentChapter?.id != summary.id {
                Spacer(); ProgressView("读取章节"); Spacer()
            } else if editor.currentChapter?.id == summary.id {
                TabView(selection: $face) {
                    V2IOSIntentFace().tag(V2DeskChapterFace.intent)
                    V2IOSManuscriptFace(snapshot: snapshot).tag(V2DeskChapterFace.manuscript)
                    V2IOSEvidenceFace(snapshot: snapshot).tag(V2DeskChapterFace.evidence)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                pageIndicator
                V2IOSActionDock(
                    face: $face,
                    primary: snapshot.primaryAction,
                    primaryAction: { tapPrimary(snapshot.primaryAction) },
                    inspirationAction: { showingInspiration = true },
                    inspirationDisabled: snapshot.chapterState == .accepted
                )
            } else {
                VStack(spacing: 12) {
                    Text("这一章没有读到")
                        .font(V2DeskType.prose(19, weight: .semibold))
                    V2IOSSecondaryButton(title: "返回章节", action: dismiss.callAsFunction)
                }.padding(24)
                Spacer()
            }
        }
        .v2IOSPage()
        .task(id: summary.id) {
            inspiration.clearIfChapterChanged(to: summary.id)
            await editor.load(summary)
            if let book = session.currentBook { await characters.load(bookId: book.id) }
        }
        .onChange(of: editor.currentChapter) { _, chapter in
            if let chapter { workspace.upsert(chapter) }
        }
        .onDisappear { editor.persistLocalDraftIfNeeded() }
        .sheet(isPresented: $showingInspiration) {
            V2IOSInspirationSheet()
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
        .sheet(isPresented: $showingExport) {
            V2IOSExportSheet(currentChapterID: editor.currentChapter?.id)
                .presentationDetents([.large])
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
        .sheet(isPresented: $showingSettings) {
            V2IOSSettingsView().presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
        .confirmationDialog("这一章会被记为完成", isPresented: $showingAcceptWarning, titleVisibility: .visible) {
            Button("仍然接受", role: .destructive) { Task { if let chapter = await editor.accept(overrideChecker: true) { workspace.upsert(chapter) } } }
            Button("返回", role: .cancel) {}
        } message: {
            Text("检查发现的问题不会再提醒你；正文和本章意图会保留，随后会单独整理记忆。")
        }
        .confirmationDialog("重新编辑这一章？", isPresented: $showingReopen, titleVisibility: .visible) {
            Button("重新编辑", role: .destructive) {
                Task {
                    if let chapter = await editor.reopen() { workspace.upsert(chapter) }
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("正文与本章意图会保留；本章之后的归档记忆可能不再可靠，并会在章节轨中标记出来。")
        }
    }

    private var source: V2DeskEditorSource {
        V2DeskEditorSource(
            chapter: editor.currentChapter,
            writingPhase: editor.writingPhase,
            checkerResult: editor.checkerResult,
            checkerAppliesToVisibleDraft: editor.checkerAppliesToVisibleDraft,
            checkerRefreshing: editor.checkerRefreshing,
            staleCheckedSnapshot: editor.staleCheckedSnapshot,
            saveState: editor.saveState,
            connectionInterrupted: editor.pollingConnectionInterrupted
        )
    }

    private func header(snapshot: V2DeskSnapshot) -> some View {
        HStack(spacing: 7) {
            V2IOSBackButton(action: dismiss.callAsFunction, label: "返回章节")
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title.v2IOSTrimmed.isEmpty ? "第 \(summary.index) 章" : snapshot.title)
                    .font(V2DeskType.control(13.5, weight: .semibold)).lineLimit(1)
                Text(subtitle(snapshot: snapshot))
                    .font(V2DeskType.control(11)).foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
            }
            Spacer()
            if snapshot.chapterState == .accepted {
                Text("已接受")
                    .font(V2DeskType.control(11, weight: .medium))
                    .foregroundStyle(V2DeskPalette.color(.success, scheme: colorScheme))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(V2DeskPalette.color(.success, scheme: colorScheme).opacity(0.4)))
            }
            Menu {
                if snapshot.chapterState == .accepted {
                    Button("重开这一章", role: .destructive) { showingReopen = true }
                    Button("导出") { showingExport = true }
                } else {
                    Button("保存到服务器") { Task { if let chapter = await editor.save() { workspace.upsert(chapter) } } }
                    Button("导出") { showingExport = true }
                }
            } label: {
                Text("更多").font(V2DeskType.control(12)).frame(width: 48, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(V2DeskPalette.color(.titleBar, scheme: colorScheme))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func subtitle(snapshot: V2DeskSnapshot) -> String {
        if snapshot.showsUnsavedLocalDraft { return "本机草稿 · \(snapshot.characterCount) 字" }
        if snapshot.chapterState == .accepted { return "已完成 · \(snapshot.characterCount) 字" }
        return snapshot.characterCount == 0 ? "还没有正文" : "草稿 · \(snapshot.characterCount) 字"
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(V2DeskChapterFace.allCases, id: \.self) { item in
                Capsule()
                    .fill(item == face ? V2DeskPalette.color(.ink, scheme: colorScheme) : V2DeskPalette.color(.ink, scheme: colorScheme).opacity(0.15))
                    .frame(width: 22, height: 3)
                    .accessibilityLabel(item.title)
            }
        }
        .padding(.vertical, 12)
    }

    private func tapPrimary(_ action: V2DeskPrimaryAction) {
        switch action {
        case .generate, .retryGeneration: Task { if let chapter = await editor.generate() { workspace.upsert(chapter) } }
        case .cancelGeneration: Task { if let chapter = await editor.cancelWriting() { workspace.upsert(chapter) } }
        case .rerunChecker: Task { _ = await editor.rerunChecker() }
        case .accept: Task { if let chapter = await editor.accept() { workspace.upsert(chapter) } }
        case .acceptWithWarning: showingAcceptWarning = true
        case .startNextChapter: Task { await workspace.createChapter() }
        case .retryArchive: Task { if let chapter = await editor.retryArchive() { workspace.upsert(chapter) } }
        case .openSettings: showingSettings = true
        case .none: break
        }
    }

    private func perform(_ action: V2DeskPrimaryAction) { tapPrimary(action) }
}

private struct V2IOSTaskBanner: View {
    let banner: V2DeskTaskBanner
    let primaryAction: V2DeskPrimaryAction
    let perform: (V2DeskPrimaryAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 9) {
            V2DeskStatusMark(marker: marker, diameter: 7)
            Text(banner.text).font(V2DeskType.control(12.5)).lineLimit(2)
            Spacer(minLength: 6)
            if let action = banner.action, action != primaryAction {
                Button(action.title) { perform(action) }
                    .font(V2DeskType.control(12.5, weight: .medium))
                    .foregroundStyle(banner.tone == .danger ? V2DeskPalette.color(.danger, scheme: colorScheme) : V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    .frame(minWidth: 44, minHeight: 32)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(background)
        .overlay(alignment: .bottom) { Rectangle().fill(markerColor.opacity(0.26)).frame(height: 1) }
    }

    private var marker: V2DeskMarker { V2DeskMarker(kind: banner.kind == .cancelled ? .hollowRing : .solidDot, tone: banner.tone) }
    private var markerColor: Color { switch banner.tone { case .accent: V2DeskPalette.color(.accent, scheme: colorScheme); case .success: V2DeskPalette.color(.success, scheme: colorScheme); case .warning: V2DeskPalette.color(.warning, scheme: colorScheme); case .danger: V2DeskPalette.color(.danger, scheme: colorScheme); case .neutral, .stale: V2DeskPalette.color(.tertiaryInk, scheme: colorScheme) } }
    private var background: Color { switch banner.tone { case .accent: V2DeskPalette.color(.taskWriting, scheme: colorScheme); case .success: V2DeskPalette.color(.taskSuccess, scheme: colorScheme); case .warning: V2DeskPalette.color(.taskWarning, scheme: colorScheme); case .danger: V2DeskPalette.color(.taskFailure, scheme: colorScheme); case .neutral, .stale: V2DeskPalette.color(.card, scheme: colorScheme) } }
}

private struct V2IOSActionDock: View {
    @Binding var face: V2DeskChapterFace
    let primary: V2DeskPrimaryAction
    let primaryAction: () -> Void
    let inspirationAction: () -> Void
    let inspirationDisabled: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Button { face = alternateFace } label: {
                Text(alternateFace.title)
                    .font(V2DeskType.control(12, weight: .medium))
                    .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    .frame(width: 48, height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)))
            }.buttonStyle(.plain).accessibilityLabel("查看\(alternateFace.title)")
            V2IOSPrimaryButton(title: primary.title, disabled: primary == .none, action: primaryAction)
            Button(action: inspirationAction) {
                Text("✦").font(.system(size: 17)).foregroundStyle(V2DeskPalette.color(.accent, scheme: colorScheme)).frame(width: 48, height: 48).overlay(RoundedRectangle(cornerRadius: 12).stroke(V2DeskPalette.color(.strongLine, scheme: colorScheme)))
            }
            .buttonStyle(.plain)
            .disabled(inspirationDisabled)
            .accessibilityLabel("找方向")
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
        .background(V2DeskPalette.color(.rail, scheme: colorScheme))
        .overlay(alignment: .top) { Divider() }
    }

    private var alternateFace: V2DeskChapterFace {
        switch face { case .intent: .manuscript; case .manuscript: .intent; case .evidence: .manuscript }
    }
}
