import SwiftUI

struct LinoIWorkspaceView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var characters: CharactersStore
    @EnvironmentObject private var agents: AgentSettingsStore

    var body: some View {
        VStack(spacing: 0) {
            LinoIWorkspaceHeader()

            ScrollView {
                Group {
                    switch session.selectedTab {
                    case .chapters:
                        LinoIChaptersPane()
                    case .characters:
                        LinoICharactersPane()
                    case .settings, .agents:
                        LinoIBookSettingsPane()
                    }
                }
                .id(session.selectedTab)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 7)),
                    removal: .identity
                ))
                .linoAnimation(LinoMotion.content, value: session.selectedTab)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 26)
            }
            .refreshable { await reload() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            LinoIWorkspaceTabBar()
        }
        .task(id: session.currentBook?.id) {
            if session.selectedTab == .agents {
                session.selectedTab = .settings
            }
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
        HStack(spacing: 7) {
            Button {
                session.closeBook()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(LinoTheme.ink)

            Text(bookTitle)
                .font(LinoType.bookTitle)
                .foregroundStyle(LinoTheme.ink)
                .lineLimit(1)

            Spacer()

            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LinoTheme.muted)
                .frame(width: 38, height: 38)
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
    }

    private var bookTitle: String {
        guard let title = session.currentBook?.title, !title.isEmpty else { return "未命名书籍" }
        return title
    }
}

private struct LinoIWorkspaceTabBar: View {
    @EnvironmentObject private var session: AppSession

    private let tabs: [(WorkspaceTab, String)] = [
        (.chapters, "doc.text"),
        (.characters, "person.2"),
        (.settings, "gearshape"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.0) { tab, icon in
                Button {
                    session.selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 23)
                        Text(tabLabel(tab))
                            .font(LinoType.ui(10.5, .medium))
                    }
                    .foregroundStyle(session.selectedTab == tab ? LinoTheme.accent : LinoTheme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(session.selectedTab == tab ? "已选择" : "未选择")
            }
        }
        .background(LinoTheme.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(LinoTheme.line).frame(height: 1)
        }
    }

    private func tabLabel(_ tab: WorkspaceTab) -> String {
        tab == .chapters ? "稿件" : tab.rawValue
    }
}

struct LinoIChaptersPane: View {
    @EnvironmentObject private var workspace: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("稿件")
                        .font(LinoType.paneTitle)
                        .foregroundStyle(LinoTheme.ink)
                    Text(chapterSummary)
                        .font(LinoType.ui(12))
                        .foregroundStyle(LinoTheme.muted)
                }
                Spacer()
                Button {
                    Task { await workspace.createChapter() }
                } label: {
                    Label("新章", systemImage: "plus")
                        .font(LinoType.ui(12.5, .semibold))
                        .foregroundStyle(LinoTheme.accentText)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(LinoTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            if workspace.chapters.isEmpty && !workspace.isLoading {
                LinoIEmptyCard(
                    title: "还没有章节",
                    subtitle: "先新建一章，再填写剧情 Bible 和允许人物。",
                    actionTitle: "新建章节"
                ) {
                    Task { await workspace.createChapter() }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(workspace.chapters.enumerated()), id: \.element.id) { offset, chapter in
                        NavigationLink(value: chapter) {
                            LinoIChapterRow(chapter: chapter)
                        }
                        .buttonStyle(.plain)
                        if offset != workspace.chapters.count - 1 {
                            Divider()
                                .overlay(LinoTheme.line)
                                .padding(.leading, 54)
                        }
                    }
                }
                .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
                .shadow(color: LinoTheme.hex(0x17181C, opacity: 0.04), radius: 2, y: 1)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .linoAnimation(LinoMotion.listItem, value: workspace.chapters.map(\.id))
            }
        }
    }

    private var chapterSummary: String {
        let completed = workspace.chapters.filter { $0.status == "finalized" }.count
        let awaiting = workspace.chapters.filter { $0.status == "draft_ready" }.count
        return "\(workspace.chapters.count) 章 · 已完成 \(completed) · 待接受 \(awaiting)"
    }
}

private struct LinoIChapterRow: View {
    let chapter: ChapterSummary

    var body: some View {
        HStack(spacing: 13) {
            Text("\(chapter.index)")
                .font(LinoType.serif(15))
                .foregroundStyle(LinoTheme.faint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 5) {
                Text(chapter.title.isEmpty ? "第 \(chapter.index) 章" : chapter.title)
                    .font(LinoType.cardTitle)
                    .foregroundStyle(LinoTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(chapter.status.linoStatusLabel)
                        .font(LinoType.caption)
                        .foregroundStyle(statusColor)
                    Text(chapter.updatedAt.linoShortDate)
                        .font(LinoType.caption)
                        .foregroundStyle(LinoTheme.faint)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LinoTheme.faint)
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch chapter.status {
        case "finalized": return LinoTheme.success
        case "draft_ready", "extracting": return LinoTheme.warning
        case "writing": return LinoTheme.accent
        case "failed": return LinoTheme.danger
        default: return LinoTheme.muted
        }
    }
}

struct LinoIBookSettingsPane: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var title = ""
    @State private var world = ""
    @State private var loadedBookId: String?
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var showingShare = false
    @State private var showingConnection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("设定")
                    .font(LinoType.paneTitle)
                    .foregroundStyle(LinoTheme.ink)
                Text("世界观进入 Writer 的硬约束区")
                    .font(LinoType.ui(12))
                    .foregroundStyle(LinoTheme.muted)
            }
            .padding(.horizontal, 4)

            settingsSection("书") {
                VStack(alignment: .leading, spacing: 0) {
                    settingsTextEditor(label: "书名", text: $title, minHeight: 44, font: LinoType.serif(17, .semibold))
                    Divider().overlay(LinoTheme.line)
                    settingsTextEditor(label: "世界观设定", text: $world, minHeight: 150, font: LinoType.serif(14))
                    Divider().overlay(LinoTheme.line)
                    Button {
                        saveBook()
                    } label: {
                        Text(workspace.isLoading ? "保存中" : "保存书籍设定")
                            .font(LinoType.ui(13, .semibold))
                            .foregroundStyle(LinoTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 48)
                            .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                }
            }

            settingsSection("导出") {
                VStack(spacing: 0) {
                    settingsActionRow("导出全书", detail: ".txt") { Task { await exportBook() } }
                    Divider().overlay(LinoTheme.line).padding(.leading, 14)
                    settingsActionRow("导出记忆", detail: ".txt") { Task { await exportMemories() } }
                }
            }

            settingsSection("模型与连接") {
                VStack(spacing: 0) {
                    NavigationLink {
                        LinoIAgentSettingsPane()
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        settingsNavigationRow(
                            title: "Agent 与模型",
                            subtitle: "4 个 Agent · \(agents.profiles.count) 个 Profile",
                            showsConnectionDot: false
                        )
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(LinoTheme.line).padding(.leading, 14)
                    Button { showingConnection = true } label: {
                        settingsNavigationRow(
                            title: "后端连接",
                            subtitle: connectionSubtitle,
                            showsConnectionDot: !session.token.isEmpty
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear(perform: sync)
        .onChange(of: session.currentBook?.id) { _, _ in sync() }
        .sheet(isPresented: $showingShare) {
            if let exportURL { ActivityView(items: [exportURL]) }
        }
        .sheet(isPresented: $showingConnection) {
            LinoIConnectionSheet()
                .presentationDetents([.height(360)])
                .presentationCornerRadius(20)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LinoISectionLabel(title)
                .padding(.horizontal, 6)
            content()
                .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func settingsTextEditor(label: String, text: Binding<String>, minHeight: CGFloat, font: Font) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LinoISectionLabel(label)
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .font(font)
                .lineSpacing(label == "世界观设定" ? 11 : 2)
                .foregroundStyle(LinoTheme.ink2)
                .frame(minHeight: minHeight)
        }
        .padding(14)
    }

    private func settingsActionRow(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(LinoType.ui(15))
                    .foregroundStyle(LinoTheme.ink)
                Spacer()
                Text(detail)
                    .font(LinoType.ui(12))
                    .foregroundStyle(LinoTheme.faint)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LinoTheme.faint)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
        }
        .buttonStyle(.plain)
        .disabled(isExporting)
    }

    private func settingsNavigationRow(title: String, subtitle: String, showsConnectionDot: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(LinoType.ui(15))
                    .foregroundStyle(LinoTheme.ink)
                Text(subtitle)
                    .font(LinoType.ui(11.5))
                    .foregroundStyle(LinoTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            if showsConnectionDot {
                Circle().fill(LinoTheme.success).frame(width: 6, height: 6)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LinoTheme.faint)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .contentShape(Rectangle())
    }

    private var connectionSubtitle: String {
        if session.baseURL.isEmpty { return "尚未配置" }
        return "\(session.baseURL) · Token 已存 Keychain"
    }

    private func sync() {
        guard let book = session.currentBook, loadedBookId != book.id else { return }
        loadedBookId = book.id
        title = book.title
        world = book.worldSetting
    }

    private func saveBook() {
        Task {
            await workspace.saveBook(title: title, world: world)
            if let book = session.currentBook { bookshelf.upsert(book) }
        }
    }

    private func exportBook() async { await export(path: "export.txt", suffix: "") }
    private func exportMemories() async { await export(path: "memories/export.txt", suffix: "·记忆") }

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
