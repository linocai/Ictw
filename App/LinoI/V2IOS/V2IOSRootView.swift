import SwiftUI

/// Integration root. The app entry may replace the legacy `RootView` with this
/// type without changing any Store construction or environment wiring.
struct V2IOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @EnvironmentObject private var editor: ChapterEditorStore
    @EnvironmentObject private var notices: NoticeBus

    var body: some View {
        NavigationStack(path: $workspace.chapterPath) {
            Group {
                if session.token.v2IOSTrimmed.isEmpty {
                    V2IOSConnectionView()
                } else if session.currentBook == nil {
                    V2IOSBookshelfView()
                } else {
                    V2IOSChapterRailView()
                }
            }
            .navigationDestination(for: ChapterSummary.self) { summary in
                V2IOSChapterDestinationView(summary: summary)
            }
            .overlay(alignment: .bottom) {
                V2IOSNoticeToast()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }
        }
        .v2IOSPage()
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: editor.handleScenePhaseActive()
            default: editor.persistLocalDraftIfNeeded()
            }
        }
    }
}

struct V2IOSConnectionView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var notices: NoticeBus
    @State private var baseURL = ""
    @State private var token = ""
    @State private var connecting = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            VStack(spacing: 7) {
                Text("连接 ICTW").font(V2DeskType.prose(27, weight: .semibold))
                Text("连接你的写作空间").font(V2DeskType.control(12.5)).foregroundStyle(Color.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                connectionField(label: "后端地址") {
                    TextField("https://…", text: $baseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                connectionField(label: "访问密钥") {
                    SecureField("访问密钥", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            V2IOSPrimaryButton(title: connecting ? "正在连接" : "保存并连接", disabled: connecting || baseURL.v2IOSTrimmed.isEmpty || token.v2IOSTrimmed.isEmpty) { connect() }
            Spacer()
        }
        .padding(.horizontal, 28)
        .onAppear { baseURL = session.baseURL }
    }

    private func connectionField<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            V2IOSSectionLabel(title: label)
            content().font(V2DeskType.control(14)).padding(13).v2IOSPaper()
        }
    }

    private func connect() {
        connecting = true
        session.baseURL = baseURL.v2IOSTrimmed
        session.token = token.v2IOSTrimmed
        session.saveConnection()
        Task {
            await bookshelf.load()
            connecting = false
            if bookshelf.books.isEmpty && !bookshelf.isLoading { notices.publish("已连接，可以新建第一本书。") }
        }
    }
}

private struct V2IOSNoticeToast: View {
    @EnvironmentObject private var notices: NoticeBus

    var body: some View {
        if let notice = notices.current {
            Text(notice.message)
                .font(V2DeskType.control(12))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.78), in: Capsule())
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
