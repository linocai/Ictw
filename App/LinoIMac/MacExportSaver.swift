import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// macOS 全书导出：走 `NSSavePanel` 存 `.txt`（替代 iOS 的 `ActivityView`
/// 系统分享面板）。富正文导出只取 Backend 的单次聚合资料，不能逐章请求。
/// 沙盒下 `com.apple.security.files.user-selected.read-write` entitlement 使
/// 用户在存盘面板选定的位置可写。取消存盘（点 Cancel / 关面板）视为 no-op，
/// 不当错误处理。
enum MacExportSaver {
    /// Project packages are a separate, round-trippable backup channel.  They
    /// intentionally use a native save/open panel rather than the ordinary
    /// manuscript exporter, because an import always creates a new book.
    @MainActor
    static func exportProject(_ book: Book, session: AppSession, bookshelf: BookshelfStore) async {
        if let data = await bookshelf.exportProject(book) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(safeFilename(book.title)).ictwbook"
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.allowedContentTypes = [.ictwProjectPackage]
            panel.title = "备份完整项目"
            panel.prompt = "备份"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                session.notices.publish("项目备份已写入文件。")
            } catch {
                session.notices.publish("写入文件失败：\(error.localizedDescription)")
            }
        }
    }

    @MainActor
    static func importProject(session: AppSession, bookshelf: BookshelfStore) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.ictwProjectPackage]
        panel.title = "恢复完整项目"
        panel.prompt = "恢复为新书"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fileData = try Data(contentsOf: url)
            guard let imported = await bookshelf.importProject(fileData) else { return }
            let warning = imported.warnings.isEmpty ? "" : "\n\(imported.warnings.map(\.message).joined(separator: "\n"))"
            session.notices.publish("已恢复《\(imported.title)》为新书。\(warning)")
        } catch {
            session.notices.publish(error)
        }
    }

    @MainActor
    static func exportComposed(
        book: Book, session: AppSession, bookshelf: BookshelfStore,
        scope: ExportScope, currentChapterID: String?, format: ExportFormat,
        includeWorld: Bool, includeCharacters: Bool, separateChapters: Bool
    ) async {
        guard scope != .current || currentChapterID != nil else {
            session.notices.publish("请先选择一章，再选择“本章”导出。")
            return
        }
        guard let data = await bookshelf.exportData(book) else { return }
        let selected = V2DeskExportComposer.chapters(for: scope, in: data, currentID: currentChapterID)
        guard !selected.isEmpty else { session.notices.publish("所选范围没有可导出的正文。"); return }
        let files = V2DeskExportComposer.compose(data: data, chapters: selected, format: format, includeWorld: includeWorld, includeCharacters: includeCharacters, separateChapters: separateChapters)
        save(files: files, session: session, panelTitle: "导出正文")
    }
    /// 拉取全书导出文本并弹出存盘面板。失败经 `NoticeBus` 弹 Toast。
    @MainActor
    static func exportBook(_ book: Book, session: AppSession) async {
        await export(book, session: session, path: "export.txt", suffix: "", panelTitle: "导出全书")
    }

    /// 导出 Extractor 记忆（大事记/摘要/人物动态字段与故事线），同一存盘通道。
    @MainActor
    static func exportMemories(_ book: Book, session: AppSession) async {
        await export(book, session: session, path: "memories/export.txt", suffix: "·记忆", panelTitle: "导出记忆")
    }

    @MainActor
    private static func export(_ book: Book, session: AppSession, path: String, suffix: String, panelTitle: String) async {
        do {
            let data = try await session.api.rawRequest("/books/\(book.id)/\(path)")
            let suggested = "\(book.title.isEmpty ? "LinoI书稿" : book.title)\(suffix).txt"
            save(data: data, suggestedName: suggested, session: session, panelTitle: panelTitle)
        } catch {
            session.notices.publish(error)
        }
    }

    @MainActor
    private static func save(data: Data, suggestedName: String, session: AppSession, panelTitle: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.plainText]
        panel.title = panelTitle
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            session.notices.publish("写入文件失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func save(files: [ExportFile], session: AppSession, panelTitle: String) {
        guard !files.isEmpty else { return }
        if files.count > 1 {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = "选择导出文件夹"
            panel.prompt = "导出到此处"
            guard panel.runModal() == .OK, let directory = panel.url else { return }
            do {
                // Do not silently overwrite a sibling file after a directory
                // choice; the author can choose another folder or rename it.
                if files.contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }) {
                    throw CocoaError(.fileWriteFileExists)
                }
                for file in files {
                    guard let data = file.text.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
                    try data.write(to: directory.appendingPathComponent(file.filename), options: .atomic)
                }
            } catch { session.notices.publish("写入文件失败：\(error.localizedDescription)") }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = files[0].filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = files.first?.filename.hasSuffix(".md") == true
            ? [UTType(filenameExtension: "md") ?? .plainText]
            : [.plainText]
        panel.title = panelTitle
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let firstURL = panel.url else { return }
        do {
            guard let data = files[0].text.data(using: .utf8) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
            try data.write(to: firstURL, options: .atomic)
        } catch { session.notices.publish("写入文件失败：\(error.localizedDescription)") }
    }

    private static func safeFilename(_ value: String) -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? "ICTW-项目备份" : title).replacingOccurrences(of: "/", with: "-")
    }
}

private extension UTType {
    static let ictwProjectPackage = UTType(filenameExtension: "ictwbook") ?? .zip
}
