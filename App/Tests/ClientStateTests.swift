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

private func testLegacySynopsisDecodesAsCanonicalSummary() throws {
    let object: [String: Any] = [
        "id": "chapter-legacy",
        "book_id": "book-1",
        "index": 1,
        "title": "旧章",
        "user_prompt": "",
        "draft_text": "正文",
        "summary": "旧版梗概原文",
        "headline": "",
        "status": "finalized",
        "source": "agent",
        "updated_at": "2026-07-28T12:00:00.000000",
        "character_links": [],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let chapter = try JSONDecoder().decode(Chapter.self, from: data)
    try expect(chapter.longSummary == "旧版梗概原文", "legacy synopsis must remain visible as the canonical summary")
}

private func testConnectionDefaultMigrationPreservesCustomEndpoint() throws {
    let missing = ConnectionEndpoint.migratedBaseURL(saved: nil)
    try expect(missing.value == "https://ictw.linotsai.top" && missing.shouldPersist, "missing endpoint must migrate to Ningbo default")

    let legacy = ConnectionEndpoint.migratedBaseURL(saved: "https://linoi.neluvee.top")
    try expect(legacy.value == "https://ictw.linotsai.top" && legacy.shouldPersist, "only exact legacy default must migrate")

    let custom = ConnectionEndpoint.migratedBaseURL(saved: "https://writer.example.test/custom")
    try expect(custom.value == "https://writer.example.test/custom" && !custom.shouldPersist, "custom endpoint must remain untouched")

    let nearLegacy = ConnectionEndpoint.migratedBaseURL(saved: "https://linoi.neluvee.top/")
    try expect(nearLegacy.value == "https://linoi.neluvee.top/" && !nearLegacy.shouldPersist, "non-exact saved address must remain user-owned")
}

private func testAPIEndpointBearerAndStructuredConfigurationError() throws {
    let api = APIClient(baseURL: "https://ictw.linotsai.top/", token: "test-token")
    try expect(api.apiRoot == "https://ictw.linotsai.top/api/v1", "API root must normalize one trailing slash")
    let request = try api.preparedRequest("/chapters/chapter-1/job")
    try expect(request.url?.absoluteString == "https://ictw.linotsai.top/api/v1/chapters/chapter-1/job", "API path must use current endpoint")
    try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token", "Bearer header must be retained")

    let body = try JSONSerialization.data(withJSONObject: [
        "detail": ["code": "llm_profile_not_configured", "message": "该 Agent 尚未完成可用模型配置", "details": ["agent_role": "writer"]],
    ])
    let structured = APIClient.structuredError(from: body)
    try expect(structured?.code == "llm_profile_not_configured", "configuration code must decode as structured API error")
    try expect(structured?.message == "该 Agent 尚未完成可用模型配置", "configuration message must remain user-displayable")
}

private func testInspirationResponseAndEmptySnapshotRequestDecode() throws {
    let data = try JSONSerialization.data(withJSONObject: [
        "cards": [
            [
                "title": "潮水之前",
                "body": "让人物在道路消失前做出选择。",
                "history_basis": "上一章留下了未关闭的闸门。",
                "note": "可以保持结尾开放。",
                "history_chapter_indexes": [2, 3],
            ],
            [
                "title": "空房间",
                "body": "从一个本应有人却空着的房间开始。",
                "history_basis": NSNull(),
                "note": NSNull(),
                "history_chapter_indexes": [],
            ],
            [
                "title": "错误答案",
                "body": "先让最合理的答案被相信，再展示它的代价。",
                "history_basis": NSNull(),
                "note": NSNull(),
                "history_chapter_indexes": [],
            ],
        ],
    ])
    let response = try JSONDecoder().decode(InspirationResponse.self, from: data)
    try expect(response.cards.count == 3, "inspiration response must decode all cards")
    try expect(response.cards[0].historyChapterIndexes == [2, 3], "history chapter indexes must remain visible")
    try expect(response.cards[1].historyBasis == nil, "optional history basis must decode")

    let api = APIClient(baseURL: "https://ictw.linotsai.top", token: "test-token")
    let request = try api.preparedRequest(
        "/chapters/chapter-1/inspirations",
        method: "POST",
        body: InspirationRequestPayload(title: "", bible: "", selectedCharacterIds: [])
    )
    let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    try expect(payload?["title"] as? String == "", "empty title must remain a valid inspiration snapshot")
    try expect(payload?["bible"] as? String == "", "empty Bible must remain a valid inspiration snapshot")
    try expect((payload?["selected_character_ids"] as? [String]) == [], "empty character selection must remain valid")
}

private func testInspirationSnapshotStalenessAppendAndUndo() throws {
    let chapter = try makeChapter()
    let snapshot = InspirationSnapshot(chapter)
    try expect(!InspirationDraftPolicy.isStale(snapshot: snapshot, current: chapter), "unchanged inspiration snapshot must stay current")

    var edited = chapter
    edited.userPrompt = "新的 Bible"
    try expect(InspirationDraftPolicy.isStale(snapshot: snapshot, current: edited), "Bible edits during generation must mark results stale")
    edited = chapter
    edited.characterLinks = [ChapterLink(characterId: "character-2")]
    try expect(InspirationDraftPolicy.isStale(snapshot: snapshot, current: edited), "character changes during generation must mark results stale")

    let emptyInsertion = InspirationDraftPolicy.appending(body: "新的灵感", to: "  \n")
    try expect(emptyInsertion == "新的灵感", "an empty Bible must receive only the idea body")
    let appended = InspirationDraftPolicy.appending(body: "新的灵感", to: "已有内容")
    try expect(appended == "已有内容\n\n新的灵感", "a non-empty Bible must append without overwriting")
    let undo = InspirationUndo(chapterID: chapter.id, before: "已有内容", after: appended)
    try expect(undo.canApply(chapterID: chapter.id, currentBible: appended), "unchanged insertion must offer one undo")
    try expect(!undo.canApply(chapterID: chapter.id, currentBible: appended + "手改"), "manual edits must invalidate inspiration undo")
}

private func testInspirationErrorsUseAuthorFacingCopy() throws {
    let configuration = InspirationErrorCopy.message(
        for: APIError.validation(
            code: "llm_profile_not_configured",
            message: "该 Agent 尚未完成可用模型配置",
            names: []
        )
    )
    try expect(configuration.contains("设置 → Agent"), "configuration copy must tell the author where to act")
    try expect(!configuration.contains("llm_profile"), "configuration copy must hide internal error codes")

    let oldBackend = InspirationErrorCopy.message(for: APIError.http(404, "Not Found"))
    try expect(oldBackend.contains("更新后端"), "old backend copy must explain the required action")
    try expect(!oldBackend.contains("Not Found"), "old backend copy must not expose raw transport wording")
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
        "visible_checker_result": ["verdict": "passed", "issues": [], "draft_fingerprint": "visible-fingerprint"],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let status = try JSONDecoder().decode(WriteJobStatus.self, from: data)
    try expect(status.memoryContext?.brief == "第 1 章事实", "v1.6 memory brief must decode")
    try expect(status.memoryContext?.previousTail == "上一章结尾", "previous ending must stay separate")
    try expect(status.memoryContext?.sources.first?.excerpt == "原始依据", "source excerpts must decode")
    try expect(status.checkerResult?.displayVerdict == "suspect", "checker verdict must decode")
    try expect(status.visibleCheckerResult?.isPassed == true, "visible draft Checker result must decode separately")
    try expect(status.checkerResult?.issues?.first?.bibleEvidence == "Bible 片段", "checker evidence must decode")
    try expect(ChapterWritingPhase.legacyRevising.label == "旧版任务记录", "legacy phase must not expose Reviser")
}

private func testRejectedCandidateKeepsSpecificCheckerReasonsSeparate() throws {
    let object: [String: Any] = [
        "chapter_id": "chapter-1", "kind": "write", "phase": "failed",
        "error_code": "checker_rejected",
        "error_message": "Checker 未通过；请修改",
        "checker_result": [
            "verdict": "violation",
            "issues": [
                ["kind": "new_plot", "draft_evidence": "候选证据", "bible_evidence": "Bible 证据", "reason": "新增了 Bible 未授权剧情"],
                ["kind": "duplicate", "draft_evidence": "另一证据", "bible_evidence": "Bible 证据", "reason": "新增了 Bible 未授权剧情"],
            ],
        ],
        "visible_checker_result": ["verdict": "passed", "issues": []],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let status = try JSONDecoder().decode(WriteJobStatus.self, from: data)
    try expect(
        status.specificFailureReason == "Checker 未通过：新增了 Bible 未授权剧情",
        "Checker issue reasons must override the generic rejection copy without duplication"
    )
    try expect(
        status.failedCandidateCheckerResult?.displayVerdict == "violation",
        "rejected candidate result must stay available separately"
    )
    try expect(
        status.visibleCheckerResult?.isPassed == true,
        "old visible draft Checker result must remain independently identifiable"
    )
}

private func testExtractorFailureKeepsSpecificBackendRule() throws {
    let status = WriteJobStatus(
        chapterId: "chapter-1",
        jobId: "extract-1",
        outcomeCurrent: true,
        kind: "extract",
        phase: "failed",
        attempt: 3,
        errorCode: "extract_failed",
        errorMessage: "Extractor 连续 3 次未通过确定性校验：证据未明确所属人物",
        errorContext: nil,
        violations: nil,
        chapter: nil,
        updatedCharacterIds: nil,
        addedEventIds: nil
    )
    try expect(
        status.specificFailureReason == "正文已接受；Extractor 连续 3 次未通过确定性校验：证据未明确所属人物。可直接重新归档，无需再次检查 Bible",
        "Extractor failures must preserve the exact safe backend rule while explaining that accepted prose is retained"
    )
}

private func testCheckerOverrideSurvivesExtractorFailure() throws {
    let object: [String: Any] = [
        "chapter_id": "chapter-1",
        "job_id": "extract-override-1",
        "outcome_current": true,
        "kind": "extract",
        "phase": "failed",
        "attempt": 3,
        "error_code": "extract_failed",
        "error_message": "Extractor 连续 3 次未通过确定性校验：证据不足",
        "checker_result": [
            "override": true,
            "draft_fingerprint": "approved-fingerprint",
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let status = try JSONDecoder().decode(WriteJobStatus.self, from: data)
    try expect(status.checkerResult?.isOverride == true, "explicit Checker override must decode from extract jobs")
    try expect(
        status.specificFailureReason?.contains("可直接重新归档，无需再次检查 Bible") == true,
        "Extractor failure must explain that archive retry is independent from Checker approval"
    )

    try expect(
        CheckerOverrideActionPolicy.shouldOffer(
            hasDraft: true,
            phase: .idle,
            checkerAllowsAcceptance: false
        ),
        "force accept must remain available when Checker is stale, unavailable or has not run"
    )
    try expect(
        !CheckerOverrideActionPolicy.shouldOffer(
            hasDraft: true,
            phase: .failed(code: "extract_failed", message: "失败", stage: .extraction),
            checkerAllowsAcceptance: false
        ),
        "an accepted extraction failure should offer Extractor retry instead of asking for another override"
    )
}

private func testExtractorStateSalvageWarningDecodesOnSuccessfulCompletion() throws {
    let object: [String: Any] = [
        "chapter_id": "chapter-1",
        "job_id": "extract-salvaged-1",
        "outcome_current": true,
        "kind": "extract",
        "phase": "done",
        "attempt": 3,
        "error_context": [
            "stage": "state_salvage",
            "completion_warning": "本章已接受；1 项人物当前状态未归档：即时快照“当前行动”的原文证据及近邻语境无法确认所属人物。正文、摘要及其余合格记忆已保存。",
            "dropped_state_components": 1,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    let status = try JSONDecoder().decode(WriteJobStatus.self, from: data)
    try expect(
        status.completionWarning == "本章已接受；1 项人物当前状态未归档：即时快照“当前行动”的原文证据及近邻语境无法确认所属人物。正文、摘要及其余合格记忆已保存。",
        "successful conservative state salvage must surface its exact Chinese warning"
    )
    try expect(status.errorContext?.droppedStateComponents == 1, "dropped state count must decode")
}

private func testDraftReadyDoesNotPretendCheckerPassed() throws {
    let pending = ChapterEditorPresentationState.make(
        phase: .idle,
        chapterStatus: "draft_ready",
        checkerVerdict: nil,
        validationReason: nil,
        saveState: .synced,
        connectionInterrupted: false
    )
    let pendingCheck = pending.steps.first { $0.stage == .bibleChecking }
    try expect(pendingCheck?.state == .pending, "draft_ready without a current Checker pass must stay pending")

    let passed = ChapterEditorPresentationState.make(
        phase: .idle,
        chapterStatus: "draft_ready",
        checkerVerdict: "passed",
        validationReason: nil,
        saveState: .synced,
        connectionInterrupted: false
    )
    let passedCheck = passed.steps.first { $0.stage == .bibleChecking }
    try expect(passedCheck?.state == .completed, "only an explicit current pass may complete Bible checking")

    let violation = ChapterEditorPresentationState.make(
        phase: .idle,
        chapterStatus: "draft_ready",
        checkerVerdict: "violation",
        validationReason: nil,
        saveState: .synced,
        connectionInterrupted: false
    )
    let failedCheck = violation.steps.first { $0.stage == .bibleChecking }
    try expect(failedCheck?.state == .failed, "a Checker violation must render as failed")
}

private func testLateRefreshCannotOverwriteLocalCharacterEdit() throws {
    try expect(
        ChapterRefreshReconciler.shouldReplaceLocal(
            startingRevision: 8,
            currentRevision: 8,
            hasLocalInputDivergence: false
        ),
        "an unchanged synchronized editor may accept a server refresh"
    )
    try expect(
        !ChapterRefreshReconciler.shouldReplaceLocal(
            startingRevision: 8,
            currentRevision: 9,
            hasLocalInputDivergence: true
        ),
        "a late refresh must not undo a character selection made in flight"
    )
}

private func testFailedRegenerationKeepsVisibleDraftActions() throws {
    let failed = ChapterWritingPhase.failed(
        code: "checker_rejected",
        message: "新候选未通过",
        stage: .bibleChecking
    )
    try expect(
        VisibleDraftActionPolicy.canCheck(hasDraft: true, phase: failed),
        "a preserved visible baseline must remain eligible for Checker after regeneration fails"
    )
    try expect(
        VisibleDraftActionPolicy.canAccept(
            hasDraft: true,
            phase: failed,
            checkerApplies: true,
            checkerPassed: true
        ),
        "a preserved baseline with its own current pass must remain acceptable"
    )
    try expect(
        !VisibleDraftActionPolicy.canAccept(
            hasDraft: true,
            phase: failed,
            checkerApplies: false,
            checkerPassed: false
        ),
        "a preserved baseline without a current pass must require recheck"
    )
}

private func testLocalDraftPersistsOnlyAtTransitionBoundaries() throws {
    try expect(
        ChapterLocalDraftPersistencePolicy.needsPersistence(.unsaved),
        "an in-memory edit must be flushed at the next transition boundary"
    )
    try expect(
        !ChapterLocalDraftPersistencePolicy.needsPersistence(.synced),
        "server-synced content must not cause another local disk write"
    )
    try expect(
        !ChapterLocalDraftPersistencePolicy.needsPersistence(.localDraft),
        "duplicate lifecycle events must not rewrite an already persisted local draft"
    )
    try expect(
        ChapterLocalDraftPersistencePolicy.needsPersistence(
            .remoteSaveFailed(message: "failed", localDraftPreserved: false)
        ),
        "a failed remote save without a local snapshot must retry local persistence"
    )
}

@main
private struct ClientStateTestRunner {
    static func main() throws {
        try testLegacySynopsisDecodesAsCanonicalSummary()
        try testConnectionDefaultMigrationPreservesCustomEndpoint()
        try testAPIEndpointBearerAndStructuredConfigurationError()
        try testInspirationResponseAndEmptySnapshotRequestDecode()
        try testInspirationSnapshotStalenessAppendAndUndo()
        try testInspirationErrorsUseAuthorFacingCopy()
        try testCurrentServerFailureIsApplied()
        try testOldOrFinalizedServerFailureIsDiscarded()
        try testOldServerFailureRemainsLocalOnly()
        try testNewerLocalInputsDiscardServerTerminal()
        try testCachedFailureRestoresSafeDetails()
        try testCachedFailureInvalidatesOnAnyInputChangeOrFinalization()
        try testV16ContextAndCheckerDecode()
        try testRejectedCandidateKeepsSpecificCheckerReasonsSeparate()
        try testExtractorFailureKeepsSpecificBackendRule()
        try testCheckerOverrideSurvivesExtractorFailure()
        try testExtractorStateSalvageWarningDecodesOnSuccessfulCompletion()
        try testDraftReadyDoesNotPretendCheckerPassed()
        try testLateRefreshCannotOverwriteLocalCharacterEdit()
        try testFailedRegenerationKeepsVisibleDraftActions()
        try testLocalDraftPersistsOnlyAtTransitionBoundaries()
        print("Client state tests passed")
    }
}
