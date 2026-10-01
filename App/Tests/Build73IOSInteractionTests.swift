import Foundation
import Combine

extension String { var v2IOSTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
@MainActor final class ClientSyncStore { var networkActionsAvailable = true }
@MainActor final class AppSession {
    struct Book { var id = "book-a" }
    var currentBook: Book? = Book()
    var bookContextID = UUID()
}
@MainActor final class WorkspaceStore {
    struct Route { var id: String }
    var chapterPath = [Route(id: "chapter-a")]
    var chapterNavigationID = UUID()
    var refreshed: [String] = []
    func upsert(_ chapter: Chapter) {}
    func refreshChapters(bookId: String) async { refreshed.append(bookId) }
}
@MainActor final class ChapterEditorStore {
    let sync = ClientSyncStore()
    var currentChapter: Chapter? = try! makeChapter()
    var editingSessionID = UUID()
    var writingPhase: ChapterWritingPhase = .idle
    var isSaving = false
    var checkerRefreshing = false
    var previewRequests = 0
    var rewriteRequests = 0
    var reopenRequests = 0
    var saveRequests = 0
    private var preview: CheckedContinuation<RewriteImpactPreview?, Never>?
    private var operation: CheckedContinuation<Void, Never>?
    func loadRewriteImpact() async -> RewriteImpactPreview? {
        previewRequests += 1
        return await withCheckedContinuation { preview = $0 }
    }
    func finishPreview() { let held = preview; preview = nil; held?.resume(returning: nil) }
    func rewrite(continuationIsCurrent: @MainActor () -> Bool = { true }) async -> ChapterRewriteOutcome {
        rewriteRequests += 1
        await withCheckedContinuation { operation = $0 }
        return .succeeded(currentChapter!)
    }
    func reopen() async -> Chapter? { reopenRequests += 1; return currentChapter }
    func save() async {
        saveRequests += 1; isSaving = true
        await withCheckedContinuation { operation = $0 }
        isSaving = false
    }
    func finishOperation() { let held = operation; operation = nil; held?.resume() }
}

// The runner inserts the shipping coordinator verbatim. Stub transports hold
// its actual async callbacks while navigation and editor ownership change.
// BUILD73:COORDINATOR

func makeChapter() throws -> Chapter {
    let object: [String: Any] = ["id": "chapter-a", "book_id": "book-a", "index": 1, "title": "Title",
        "user_prompt": "Intent", "draft_text": "Author draft", "summary": "", "source": "manual",
        "updated_at": "2026-10-01T00:00:00Z", "status": "draft_ready", "character_links": []]
    return try JSONDecoder().decode(Chapter.self, from: JSONSerialization.data(withJSONObject: object))
}
@main struct Build73IOSInteractionTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ result: @autoclosure () -> Bool, _ reason: String) throws {
            checks += 1
            if !result() { throw Failure(reason: reason) }
        }
        func settle() async { for _ in 0..<25 { await Task.yield() } }
        let session = AppSession(), workspace = WorkspaceStore(), editor = ChapterEditorStore()
        let actions = V2IOSChapterActionCoordinator()
        func start(_ reopen: Bool = false) {
            actions.startPreview(reopen: reopen, chapterID: "chapter-a", bookID: "book-a",
                editor: editor, session: session, workspace: workspace)
        }
        start(); start(true); start()
        try expect(actions.preparing && actions.busy, "All rewrite entries must share one synchronous preview gate")
        await settle()
        try expect(editor.previewRequests == 1, "Menu/dock double taps must send one preview")
        actions.run(editor: editor) { await editor.save() }
        await settle()
        try expect(editor.saveRequests == 0, "A preview must block a competing explicit save")
        editor.finishPreview(); await settle()
        try expect(actions.showingRewrite && actions.busy, "Failed preview still needs the conservative shared confirmation")
        start(true); await settle()
        try expect(editor.previewRequests == 1, "Confirmation must retain the gate against reopen")
        actions.confirm(reopen: false, editor: editor, session: session, workspace: workspace)
        actions.confirm(reopen: false, editor: editor, session: session, workspace: workspace)
        await settle()
        try expect(editor.rewriteRequests == 1 && actions.running, "Repeated confirmation must neither duplicate rewrite nor release its gate")
        editor.finishOperation(); await settle()
        try expect(!actions.busy && workspace.refreshed == ["book-a"], "Completed rewrite must release the gate and refresh its book")
        for mutation in 0..<5 {
            let a = V2IOSChapterActionCoordinator(), e = ChapterEditorStore(), s = AppSession(), w = WorkspaceStore()
            a.startPreview(chapterID: "chapter-a", bookID: "book-a", editor: e, session: s, workspace: w)
            await settle()
            switch mutation {
            case 0: s.bookContextID = UUID()
            case 1: w.chapterPath = [.init(id: "chapter-b")]
            case 2: w.chapterNavigationID = UUID() // same-ID reentry
            case 3: e.editingSessionID = UUID()
            default: e.currentChapter?.status = "finalized"
            }
            e.finishPreview(); await settle()
            try expect(!a.busy && !a.showingRewrite, "Stale visit or acceptance must discard the late preview")
            a.confirm(reopen: false, editor: e, session: s, workspace: w); await settle()
            try expect(e.rewriteRequests == 0, "An invalidated receipt must never rewrite")
        }
        let undispatched = V2IOSChapterActionCoordinator(), undispatchedEditor = ChapterEditorStore()
        undispatched.startPreview(chapterID: "chapter-a", bookID: "book-a", editor: undispatchedEditor, session: session, workspace: workspace)
        workspace.chapterNavigationID = UUID(); await settle()
        try expect(undispatchedEditor.previewRequests == 0 && !undispatched.busy,
            "Navigation before the preview Task starts must not send an old preview")
        start(); await settle(); editor.finishPreview(); await settle()
        actions.invalidate()
        actions.confirm(reopen: false, editor: editor, session: session, workspace: workspace); await settle()
        try expect(editor.rewriteRequests == 1, "Cancelling the confirmation must revoke its receipt")
        start(); await settle(); editor.finishPreview(); await settle()
        workspace.chapterNavigationID = UUID()
        actions.confirm(reopen: false, editor: editor, session: session, workspace: workspace); await settle()
        try expect(editor.rewriteRequests == 1 && !actions.busy, "Confirmation must revalidate same-ID navigation ownership")
        let beforeSave = editor.saveRequests
        actions.run(editor: editor) { await editor.save() }
        actions.run(editor: editor) { await editor.save() }
        await settle()
        try expect(editor.saveRequests == beforeSave + 1 && actions.running, "Explicit save double taps must issue one actual callback")
        start(); await settle()
        try expect(!actions.preparing, "An active save cannot open a rewrite preview")
        editor.finishOperation(); await settle()
        actions.run(editor: editor) { await editor.save() }
        editor.editingSessionID = UUID(); await settle()
        try expect(editor.saveRequests == beforeSave + 1 && !actions.busy, "Navigation before dispatch must cancel the queued old action")

        let phases: [ChapterWritingPhase] = [.idle, .accepting, .writing, .failed(code: nil, message: "unknown", stage: nil),
            .failed(code: "checker_unavailable", message: "failed", stage: .bibleChecking)]
        for (index, phase) in phases.enumerated() {
            try expect(V2IOSChapterInteractionPolicy.blocksChapterMutation(phase: phase, saving: false, checking: false) == [false,true,true,true,false][index],
                "Only confirmed idle/failure states may save or rewrite")
        }
        try expect(V2IOSChapterInteractionPolicy.blocksChapterMutation(phase: .idle, saving: true, checking: false), "Saving must block model/accept actions")
        try expect(V2IOSChapterInteractionPolicy.blocksChapterMutation(phase: .idle, saving: false, checking: true), "Checking must block competing save/rewrite")
        for primary in [V2DeskPrimaryAction.generate, .retryGeneration, .rerunChecker, .retryGeneratedCandidateChecker, .accept] {
            try expect(V2IOSChapterInteractionPolicy.mergesPrimaryIntoRewrite(primary, hasDraft: true) == (primary == .generate || primary == .retryGeneration),
                "Only generation with visible prose may merge into rewrite")
            try expect(!V2IOSChapterInteractionPolicy.mergesPrimaryIntoRewrite(primary, hasDraft: false), "An empty chapter must keep its original primary action")
        }
        for state in [ChapterSaveState.unsaved, .localDraft, .restoredLocalDraft, .remoteSaveFailed(message: "failed", localDraftPreserved: false)] {
            try expect(V2IOSChapterInteractionPolicy.saveTitle(state: state, online: true) == "保存", "Unsynced inputs need explicit online saving")
            try expect(V2IOSChapterInteractionPolicy.saveTitle(state: state, online: false) == "保存到本机", "Offline saving must be clearly local")
        }
        for state in [ChapterSaveState.synced, .savingLocally, .savingRemotely] {
            try expect(V2IOSChapterInteractionPolicy.saveTitle(state: state, online: true) == nil, "Synced/saving states cannot invite duplicate saving")
        }
        func snapshot(_ phase: ChapterWritingPhase, interrupted: Bool = false, target: String? = nil, retry: Bool = false) -> V2DeskSnapshot {
            V2DeskPresentation.make(V2DeskEditorSource(chapter: editor.currentChapter, writingPhase: phase,
                checkerResult: nil, checkerAppliesToVisibleDraft: false, checkerRefreshing: false,
                staleCheckedSnapshot: nil, saveState: .synced, connectionInterrupted: interrupted,
                canRetryGeneratedCandidateChecker: retry, checkerTarget: target, isLastChapterInBook: true))
        }
        let unknownAccept = snapshot(.accepting, interrupted: true)
        try expect(unknownAccept.primaryAction == .none && unknownAccept.taskBanner?.action == .refreshTaskStatus,
            "Unknown acceptance must retain read-only refresh, never reopen or duplicate accept")
        try expect(snapshot(.writing).primaryAction == .cancelGeneration, "Writing must retain cancellation")
        try expect(snapshot(.failed(code: "checker_unavailable", message: "failed", stage: .bibleChecking), target: "visible_draft").primaryAction == .rerunChecker,
            "Visible checker failure must keep rechecking current prose as primary")
        try expect(snapshot(.failed(code: "checker_unavailable", message: "failed", stage: .bibleChecking), target: ChapterCheckerTarget.generatedCandidate, retry: true).primaryAction == .retryGeneratedCandidateChecker,
            "Generated checker recovery must stay check-only")
        print("Build73 actual iOS coordinator and policies: \(checks) checks passed")
    }
    struct Failure: Error { let reason: String }
}
