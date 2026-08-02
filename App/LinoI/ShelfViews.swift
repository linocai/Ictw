import SwiftUI

struct LinoIShelfView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var showingNewBook = false
    @State private var showingConnection = false

    private let columns = [
        GridItem(.flexible(), spacing: 18, alignment: .top),
        GridItem(.flexible(), spacing: 18, alignment: .top),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if bookshelf.books.isEmpty && !bookshelf.isLoading {
                    LinoIEmptyCard(
                        title: "还没有书",
                        subtitle: "新建一本书后，就可以开始维护世界观、人物卡和章节正文。",
                        actionTitle: "新建书"
                    ) {
                        showingNewBook = true
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(bookshelf.books) { book in
                            LinoIBookCard(book: book) {
                                Task { await bookshelf.open(book) }
                            }
                        }

                        Button {
                            showingNewBook = true
                        } label: {
                            VStack(spacing: 9) {
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .regular))
                                Text("新建书")
                                    .font(LinoType.ui(13, .semibold))
                            }
                            .foregroundStyle(LinoTheme.muted)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(3 / 4, contentMode: .fit)
                        }
                        .buttonStyle(LinoIDashedButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 36)
        }
        .refreshable { await bookshelf.load() }
        .sheet(isPresented: $showingNewBook) {
            LinoINewBookSheet()
                .presentationDetents([.height(250)])
                .presentationCornerRadius(20)
        }
        .sheet(isPresented: $showingConnection) {
            LinoIConnectionSheet()
                .presentationDetents([.height(360)])
                .presentationCornerRadius(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("LINOI")
                        .font(LinoType.ui(11.5, .medium))
                        .tracking(1.6)
                        .foregroundStyle(LinoTheme.muted)
                    Text("书架")
                        .font(LinoType.display)
                        .foregroundStyle(LinoTheme.ink)
                }
                Spacer()
                Button {
                    showingConnection = true
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(session.token.isEmpty ? LinoTheme.warning : LinoTheme.success)
                            .frame(width: 6, height: 6)
                        Text(session.token.isEmpty ? "未连接" : "已连接")
                            .font(LinoType.ui(13, .medium))
                    }
                    .foregroundStyle(LinoTheme.ink2)
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(LinoTheme.surface, in: Capsule())
                    .overlay(Capsule().stroke(LinoTheme.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityHint("打开后端连接设置")
            }

            Text(shelfSummary)
                .font(LinoType.ui(12))
                .foregroundStyle(LinoTheme.muted)
        }
    }

    private var shelfSummary: String {
        let chapters = bookshelf.books.reduce(0) { $0 + $1.chapterCount }
        let latest = bookshelf.books.first?.updatedAt.linoShortDate ?? "暂无记录"
        return "\(bookshelf.books.count) 本书 · \(chapters) 章 · 最近更新 \(latest)"
    }
}

private struct LinoIBookCard: View {
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var confirmingDelete = false

    let book: Book
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                LinoIPaperBookCover(title: bookTitle, seed: book.id)

                VStack(alignment: .leading, spacing: 4) {
                    Text(bookTitle)
                        .font(LinoType.serif(15, .semibold))
                        .foregroundStyle(LinoTheme.ink)
                        .lineLimit(1)
                    Text("\(book.chapterCount) 章 · \(book.characterCount) 人物 · \(book.updatedAt.linoShortDate)")
                        .font(LinoType.caption)
                        .foregroundStyle(LinoTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .buttonStyle(LinoICardButtonStyle())
        .contextMenu {
            Button("删除这本书", systemImage: "trash", role: .destructive) {
                confirmingDelete = true
            }
        }
        .confirmationDialog(
            "删除《\(bookTitle)》？",
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

    private var bookTitle: String {
        book.title.isEmpty ? "未命名书籍" : book.title
    }
}

private struct LinoIPaperBookCover: View {
    let title: String
    let seed: String

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 10,
                topTrailingRadius: 10,
                style: .continuous
            )
            .fill(LinoTheme.coverPaper(seed))

            HStack(spacing: 0) {
                LinoTheme.coverInk.opacity(0.06)
                    .frame(width: 5)
                Spacer(minLength: 0)
            }

            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 2,
                bottomTrailingRadius: 5,
                topTrailingRadius: 5,
                style: .continuous
            )
            .stroke(LinoTheme.coverInk.opacity(0.20), lineWidth: 1)
            .padding(.top, 12)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .padding(.leading, 20)

            VStack(spacing: 2) {
                VStack(spacing: 1) {
                    ForEach(Array(title.prefix(8).enumerated()), id: \.offset) { _, character in
                        Text(String(character))
                            .font(LinoType.serif(19, .semibold))
                    }
                }
                .tracking(5)
                .foregroundStyle(LinoTheme.coverInk)
                .padding(.top, 23)

                Spacer()

                Text(mark)
                    .font(LinoType.ui(9.5, .medium))
                    .tracking(2.4)
                    .foregroundStyle(LinoTheme.coverInk.opacity(0.55))
                    .padding(.bottom, 21)
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 10,
                topTrailingRadius: 10,
                style: .continuous
            )
            .stroke(LinoTheme.coverInk.opacity(0.05), lineWidth: 1)
        )
    }

    private var mark: String {
        let transformed = title
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripCombiningMarks, reverse: false) ?? title
        let letters = transformed
            .split(whereSeparator: { !$0.isLetter })
            .compactMap(\.first)
            .prefix(4)
        let result = String(letters).uppercased()
        return result.isEmpty ? "LINOI" : result
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
                    .font(LinoType.ui(12))
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
                        .foregroundStyle(LinoTheme.accent)
                }
            }
            .background(LinoTheme.bg.ignoresSafeArea())
        }
    }
}
