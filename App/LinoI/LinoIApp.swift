import SwiftUI

@main
struct LinoIApp: App {
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
            RootView()
                .preferredColorScheme(.light)
                .environmentObject(notices)
                .environmentObject(session)
                .environmentObject(bookshelfStore)
                .environmentObject(workspaceStore)
                .environmentObject(charactersStore)
                .environmentObject(chapterEditorStore)
                .environmentObject(agentSettingsStore)
                .tint(LinoTheme.accent)
                .task {
                    await session.bootstrap()
                    await bookshelfStore.load()
                }
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var notices: NoticeBus
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var chapterEditorStore: ChapterEditorStore

    var body: some View {
        NavigationStack(path: $workspace.chapterPath) {
            ZStack {
                LinoTheme.background.ignoresSafeArea()
                Group {
                    if session.currentBook == nil {
                        LinoIShelfView()
                            .transition(.opacity)
                    } else {
                        LinoIWorkspaceView()
                            .transition(.opacity)
                    }
                }
                .animation(LinoMotion.content, value: session.currentBook?.id)
            }
            .navigationDestination(for: ChapterSummary.self) { summary in
                LinoIChapterEditorScreen(summary: summary)
            }
            .overlay(alignment: .bottom) {
                LinoIToast()
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                chapterEditorStore.handleScenePhaseActive()
            }
        }
    }
}
