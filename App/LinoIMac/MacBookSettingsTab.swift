import SwiftUI

/// 右栏「书设定」tab：书名 + 世界观设定 editor + 保存（`WorkspaceStore.saveBook`）
/// + 导出全书 `.txt`（`MacExportSaver`）。语义对齐 iOS `LinoIBookSettingsPane`：
/// 世界观进入 Writer 硬约束区；保存后同步回书架卡片（`bookshelf.upsert`）。
struct MacBookSettingsTab: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var agents: AgentSettingsStore
    @EnvironmentObject private var characters: CharactersStore
    let currentChapterID: String?

    @State private var title = ""
    @State private var world = ""
    @State private var loadedBookId: String?
    @State private var isExporting = false
    @State private var exportScope: ExportScope = .accepted
    @State private var exportFormat: ExportFormat = .plainText
    @State private var exportSeparateChapters = false
    @State private var exportWorld = true
    @State private var exportCharacters = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                LinoISectionLabel("书设定")
                Text("世界观设定会进入 Writer 的硬约束区。")
                    .font(.system(size: 12))
                    .foregroundStyle(LinoTheme.muted)
            }

            settingsCard
            personasCard
            exportCard
        }
        .onAppear(perform: sync)
        .onChange(of: session.currentBook?.id) { _, _ in sync() }
        .task(id: session.currentBook?.id) {
            if let id = session.currentBook?.id { await agents.loadBookPersonas(bookID: id) }
        }
    }

    private var personasCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinoISectionLabel("本书 Agent 人格")
            Text("默认跟随全局；模型、绑定和推理参数保持全局。修改只影响之后启动的任务。")
                .font(.system(size: 12)).foregroundStyle(LinoTheme.muted)
            ForEach(agents.bookPersonas) { persona in
                MacBookPersonaRow(role: persona.agentRole)
            }
        }
        .padding(14)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("书名")
                LinoITextField("书名", text: $title)
            }
            LinoIEditor(
                title: "世界观设定",
                text: $world,
                minHeight: 200,
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
            .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
            .onHover { pointer($0) }
        }
        .padding(14)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LinoISectionLabel("导出")
            Text("把全书已完成章节导出为纯文本，方便备份或投稿。")
                .font(.system(size: 12))
                .foregroundStyle(LinoTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Picker("章节范围", selection: $exportScope) { ForEach(ExportScope.allCases) { Text($0.label).tag($0) } }
                .labelsHidden().pickerStyle(.menu)
            Picker("格式", selection: $exportFormat) { ForEach(ExportFormat.allCases) { Text($0.label).tag($0) } }
                .labelsHidden().pickerStyle(.menu)
            Toggle("每章一个文件", isOn: $exportSeparateChapters).toggleStyle(.switch)
            Toggle("附世界观", isOn: $exportWorld).toggleStyle(.switch)
            Toggle("附人物设定", isOn: $exportCharacters).toggleStyle(.switch)
            Text("导出读取已保存版本；当前编辑器未保存的本机修改不会包含。记忆导出保持独立。")
                .font(.system(size: 11)).foregroundStyle(LinoTheme.muted).fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    guard let book = session.currentBook else { return }
                    isExporting = true
                    await MacExportSaver.exportComposed(
                        book: book, session: session, chapterSummaries: workspace.chapters,
                        characters: characters.characters, scope: exportScope, currentChapterID: currentChapterID,
                        format: exportFormat, includeWorld: exportWorld, includeCharacters: exportCharacters,
                        separateChapters: exportSeparateChapters
                    )
                    isExporting = false
                }
            } label: {
                Text(isExporting ? "正在导出" : "导出正文")
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
            .disabled(isExporting || session.currentBook == nil)
            .onHover { pointer($0 && !isExporting && session.currentBook != nil) }
            Text("把大事记、章节摘要、人物动态字段与故事线（Extractor 记忆）导出为纯文本。")
                .font(.system(size: 12))
                .foregroundStyle(LinoTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    guard let book = session.currentBook else { return }
                    isExporting = true
                    await MacExportSaver.exportMemories(book, session: session)
                    isExporting = false
                }
            } label: {
                Text(isExporting ? "正在导出" : "导出记忆")
            }
            .buttonStyle(LinoITintButtonStyle(compact: true))
            .disabled(isExporting || session.currentBook == nil)
            .onHover { pointer($0 && !isExporting && session.currentBook != nil) }
        }
        .padding(14)
        .linoPanelGlass(cornerRadius: LinoMacMetrics.cardRadius)
    }

    private func sync() {
        guard let book = session.currentBook, loadedBookId != book.id else { return }
        loadedBookId = book.id
        title = book.title
        world = book.worldSetting
    }
}

private struct MacBookPersonaRow: View {
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
        if let persona {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if !isEditing {
                    Text(persona.source == "book" ? "本书自定义人格" : "跟随全局人格").font(.system(size: 12, weight: .semibold)).foregroundStyle(LinoTheme.accentDeep)
                    Text(persona.effectivePersona).font(.system(size: 12)).foregroundStyle(LinoTheme.muted).fixedSize(horizontal: false, vertical: true)
                    Button(persona.source == "book" ? "编辑本书人格" : "为本书自定义") { draft = persona.effectivePersona; isEditing = true }
                        .buttonStyle(LinoITintButtonStyle(compact: true)).onHover { pointer($0) }
                } else {
                    LinoIEditor(title: "本书可编辑人格", text: $draft, minHeight: 160, placeholder: "仅用于本书的人格。")
                    Text("程序协议、模型和推理参数仍由全局设置控制。")
                        .font(.system(size: 11)).foregroundStyle(LinoTheme.muted)
                    HStack {
                        if persona.source == "book" {
                            Button("改回跟随全局") { confirmingReset = true }
                                .buttonStyle(LinoITintButtonStyle(compact: true)).onHover { pointer($0) }
                        }
                        Spacer()
                        Button("保存本书人格") {
                            if let id = session.currentBook?.id { Task { if await agents.saveBookPersona(bookID: id, role: role, editablePersona: draft) { isEditing = false } } }
                        }.buttonStyle(LinoIPrimaryButtonStyle(compact: true)).onHover { pointer($0) }
                    }
                }
            }.padding(.top, 8)
        } label: {
            HStack {
                Text(role.linoAgentName).font(.system(size: 13, weight: .semibold)).foregroundStyle(LinoTheme.ink)
                Spacer()
                Text(persona.source == "book" ? "本书自定义" : "跟随全局").font(.system(size: 11)).foregroundStyle(LinoTheme.muted)
            }
        }
        .padding(10).background(LinoTheme.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { draft = persona.bookPersona ?? persona.effectivePersona }
        .onChange(of: persona.source) { _, _ in
            if let current = self.persona { draft = current.bookPersona ?? current.effectivePersona; isEditing = false }
        }
        .confirmationDialog("改回跟随全局？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("删除本书自定义", role: .destructive) {
                if let id = session.currentBook?.id { Task { if await agents.resetBookPersona(bookID: id, role: role) { isEditing = false } } }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("将删除这本书的\(role.linoAgentName)人格设置，之后自动使用全局人格。当前这份自定义内容不会保留。") }
        }
    }
}
