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
    /// 拉取全书导出文本并弹出存盘面板。失败经 `NoticeBus` 弹 Toast。
    @MainActor
    static func exportBook(_ book: Book, session: AppSession) async {
        await export(book, session: session, path: "export.txt", suffix: "", panelTitle: "导出全书")
    }

    /// 导出 Extractor 记忆（大事记/梗概/人物动态字段与故事线），同一存盘通道。
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
}
