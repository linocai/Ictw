import SwiftUI

struct LinoIWorkspaceView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var agents: AgentSettingsStore

    var body: some View {
        VStack(spacing: 0) {
            LinoIWorkspaceHeader()
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)

            LinoIWorkspaceSegment()
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            ScrollView {
                // tab 内容瞬时切换（同 MacRightPanel，v1.4.1 性能修复）：交叉淡化
                // 期间两个 tab 的玻璃卡并存掉帧，动效由分段 pill 滑动承担。
                Group {
                    switch session.selectedTab {
                    case .chapters:
                        LinoIChaptersPane()
                    case .characters:
                        LinoICharactersPane()
                    case .settings:
                        LinoIBookSettingsPane()
                    case .agents:
                        LinoIAgentSettingsPane()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 34)
            }
            .refreshable {
                await reload()
            }
        }
        .task(id: session.currentBook?.id) {
            await reload()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func reload() async {
        guard let book = session.currentBook else { return }
        await workspace.load(bookId: book.id)
        await characters.load(bookId: book.id)
        await agents.load()
    }
}

private struct LinoIWorkspaceHeader: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        HStack(spacing: 11) {
            Button {
                session.closeBook()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LinoTheme.accentDeep)
            .background(Color.white.opacity(0.72), in: Circle())
            .overlay(Circle().stroke(LinoTheme.hairline, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(session.currentBook?.title.isEmpty == false ? session.currentBook?.title ?? "未命名书籍" : "未命名书籍")
                    .font(LinoType.heading)
                    .foregroundStyle(LinoTheme.ink)
                    .lineLimit(1)
                Text("Memory Selector / Writer / Reviser / Extractor")
                    .font(.caption)
                    .foregroundStyle(LinoTheme.muted)
            }
            Spacer()
        }
    }
}

private struct LinoIWorkspaceSegment: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        LinoISegmented(
            options: WorkspaceTab.allCases,
            label: { $0.rawValue },
            selection: $session.selectedTab
        )
    }
}

struct LinoIChaptersPane: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("章节")
                        .font(LinoType.heading)
                        .foregroundStyle(LinoTheme.ink)
                    Text("按顺序推进正文、接受后自动提取本章结果。")
                        .font(.caption)
                        .foregroundStyle(LinoTheme.muted)
                }
                Spacer()
                Button {
                    Task { await workspace.createChapter() }
                } label: {
                    Label("章节", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(LinoITintButtonStyle(compact: true))
            }

            if workspace.chapters.isEmpty && !workspace.isLoading {
                LinoIEmptyCard(
                    title: "还没有章节",
                    subtitle: "先新建一章，再填写剧情 Bible、作者备注、目标字数和允许人物。",
                    actionTitle: "新建章节"
                ) {
                    Task { await workspace.createChapter() }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(workspace.chapters) { chapter in
                        NavigationLink(value: chapter) {
                            LinoIChapterRow(chapter: chapter)
                        }
                        .buttonStyle(LinoICardButtonStyle())
                    }
                }
                .animation(LinoMotion.listItem, value: workspace.chapters.map(\.id))
            }
        }
        .padding(.top, 8)
    }
}

private struct LinoIChapterRow: View {
    let chapter: ChapterSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text("\(chapter.index)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 42, height: 50)
            .background(LinoTheme.coverGradient(chapter.id), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            HStack(spacing: 8) {
                Text(chapter.title.isEmpty ? "第 \(chapter.index) 章" : chapter.title)
                    .font(LinoType.cardTitle)
                    .foregroundStyle(LinoTheme.ink)
                    .lineLimit(1)
                LinoIStatusPill(text: chapter.status.linoStatusLabel, status: chapter.status)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(LinoTheme.faint)
        }
        .padding(12)
        .linoCard(cornerRadius: 17)
    }
}

struct LinoIBookSettingsPane: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var title = ""
    @State private var world = ""
    @State private var loadedBookId: String?
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showingShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("设定")
                    .font(LinoType.heading)
                    .foregroundStyle(LinoTheme.ink)
                Text("世界观设定会进入 Writer 的硬约束区。")
                    .font(.caption)
                    .foregroundStyle(LinoTheme.muted)
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    LinoISectionLabel("书名")
                    LinoITextField("书名", text: $title)
                }
                LinoIEditor(
                    title: "世界观设定",
                    text: $world,
                    minHeight: 260,
                    placeholder: "全局世界观、硬设定、不能违背的事实。"
                )
                Button {
                    Task {
                        await workspace.saveBook(title: title, world: world)
                        if let book = session.currentBook {
                            bookshelf.upsert(book)
                        }
                    }
                } label: {
                    Text(workspace.isLoading ? "保存中" : "保存设定")
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
            }
            .padding(14)
            .linoGlass(cornerRadius: 20)

            VStack(alignment: .leading, spacing: 10) {
                LinoISectionLabel("导出")
                Text("把全书已完成章节导出为纯文本，方便备份或投稿。")
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.muted)
                Button {
                    Task { await exportBook() }
                } label: {
                    Text(isExporting ? "正在导出" : "导出全书")
                }
                .buttonStyle(LinoITintButtonStyle())
                .disabled(isExporting || session.currentBook == nil)
                Text("把大事记、章节梗概、人物动态字段与故事线（Extractor 记忆）导出为纯文本。")
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.muted)
                Button {
                    Task { await exportMemories() }
                } label: {
                    Text(isExporting ? "正在导出" : "导出记忆")
                }
                .buttonStyle(LinoITintButtonStyle())
                .disabled(isExporting || session.currentBook == nil)
            }
            .padding(14)
            .linoGlass(cornerRadius: 20)
        }
        .padding(.top, 8)
        .onAppear(perform: sync)
        .onChange(of: session.currentBook?.id) { _, _ in sync() }
        .sheet(isPresented: $showingShare) {
            if let exportURL {
                ActivityView(items: [exportURL])
            }
        }
    }

    private func sync() {
        guard let book = session.currentBook, loadedBookId != book.id else { return }
        loadedBookId = book.id
        title = book.title
        world = book.worldSetting
    }

    private func exportBook() async {
        await export(path: "export.txt", suffix: "")
    }

    private func exportMemories() async {
        await export(path: "memories/export.txt", suffix: "·记忆")
    }

    private func export(path: String, suffix: String) async {
        guard let book = session.currentBook else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let data = try await session.api.rawRequest("/books/\(book.id)/\(path)")
            let filename = "\(book.title.isEmpty ? "LinoI书稿" : book.title)\(suffix).txt"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try data.write(to: url, options: [.atomic])
            exportURL = url
            showingShare = true
        } catch {
            session.notices.publish(error)
        }
    }
}
