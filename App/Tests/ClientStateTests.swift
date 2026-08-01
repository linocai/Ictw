import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.assertion(message) }
}

private func makeChapter(status: String = "draft_ready") throws -> Chapter {
    let object: [String: Any] = [
        "id": "chapter-1",
        "book_id": "book-1",
        "index": 1,
        "title": "第一章",
        "user_prompt": "林夕进入废城",
        "target_word_count": 3000,
        "author_note": "冷静克制",
        "draft_text": "正文",
        "summary": "",
        "headline": "",
        "status": status,
        "source": "agent",
        "updated_at": "2026-07-28T12:00:00.000000",
        "character_links": [["character_id": "character-1"]],
        "exempted_character_names": [],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(Chapter.self, from: data)
}

private func makeStatus(
    phase: String,
    outcomeCurrent: Bool?
) -> WriteJobStatus {
    WriteJobStatus(
        chapterId: "chapter-1",
        jobId: "job-1",
        outcomeCurrent: outcomeCurrent,
        kind: phase == "extracting" ? "extract" : "write",
        phase: phase,
        attempt: nil,
        errorCode: phase == "failed" ? "revision_failed" : nil,
        errorMessage: nil,
        errorContext: nil,
        violations: nil,
        chapter: nil,
        updatedCharacterIds: nil,
        addedEventIds: nil
    )
}

private func testCurrentServerFailureIsApplied() throws {
    let chapter = try makeChapter()
    let decision = ChapterJobReconciler.decide(
        status: makeStatus(phase: "failed", outcomeCurrent: true),
        chapter: chapter,
        hasLocalInputDivergence: false
    )
    try expect(decision == .currentTerminal, "current cross-device failure must be applied")
}

private func testOldOrFinalizedServerFailureIsDiscarded() throws {
    let draft = try makeChapter()
    let stale = ChapterJobReconciler.decide(
        status: makeStatus(phase: "failed", outcomeCurrent: false),
        chapter: draft,
        hasLocalInputDivergence: false
    )
    try expect(stale == .obsoleteTerminal, "server-marked stale failure must be discarded")

    let finalized = try makeChapter(status: "finalized")
    let finalizedFailure = ChapterJobReconciler.decide(
        status: makeStatus(phase: "failed", outcomeCurrent: true),
        chapter: finalized,
        hasLocalInputDivergence: false
    )
    try expect(finalizedFailure == .obsoleteTerminal, "failure must never override finalized chapter")
}

private func testOldServerFailureRemainsLocalOnly() throws {
    let chapter = try makeChapter()
    let decision = ChapterJobReconciler.decide(
        status: makeStatus(phase: "failed", outcomeCurrent: nil),
        chapter: chapter,
        hasLocalInputDivergence: false
    )
    try expect(decision == .unverifiedTerminal, "old server failure must not be replayed as current")
}

private func testNewerLocalInputsDiscardServerTerminal() throws {
    let chapter = try makeChapter()
    let failure = ChapterJobReconciler.decide(
        status: makeStatus(phase: "failed", outcomeCurrent: true),
        chapter: chapter,
        hasLocalInputDivergence: true
    )
    try expect(failure == .obsoleteTerminal, "server failure must not bind to newer local inputs")

    let done = ChapterJobReconciler.decide(
        status: makeStatus(phase: "done", outcomeCurrent: true),
        chapter: chapter,
        hasLocalInputDivergence: true
    )
    try expect(done == .obsoleteTerminal, "server completion must not replace newer local inputs")
}

private func testCachedFailureRestoresSafeDetails() throws {
    let suite = "ictw.client-state-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw TestFailure.assertion("unable to create isolated UserDefaults")
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    let chapter = try makeChapter()
    let phase = ChapterWritingPhase.failed(
        code: "checker_failed",
        message: "Bible 检查未完成",
        stage: .bibleChecking
    )
    ChapterTaskOutcomeStore.save(
        phase: phase,
        chapter: chapter,
        validationReason: "正文含未获准人物",
        pendingExemptionNames: ["林夕"],
        jobID: "job-1",
        defaults: defaults
    )

    guard let restored = ChapterTaskOutcomeStore.load(chapter: chapter, defaults: defaults) else {
        throw TestFailure.assertion("cached failure was not restored")
    }
    try expect(restored.phase == phase, "failure phase must survive restart")
    try expect(restored.validationReason == "正文含未获准人物", "validation detail must survive restart")
    try expect(restored.pendingExemptionNames == ["林夕"], "exemption action inputs must survive restart")
    try expect(restored.jobID == "job-1", "job identity must survive restart")
}

private func testCachedFailureInvalidatesOnAnyInputChangeOrFinalization() throws {
    let suite = "ictw.client-state-tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        throw TestFailure.assertion("unable to create isolated UserDefaults")
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    let chapter = try makeChapter()
    ChapterTaskOutcomeStore.save(
        phase: .failed(code: "write_failed", message: "失败", stage: .drafting),
        chapter: chapter,
        defaults: defaults
    )

    var changedBible = chapter
    changedBible.userPrompt = "已经调整的剧情"
    try expect(
        ChapterTaskOutcomeStore.load(chapter: changedBible, defaults: defaults) == nil,
        "body-only matching must not survive Bible changes"
    )
    try expect(
        ChapterTaskOutcomeStore.load(chapter: chapter, defaults: defaults) == nil,
        "an invalidated outcome must not resurrect when inputs change back"
    )

    ChapterTaskOutcomeStore.save(
        phase: .failed(code: "extract_failed", message: "失败", stage: .extraction),
        chapter: chapter,
        defaults: defaults
    )
    var finalized = chapter
    finalized.status = "finalized"
    try expect(
        ChapterTaskOutcomeStore.load(chapter: finalized, defaults: defaults) == nil,
        "cached extraction failure must not override finalized state"
    )
}

private func testV16ContextAndCheckerDecode() throws {
    let object: [String: Any] = [
        "chapter_id": "chapter-1", "kind": "write", "phase": "done",
        "memory_context": [
            "memory_brief": [["text": "第 1 章事实"]],
            "previous_ending": "上一章结尾",
            "memory_non_whitespace_count": 8,
            "sources": [["id": "chapter:1:summary", "chapter_index": 1, "memory_type": "summary", "source_excerpt": "原始依据"]],
            "conflicts": [["text": "历史记录与 Bible 可能不同", "source_ids": ["chapter:1:summary"]]],
        ],
        "checker_result": ["verdict": "suspect", "issues": [["kind": "new_plot", "draft_evidence": "正文片段", "bible_evidence": "Bible 片段", "reason": "会影响后续事实"]], "draft_fingerprint": "fingerprint"],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let status = try JSONDecoder().decode(WriteJobStatus.self, from: data)
    try expect(status.memoryContext?.brief == "第 1 章事实", "v1.6 memory brief must decode")
    try expect(status.memoryContext?.previousTail == "上一章结尾", "previous ending must stay separate")
    try expect(status.memoryContext?.sources.first?.excerpt == "原始依据", "source excerpts must decode")
    try expect(status.checkerResult?.displayVerdict == "suspect", "checker verdict must decode")
    try expect(status.checkerResult?.issues?.first?.bibleEvidence == "Bible 片段", "checker evidence must decode")
    try expect(ChapterWritingPhase.legacyRevising.label == "旧版任务记录", "legacy phase must not expose Reviser")
}

@main
private struct ClientStateTestRunner {
    static func main() throws {
        try testCurrentServerFailureIsApplied()
        try testOldOrFinalizedServerFailureIsDiscarded()
        try testOldServerFailureRemainsLocalOnly()
        try testNewerLocalInputsDiscardServerTerminal()
        try testCachedFailureRestoresSafeDetails()
        try testCachedFailureInvalidatesOnAnyInputChangeOrFinalization()
        try testV16ContextAndCheckerDecode()
        print("Client state tests passed")
    }
}
