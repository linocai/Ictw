import SwiftUI

struct V2IOSBookshelfView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var showingNewBook = false
    @State private var showingSettings = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                header
                if bookshelf.isLoading && bookshelf.books.isEmpty {
                    ProgressView().padding(.vertical, 52)
                } else if bookshelf.books.isEmpty {
                    V2IOSFirstStartView(openNewBook: { showingNewBook = true })
                        .padding(.top, 84)
                } else {
                    ForEach(bookshelf.books) { book in
                        Button {
                            Task { await bookshelf.open(book) }
                        } label: {
                            V2IOSBookShelfRow(book: book, isCurrent: session.currentBook?.id == book.id)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.secondary.opacity(0.15))
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .refreshable { await bookshelf.load() }
        .sheet(isPresented: $showingNewBook) {
            V2IOSNewBookSheet()
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
        .sheet(isPresented: $showingSettings) {
            V2IOSSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(V2DeskMetric.sheetCornerRadius)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("书架")
                    .font(V2DeskType.prose(25, weight: .semibold))
                Text("正文在这里继续生长")
                    .font(V2DeskType.control(11.5))
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            Button("设置") { showingSettings = true }
                .font(V2DeskType.control(12.5, weight: .medium))
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.plain)
            Button("新建一本") { showingNewBook = true }
                .font(V2DeskType.control(12.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 72, minHeight: 44)
                .buttonStyle(.plain)
        }
        .padding(.top, 18)
        .padding(.bottom, 18)
    }
}

private struct V2IOSBookShelfRow: View {
    let book: Book
    let isCurrent: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(isCurrent ? V2DeskPalette.color(.accent, scheme: colorScheme) : .clear)
                .frame(width: 2, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title.v2IOSTrimmed.isEmpty ? "未命名书籍" : book.title)
                    .font(V2DeskType.prose(17, weight: .medium))
                    .foregroundStyle(V2DeskPalette.color(.ink, scheme: colorScheme))
                    .lineLimit(1)
                Text("\(book.chapterCount) 章")
                    .font(V2DeskType.control(11))
                    .foregroundStyle(V2DeskPalette.color(.tertiaryInk, scheme: colorScheme))
            }
            Spacer(minLength: 8)
            shelfHealth
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(isCurrent ? V2DeskPalette.color(.manuscriptPaper, scheme: colorScheme) : .clear)
    }

    @ViewBuilder private var shelfHealth: some View {
        if book.archiveAttentionCount > 0 {
            HStack(spacing: 5) {
                V2DeskStatusMark(marker: .unreliable, diameter: 7)
                Text("\(book.archiveAttentionCount) 章记忆待重整")
            }
            .font(V2DeskType.control(11))
            .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
        } else if book.archivePendingCount > 0 {
            Text("正在整理记忆")
                .font(V2DeskType.control(11))
                .foregroundStyle(V2DeskPalette.color(.accent, scheme: colorScheme))
        } else {
            Text(book.updatedAt)
                .font(V2DeskType.control(11))
                .foregroundStyle(V2DeskPalette.color(.metadataInk, scheme: colorScheme))
                .lineLimit(1)
        }
    }
}

private struct V2IOSFirstStartView: View {
    let openNewBook: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("从第一本开始")
                .font(V2DeskType.prose(27, weight: .semibold))
            V2IOSPrimaryButton(title: "新建一本", action: openNewBook)
        }
        .padding(.horizontal, 4)
    }
}

private struct V2IOSNewBookSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var bookshelf: BookshelfStore
    @EnvironmentObject private var workspace: WorkspaceStore
    @State private var title = ""
    @State private var world = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Capsule().fill(Color.secondary.opacity(0.22)).frame(width: 38, height: 4).frame(maxWidth: .infinity)
            HStack {
                Text("新建一本").font(V2DeskType.prose(20, weight: .semibold))
                Spacer()
                Button("取消") { dismiss() }.frame(minHeight: 44).buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 8) {
                V2IOSSectionLabel(title: "书名")
                TextField("书名", text: $title)
                    .textFieldStyle(.plain)
                    .padding(13)
                    .v2IOSPaper()
            }
            VStack(alignment: .leading, spacing: 8) {
                V2IOSSectionLabel(title: "世界观")
                TextEditor(text: $world)
                    .font(V2DeskType.prose(15))
                    .frame(minHeight: 124)
                    .padding(8)
                    .v2IOSPaper()
                    .overlay(alignment: .topLeading) {
                        if world.isEmpty {
                            Text("可以稍后再写")
                                .font(V2DeskType.prose(15))
                                .foregroundStyle(Color.secondary)
                                .padding(.horizontal, 14).padding(.vertical, 15)
                                .allowsHitTesting(false)
                        }
                    }
            }
            V2IOSPrimaryButton(title: creating ? "正在创建" : "创建", disabled: creating) {
                creating = true
                Task {
                    await bookshelf.createBook(title: title.v2IOSTrimmed.isEmpty ? "未命名书籍" : title.v2IOSTrimmed)
                    if !world.v2IOSTrimmed.isEmpty { await workspace.saveBook(title: title.v2IOSTrimmed, world: world) }
                    creating = false
                    dismiss()
                }
            }
        }
        .padding(20)
        .v2IOSPage()
    }
}
