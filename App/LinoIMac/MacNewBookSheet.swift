import SwiftUI

/// 新建作品 sheet：书名输入 + 创建。macOS sheet 用固定尺寸
/// （`presentationDetents` 是 iOS/iPadOS-only API，这里改用 `.frame`）。
/// `BookshelfStore.createBook` 拿到服务器返回的新书后会直接把它写进
/// `session.currentBook`，因此这里创建成功即视为"自动 open 进书"，不需要
/// 再手动调一次 `bookshelf.open(_:)`。
struct MacNewBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bookshelf: BookshelfStore

    @State private var title = ""
    @State private var isCreating = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("新建作品")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LinoTheme.ink)
                Spacer()
                LinoMacIconButton(systemName: "xmark", size: 26, fontSize: 11, help: "取消") {
                    dismiss()
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                LinoISectionLabel("书名")
                LinoITextField("给这本书起个名字", text: $title)
                    .focused($titleFocused)
                    .onSubmit { Task { await create() } }
            }

            Text("世界观设定进入书籍后再填写，方便先把项目建起来。")
                .font(.system(size: 12))
                .foregroundStyle(LinoTheme.muted)

            Spacer()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(LinoITintButtonStyle())
                    .onHover { pointer($0) }
                Button {
                    Task { await create() }
                } label: {
                    HStack(spacing: 6) {
                        if isCreating {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text("创建")
                    }
                }
                .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                .disabled(isCreating)
                .onHover { pointer($0 && !isCreating) }
            }
        }
        .padding(24)
        .frame(width: 420, height: 260)
        .background(LinoTheme.background)
        .onAppear { titleFocused = true }
    }

    private func create() async {
        guard !isCreating else { return }
        isCreating = true
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await bookshelf.createBook(title: name.isEmpty ? "未命名书籍" : name)
        isCreating = false
        dismiss()
    }
}
