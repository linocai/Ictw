import Foundation

// The runner inserts the actual recovery handlers and root status policies.
// The shared-store filesystem/CAS implementation has its own HTTP regressions.
struct RetainedChapterDraft: Equatable {
    let id: String
    let draftText: String
    let copyText: String
}
enum TestFailure: Error, LocalizedError {
    case read, changed
    var errorDescription: String? {
        switch self {
        case .read: "本机保留稿无法读取，请重试。"
        case .changed: "这份保留稿内容已变化，请重新打开后确认；副本仍保留。"
        }
    }
}
@MainActor final class ClientSyncStore {
    var values: [RetainedChapterDraft] = []
    var failRead = false, failRemoval = false
    var removeCalls = 0
    var hasRetainedChapterDrafts: Bool { !values.isEmpty }
    var hasPersistentSyncFailure = false, isOnline = true, isFlushing = false
    var conflicts: [String] = []
    var failedMutationCount = 0, pendingCount = 0
    func retainedChapterDrafts() throws -> [RetainedChapterDraft] {
        if failRead { throw TestFailure.read }; return values
    }
    func removeRetainedChapterDraft(_ draft: RetainedChapterDraft) throws {
        removeCalls += 1
        if failRemoval { throw TestFailure.changed }
        guard values.contains(draft) else { throw TestFailure.changed }
        values.removeAll { $0.id == draft.id }
    }
}
@MainActor final class RecoveryNotices {
    enum Tone { case error }
    var messages: [String] = []
    func publish(_ message: String, critical: Bool = false, tone: Tone? = nil) { messages.append(message) }
    func publish(_ error: Error) { messages.append(error.localizedDescription) }
}
@MainActor final class ChapterEditorStore {
    let sync: ClientSyncStore
    init(sync: ClientSyncStore) { self.sync = sync }
    func removeRetainedChapterDraft(_ draft: RetainedChapterDraft) throws { try sync.removeRetainedChapterDraft(draft) }
}
@MainActor enum V2RetainedDraftClipboard {
    static var value: String?
    static var canWrite = true
    static func write(_ text: String) -> Bool {
        guard canWrite else { return false }; value = text; return true
    }
}
@MainActor final class RecoveryList {
    let sync: ClientSyncStore
    let notices = RecoveryNotices()
    var drafts: [RetainedChapterDraft] = []
    var selected: RetainedChapterDraft?
    var readFailure: String?
    init(sync: ClientSyncStore) { self.sync = sync }
    // BUILD70:RETAINED_RELOAD
}
@MainActor final class RecoveryDetail {
    let sync: ClientSyncStore
    let editor: ChapterEditorStore
    let draft: RetainedChapterDraft
    let notices = RecoveryNotices()
    var confirmingRemoval = false, removedCalls = 0, dismissed = 0
    init(sync: ClientSyncStore, draft: RetainedChapterDraft) { self.sync = sync; self.draft = draft; self.editor = ChapterEditorStore(sync: sync) }
    func removed() { removedCalls += 1 }
    func dismiss() { dismissed += 1 }
    // BUILD70:RETAINED_COPY
    // BUILD70:RETAINED_REQUEST
    // BUILD70:RETAINED_CANCEL
    // BUILD70:RETAINED_CONFIRM
    // BUILD70:RETAINED_REMOVE
}
enum V2DeskSyncPill {
    enum State: Equatable { case persistenceFailed, conflict(Int), failed(Int), offline, refreshing, pending(Int), synced }
}
@MainActor final class IOSStatus {
    let sync: ClientSyncStore
    init(sync: ClientSyncStore) { self.sync = sync }
    // BUILD70:RETAINED_IOS_STATUS
}
@MainActor final class MacStatus {
    let sync: ClientSyncStore
    init(sync: ClientSyncStore) { self.sync = sync }
    // BUILD70:RETAINED_MAC_STATUS
}

@main struct Build70RetainedDraftLifecycleTests {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            checks += 1; guard condition else { throw Assertion(message: message) }
        }
        let first = RetainedChapterDraft(id: "chapter-a", draftText: " 原文\n\n保留 ", copyText: "书：原书\n章：第6章\nBible\n意图原文\n作者备注\n备注原文\n正文\n 原文\n\n保留 ")
        let second = RetainedChapterDraft(id: "chapter-b", draftText: "other prose", copyText: "other full draft")
        let sync = ClientSyncStore(); sync.values = [first, second]
        try expect(IOSStatus(sync: sync).state == nil && MacStatus(sync: sync).state == nil && sync.hasRetainedChapterDrafts, "Only retained drafts must reach the explicit recovery branch, even online without pending or conflicts")
        let list = RecoveryList(sync: sync); list.reload()
        try expect(list.drafts == [first, second] && list.readFailure == nil, "Opening the recovery list must read both preserved copies without a network request")
        sync.failRead = true; list.reload()
        try expect(list.readFailure?.contains("未能读取") == true && !list.notices.messages.isEmpty, "Read failure must be visible in the page and notifications")
        try expect(list.drafts == [first, second] && sync.values == [first, second], "Read failure must not discard already-visible or persisted drafts")
        sync.failRead = false; list.reload()
        try expect(list.readFailure == nil, "Explicit refresh must recover a previous read failure")
        let detail = RecoveryDetail(sync: sync, draft: first)
        detail.copy(first.copyText)
        try expect(V2RetainedDraftClipboard.value == first.copyText, "Copy all must include the exact full text, including Bible, notes and whitespace")
        detail.copy(first.draftText)
        try expect(V2RetainedDraftClipboard.value == first.draftText, "Prose-only copy must preserve the exact prose")
        try expect(sync.removeCalls == 0 && sync.values.count == 2, "Copying must never remove any retained copy")
        V2RetainedDraftClipboard.canWrite = false; detail.copy(first.copyText)
        try expect(detail.notices.messages.last?.contains("复制失败") == true && sync.values.count == 2, "Copy failure must explain recovery and retain the copies")
        V2RetainedDraftClipboard.canWrite = true
        detail.requestRemoval()
        try expect(detail.confirmingRemoval && sync.removeCalls == 0, "Requesting removal must first ask for confirmation")
        detail.cancelRemoval()
        try expect(!detail.confirmingRemoval && sync.removeCalls == 0 && sync.values.count == 2, "Cancellation must preserve every copy")
        detail.requestRemoval(); sync.failRemoval = true; detail.confirmRemoval()
        try expect(!detail.confirmingRemoval && detail.dismissed == 0 && detail.removedCalls == 0 && sync.values.count == 2, "CAS or storage failure must leave the detail and retained copies intact")
        try expect(detail.notices.messages.last?.contains("已变化") == true, "Removal failure must show the actual store error")
        sync.failRemoval = false; detail.requestRemoval(); detail.confirmRemoval()
        try expect(sync.values == [second] && detail.dismissed == 1 && detail.removedCalls == 1, "Confirmed successful removal must remove exactly the selected copy and refresh")
        list.reload()
        try expect(list.drafts == [second], "The list must reflect the confirmed removal")
        let remaining = RecoveryDetail(sync: sync, draft: second); remaining.requestRemoval(); remaining.confirmRemoval()
        try expect(!sync.hasRetainedChapterDrafts && sync.pendingCount == 0, "Finishing recovery must clear its shortcut without introducing a sync mutation")
        print("Build70 actual retained-draft recovery lifecycle: \(checks) checks passed")
    }
    struct Assertion: Error { let message: String }
}
