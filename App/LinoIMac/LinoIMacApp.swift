import SwiftUI
import AppKit

/// 锁浅色双保险之一：AppKit 层锁定整体 appearance，覆盖 SwiftUI
/// `.preferredColorScheme` 管不到的系统面板——`NSSavePanel`、右键
/// `contextMenu`、`confirmationDialog` 等。配合 `MacShell` 顶层的
/// `.preferredColorScheme(.light)`（锁住 SwiftUI 层）双保险覆盖全部系统弹层。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
    }
}

/// macOS 端入口。与 iOS `LinoIApp` 一致地在 `init()` 建同一套共享 Store
/// 并注入 environment；桌面窗口配置为隐藏原生标题栏 + 最小尺寸约束。另注入
/// macOS-only 的 `MacCommandBus`，承接 `.commands` 菜单/⌘ 快捷键派发的
/// 「设置 / 新建作品 / 新建章节」意图。
@main
struct LinoIMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var notices: NoticeBus
    @StateObject private var session: AppSession
    @StateObject private var bookshelfStore: BookshelfStore
    @StateObject private var workspaceStore: WorkspaceStore
    @StateObject private var charactersStore: CharactersStore
    @StateObject private var chapterEditorStore: ChapterEditorStore
    @StateObject private var agentSettingsStore: AgentSettingsStore
    @StateObject private var commandBus = MacCommandBus()

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
                .environmentObject(commandBus)
                .frame(minWidth: 1080, minHeight: 720)
                .tint(LinoTheme.accent)
                .task {
                    await session.bootstrap()
                    await bookshelfStore.load()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    commandBus.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("新建作品") {
                    commandBus.showNewBook = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("新建章节") {
                    commandBus.showNewChapter = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(session.currentBook == nil)
            }
        }
    }
}
