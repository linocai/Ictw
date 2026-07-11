import SwiftUI

/// 书架：居中容器（最大宽 `LinoMacMetrics.shelfMaxWidth`）+ 顶部 header
/// （kicker「书架」/大标题「我的作品」/「新建作品」主按钮/⚙ 占位钮——设置
/// sheet 是块⑤/连接状态点+baseURL）+ 自适应书卡网格。全部读写走共享
/// `BookshelfStore`，本视图不持有任何书籍数据的本地拷贝。
struct MacBookshelfView: View {
    @EnvironmentObject private var session: AppSession
    @EnvironmentObject private var bookshelf: BookshelfStore
    @State private var showingNewBook = false

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 22)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                gridOrEmpty
            }
            .padding(32)
            .frame(maxWidth: LinoMacMetrics.shelfMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await bookshelf.load() }
        .sheet(isPresented: $showingNewBook) {
            MacNewBookSheet()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                LinoISectionLabel("书架")
                Text("我的作品")
                    .font(.custom("Songti SC", size: 30).weight(.bold))
                    .foregroundStyle(LinoTheme.ink)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        showingNewBook = true
                    } label: {
                        Label("新建作品", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(LinoIPrimaryButtonStyle(compact: true))
                    .onHover { pointer($0) }

                    LinoMacIconButton(systemName: "gearshape", help: "设置（块⑤开放）", isDisabled: true) {}
                }
                HStack(spacing: 8) {
                    LinoMacConnectionChip()
                    Text(session.baseURL.isEmpty ? "未配置后端" : session.baseURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LinoTheme.faint)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - 网格 / 空态 / 首次加载

    @ViewBuilder
    private var gridOrEmpty: some View {
        if bookshelf.isLoading && bookshelf.books.isEmpty {
            HStack {
                Spacer()
                ProgressView("正在加载书架…")
                    .padding(.vertical, 70)
                Spacer()
            }
        } else if bookshelf.books.isEmpty {
            LinoIEmptyCard(
                title: "还没有作品",
                subtitle: "新建一本书后，就可以开始维护世界观、人物卡和章节正文。",
                actionTitle: "新建作品"
            ) {
                showingNewBook = true
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(bookshelf.books) { book in
                    MacBookCard(
                        book: book,
                        onOpen: { Task { await bookshelf.open(book) } },
                        onDelete: { Task { await bookshelf.delete(book) } }
                    )
                }
                newBookDashedCard
            }
        }
    }

    private var newBookDashedCard: some View {
        Button {
            showingNewBook = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                Text("新建作品")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 214)
        }
        .buttonStyle(LinoIDashedButtonStyle())
        .onHover { pointer($0) }
    }
}

// MARK: - 书卡

private struct MacBookCard: View {
    let book: Book
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false
    @State private var confirmingDelete = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: LinoMacMetrics.cardRadius, style: .continuous)
                    .fill(LinoTheme.coverGradient(book.id))
                    .frame(height: 108)
                    .overlay(alignment: .bottomLeading) {
                        Text(String(book.title.prefix(2)))
                            .font(.custom("Songti SC", size: 30).weight(.bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(16)
                    }

                VStack(alignment: .leading, spacing: 7) {
                    Text(book.title.isEmpty ? "未命名书籍" : book.title)
                        .font(.custom("Songti SC", size: 16).weight(.semibold))
                        .foregroundStyle(LinoTheme.ink)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(book.chapterCount) 章 · \(book.characterCount) 人物")
                        .font(.system(size: 12))
                        .foregroundStyle(LinoTheme.muted)
                    Text(macRelativeDate(book.updatedAt))
                        .font(.system(size: 11.5))
                        .foregroundStyle(LinoTheme.faint)
                }
                .padding(14)
            }
            .frame(minHeight: 214, alignment: .top)
            .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: LinoMacMetrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LinoMacMetrics.cardRadius, style: .continuous)
                    .stroke(LinoMacMetrics.hairline, lineWidth: LinoMacMetrics.hairlineWidth)
            )
            .shadow(color: LinoTheme.hex(0x143052, opacity: hovered ? 0.20 : 0.10), radius: hovered ? 22 : 14, y: hovered ? 12 : 8)
            .offset(y: hovered ? -3 : 0)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.18), value: hovered)
        .onHover { inside in
            hovered = inside
            pointer(inside)
        }
        .contextMenu {
            Button("打开", systemImage: "arrow.forward.circle", action: onOpen)
            Button("删除这本书", systemImage: "trash", role: .destructive) {
                confirmingDelete = true
            }
        }
        .confirmationDialog(
            "删除《\(book.title.isEmpty ? "未命名书籍" : book.title)》？",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销，书籍下所有章节、人物与记忆都会被删除。")
        }
    }
}

/// Mac 书架专用的相对时间格式：今天 HH:mm / 昨天 HH:mm / N 天前（一周内）/
/// M月d日（更早）。与 iOS `String.linoShortDate`（`RelativeDateTimeFormatter`
/// 短样式）故意不同——书架卡片上要的是"几点"而不是笼统的"几小时前"。
private func macRelativeDate(_ raw: String) -> String {
    guard let date = parseBackendTimestamp(raw) else { return "最近更新" }

    let calendar = Calendar.current
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "HH:mm"

    if calendar.isDateInToday(date) {
        return "今天 \(timeFormatter.string(from: date))"
    }
    if calendar.isDateInYesterday(date) {
        return "昨天 \(timeFormatter.string(from: date))"
    }
    let startOfDate = calendar.startOfDay(for: date)
    let startOfNow = calendar.startOfDay(for: Date())
    let days = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
    if days > 0 && days < 7 {
        return "\(days) 天前"
    }
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "M月d日"
    return dateFormatter.string(from: date)
}

/// 后端 `updated_at` 实际落地是 SQLite 经 SQLAlchemy `DateTime(timezone=True)`
/// 存取后丢了时区标记的裸时间字符串（例如 `"2026-07-11T05:57:11.827494"`，
/// 无 `Z`/偏移），不是标准 `ISO8601DateFormatter` 能直接吃的格式——照单纯
/// `.withInternetDateTime` 解析会稳定返回 nil，卡片会永远显示"最近更新"退
/// 化态。这里按后端 `utc_now()`（写库前就是 UTC）把裸字符串当 UTC 解释，
/// 换算到 `Calendar.current` 的本地时区再做"今天/昨天"判断；同时保留标准
/// ISO8601（含时区）分支，未来后端序列化换成带时区字符串也能直接命中。
private func parseBackendTimestamp(_ raw: String) -> Date? {
    let isoFractional = ISO8601DateFormatter()
    isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFractional.date(from: raw) { return date }
    if let date = ISO8601DateFormatter().date(from: raw) { return date }

    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) { return date }
    }
    return nil
}
