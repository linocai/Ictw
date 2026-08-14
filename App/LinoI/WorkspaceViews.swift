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
        let pending = workspace.chapters.filter { ChapterArchiveRailState.resolve(status: $0.archiveStatus, canRetry: $0.archiveCanRetry) == .pending }.count
        let attention = workspace.chapters.filter { ChapterArchiveRailState.resolve(status: $0.archiveStatus, canRetry: $0.archiveCanRetry) == .attention }.count
        var text = "\(workspace.chapters.count) 章 · 已完成 \(completed) · 待接受 \(awaiting)"
        if pending > 0 { text += " · 归档中 \(pending)" }
        if attention > 0 { text += " · 归档待处理 \(attention)" }
        return text
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
                    if let archiveLabel = ChapterArchiveRailState.resolve(status: chapter.archiveStatus, canRetry: chapter.archiveCanRetry).label {
                        Text(archiveLabel)
                            .font(LinoType.caption).foregroundStyle(LinoTheme.warning)
                    }
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
    @EnvironmentObject private var characters: CharactersStore
    @State private var title = ""
    @State private var world = ""
    @State private var loadedBookId: String?
    @State private var isExporting = false
    @State private var exportURL: URL?
    @State private var exportURLs: [URL] = []
    @State private var showingShare = false
    @State private var showingConnection = false
    @State private var exportScope: ExportScope = .accepted
    @State private var exportFormat: ExportFormat = .plainText
    @State private var exportSeparateChapters = false
    @State private var exportWorld = true
    @State private var exportCharacters = true

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
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("章节范围", selection: $exportScope) { ForEach(ExportScope.allCases) { Text($0.label).tag($0) } }
                        Picker("格式", selection: $exportFormat) { ForEach(ExportFormat.allCases) { Text($0.label).tag($0) } }
                        Toggle("每章一个文件", isOn: $exportSeparateChapters).tint(LinoTheme.accent)
                        Toggle("附世界观", isOn: $exportWorld).tint(LinoTheme.accent)
                        Toggle("附人物设定", isOn: $exportCharacters).tint(LinoTheme.accent)
                        Text("正文导出使用已保存版本；当前其他编辑页未保存的本机修改不会包含在内。记忆导出独立处理。")
                            .font(LinoType.ui(11.5)).foregroundStyle(LinoTheme.muted)
                        Button(isExporting ? "正在准备导出" : "导出正文") { Task { await exportBook() } }
                            .buttonStyle(LinoITintButtonStyle(compact: true)).disabled(isExporting)
                    }
                    .padding(14)
                    Divider().overlay(LinoTheme.line).padding(.leading, 14)
                    settingsActionRow("导出记忆", detail: ".txt") { Task { await exportMemories() } }
                }
            }

            settingsSection("本书 Agent 人格") {
                NavigationLink {
                    LinoIBookPersonasPane()
                } label: {
                    settingsNavigationRow(
                        title: "本书人格",
                        subtitle: "默认跟随全局；模型与推理参数仍为全局",
                        showsConnectionDot: false
                    )
                }
                .buttonStyle(.plain)
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
            if !exportURLs.isEmpty { ActivityView(items: exportURLs) }
            else if let exportURL { ActivityView(items: [exportURL]) }
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

    private func exportBook() async {
        guard let book = session.currentBook else { return }
        if exportScope == .current && workspace.chapterPath.last == nil {
            session.notices.publish("请先从章节列表打开一章，再选择“本章”导出。")
            return
        }
        isExporting = true
        defer { isExporting = false }
        do {
            let details: [Chapter] = try await withThrowingTaskGroup(of: Chapter.self) { group in
                for summary in workspace.chapters { group.addTask { try await session.api.request("/chapters/\(summary.id)") } }
                var values: [Chapter] = []
                for try await chapter in group { values.append(chapter) }
                return values
            }
            let selected = ExportComposer.chapters(for: exportScope, chapters: details, currentID: workspace.chapterPath.last?.id)
            guard !selected.isEmpty else { session.notices.publish("所选范围没有可导出的正文。"); return }
            let files = ExportComposer.compose(
                book: book, chapters: selected, characters: characters.characters, format: exportFormat,
                includeWorld: exportWorld, includeCharacters: exportCharacters, separateChapters: exportSeparateChapters
            )
            let urls = try files.map { file -> URL in
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
                guard let data = file.text.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
                try data.write(to: url, options: .atomic)
                return url
            }
            exportURL = urls.first
            exportURLs = urls
            showingShare = true
        } catch { session.notices.publish(error) }
    }
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

/// Book overrides live beside book settings, not in global Agent settings.
/// The first tap into customization only seeds this view's unsaved text.
private struct LinoIBookPersonasPane: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    private let roles = ["memory_selector", "writer", "checker", "extractor", "inspiration_creator"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("本书人格")
                    .font(LinoType.paneTitle).foregroundStyle(LinoTheme.ink)
                Text("只影响之后启动的任务。模型、绑定和推理参数始终使用全局设置。")
                    .font(LinoType.ui(12)).foregroundStyle(LinoTheme.muted)
                VStack(spacing: 0) {
                    ForEach(Array(roles.enumerated()), id: \.element) { offset, role in
                        if let persona = agents.bookPersonas.first(where: { $0.agentRole == role }) {
                            NavigationLink { LinoIBookPersonaEditor(role: role) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(role.linoAgentName).font(LinoType.ui(15, .medium)).foregroundStyle(LinoTheme.ink)
                                        Text(persona.source == "book" ? "本书自定义" : "跟随全局").font(LinoType.caption).foregroundStyle(LinoTheme.muted)
                                    }
                                    Spacer(); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(LinoTheme.faint)
                                }.padding(.horizontal, 14).frame(height: 58)
                            }.buttonStyle(.plain)
                        }
                        if offset != roles.count - 1 { Divider().overlay(LinoTheme.line).padding(.leading, 14) }
                    }
                }
                .background(LinoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(LinoTheme.line, lineWidth: 1))
            }.padding(16)
        }
        .background(LinoTheme.bg.ignoresSafeArea())
        .task(id: session.currentBook?.id) {
            if let id = session.currentBook?.id { await agents.loadBookPersonas(bookID: id) }
        }
    }
}

private struct LinoIBookPersonaEditor: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var agents: AgentSettingsStore
    @State private var draft = ""
    @State private var isEditing = false
    @State private var confirmingReset = false
    let role: String

    private var persona: BookAgentPersona? {
        agents.bookPersonas.first(where: { $0.agentRole == role })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if let persona {
                    VStack(alignment: .leading, spacing: 16) {
                    Text(role.linoAgentName).font(LinoType.paneTitle).foregroundStyle(LinoTheme.ink)
                    if !isEditing {
                        Text(persona.source == "book" ? "本书自定义人格" : "跟随全局人格").font(LinoType.ui(13, .semibold)).foregroundStyle(LinoTheme.accent)
                        Text(persona.effectivePersona).font(LinoType.serif(14)).foregroundStyle(LinoTheme.ink2)
                        Button(persona.source == "book" ? "编辑本书人格" : "为本书自定义") {
                            draft = persona.effectivePersona; isEditing = true
                        }.buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                    } else {
                        LinoIEditor(title: "本书可编辑人格", text: $draft, minHeight: 220, placeholder: "填写仅用于本书的人格。")
                        Text("程序协议只读且始终生效；模型参数仍为全局。")
                            .font(LinoType.ui(11.5)).foregroundStyle(LinoTheme.muted)
                        HStack {
                            if persona.source == "book" {
                                Button("改回跟随全局") { confirmingReset = true }.buttonStyle(LinoITintButtonStyle(compact: true))
                            }
                            Spacer()
                            Button("保存本书人格") {
                                if let id = session.currentBook?.id { Task { if await agents.saveBookPersona(bookID: id, role: role, editablePersona: draft) { isEditing = false } } }
                            }.buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                        }
                    }
                    }.padding(16)
                }
            }
        }
        .background(LinoTheme.bg.ignoresSafeArea())
        .onAppear { if let persona { draft = persona.bookPersona ?? persona.effectivePersona } }
        .onChange(of: persona?.source) { _, _ in
            if let persona { draft = persona.bookPersona ?? persona.effectivePersona; isEditing = false }
        }
        .confirmationDialog("改回跟随全局？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("删除本书自定义", role: .destructive) {
                if let id = session.currentBook?.id { Task { if await agents.resetBookPersona(bookID: id, role: role) { isEditing = false } } }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("将删除这本书的\(role.linoAgentName)人格设置，之后自动使用全局人格。当前这份自定义内容不会保留。") }
    }
}
