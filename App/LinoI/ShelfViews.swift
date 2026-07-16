import SwiftUI

struct LinoIShelfView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var showingNewBook = false
    @State private var showingConnection = false

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14, alignment: .top)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                connectionStrip

                if bookshelf.books.isEmpty && !bookshelf.isLoading {
                    LinoIEmptyCard(
                        title: "还没有书",
                        subtitle: "新建一本书后，就可以开始维护世界观、人物卡和章节正文。",
                        actionTitle: "新建书"
                    ) {
                        showingNewBook = true
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(bookshelf.books) { book in
                            LinoIBookCard(book: book) {
                                Task { await bookshelf.open(book) }
                            }
                        }
                        Button {
                            showingNewBook = true
                        } label: {
                            VStack(spacing: 10) {
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .semibold))
                                Text("新建书")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 178)
                        }
                        .buttonStyle(LinoIDashedButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 34)
        }
        .refreshable { await bookshelf.load() }
        .sheet(isPresented: $showingNewBook) {
            LinoINewBookSheet()
                .presentationDetents([.height(220)])
        }
        .sheet(isPresented: $showingConnection) {
            LinoIConnectionSheet()
                .presentationDetents([.height(340)])
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 13) {
            LinoIAvatar(name: "LinoI", size: 52, rounded: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("LinoI")
                    .font(LinoType.display)
                    .foregroundStyle(LinoTheme.ink)
                Text("单人小说写作工作台")
                    .font(.subheadline)
                    .foregroundStyle(LinoTheme.muted)
            }
            Spacer()
            Button {
                showingConnection = true
            } label: {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderless)
            .background(Color.white.opacity(0.68), in: Circle())
            .overlay(Circle().stroke(LinoTheme.hairline, lineWidth: 0.5))
            .foregroundStyle(LinoTheme.accentDeep)
        }
    }

    private var connectionStrip: some View {
        HStack(spacing: 10) {
            Image(systemName: session.token.isEmpty ? "lock.open.trianglebadge.exclamationmark" : "lock.shield")
                .foregroundStyle(session.token.isEmpty ? LinoTheme.warning : LinoTheme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.baseURL.isEmpty ? "后端未配置" : session.baseURL)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(LinoTheme.ink)
                Text(session.token.isEmpty ? "需要 Bearer Token 才能读取项目" : "Bearer Token 已保存到 Keychain")
                    .font(.caption)
                    .foregroundStyle(LinoTheme.muted)
            }
            Spacer()
            if bookshelf.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(13)
        .linoGlass(cornerRadius: 18)
    }
}

private struct LinoIBookCard: View {
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var confirmingDelete = false

    let book: Book
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinoTheme.coverGradient(book.id))
                    .frame(height: 92)
                    .overlay(alignment: .bottomLeading) {
                        Text(String(book.title.prefix(2)))
                            .font(.custom("Songti SC", size: 28).weight(.bold))
                            .foregroundStyle(.white)
                            .padding(14)
                    }

                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title.isEmpty ? "未命名书籍" : book.title)
                        .font(LinoType.cardTitle)
                        .foregroundStyle(LinoTheme.ink)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Label("\(book.chapterCount)", systemImage: "text.book.closed")
                        Label("\(book.characterCount)", systemImage: "person.2")
                    }
                    .font(.caption)
                    .foregroundStyle(LinoTheme.muted)
                    Text(book.updatedAt.linoShortDate)
                        .font(.caption2)
                        .foregroundStyle(LinoTheme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
            .linoCard(cornerRadius: 18)
        }
        .buttonStyle(LinoICardButtonStyle())
        .contextMenu {
            Button("删除这本书", systemImage: "trash", role: .destructive) {
                confirmingDelete = true
            }
        }
        .confirmationDialog(
            "删除《\(book.title.isEmpty ? "未命名书籍" : book.title)》？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                Task { await bookshelf.delete(book) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销，书籍下所有章节、人物与记忆都会被删除。")
        }
    }
}

private struct LinoINewBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var title = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                LinoITextField("书名", text: $title)
                Text("世界观设定进入书籍后再填写，方便先把项目建起来。")
                    .font(.footnote)
                    .foregroundStyle(LinoTheme.muted)
                Spacer()
                Button("创建") {
                    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await bookshelf.createBook(title: name.isEmpty ? "未命名书籍" : name)
                        dismiss()
                    }
                }
                .buttonStyle(LinoIPrimaryButtonStyle())
            }
            .padding(18)
            .navigationTitle("新建书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .background(LinoTheme.background.ignoresSafeArea())
        }
    }
}
