import SwiftUI

/// macOS 端入口。与 iOS `LinoIApp` 一致地在 `init()` 建同一套共享 Store
/// 并注入 environment；桌面窗口配置为隐藏原生标题栏 + 最小尺寸约束。
/// 写作台 UI（书架 / 三栏 / 阅读）在后续块补全，本块 `MacShell` 为占位。
@main
struct LinoIMacApp: App {
    @StateObject private var notices: NoticeBus
    @StateObject private var session: AppSession
    @StateObject private var bookshelfStore: BookshelfStore
    @StateObject private var workspaceStore: WorkspaceStore
    @StateObject private var charactersStore: CharactersStore
    @StateObject private var chapterEditorStore: ChapterEditorStore
    @StateObject private var agentSettingsStore: AgentSettingsStore

    init() {
        let notices = NoticeBus()
        let session = AppSession(notices: notices)
        _notices = StateObject(wrappedValue: notices)
        _session = StateObject(wrappedValue: session)
        _bookshelfStore = StateObject(wrappedValue: BookshelfStore(session: session))
        _workspaceStore = StateObject(wrappedValue: WorkspaceStore(session: session))
        _charactersStore = StateObject(wrappedValue: CharactersStore(session: session))
        _chapterEditorStore = StateObject(wrappedValue: ChapterEditorStore(session: session))
        _agentSettingsStore = StateObject(wrappedValue: AgentSettingsStore(session: session))
    }

    var body: some Scene {
        WindowGroup {
            MacShell()
                .environmentObject(notices)
                .environmentObject(session)
                .environmentObject(bookshelfStore)
                .environmentObject(workspaceStore)
                .environmentObject(charactersStore)
                .environmentObject(chapterEditorStore)
                .environmentObject(agentSettingsStore)
                .frame(minWidth: 1080, minHeight: 720)
                .tint(LinoTheme.accent)
                .task {
                    await session.bootstrap()
                    await bookshelfStore.load()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
