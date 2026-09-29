import Foundation

// Actual export handlers are inserted by the runner. Only their transport,
// storage boundary and native panels are replaced with isolated fixtures.
@MainActor final class ExportNotices {
    var messages: [String] = []
    func publish(_ message: String) { messages.append(message) }
    func publish(_ error: Error) { messages.append(error.localizedDescription) }
}
@MainActor final class AppSession {
    var currentBook: Book? = try! JSONDecoder().decode(Book.self, from: Data(#"{"id":"book-a","title":"Synthetic","updated_at":"2026-09-29"}"#.utf8))
    let notices = ExportNotices()
}
@MainActor final class ChapterEditorStore {
    var results: [Bool]
    var calls = 0
    init(_ results: [Bool]) { self.results = results }
    func persistLocalDraftIfNeeded() -> Bool { calls += 1; return results.isEmpty ? true : results.removeFirst() }
}
enum ExportSelection { case project, prose(scope: ExportScope, currentChapterID: String?, includeWorldview: Bool, includeCharacters: Bool) }
struct ExportReceipt {}
struct ExportData { var chapters = [1] }
@MainActor final class BookshelfStore {
    var requests = 0, validations = 0
    func prepareExport(bookID: String, selection: ExportSelection) throws -> ExportReceipt { ExportReceipt() }
    func validateExport(_ receipt: ExportReceipt) throws { validations += 1 }
    func exportProject(_ book: Book) async -> Data? { requests += 1; return Data("synthetic package".utf8) }
    func exportData(_ book: Book, selection: ExportSelection) async -> ExportData? { requests += 1; return ExportData() }
}
enum V2DeskExportComposer {
    static func chapters(for scope: ExportScope, in data: ExportData, currentID: String?) -> [Int] { data.chapters }
    static func compose(data: ExportData, chapters: [Int], format: ExportFormat, includeWorld: Bool, includeCharacters: Bool, separateChapters: Bool) -> [ExportFile] {
        [ExportFile(filename: "synthetic.txt", text: "synthetic prose")]
    }
}
struct UTType: Sendable {
    init?(filenameExtension: String) {}
    private init() {}
    static let plainText = UTType()
    static let ictwProjectPackage = UTType()
}
@MainActor class NSSavePanel {
    enum Response { case OK, cancel }
    static var target: URL!
    static var response = Response.OK
    static var presentations = 0
    var nameFieldStringValue = "", title = "", prompt = ""
    var canCreateDirectories = false, isExtensionHidden = false
    var allowedContentTypes: [UTType] = []
    var url: URL? { Self.target }
    func runModal() -> Response { Self.presentations += 1; return Self.response }
}
@MainActor final class NSOpenPanel: NSSavePanel {
    var canChooseDirectories = false, canChooseFiles = false, allowsMultipleSelection = false
    override var url: URL? { Self.target.deletingLastPathComponent() }
}
@MainActor var currentOutputRoot: URL!
@MainActor func fixtureOutputRoot() -> URL { currentOutputRoot }
@MainActor enum V2IOSExportFiles {
    // BUILD70:IOS_WRITE
}
@MainActor enum MacExportSaver {
    // BUILD70:MAC_PACKAGE
    // BUILD70:MAC_PROSE
    // BUILD70:MAC_SAVE_FILES
    private static func safeFilename(_ value: String) -> String { value }
}
@MainActor final class IOSProjectExport {
    let session = AppSession(), bookshelf = BookshelfStore()
    let editor: ChapterEditorStore
    var notices: ExportNotices { session.notices }
    var preparingExport = false, importing = false, showingShare = false
    var sharingURL: URL?
    init(_ results: [Bool]) { editor = ChapterEditorStore(results) }
    private func sanitizedFilename(_ value: String) -> String { value }
    // BUILD70:IOS_PACKAGE
}
@MainActor final class IOSProseExport {
    let session = AppSession(), bookshelf = BookshelfStore()
    let editor: ChapterEditorStore
    var notices: ExportNotices { session.notices }
    var scope = ExportScope.all, format = ExportFormat.plainText
    var includeWorld = true, includeCharacters = true, separate = false, isExporting = false, sharing = false
    var completedChapters = 0, totalChapters = 0
    var currentChapterID: String?
    var urls: [URL] = []
    var exportSessionID: UUID?
    var exportTask: Task<Void, Never>?
    init(_ results: [Bool]) { editor = ChapterEditorStore(results) }
    // BUILD70:IOS_PROSE
    // BUILD70:IOS_CANCEL
    // BUILD70:IOS_CURRENT
    // BUILD70:IOS_FINISH
}

@main struct Build70ExportLifecycleTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ICTW_EXPORT_FIXTURE_ROOT"]!)
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            checks += 1; guard condition else { throw Failure(message: message) }
        }
        func resetOutput() throws {
            currentOutputRoot = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: currentOutputRoot, withIntermediateDirectories: true)
            NSSavePanel.target = currentOutputRoot.appendingPathComponent("result.txt")
            NSSavePanel.response = .OK; NSSavePanel.presentations = 0
        }
        func expectsRecovery(_ notices: ExportNotices) throws {
            let text = notices.messages.last ?? ""
            try expect(text.contains("本机草稿未能保存") && text.contains("未导出") && text.contains("复制") && text.contains("存储") && text.contains("重试"), "Every persistence failure must give its reason and a usable recovery action")
        }
        for stage in 1...3 {
            let results = Array(repeating: true, count: stage - 1) + [false]
            try resetOutput()
            let package = IOSProjectExport(results)
            await package.exportCurrentBook()
            try expectsRecovery(package.notices)
            try expect(!package.showingShare && !package.preparingExport, "iOS package failure must not share or stay busy")
            try expect(package.bookshelf.requests == (stage == 1 ? 0 : 1), "A failed initial preserve must stop before the export API")
            try resetOutput()
            let prose = IOSProseExport(results)
            prose.startExport(); await prose.exportTask?.value
            try expectsRecovery(prose.notices)
            try expect(!prose.sharing && !prose.isExporting, "iOS prose failure must not share or stay busy")
            try resetOutput()
            let session = AppSession(), shelf = BookshelfStore(), editor = ChapterEditorStore(results)
            let success = await MacExportSaver.exportProject(session.currentBook!, session: session, bookshelf: shelf, editor: editor)
            try expectsRecovery(session.notices)
            try expect(!success && !FileManager.default.fileExists(atPath: NSSavePanel.target.path), "Mac package failure must stop before destination write")
            try expect(NSSavePanel.presentations == (stage == 3 ? 1 : 0), "Native save panel must only open after the network snapshot is valid")
            try resetOutput()
            let proseSession = AppSession(), proseShelf = BookshelfStore(), proseEditor = ChapterEditorStore(results)
            let proseSuccess = await MacExportSaver.exportComposed(book: proseSession.currentBook!, session: proseSession, bookshelf: proseShelf, editor: proseEditor, scope: .all, currentChapterID: nil, format: .plainText, includeWorld: true, includeCharacters: true, separateChapters: false)
            try expectsRecovery(proseSession.notices)
            try expect(!proseSuccess && !FileManager.default.fileExists(atPath: NSSavePanel.target.path), "Mac prose beforeWrite persistence error must be visible and must not write")
        }
        try resetOutput()
        let package = IOSProjectExport([true, true, true])
        await package.exportCurrentBook()
        try expect(package.showingShare && package.sharingURL != nil && package.notices.messages.isEmpty, "Normal iOS package export must still reach sharing")
        try resetOutput()
        let prose = IOSProseExport([true, true, true]); prose.startExport(); await prose.exportTask?.value
        try expect(prose.sharing && prose.urls.count == 1 && prose.notices.messages.isEmpty, "Normal iOS prose export must still reach sharing")
        for isProject in [true, false] {
            try resetOutput()
            let session = AppSession(), shelf = BookshelfStore(), editor = ChapterEditorStore([true, true, true])
            let success: Bool
            if isProject { success = await MacExportSaver.exportProject(session.currentBook!, session: session, bookshelf: shelf, editor: editor) }
            else { success = await MacExportSaver.exportComposed(book: session.currentBook!, session: session, bookshelf: shelf, editor: editor, scope: .all, currentChapterID: nil, format: .plainText, includeWorld: true, includeCharacters: true, separateChapters: false) }
            try expect(success && FileManager.default.fileExists(atPath: NSSavePanel.target.path), "Normal Mac export must still write its destination")
        }
        try resetOutput(); NSSavePanel.response = .cancel
        let cancelledSession = AppSession()
        let cancelled = await MacExportSaver.exportComposed(book: cancelledSession.currentBook!, session: cancelledSession, bookshelf: BookshelfStore(), editor: ChapterEditorStore([true, true]), scope: .all, currentChapterID: nil, format: .plainText, includeWorld: true, includeCharacters: true, separateChapters: false)
        try expect(!cancelled && cancelledSession.notices.messages.isEmpty, "Explicit panel cancellation must remain a quiet no-op")
        print("Build70 actual export persistence lifecycle: \(checks) checks passed")
    }
    struct Failure: Error { let message: String }
}
