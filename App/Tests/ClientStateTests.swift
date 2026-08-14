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

private func makeChapterSummary(
    id: String,
    index: Int,
    title: String,
    status: String
) throws -> ChapterSummary {
    let object: [String: Any] = [
        "id": id,
        "book_id": "book-1",
        "index": index,
        "title": title,
        "status": status,
        "source": "agent",
        "updated_at": "2026-08-14T12:00:00.000000",
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(ChapterSummary.self, from: data)
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
        body: InspirationRequestPayload(
            title: "",
            bible: "",
            selectedCharacterIds: [],
            pacingBoundary: "只推进到开始熟络，不确认关系。"
        )
    )
    let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    try expect(payload?["title"] as? String == "", "empty title must remain a valid inspiration snapshot")
    try expect(payload?["bible"] as? String == "", "empty Bible must remain a valid inspiration snapshot")
    try expect((payload?["selected_character_ids"] as? [String]) == [], "empty character selection must remain valid")
    try expect(payload?["pacing_boundary"] as? String == "只推进到开始熟络，不确认关系。", "pacing boundary must use its wire key")
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
    let boundedSnapshot = InspirationSnapshot(chapter, pacingBoundary: "只推进到熟络")
    try expect(
        !InspirationDraftPolicy.isStale(snapshot: boundedSnapshot, current: chapter, pacingBoundary: "  只推进到熟络  "),
        "boundary whitespace must normalize before staleness comparison"
    )
    try expect(
        InspirationDraftPolicy.isStale(snapshot: boundedSnapshot, current: chapter, pacingBoundary: "推进到确认关系"),
        "changed pacing boundary must mark results stale"
    )
    let longBoundary = String(repeating: "界", count: 510)
    try expect(
        InspirationDraftPolicy.normalizedPacingBoundary(longBoundary).count == 500,
        "pacing boundary must stay within the backend request limit"
    )

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

private func testV193ArchiveAndBookPersonaDecode() throws {
    let bookData = try JSONSerialization.data(withJSONObject: [
        "id": "book-1", "title": "测试书", "world_setting": "海上城市", "chapter_count": 2,
        "character_count": 1, "archive_pending_count": 1, "archive_attention_count": 2,
        "updated_at": "2026-08-14T12:00:00.000000",
    ])
    let book = try JSONDecoder().decode(Book.self, from: bookData)
    try expect(book.archivePendingCount == 1 && book.archiveAttentionCount == 2, "book archive counts must decode")

    let summaryData = try JSONSerialization.data(withJSONObject: [
        "id": "chapter-1", "book_id": "book-1", "index": 1, "title": "第一章", "status": "finalized",
        "source": "agent", "updated_at": "2026-08-14T12:00:00.000000", "archive_status": "failed",
        "archive_schema": "v2", "archive_can_retry": true, "archive_latest_attempt_status": "failed",
    ])
    let summary = try JSONDecoder().decode(ChapterSummary.self, from: summaryData)
    try expect(summary.archiveCanRetry && summary.archiveStatus == "failed", "chapter archive health must decode")

    let personaData = try JSONSerialization.data(withJSONObject: [
        "agent_role": "writer", "source": "book", "book_persona": "短句", "global_persona": "全局",
        "default_persona": "默认", "effective_persona": "短句", "program_protocol": "只读",
    ])
    let persona = try JSONDecoder().decode(BookAgentPersona.self, from: personaData)
    try expect(persona.source == "book" && persona.effectivePersona == "短句", "book persona source and effective text must decode")
}

private func testCheckedSnapshotAndExportComposer() throws {
    let chapter = try makeChapter(status: "finalized")
    let result = CheckerResult(verdict: "passed", status: "passed", draftFingerprint: nil, issues: nil, errorCode: nil, wasOverridden: nil)
    let snapshot = CheckedDraftSnapshot(chapter: chapter, checkerResult: result)
    try expect(snapshot.applies(to: chapter), "unchanged checked draft must retain its local result")
    let unavailable = CheckerResult(verdict: nil, status: "unavailable", draftFingerprint: nil, issues: nil, errorCode: nil, wasOverridden: nil)
    try expect(!unavailable.hasConcreteVerdict, "unavailable Checker state must not become a historical verdict")
    try expect(!CheckedDraftSnapshot(chapter: chapter, checkerResult: unavailable).checkerResult.hasConcreteVerdict, "snapshot guard must distinguish a real verdict from availability state")
    try expect(
        CheckerSnapshotPresentationPolicy.shouldShowStaleSnapshot(
            hasConcreteSnapshot: true, checkerAppliesToVisibleDraft: true, currentCheckerResult: unavailable
        ),
        "an unavailable current response must leave a concrete old result visibly stale"
    )
    try expect(
        !CheckerSnapshotPresentationPolicy.shouldShowStaleSnapshot(
            hasConcreteSnapshot: true, checkerAppliesToVisibleDraft: true, currentCheckerResult: result
        ),
        "a current concrete verdict must hide the old snapshot"
    )
    var revised = chapter
    revised.draftText = "正文已修改。另起一句。"
    try expect(!snapshot.applies(to: revised), "draft edits must stale local checker snapshot")
    try expect(!CheckedDraftSentenceDiff.changedRanges(previous: chapter.draftText, current: revised.draftText).isEmpty, "a real local baseline must yield deterministic changed sentences")

    let bookData = try JSONSerialization.data(withJSONObject: [
        "id": "book-1", "title": "测试书", "world_setting": "海上城市", "chapter_count": 1,
        "character_count": 0, "updated_at": "2026-08-14T12:00:00.000000",
    ])
    let book = try JSONDecoder().decode(Book.self, from: bookData)
    let files = ExportComposer.compose(book: book, chapters: [chapter], characters: [], format: .markdown, includeWorld: true, includeCharacters: false, separateChapters: false)
    try expect(files.count == 1 && files[0].filename.hasSuffix(".md"), "markdown export must produce one markdown file")
    try expect(files[0].text.contains("## 世界观") && files[0].text.contains("## 第 1 章"), "export must include opted-in fixed setting and chapter prose")
    let separate = ExportComposer.compose(book: book, chapters: [chapter], characters: [], format: .plainText, includeWorld: true, includeCharacters: true, separateChapters: true)
    try expect(separate.count == 2 && separate[0].filename.contains("设定") && separate[0].text.contains("世界观"), "per-chapter export must emit one non-empty settings companion")

    try expect(
        ExportPresentationPolicy.availableScopes(currentChapterID: nil) == [.accepted, .all],
        "book-level export must not offer an unavailable current chapter scope"
    )
    try expect(
        ExportPresentationPolicy.availableScopes(currentChapterID: "chapter-1") == [.accepted, .all, .current],
        "chapter-level export must retain the current chapter scope"
    )
}

private func testArchiveRailUsesHealthNotSchema() throws {
    try expect(
        ChapterArchiveRailState.resolve(status: "pending", canRetry: false) == .pending,
        "pending archive must show even without an active archive schema"
    )
    try expect(
        ChapterArchiveRailState.resolve(status: "failed", canRetry: true) == .attention,
        "retryable failed archive must show attention even without a schema"
    )
    try expect(
        ChapterArchiveRailState.resolve(status: "stale", canRetry: false) == .none,
        "a fresh draft's default stale state must not appear as archive attention"
    )
}

private func testFinalizedChapterEditingPolicy() throws {
    let draft = try makeChapter()
    let finalized = try makeChapter(status: "finalized")
    try expect(ChapterEditingPolicy.canEdit(draft), "draft chapters must remain editable")
    try expect(!ChapterEditingPolicy.canEdit(finalized), "finalized chapters must stay immutable until reopen changes their status")
    try expect(!ChapterEditingPolicy.canEdit(nil), "a missing chapter must never accept an edit")
}

private func testBookPersonaResponseCannotCrossBook() throws {
    try expect(
        BookPersonaResponsePolicy.accepts(responseBookID: "book-b", activeBookID: "book-b", targetBookID: "book-b"),
        "current book persona response must apply"
    )
    try expect(
        !BookPersonaResponsePolicy.accepts(responseBookID: "book-a", activeBookID: "book-b", targetBookID: "book-b"),
        "a slow old-book response must not overwrite the new book"
    )
}

private func makeV2DeskSource(
    chapter: Chapter? = nil,
    writingPhase: ChapterWritingPhase = .idle,
    checkerResult: CheckerResult? = nil,
    checkerApplies: Bool = false,
    checkerRefreshing: Bool = false,
    staleSnapshot: CheckedDraftSnapshot? = nil,
    saveState: ChapterSaveState = .synced,
    connectionInterrupted: Bool = false
) -> V2DeskEditorSource {
    V2DeskEditorSource(
        chapter: chapter,
        writingPhase: writingPhase,
        checkerResult: checkerResult,
        checkerAppliesToVisibleDraft: checkerApplies,
        checkerRefreshing: checkerRefreshing,
        staleCheckedSnapshot: staleSnapshot,
        saveState: saveState,
        connectionInterrupted: connectionInterrupted
    )
}

private func checkerResult(_ verdict: String, issues: [CheckerIssue] = []) -> CheckerResult {
    CheckerResult(
        verdict: verdict,
        status: verdict,
        draftFingerprint: nil,
        issues: issues,
        errorCode: nil,
        wasOverridden: nil
    )
}

private func testV2DeskUsesFixedThreeFacesAndOnePrimaryAction() throws {
    try expect(
        V2DeskChapterFace.allCases == [.intent, .manuscript, .evidence],
        "v2 chapter navigation must retain exactly intent, manuscript and evidence faces"
    )

    let empty = V2DeskPresentation.make(makeV2DeskSource())
    try expect(empty.chapterState == .empty, "an empty desk must remain an empty chapter state")
    try expect(empty.primaryAction == .generate, "an empty chapter must offer generation as its only primary action")
    try expect(empty.marker == .notYetHappened, "an empty chapter must use the not-yet marker")
    try expect(empty.evidence == .none, "an empty chapter must not invent Checker evidence")

    var prose = try makeChapter()
    prose.draftText = "作者已有的一段正文。"
    let drafting = V2DeskPresentation.make(makeV2DeskSource(chapter: prose))
    try expect(drafting.chapterState == .drafting, "existing prose without a current Checker result must remain drafting")
    try expect(drafting.primaryAction == .rerunChecker, "existing prose without current evidence must require a recheck")
    try expect(!drafting.isBodyReadOnly, "unaccepted prose must remain editable")
}

private func testV2DeskGenerationCancelAndFailurePreserveVisibleProse() throws {
    var chapter = try makeChapter()
    chapter.draftText = "作者正在保留的原正文。"

    let generating = V2DeskPresentation.make(makeV2DeskSource(chapter: chapter, writingPhase: .writing))
    try expect(generating.chapterState == .generating, "write-side jobs must map to generating")
    try expect(generating.primaryAction == .cancelGeneration, "a generating chapter must expose cancellation as its only primary action")
    try expect(generating.taskBanner?.kind == .writing, "generation must be represented in the task banner")
    try expect(generating.isBodyEditableWhileGenerating, "visible prose must remain editable while a job runs")
    try expect(!generating.isBodyReadOnly, "generation must not make the visible prose read-only")

    let cancelled = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        writingPhase: .cancelled(message: "已取消", stage: .drafting)
    ))
    try expect(cancelled.primaryAction == .generate, "cancelled generation must allow a new generation")
    try expect(cancelled.taskBanner?.kind == .cancelled, "cancelled generation must remain author-visible")
    try expect(cancelled.taskBanner?.text.contains("正文没有变化") == true, "cancellation must state that visible prose was preserved")

    let failed = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        writingPhase: .failed(code: "write_failed", message: "失败", stage: .drafting)
    ))
    try expect(failed.chapterState == .failed, "a write failure must remain a failure state")
    try expect(failed.primaryAction == .retryGeneration, "a write failure must retry rather than expose a server-side alternative draft")
    try expect(failed.taskBanner?.text.contains("正文没有变化") == true, "write failure must state that visible prose was preserved")
}

private func testV2DeskCheckerCurrentStaleAndUnavailableStates() throws {
    var chapter = try makeChapter()
    chapter.draftText = "雨停之后，林夕走进旧站。"
    let passed = checkerResult("passed")
    let currentPassed = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        checkerResult: passed,
        checkerApplies: true
    ))
    try expect(currentPassed.chapterState == .checked, "only a concrete current pass may produce checked state")
    try expect(currentPassed.primaryAction == .accept, "a current Checker pass may enable acceptance")
    guard case .current(let verdict, _) = currentPassed.evidence else {
        throw TestFailure.assertion("current Checker evidence must stay current")
    }
    try expect(verdict == .passed, "current pass must retain its verdict")

    let issue = CheckerIssue(kind: "new_plot", draftEvidence: "林夕走进旧站", bibleEvidence: "尚未进入旧站", reason: "越界")
    let suspect = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        checkerResult: checkerResult("suspect", issues: [issue]),
        checkerApplies: true
    ))
    try expect(suspect.primaryAction == .acceptWithWarning, "a current suspect verdict must use the confirmed warning accept path")
    try expect(suspect.primaryAction.requiresConfirmation, "warning acceptance must require confirmation")
    guard case .current(let suspectVerdict, let issues) = suspect.evidence else {
        throw TestFailure.assertion("suspect Checker evidence must remain current")
    }
    try expect(suspectVerdict == .suspect && issues.count == 1, "current issues must retain backend evidence")

    let snapshot = CheckedDraftSnapshot(chapter: chapter, checkerResult: passed)
    var bodyEdited = chapter
    bodyEdited.draftText = "雨停之后，林夕改去码头。"
    let stale = V2DeskPresentation.make(makeV2DeskSource(
        chapter: bodyEdited,
        staleSnapshot: snapshot
    ))
    try expect(stale.chapterState == .needsRecheck, "changed prose with only a historical result must require recheck")
    try expect(stale.primaryAction == .rerunChecker, "stale Checker evidence must never authorize acceptance")
    try expect(stale.marker == .unreliable, "stale Checker evidence must use the unreliable marker")
    guard case .stale(_, _, let canMarkChangedSentences) = stale.evidence else {
        throw TestFailure.assertion("historical Checker evidence must be visibly stale")
    }
    try expect(canMarkChangedSentences, "sentence marking requires and may use a real local baseline")

    var bibleEdited = chapter
    bibleEdited.userPrompt = "新的本章意图"
    let staleWithoutBodyDiff = V2DeskPresentation.make(makeV2DeskSource(
        chapter: bibleEdited,
        staleSnapshot: snapshot
    ))
    guard case .stale(_, _, let canMarkChangedSentences) = staleWithoutBodyDiff.evidence else {
        throw TestFailure.assertion("input changes must stale historical evidence even without a body diff")
    }
    try expect(!canMarkChangedSentences, "sentence marking must not be fabricated when the body has no provable diff")

    let currentUnavailableResult = CheckerResult(
        verdict: nil,
        status: "unavailable",
        draftFingerprint: nil,
        issues: nil,
        errorCode: nil,
        wasOverridden: nil
    )
    let unavailableCurrent = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        checkerResult: currentUnavailableResult,
        checkerApplies: true
    ))
    try expect(unavailableCurrent.primaryAction == .rerunChecker, "a completed unavailable check must offer recheck as the single primary action")
    try expect(unavailableCurrent.taskBanner?.kind == .checkerUnavailable, "a completed unavailable check must be author-visible")
    try expect(unavailableCurrent.taskBanner?.tone == .warning, "a completed unavailable check must use warning semantics")
    try expect(unavailableCurrent.taskBanner?.text == "这次没能检查", "unavailable Checker copy must state the failed check without machine detail")
    try expect(unavailableCurrent.taskBanner?.action == .acceptWithWarning, "unavailable Checker acceptance must remain a distinct confirmed secondary action")
    try expect(unavailableCurrent.evidence == .unavailable, "unavailable Checker data must never become current evidence")

    let unavailableCurrentWithHistory = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        checkerResult: currentUnavailableResult,
        checkerApplies: true,
        staleSnapshot: snapshot
    ))
    try expect(unavailableCurrentWithHistory.primaryAction == .rerunChecker, "historical evidence must not change unavailable Checker primary action")
    try expect(unavailableCurrentWithHistory.taskBanner?.action == .acceptWithWarning, "historical evidence must not turn warning acceptance into the primary action")
    guard case .stale = unavailableCurrentWithHistory.evidence else {
        throw TestFailure.assertion("unavailable current Checker data must retain historical evidence only as stale")
    }

    let unavailableWithHistory = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        checkerResult: currentUnavailableResult,
        checkerApplies: false,
        checkerRefreshing: true,
        staleSnapshot: snapshot
    ))
    try expect(unavailableWithHistory.primaryAction == .none, "an in-flight recheck must not offer a competing primary action")
    try expect(unavailableWithHistory.taskBanner?.kind == .checking, "an unavailable/in-flight Checker must stay in the task banner")
    guard case .stale = unavailableWithHistory.evidence else {
        throw TestFailure.assertion("an unavailable Checker must preserve prior concrete evidence only as stale")
    }

    let unavailableWithoutHistory = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        checkerResult: currentUnavailableResult,
        checkerApplies: false,
        checkerRefreshing: true
    ))
    try expect(unavailableWithoutHistory.evidence == .unavailable, "unavailable Checker data without a real snapshot must not invent evidence")
}

private func testV2DeskAcceptedArchiveIsolationAndAttention() throws {
    var newDraft = try makeChapter()
    newDraft.draftText = "尚未接受的新草稿。"
    newDraft.archive = ChapterArchive(
        status: "stale",
        archiveSchema: "",
        revisionId: nil,
        revision: nil,
        summary: "",
        facts: [],
        stateDeltaCount: 0,
        errorCode: nil,
        errorMessage: nil,
        canRetry: false,
        latestAttemptStatus: nil,
        inactivePreview: ChapterArchiveInactivePreview(
            revisionId: "should-not-render",
            revision: 0,
            status: "stale",
            summary: "默认草稿状态不是归档预览",
            factCount: 1,
            stateDeltaCount: 1
        )
    )
    let notStartedArchive = V2DeskPresentation.make(makeV2DeskSource(chapter: newDraft))
    try expect(notStartedArchive.archive == .notStarted, "a new draft's default stale archive state must not become archive attention")

    var accepted = try makeChapter(status: "finalized")
    accepted.draftText = "已经被作者接受的正文。"
    accepted.archive = ChapterArchive(
        status: "pending",
        archiveSchema: "v2",
        revisionId: nil,
        revision: nil,
        summary: "",
        facts: [],
        stateDeltaCount: 0,
        errorCode: nil,
        errorMessage: nil,
        canRetry: false,
        latestAttemptStatus: "pending",
        inactivePreview: nil
    )
    let pending = V2DeskPresentation.make(makeV2DeskSource(chapter: accepted))
    try expect(pending.chapterState == .accepted && pending.isBodyReadOnly, "acceptance must make the manuscript read-only immediately")
    try expect(pending.primaryAction == .startNewChapter, "archive work must not replace the accepted chapter primary action")
    try expect(pending.primaryAction.title == "开始新一章", "accepted desk creation must not be labelled as reading navigation")
    try expect(pending.archive == .pending, "pending archive must remain independent from accepted prose")
    try expect(pending.taskBanner?.kind == .archiving, "archive work must stay visible as a background fact")

    accepted.archive = ChapterArchive(
        status: "stale",
        archiveSchema: "v2",
        revisionId: "revision-1",
        revision: 1,
        summary: "",
        facts: [],
        stateDeltaCount: 0,
        errorCode: nil,
        errorMessage: nil,
        canRetry: true,
        latestAttemptStatus: "stale",
        inactivePreview: ChapterArchiveInactivePreview(
            revisionId: "revision-1",
            revision: 1,
            status: "stale",
            summary: "仅供预览的失效归档",
            factCount: 2,
            stateDeltaCount: 1
        )
    )
    let staleFinalizedArchive = V2DeskPresentation.make(makeV2DeskSource(chapter: accepted))
    guard case .attention(let staleCanRetry, let stalePreview) = staleFinalizedArchive.archive else {
        throw TestFailure.assertion("a retryable stale finalized revision must remain archive attention")
    }
    try expect(staleCanRetry, "retryability must distinguish a real stale revision from a new draft default")
    try expect(stalePreview?.status == "stale" && stalePreview?.factCount == 2, "only a real inactive revision may be offered as a preview")

    accepted.archive = ChapterArchive(
        status: "failed",
        archiveSchema: "v2",
        revisionId: nil,
        revision: nil,
        summary: "",
        facts: [],
        stateDeltaCount: 0,
        errorCode: "extract_failed",
        errorMessage: "失败",
        canRetry: true,
        latestAttemptStatus: "failed",
        inactivePreview: ChapterArchiveInactivePreview(
            revisionId: "revision-1",
            revision: 1,
            status: "failed",
            summary: "不可作为记忆的预览",
            factCount: 2,
            stateDeltaCount: 1
        )
    )
    let failedArchive = V2DeskPresentation.make(makeV2DeskSource(chapter: accepted))
    guard case .attention(let canRetry, let preview) = failedArchive.archive else {
        throw TestFailure.assertion("failed archive must remain an attention state, not active memory")
    }
    try expect(canRetry, "retry capability must come from the actual archive contract")
    try expect(preview?.status == "failed" && preview?.factCount == 2, "inactive revision preview must remain display-only metadata")
    try expect(failedArchive.isBodyReadOnly, "archive failure must never reopen accepted prose")
    try expect(failedArchive.primaryAction == .startNewChapter, "archive retry must stay secondary to accepted chapter flow")
}

private func testV2DeskReadingOrderSeparatesNavigationFromCreation() throws {
    let chapterOne = try makeChapterSummary(id: "one", index: 1, title: "第一章", status: "finalized")
    let chapterThree = try makeChapterSummary(id: "three", index: 3, title: "第三章", status: "draft_ready")
    let chapterTen = try makeChapterSummary(id: "ten", index: 10, title: "第十章", status: "finalized")
    let unordered = [chapterTen, chapterThree, chapterOne]

    try expect(
        V2DeskReadingOrder.next(after: chapterOne.id, in: unordered) == .write(chapterThree),
        "an unfinished next chapter must continue writing that real chapter across index gaps"
    )
    try expect(
        V2DeskReadingOrder.next(after: chapterThree.id, in: unordered) == .read(chapterTen),
        "a finalized next chapter must continue reading its real chapter"
    )
    try expect(
        V2DeskReadingOrder.next(after: chapterTen.id, in: unordered) == .startNewChapter,
        "only the actual final chapter may offer creation"
    )
    try expect(
        V2DeskReadingOrder.previous(after: chapterThree.id, in: unordered) == chapterOne,
        "previous navigation must use sorted existing chapters despite unordered input"
    )
    try expect(
        V2DeskReadingOrder.previous(after: chapterOne.id, in: unordered) == nil,
        "the first chapter has no previous navigation target"
    )
    try expect(
        V2DeskReadingOrder.next(after: "missing", in: unordered) == nil,
        "a missing current ID must never become an implicit create command"
    )
    try expect(
        V2DeskReadingOrder.previous(after: "missing", in: unordered) == nil,
        "a missing current ID must never invent a previous chapter"
    )
}

private func testV2DeskLocalSaveConnectionAndModelConfiguration() throws {
    var chapter = try makeChapter()
    chapter.draftText = "本地草稿。"
    let localDraft = V2DeskPresentation.make(makeV2DeskSource(chapter: chapter, saveState: .localDraft))
    try expect(localDraft.showsUnsavedLocalDraft, "a recoverable local draft must not be displayed as server-synced")

    let disconnected = V2DeskPresentation.make(makeV2DeskSource(chapter: chapter, connectionInterrupted: true))
    try expect(disconnected.taskBanner?.kind == .connectionInterrupted, "connection interruption must be visible without discarding prose")
    try expect(disconnected.taskBanner?.action == nil, "connection interruption must not invent a server command")

    for code in [
        "llm_profile_not_configured",
        "llm_profile_missing",
        "extractor_thinking_not_disableable",
    ] {
        let missingModel = V2DeskPresentation.make(makeV2DeskSource(
            chapter: chapter,
            writingPhase: .failed(code: code, message: "尚未配置模型", stage: .drafting)
        ))
        try expect(missingModel.primaryAction == .openSettings, "the current backend configuration error \(code) must route authors to settings")
        try expect(missingModel.taskBanner?.action == .openSettings, "configuration failure \(code) must expose settings from the task banner")
    }

    let ordinaryLLMFailure = V2DeskPresentation.make(makeV2DeskSource(
        chapter: chapter,
        writingPhase: .failed(code: "llm_timeout", message: "超时", stage: .drafting)
    ))
    try expect(ordinaryLLMFailure.primaryAction == .retryGeneration, "unrelated LLM failures must remain retryable rather than be mislabeled as missing settings")
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
        try testV193ArchiveAndBookPersonaDecode()
        try testCheckedSnapshotAndExportComposer()
        try testArchiveRailUsesHealthNotSchema()
        try testFinalizedChapterEditingPolicy()
        try testBookPersonaResponseCannotCrossBook()
        try testV2DeskUsesFixedThreeFacesAndOnePrimaryAction()
        try testV2DeskGenerationCancelAndFailurePreserveVisibleProse()
        try testV2DeskCheckerCurrentStaleAndUnavailableStates()
        try testV2DeskAcceptedArchiveIsolationAndAttention()
        try testV2DeskReadingOrderSeparatesNavigationFromCreation()
        try testV2DeskLocalSaveConnectionAndModelConfiguration()
        try runV202NoticeLifecycleTests()
        print("Client state tests passed")
    }
}
