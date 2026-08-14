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
            // The book shelf and chapter rail own their root-level chrome.
            // Destinations explicitly restore the system navigation bar.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ChapterSummary.self) { summary in
                V2IOSChapterDestinationView(summary: summary)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                V2IOSNoticeToast()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let notice = notices.current {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: notice.isCritical ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.isCritical ? Color.red.opacity(0.9) : Color.white.opacity(0.82))
                    .accessibilityHidden(true)
                Text(notice.message)
                    .font(V2DeskType.control(12))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    notices.dismiss(id: notice.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityLabel("关闭提示")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(notice.isCritical ? "重要提示" : "提示")
            .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: notice.id)
        }
    }
}
