import SwiftUI

/// Reusable state marks and stripes. Builders should use these rather than
/// inventing color-only status indicators on either platform.
struct V2DeskStatusMark: View {
    let marker: V2DeskMarker
    var diameter: CGFloat = 7

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch marker.kind {
        case .hidden:
            Color.clear.frame(width: diameter, height: diameter)
        case .solidDot:
            Circle()
                .fill(toneColor)
                .frame(width: diameter, height: diameter)
        case .hollowRing:
            Circle()
                .stroke(toneColor, lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
        case .striped:
            V2DeskStripeFill()
                .frame(width: diameter, height: diameter)
                .clipShape(RoundedRectangle(cornerRadius: 1))
        }
    }

    private var toneColor: Color {
        switch marker.tone {
        case .neutral: V2DeskPalette.color(.tertiaryInk, scheme: colorScheme)
        case .accent: V2DeskPalette.color(.accent, scheme: colorScheme)
        case .success: V2DeskPalette.color(.success, scheme: colorScheme)
        case .warning: V2DeskPalette.color(.warning, scheme: colorScheme)
        case .danger: V2DeskPalette.color(.danger, scheme: colorScheme)
        case .stale: V2DeskPalette.color(.disabledInk, scheme: colorScheme)
        }
    }
}

struct V2DeskStripeFill: View {
    var lineWidth: CGFloat = 2
    var spacing: CGFloat = 4

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(V2DeskPalette.color(.staleStripeBase, scheme: colorScheme))
            )
            var x = -size.height
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(
                    path,
                    with: .color(V2DeskPalette.color(.staleStripeLine, scheme: colorScheme)),
                    lineWidth: lineWidth
                )
                x += spacing
            }
        }
    }
}

// MARK: - Reliability states

/// The v2.1 reliability contract is deliberately expressed in words as well
/// as color.  These small views are shared by both platforms so an offline
/// cache, a pending save, and a write conflict never acquire competing visual
/// meanings in the iOS and macOS surfaces.
struct V2DeskSyncPill: View {
    enum State: Equatable {
        case refreshing
        case offline
        case pending(Int)
        case conflict(Int)
        case persistenceFailed
        case synced

        var title: String {
            switch self {
            case .refreshing: "正在刷新"
            case .offline: "离线浏览"
            case .pending(let count): count == 1 ? "1 项未同步" : "\(count) 项未同步"
            case .conflict(let count): count == 1 ? "1 项待处理冲突" : "\(count) 项待处理冲突"
            case .persistenceFailed: "本机保存需要处理"
            case .synced: "已同步"
            }
        }

        var tone: V2DeskTone {
            switch self {
            case .refreshing: .accent
            case .offline: .warning
            case .pending: .warning
            case .conflict: .danger
            case .persistenceFailed: .danger
            case .synced: .success
            }
        }

        var symbol: String {
            switch self {
            case .refreshing: "arrow.triangle.2.circlepath"
            case .offline: "wifi.slash"
            case .pending: "arrow.up.circle"
            case .conflict: "exclamationmark.triangle"
            case .persistenceFailed: "externaldrive.badge.exclamationmark"
            case .synced: "checkmark.circle"
            }
        }
    }

    let state: State
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(V2DeskType.control(compact ? 10.5 : 11.5, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 4 : 5)
            .background(color.opacity(0.10), in: Capsule())
            .overlay { Capsule().stroke(color.opacity(0.26), lineWidth: 1) }
            .accessibilityLabel(state.title)
    }

    private var color: Color {
        switch state.tone {
        case .neutral: V2DeskPalette.color(.secondaryInk, scheme: colorScheme)
        case .accent: V2DeskPalette.color(.accent, scheme: colorScheme)
        case .success: V2DeskPalette.color(.success, scheme: colorScheme)
        case .warning: V2DeskPalette.color(.warning, scheme: colorScheme)
        case .danger: V2DeskPalette.color(.danger, scheme: colorScheme)
        case .stale: V2DeskPalette.color(.disabledInk, scheme: colorScheme)
        }
    }
}

struct V2DeskOfflineExplanation: View {
    var body: some View {
        Label("正在显示上次成功同步的内容。生成、检查、归档、搜索和导入需要重新联网。", systemImage: "wifi.slash")
            .font(V2DeskType.control(11.5))
            .foregroundStyle(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("离线浏览。生成、检查、归档、搜索和导入需要重新联网。")
    }
}

/// Conflict decisions change the durable source of truth, but the currently
/// presented store may still hold the pre-decision object.  Both platforms
/// call this after a decision or a completed re-submit so the author never
/// keeps reading an obsolete local snapshot.
@MainActor
enum V2DeskConflictRefresh {
    static func run(
        _ applied: [AppliedSyncMutation],
        session: AppSession,
        bookshelf: BookshelfStore,
        workspace: WorkspaceStore,
        editor: ChapterEditorStore,
        characters: CharactersStore,
        agents: AgentSettingsStore
    ) async {
        guard !applied.isEmpty else { return }
        let bookIDs = Set(applied.filter { $0.resourceKind == .book }.map(\.resourceID))
        let chapterIDs = Set(applied.filter { $0.resourceKind == .chapter }.map(\.resourceID))
        let refreshesCharacters = applied.contains {
            $0.resourceKind == .character || $0.resourceKind == .characterEvent
        }
        let refreshesAgents = applied.contains {
            $0.resourceKind == .agentPersona || $0.resourceKind == .modelBinding || $0.resourceKind == .llmProfile
        }

        if !bookIDs.isEmpty {
            let currentID = session.currentBook?.id
            await bookshelf.load()
            if let currentID, bookIDs.contains(currentID),
               let refreshed = bookshelf.books.first(where: { $0.id == currentID }) {
                session.currentBook = refreshed
            }
        }
        if let bookID = session.currentBook?.id, !chapterIDs.isEmpty {
            await workspace.refreshChapters(bookId: bookID)
            if let currentID = editor.currentChapter?.id,
               chapterIDs.contains(currentID),
               let summary = workspace.chapters.first(where: { $0.id == currentID }) {
                await editor.load(summary)
            }
        }
        if refreshesCharacters, let bookID = session.currentBook?.id {
            await characters.load(bookId: bookID)
        }
        if refreshesAgents {
            await agents.load()
            if let bookID = session.currentBook?.id {
                _ = await agents.loadBookPersonas(bookID: bookID)
                _ = await agents.loadBookModelBindings(bookID: bookID)
            }
        }
    }

    static func run(
        _ conflict: ContentConflict,
        session: AppSession,
        bookshelf: BookshelfStore,
        workspace: WorkspaceStore,
        editor: ChapterEditorStore,
        characters: CharactersStore,
        agents: AgentSettingsStore
    ) async {
        switch conflict.resourceKind {
        case .book:
            let wasCurrentBook = session.currentBook?.id == conflict.resourceID
            await bookshelf.load()
            if wasCurrentBook,
               let refreshedBook = bookshelf.books.first(where: { $0.id == conflict.resourceID }) {
                session.currentBook = refreshedBook
                await workspace.refreshChapters(bookId: refreshedBook.id)
            }
        case .chapter:
            guard let bookID = session.currentBook?.id else { return }
            await workspace.refreshChapters(bookId: bookID)
            if editor.currentChapter?.id == conflict.resourceID,
               let summary = workspace.chapters.first(where: { $0.id == conflict.resourceID }) {
                await editor.load(summary)
            }
        case .character, .characterEvent:
            if let bookID = session.currentBook?.id { await characters.load(bookId: bookID) }
        case .agentPersona, .modelBinding, .llmProfile:
            await agents.load()
            if let bookID = session.currentBook?.id {
                _ = await agents.loadBookPersonas(bookID: bookID)
                _ = await agents.loadBookModelBindings(bookID: bookID)
            }
        }
    }
}

/// A deliberately explicit decision card.  The caller owns all mutation and
/// navigation; this component only guarantees that a local overwrite can
/// never look like a harmless automatic refresh.
struct V2DeskConflictDecisionCard: View {
    let title: String
    let detail: String
    let useServer: () -> Void
    let keepLocal: () -> Void
    var requiresSecretReentry = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(V2DeskPalette.color(.danger, scheme: colorScheme))
                Text(title).font(V2DeskType.control(13, weight: .medium))
                Spacer()
                Text("需要决定")
                    .font(V2DeskType.control(10.5, weight: .medium))
                    .foregroundStyle(V2DeskPalette.color(.danger, scheme: colorScheme))
            }
            Text(detail)
                .font(V2DeskType.control(11.5))
                .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if requiresSecretReentry {
                Text("本机修改涉及访问密钥，密钥不会写入待同步内容。请采用服务器版本，或返回模型 Profile 重新输入密钥后保存。")
                    .font(V2DeskType.control(11.5))
                    .foregroundStyle(V2DeskPalette.color(.secondaryInk, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Button("采用服务器版本", action: useServer)
                    .buttonStyle(.bordered)
            } else {
                HStack(spacing: 8) {
                    Button("采用服务器版本", action: useServer)
                        .buttonStyle(.bordered)
                    Button("比较后保留本机", action: keepLocal)
                        .buttonStyle(.borderedProminent)
                        .tint(V2DeskPalette.color(.ink, scheme: colorScheme))
                }
                .font(V2DeskType.control(11.5, weight: .medium))
            }
        }
        .padding(12)
        .background(V2DeskPalette.color(.taskFailure, scheme: colorScheme), in: RoundedRectangle(cornerRadius: V2DeskMetric.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: V2DeskMetric.cardCornerRadius, style: .continuous)
                .stroke(V2DeskPalette.color(.danger, scheme: colorScheme).opacity(0.34), lineWidth: 1)
        }
    }
}

/// Both platforms receive an already bounded export aggregate from the
/// Backend.  This mapper is deliberately presentation-only: it never fetches
/// chapters itself and therefore cannot regress into an N+1 export path.
enum V2DeskExportComposer {
    static func chapters(for scope: ExportScope, in data: BookExportData, currentID: String?) -> [BookExportChapter] {
        switch scope {
        case .accepted: data.chapters.filter { $0.status == "finalized" }
        case .all: data.chapters
        case .current: data.chapters.filter { $0.id == currentID }
        }
    }

    static func compose(
        data: BookExportData,
        chapters: [BookExportChapter],
        format: ExportFormat,
        includeWorld: Bool,
        includeCharacters: Bool,
        separateChapters: Bool
    ) -> [ExportFile] {
        let sorted = chapters.sorted { $0.index < $1.index }
        let base = filename(data.title)
        if separateChapters {
            var files: [ExportFile] = []
            if let companion = companion(data: data, format: format, includeWorld: includeWorld, includeCharacters: includeCharacters) {
                files.append(ExportFile(filename: "\(base)-设定.\(format.fileExtension)", text: companion))
            }
            files.append(contentsOf: sorted.map { chapter in
                ExportFile(filename: "\(base)-第\(chapter.index)章.\(format.fileExtension)", text: chapterText(chapter, format: format))
            })
            return files
        }
        var parts: [String] = [format == .markdown ? "# \(title(data))" : title(data)]
        if includeWorld, !data.worldSetting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(format == .markdown ? "## 世界观\n\n\(data.worldSetting)" : "世界观\n\(data.worldSetting)")
        }
        if includeCharacters, !data.characters.isEmpty {
            parts.append(characterText(data.characters, format: format))
        }
        parts.append(contentsOf: sorted.map { chapterText($0, format: format) })
        return [ExportFile(filename: "\(base).\(format.fileExtension)", text: parts.joined(separator: "\n\n"))]
    }

    private static func companion(data: BookExportData, format: ExportFormat, includeWorld: Bool, includeCharacters: Bool) -> String? {
        var parts: [String] = []
        if includeWorld, !data.worldSetting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(format == .markdown ? "## 世界观\n\n\(data.worldSetting)" : "世界观\n\(data.worldSetting)")
        }
        if includeCharacters, !data.characters.isEmpty { parts.append(characterText(data.characters, format: format)) }
        guard !parts.isEmpty else { return nil }
        return (format == .markdown ? "# \(title(data))" : title(data)) + "\n\n" + parts.joined(separator: "\n\n")
    }

    private static func chapterText(_ chapter: BookExportChapter, format: ExportFormat) -> String {
        let heading = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "第 \(chapter.index) 章"
            : "第 \(chapter.index) 章 \(chapter.title)"
        return format == .markdown ? "## \(heading)\n\n\(chapter.draftText)" : "\(heading)\n\n\(chapter.draftText)"
    }

    private static func characterText(_ characters: [BookExportCharacter], format: ExportFormat) -> String {
        let rows = characters.sorted { $0.name < $1.name }.map { character in
            format == .markdown
                ? "- **\(character.name)**（身份：\(character.role.isEmpty ? "未填写" : character.role)）\n  \(character.fixedProfile)"
                : "\(character.name)（身份：\(character.role.isEmpty ? "未填写" : character.role)）\n\(character.fixedProfile)"
        }
        return (format == .markdown ? "## 人物设定\n\n" : "人物设定\n") + rows.joined(separator: "\n\n")
    }

    private static func title(_ data: BookExportData) -> String {
        data.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名书籍" : data.title
    }

    private static func filename(_ title: String) -> String {
        (title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ICTW书稿" : title)
            .replacingOccurrences(of: "/", with: "-")
    }
}
