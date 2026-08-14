import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// macOS 全书导出：走 `NSSavePanel` 存 `.txt`（替代 iOS 的 `ActivityView`
/// 系统分享面板）。正文数据取 `GET /books/{id}/export.txt`（`session.api
/// .rawRequest`，与 iOS `LinoIBookSettingsPane.exportBook` 同一后端路径）。
/// 沙盒下 `com.apple.security.files.user-selected.read-write` entitlement 使
/// 用户在存盘面板选定的位置可写。取消存盘（点 Cancel / 关面板）视为 no-op，
/// 不当错误处理。
enum MacExportSaver {
    @MainActor
    static func exportComposed(
        book: Book, session: AppSession, chapterSummaries: [ChapterSummary], characters: [Character],
        scope: ExportScope, currentChapterID: String?, format: ExportFormat,
        includeWorld: Bool, includeCharacters: Bool, separateChapters: Bool
    ) async {
        guard scope != .current || currentChapterID != nil else {
            session.notices.publish("请先选择一章，再选择“本章”导出。")
            return
        }
        do {
            let details: [Chapter] = try await withThrowingTaskGroup(of: Chapter.self) { group in
                for summary in chapterSummaries { group.addTask { try await session.api.request("/chapters/\(summary.id)") } }
                var result: [Chapter] = []
                for try await chapter in group { result.append(chapter) }
                return result
            }
            let selected = ExportComposer.chapters(for: scope, chapters: details, currentID: currentChapterID)
            guard !selected.isEmpty else { session.notices.publish("所选范围没有可导出的正文。"); return }
            let files = ExportComposer.compose(book: book, chapters: selected, characters: characters, format: format, includeWorld: includeWorld, includeCharacters: includeCharacters, separateChapters: separateChapters)
            save(files: files, session: session, panelTitle: "导出正文")
        } catch { session.notices.publish(error) }
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
}
