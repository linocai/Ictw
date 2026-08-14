import SwiftUI

struct V2IOSChapterRailView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var showingWorld = false
    @State private var showingCharacters = false
    @State private var showingBookSettings = false
    @State private var showingExport = false
    @State private var showingGlobalSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if workspace.isLoading && workspace.chapters.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else {
                List {
                    ForEach(workspace.chapters) { chapter in
                        NavigationLink(value: chapter) { V2IOSChapterRailRow(chapter: chapter) }
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .listRowBackground(Color.clear)
                    }
                    Button { Task { await workspace.createChapter() } } label: {
                        Label("新建章节", systemImage: "plus")
                            .font(V2DeskType.control(13, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            railFooter
        }
        .task(id: session.currentBook?.id) {
            guard let book = session.currentBook else { return }
            await workspace.load(bookId: book.id)
            await characters.load(bookId: book.id)
            await agents.load()
        }
        .refreshable {
            guard let book = session.currentBook else { return }
            await workspace.load(bookId: book.id)
            await characters.load(bookId: book.id)
        }
        .sheet(isPresented: $showingWorld) { V2IOSWorldEditorView().presentationCornerRadius(V2DeskMetric.sheetCornerRadius) }
        .sheet(isPresented: $showingCharacters) { V2IOSCharactersView().presentationCornerRadius(V2DeskMetric.sheetCornerRadius) }
        .sheet(isPresented: $showingBookSettings) {
            V2IOSBookSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
        .sheet(isPresented: $showingExport) {
            V2IOSExportSheet(currentChapterID: nil)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
        .sheet(isPresented: $showingGlobalSettings) {
            V2IOSSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            V2IOSBackButton(action: session.closeBook, label: "返回书架")
            VStack(alignment: .leading, spacing: 2) {
                Text(session.currentBook?.title.v2IOSTrimmed.isEmpty == false ? session.currentBook!.title : "未命名书籍")
                    .font(V2DeskType.prose(18, weight: .semibold)).lineLimit(1)
                Text("章节")
                    .font(V2DeskType.control(11)).foregroundStyle(Color.secondary)
            }
            Spacer()
            Menu {
                Button("书设置") { showingBookSettings = true }
                Button("导出正文") { showingExport = true }
                Button("全局设置") { showingGlobalSettings = true }
            } label: {
                Text("设置").font(V2DeskType.control(12.5, weight: .medium)).frame(width: 52, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var railFooter: some View {
        HStack(spacing: 0) {
            V2IOSRailFooterButton(title: "人物 \(characters.characters.count)", action: { showingCharacters = true })
            V2IOSRailFooterButton(title: "世界观", action: { showingWorld = true })
            V2IOSRailFooterButton(title: "导出", action: { showingExport = true })
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct V2IOSChapterRailRow: View {
    let chapter: ChapterSummary
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            V2DeskStatusMark(marker: marker, diameter: 7)
            Text("\(chapter.index)").font(V2DeskType.chapterNumber(13)).foregroundStyle(V2DeskPalette.color(.tertiaryInk, scheme: colorScheme)).frame(width: 20, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title.v2IOSTrimmed.isEmpty ? "第 \(chapter.index) 章" : chapter.title)
                    .font(V2DeskType.control(13.5, weight: chapter.status == "finalized" ? .regular : .medium))
                    .lineLimit(1)
                if let label = archiveRailState.label {
                    Text(label).font(V2DeskType.control(10.5)).foregroundStyle(Color.secondary)
                }
            }
            Spacer()
            if archiveRailState == .attention {
                Text("待处理").font(V2DeskType.control(10.5)).foregroundStyle(V2DeskPalette.color(.tertiaryInk, scheme: colorScheme))
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .overlay {
            if archiveRailState == .attention {
                V2IOSStripedSurface().opacity(0.32)
            }
        }
    }

    private var marker: V2DeskMarker {
        if chapter.status == "finalized" { return .confirmed }
        if archiveRailState == .attention { return .unreliable }
        return .notYetHappened
    }

    private var archiveRailState: ChapterArchiveRailState {
        ChapterArchiveRailState.resolve(status: chapter.archiveStatus, canRetry: chapter.archiveCanRetry)
    }
}

private struct V2IOSRailFooterButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(V2DeskType.control(11.5, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.plain)
    }
}
