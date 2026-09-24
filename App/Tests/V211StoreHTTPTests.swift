import Foundation

private struct HTTPTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw HTTPTestFailure(description: message) }
}

private struct RequestEvent: Decodable {
    let method: String
    let path: String
    let bodyText: String
    let ifMatch: String?
}

private struct FixtureState: Decodable {
    let book: Book
    let character: Character
    let chapters: [String: Chapter]
    let requests: [RequestEvent]
}

@MainActor
private func fixture(_ path: String = "state", _ value: [String: Any]? = nil) async throws -> FixtureState {
    let root = ProcessInfo.processInfo.environment["LINOI_DEBUG_BASE_URL"]!
    var request = URLRequest(url: URL(string: root + "/api/v1/_test/" + path)!)
    if let value {
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: value)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    try check((response as? HTTPURLResponse)?.statusCode == 200, "fixture control failed")
    return try JSONDecoder.lino.decode(FixtureState.self, from: data)
}

@MainActor
private func eventually(_ message: String, attempts: Int = 150, _ predicate: () async throws -> Bool) async throws {
    for _ in 0..<attempts {
        if try await predicate() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw HTTPTestFailure(description: "timed out: " + message)
}

@MainActor
private final class Harness {
    let notices = NoticeBus()
    let session: AppSession
    let sync: ClientSyncStore
    let editor: ChapterEditorStore
    let chapters: [Chapter]
    let book: Book
    let character: Character
    let cacheRoot: URL

    init(_ name: String, _ options: [String: Any] = [:], load: Bool = true) async throws {
        var config = options
        let prefix = name + "-" + UUID().uuidString
        config["prefix"] = prefix
        let state = try await fixture("reset", config)
        book = state.book
        character = state.character
        chapters = state.chapters.values.sorted { $0.index < $1.index }
        session = AppSession(notices: notices)
        session.baseURL = ProcessInfo.processInfo.environment["LINOI_DEBUG_BASE_URL"]!
        session.token = "synthetic-test-token"
        session.currentBook = book
        cacheRoot = DebugRuntimeConfiguration.dataRoot!.appendingPathComponent(prefix)
        let cache = ClientSnapshotCache(root: cacheRoot)
        cache.saveBooks([book])
        cache.saveCharacters([character], bookID: book.id)
        chapters.forEach { cache.saveChapter($0) }
        sync = ClientSyncStore(cache: cache, notices: notices)
        editor = ChapterEditorStore(session: session, sync: sync)
        if load { await self.load(0) }
    }

    func load(_ index: Int) async {
        let data = try! JSONEncoder.lino.encode(chapters[index])
        await editor.load(try! JSONDecoder.lino.decode(ChapterSummary.self, from: data))
    }

    func snapshot() -> V2DeskSnapshot {
        V2DeskPresentation.make(V2DeskEditorSource(
            chapter: editor.currentChapter, writingPhase: editor.writingPhase,
            checkerResult: editor.checkerResult,
            checkerAppliesToVisibleDraft: editor.checkerAppliesToVisibleDraft,
            checkerRefreshing: editor.checkerRefreshing,
            staleCheckedSnapshot: editor.staleCheckedSnapshot,
            saveState: editor.saveState,
            connectionInterrupted: editor.pollingConnectionInterrupted,
            taskMonitoringMessage: editor.taskMonitoringMessage,
            preflightAcceptanceMessage: editor.preflightAcceptanceMessage,
            isLastChapterInBook: false
        ))
    }

    func enqueue(_ index: Int, text: String) throws {
        var changed = chapters[index]
        changed.draftText = text
        try check(sync.enqueue(kind: .chapter, id: changed.id,
            path: "/chapters/" + changed.id, method: "PATCH",
            baseRevision: changed.contentRevision, payload: ChapterPatchPayload(changed),
            baseSnapshot: ChapterPatchPayload(chapters[index])), "enqueue must persist")
    }
}

@main
private struct V211StoreHTTPTests {
    @MainActor
    static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("F1 explicit rejection and recheck recovery", rejectedAccept),
            ("F1 lost response and unavailable verification", unknownAccept),
            ("F1 lost response with authoritative recovery", recoveredAccept),
            ("F1 accepting is visibly pending", pendingAccept),
            ("F2 current archive failure and archive-only retry", archiveRetry),
            ("F2 current server archive outranks cached older job", newerArchiveFailure),
            ("F3 permanent failure survives restart and isolates resources", syncFailures),
            ("F3 authentication pauses all pending resources", syncAuthentication),
            ("F3 temporary HTTP failure is bounded", syncRetryable),
            ("F3 newest rejected edit replaces queued old payload", syncLatestPayload),
            ("F3 real save entrances classify transport and rejection", directSaveFailures),
            ("F3 global configuration failure pauses the queue", syncConfiguration),
            ("F3 failed conflict follow-up retains actionable error", conflictReadFailure),
            ("F3 malformed or wrong-resource success never drops pending content", invalidSyncSuccess),
            ("F3 failed disk writes never promise durable saving", diskWriteFailure),
            ("F4 late unavailable survives chapter switch", lateChecker),
            ("F4 late unavailable survives local edit", editedChecker),
            ("F4 timeout, invalid response and legacy unavailable remain actionable", checkerFailureShapes),
            ("F5 safe preflight reasons and override boundary", preflight),
            ("F5 accept preflight preserves explicit length-only choice", acceptPreflight),
            ("v2.2 passed short draft requires its own acceptance confirmation", shortDraftAcceptanceConfirmation),
            ("v2.2 history confirmation is token-bound and explicit", readinessConfirmation),
            ("v2.2 archive recovery warning is token-bound", archiveRecoveryConfirmation),
            ("v2.2 generated-candidate retry never starts Writer or checks visible draft", generatedCandidateRetry),
            ("v2.2 manual Checker Job survives finalized cold loads", manualCheckerJobColdLoad),
            ("v2.2 Extractor Job keeps visible Checker evidence after cold load", extractorJobKeepsVisibleChecker),
            ("Build62 visible recheck supersedes generation failures only", recheckAfterGenerationFailure),
            ("F6 permanent polling and manual request identities", pollingIdentity),
            ("F6 retrying observer records one error and recovers", pollingRecovery),
            ("F6 transient polling stops after a finite retry budget", boundedPolling),
            ("F6 malformed job response stops polling", malformedPolling),
            ("F6 reason-only hidden candidate preserves true failure", hiddenCandidate),
            ("F1/F6 structured HTTP statuses retain retry semantics", structuredStatuses),
            ("F8 leaving context keeps old failure in history", inspirationLeaves),
            ("F8 explicit cancellation does not report failure", inspirationCancel),
            ("F9 shelf success reflects HTTP outcome", shelfConnection),
            ("late refresh cannot pollute another chapter", lateRefresh),
            ("late start cannot cancel another chapter monitor", lateStart),
            ("late action refusal keeps original chapter and action in history", lateActionRefusals),
        ]
        var failures = 0
        for (name, test) in tests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        if let suite = ProcessInfo.processInfo.environment["LINOI_DEBUG_DEFAULTS_SUITE"] {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        print("Store HTTP regressions: \(tests.count - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func rejectedAccept() async throws {
        let h = try await Harness("reject", ["accept_mode": "reject"])
        _ = await h.editor.rerunChecker()
        _ = await h.editor.accept()
        try check(h.editor.currentChapter?.status == "draft_ready", "rejected accept cannot finalize")
        try check(h.snapshot().primaryAction == .rerunChecker, "refusal must recheck, never rewrite")
        try check(!h.notices.history.isEmpty, "accept refusal needs history")
        try check(h.notices.history.count == 1, "one refused action must produce exactly one history entry")
        try check(h.notices.history.contains { $0.message.contains(h.book.title) && $0.message.contains("第 1 章") && $0.message.contains("接受") }, "accept refusal must identify its original chapter and action")
        _ = await h.editor.rerunChecker()
        try check(h.snapshot().primaryAction == .accept, "new successful check must clear old refusal")
        let state = try await fixture()
        try check(state.requests.filter { $0.path.hasSuffix("/accept") }.count == 1, "only one accept")
        try check(!state.requests.contains { $0.path.hasSuffix("/write") || $0.path.hasSuffix("/archive/retry") }, "recovery must not start Writer/Extractor")
    }

    @MainActor static func unknownAccept() async throws {
        let h = try await Harness("unknown", ["accept_mode": "lost_and_blocked"])
        _ = await h.editor.accept()
        try check(h.editor.writingPhase.isActive, "unknown acceptance must remain locked/pending")
        try check(h.editor.taskMonitoringMessage != nil, "unknown acceptance needs a monitoring explanation")
        try check(h.snapshot().taskBanner?.action == .refreshTaskStatus, "unknown acceptance must offer read-only refresh")
        _ = await h.editor.accept()
        _ = try await fixture("config", ["get_blocked": false])
        _ = await h.editor.refreshTaskStatus()
        try check(h.editor.currentChapter?.status == "finalized", "refresh must adopt server acceptance")
        let state = try await fixture()
        try check(state.requests.filter { $0.path.hasSuffix("/accept") }.count == 1, "uncertain outcome must never repeat POST accept")
    }

    @MainActor static func recoveredAccept() async throws {
        let h = try await Harness("lost", ["accept_mode": "lost"])
        _ = await h.editor.accept()
        try check(h.editor.currentChapter?.status == "finalized", "lost reply must reconcile accepted chapter")
        try check(!h.editor.writingPhase.isFailed, "accepted chapter cannot become an accept failure")
        let state = try await fixture()
        try check(state.requests.filter { $0.path.hasSuffix("/accept") }.count == 1, "read-only reconciliation must not resubmit")
    }

    @MainActor static func pendingAccept() async throws {
        let h = try await Harness("pending", ["accept_delay": 0.3])
        let task = Task { await h.editor.accept() }
        try await eventually("accept request begins") { try await fixture().requests.contains { $0.path.hasSuffix("/accept") } }
        try check(h.snapshot().taskBanner?.text.contains("接受") == true, "accepting needs a visible pending banner")
        try check(h.snapshot().primaryAction == .none, "accepting must not expose duplicate business action")
        _ = await task.value
    }

    @MainActor static func archiveRetry() async throws {
        let h = try await Harness("archive", ["archive_failure": true, "archive_retry_delay": 0.25])
        let original = h.editor.currentChapter!.draftText
        try check(h.snapshot().taskBanner?.action == .retryArchive, "accepted archive failure needs retry")
        try check(h.notices.history.contains { $0.message.contains("超时") }, "current failure must restore into history")
        let task = Task { await h.editor.retryArchive() }
        try await eventually("archive retry begins") { try await fixture().requests.contains { $0.path.hasSuffix("/archive/retry") } }
        try check(h.snapshot().taskBanner?.text.contains("正在整理") == true, "Extractor progress must outrank stale archive error")
        try check(h.snapshot().taskBanner?.action != .retryArchive, "in-flight archive cannot offer another retry")
        _ = await task.value
        let writes = try await fixture().requests.filter { $0.method != "GET" }
        try check(writes.count == 1 && writes[0].path.hasSuffix("/archive/retry"), "archive retry must never PATCH/check/accept")
        try check(h.editor.currentChapter?.draftText == original && h.editor.currentChapter?.status == "finalized", "archive retry must preserve accepted prose")
        try check(h.editor.currentChapter?.archive?.status == "complete", "successful retry clears archive failure")
    }

    @MainActor static func newerArchiveFailure() async throws {
        let h = try await Harness("archivecurrent", ["archive_failure": true])
        try check(h.snapshot().taskBanner?.detail?.contains("超时") == true, "first failure must be cached")
        await h.load(1)
        _ = try await fixture("config", ["job_status": 503, "archive_message": "新的归档尝试被上游拒绝"])
        await h.load(0)
        try check(h.editor.currentChapter?.archive?.errorMessage == "新的归档尝试被上游拒绝", "must fetch new public archive state")
        try check(h.snapshot().taskBanner?.detail?.contains("新的归档尝试被上游拒绝") == true, "unverified old job must not override current server archive reason")
        await h.load(1)
    }

    @MainActor static func syncFailures() async throws {
        let h = try await Harness("queue", ["patch_status": 422, "patch_only_first": true])
        try h.enqueue(0, text: "A")
        try h.enqueue(1, text: "independent")
        _ = await h.sync.flush(using: h.session.api)
        try check(h.sync.pendingCount == 1 && h.sync.failedMutations.count == 1, "422 retains bad resource but flushes independent one")
        let restored = ClientSyncStore(cache: h.sync.cache)
        try check(restored.failedMutations.first?.failure?.statusCode == 422, "failure must survive a new store")
        let label = h.sync.resourceLabel(for: h.sync.pendingMutations[0])
        try check(label.contains(h.book.title) && label.contains("1"), "real patch payload must still locate book/chapter")
        try check(h.notices.history.contains { $0.message.contains(h.book.title) }, "sync notice must identify the resource")
        let before = try await fixture().requests.count
        _ = await h.sync.flush(using: h.session.api)
        let after = try await fixture().requests.count
        try check(before == after, "permanent failure must not auto-resend")
        _ = try await fixture("config", ["patch_status": 200])
        try check(h.sync.retry(h.sync.pendingMutations[0]), "explicit retry requeues")
        _ = await h.sync.flush(using: h.session.api)
        try check(h.sync.pendingCount == 0, "successful explicit retry clears queue")
    }

    @MainActor static func syncAuthentication() async throws {
        let h = try await Harness("authqueue", ["patch_status": 401])
        try h.enqueue(0, text: "A"); try h.enqueue(1, text: "B")
        _ = await h.sync.flush(using: h.session.api)
        _ = await h.sync.flush(using: h.session.api)
        let writes = try await fixture().requests.filter { $0.method == "PATCH" }
        try check(writes.count == 1 && h.sync.pendingCount == 2, "auth must pause the entire queue without losing payloads")
    }

    @MainActor static func syncRetryable() async throws {
        let h = try await Harness("retryqueue", ["patch_status": 503])
        try h.enqueue(0, text: "A")
        _ = await h.sync.flush(using: h.session.api)
        let writes = try await fixture().requests.filter { $0.method == "PATCH" }
        try check(writes.count == 1 && h.sync.pendingCount == 1, "503 must end this flush, not spin")
    }

    @MainActor static func syncLatestPayload() async throws {
        let h = try await Harness("newpayload", ["patch_status": 422])
        try h.enqueue(0, text: "A")
        _ = await h.sync.flush(using: h.session.api)
        h.editor.editString(\.draftText, value: "B")
        _ = await h.editor.save()
        let restored = ClientSyncStore(cache: h.sync.cache)
        try check(restored.pendingCount == 1, "latest failed save must keep a durable queued value")
        let pending = restored.pendingMutations[0]
        let payload = try JSONSerialization.jsonObject(with: pending.payload) as! [String: Any]
        try check(payload["draft_text"] as? String == "B", "restarted queue must retain new B, never old A")
        try check(pending.baseRevision == 7, "coalescing must preserve original revision")
        _ = try await fixture("config", ["patch_status": 200])
        _ = restored.retry(pending)
        _ = await restored.flush(using: h.session.api)
        let writes = try await fixture().requests.filter { $0.method == "PATCH" }
        let sent = try JSONSerialization.jsonObject(with: Data(writes.last!.bodyText.utf8)) as! [String: Any]
        try check(sent["draft_text"] as? String == "B", "retry must send the newest author value")
    }

    @MainActor static func directSaveFailures() async throws {
        for mode in [0, 401, 422] {
            let h = try await Harness("directsave", mode == 0 ? ["patch_lost": true] : ["patch_status": mode])
            h.editor.editString(\.draftText, value: "作者的新稿")
            _ = await h.editor.save()
            let workspace = WorkspaceStore(session: h.session, sync: h.sync)
            _ = await workspace.saveBook(title: "本机新书名", world: "本机新设定")
            let characters = CharactersStore(session: h.session, sync: h.sync)
            var changed = h.character
            changed.fixedProfile = "本机新人物设定"
            _ = await characters.update(changed)
            try check(h.sync.conflicts.isEmpty, "non-409 failure must never become a conflict")
            try check(!h.notices.history.contains { $0.message.contains("另一设备") || $0.message.contains("冲突") }, "transport/auth/validation must report their real cause")
            if mode == 0 {
                let restored = ClientSyncStore(cache: h.sync.cache)
                try check(restored.pendingCount == 3, "all three real transport-failed save entrances must durably queue")
                let kinds = Set(restored.pendingMutations.map { $0.resourceKind.rawValue })
                try check(kinds == Set(["chapter", "book", "character"]), "chapter, book and character edits must each survive")
            } else {
                try check(!h.notices.history.isEmpty, "rejection cannot disappear")
                try check(h.editor.currentChapter?.draftText == "作者的新稿", "rejected save cannot erase current prose")
            }
        }
    }

    @MainActor static func syncConfiguration() async throws {
        for emptyToken in [true, false] {
            let h = try await Harness("configuration")
            try h.enqueue(0, text: "A"); try h.enqueue(1, text: "B")
            if emptyToken { h.session.token = "" } else { h.session.baseURL = "http://[" }
            let before = try await fixture().requests.count
            _ = await h.sync.flush(using: h.session.api)
            _ = await h.sync.flush(using: h.session.api)
            try check(h.sync.pendingCount == 2 && h.sync.failedMutations.count == 1, "global configuration must pause after the first failure")
            try check(h.sync.failedMutations[0].failure?.kind.blocksAllFlushes == true, "configuration requires global pause")
            let after = try await fixture().requests.count
            try check(before == after, "invalid configuration should never reach HTTP")
        }
    }

    @MainActor static func conflictReadFailure() async throws {
        for status in [401, 404, 503, 200] {
            let h = try await Harness("conflictread")
            try h.enqueue(0, text: "A")
            _ = try await fixture("config", ["patch_status": 409, "get_status": status, "get_malformed": status == 200])
            _ = await h.sync.flush(using: h.session.api)
            let restored = ClientSyncStore(cache: h.sync.cache)
            try check(restored.pendingCount == 1 && restored.failedMutations.count == 1, "failed conflict read \(status) must preserve queued edit and failure (pending=\(restored.pendingCount), failed=\(restored.failedMutations.count))")
            try check(restored.conflicts.isEmpty, "unreadable server snapshot cannot create an incomplete conflict")
            if status != 200 {
                try check(restored.failedMutations[0].failure?.statusCode == status, "follow-up failure must retain real status")
            }
            try check(!h.notices.history.isEmpty, "conflict follow-up error must reach history")
        }
    }

    @MainActor static func invalidSyncSuccess() async throws {
        for response in ["malformed", "wrong_id"] {
          for kind in [SyncResourceKind.chapter, .book, .character] {
            let h = try await Harness("invalidsuccess", ["patch_response": response])
            if kind == .chapter { try h.enqueue(0, text: "唯一待同步正文") }
            else {
                let id = kind == .book ? h.book.id : h.character.id
                let payload = kind == .book ? ["title": "唯一待同步书名", "world_setting": "虚构世界"] : ["name": "虚构人物", "fixed_profile": "唯一待同步设定"]
                try check(h.sync.enqueue(kind: kind, id: id, path: "/" + (kind == .book ? "books/" : "characters/") + id,
                    method: "PATCH", baseRevision: 7, payload: payload, baseSnapshot: payload), "synthetic resource must queue durably")
            }
            _ = await h.sync.flush(using: h.session.api)
            let restored = ClientSyncStore(cache: h.sync.cache)
            try check(restored.pendingCount == 1 && restored.failedMutations.count == 1, "unverified \(response) success must retain the queued value and safe error")
            let payload = try JSONSerialization.jsonObject(with: restored.pendingMutations[0].payload) as! [String: Any]
            let key = kind == .chapter ? "draft_text" : kind == .book ? "title" : "fixed_profile"
            try check((payload[key] as? String)?.hasPrefix("唯一待同步") == true, "invalid success cannot delete or replace the only unsent value")
            try check(h.sync.cache.chapter(id: h.chapters[0].id)?.id == h.chapters[0].id, "wrong resource must never replace the chapter cache")
            try check(!h.notices.history.isEmpty, "invalid success must be reported instead of silently acknowledged")
          }
        }
    }

    @MainActor static func diskWriteFailure() async throws {
        let h = try await Harness("diskfailure", ["patch_lost": true])
        let manager = FileManager.default
        let drafts = DebugRuntimeConfiguration.dataRoot!.appendingPathComponent("ChapterDrafts")
        let backup = drafts.appendingPathExtension("http-test-backup")
        try manager.moveItem(at: drafts, to: backup)
        try Data("blocked synthetic draft directory".utf8).write(to: drafts)
        try manager.removeItem(at: h.cacheRoot)
        try Data("blocked synthetic sync directory".utf8).write(to: h.cacheRoot)
        defer {
            try? manager.removeItem(at: drafts)
            try? manager.moveItem(at: backup, to: drafts)
        }
        h.editor.editString(\.draftText, value: "唯一尚未落盘的新稿")
        _ = await h.editor.save()
        if case .localSaveFailed = h.editor.saveState {} else {
            throw HTTPTestFailure(description: "both persistence failures must remain localSaveFailed")
        }
        try check(h.editor.currentChapter?.draftText == "唯一尚未落盘的新稿", "in-memory author prose must survive disk failure")
        try check(h.notices.history.contains { $0.tone == .error }, "disk failure must have an actionable error")
    }

    @MainActor static func hiddenCandidate() async throws {
        let h = try await Harness("hiddenissue", ["writing": true, "job_checker_rejected": true])
        try await eventually("true terminal checker failure") { h.editor.writingPhase.isFailed }
        try check(h.editor.taskMonitoringMessage == nil, "reason-only issue must not cause schema failure")
        try check(h.editor.failedCandidateCheckerResult?.issues?.first?.reason == "既有关系出现矛盾", "safe candidate reason remains available")
        let issue = h.editor.failedCandidateCheckerResult?.issues?.first
        try check(issue?.draftEvidence.isEmpty == true && issue?.bibleEvidence.isEmpty == true, "hidden evidence stays absent")
        try check(h.editor.currentChapter?.draftText == h.chapters[0].draftText, "rejected hidden candidate cannot replace current prose")
        await h.load(1)
    }

    @MainActor static func structuredStatuses() async throws {
        for structured in [false, true] {
            for status in [429, 503] {
                let h = try await Harness("structuredpoll", ["writing": true, "job_status": status, "structured_status": structured])
                try await eventually("poll temporary failure") { h.editor.pollingConnectionInterrupted }
                _ = try await fixture("config", ["job_status": 200, "job_phase": "done"])
                try await eventually("temporary status auto recovers") { !h.editor.pollingConnectionInterrupted }
                await h.load(1)
            }
            let h = try await Harness("structuredaccept", ["accept_status": 503, "structured_status": structured])
            _ = await h.editor.accept()
            try check(h.editor.writingPhase.isActive && h.editor.taskMonitoringMessage != nil, "both structured and raw 503 acceptance have unknown outcome")
            try check(h.snapshot().taskBanner?.action == .refreshTaskStatus, "503 acceptance must offer read-only verification")
            _ = try await fixture("config", ["get_blocked": false])
            await h.load(1)
        }
    }

    @MainActor static func lateChecker() async throws {
        let h = try await Harness("latecheck", ["check_mode": "unavailable", "check_delay": 0.25])
        let task = Task { await h.editor.rerunChecker() }
        try await eventually("check begins") { try await fixture().requests.contains { $0.path.hasSuffix("/check") } }
        await h.load(1)
        _ = await task.value
        try check(h.editor.currentChapter?.id == h.chapters[1].id && h.editor.checkerResult == nil, "old failure must not contaminate new chapter")
        try check(h.notices.history.contains { $0.message.contains("拦截") && $0.message.contains(h.book.title) }, "late unavailable must remain in located history")
    }

    @MainActor static func editedChecker() async throws {
        let h = try await Harness("editcheck", ["check_mode": "unavailable", "check_delay": 0.25])
        let task = Task { await h.editor.rerunChecker() }
        try await eventually("check begins") { try await fixture().requests.contains { $0.path.hasSuffix("/check") } }
        h.editor.editString(\.draftText, value: "本次新修改")
        _ = await task.value
        try check(h.editor.currentChapter?.draftText == "本次新修改" && !h.editor.checkerAppliesToVisibleDraft, "late check cannot authorize edited prose")
        try check(h.notices.history.contains { $0.message.contains("拦截") }, "editing must not swallow unavailable notice")
    }

    @MainActor static func checkerFailureShapes() async throws {
        for (mode, expected) in [("timeout", "超时"), ("invalid", "格式无效"), ("legacy", "检查")] {
            let h = try await Harness("checkshape", ["check_mode": mode])
            _ = await h.editor.rerunChecker()
            try check(h.editor.checkerResult?.hasConcreteVerdict == false, "unavailable cannot become an effective verdict")
            try check(h.notices.history.contains { $0.message.contains(expected) && $0.tone == .error }, "each unavailable shape needs a safe error notice")
            try check(h.snapshot().primaryAction == .rerunChecker, "failed check must offer recheck, never normal acceptance")
            _ = try await fixture("config", ["check_mode": "passed"])
            _ = await h.editor.rerunChecker()
            try check(h.snapshot().primaryAction == .accept, "fresh successful recheck must recover")
        }
    }

    @MainActor static func preflight() async throws {
        for code in ["minimum_length", "unselected_character", "ambiguous_character"] {
            let h = try await Harness("preflight", ["check_mode": code])
            _ = await h.editor.rerunChecker()
            try check(h.notices.history.contains { $0.message.contains(code == "minimum_length" ? "4000" : "人物") }, "preflight must expose the concrete rule")
            if code == "minimum_length" {
                try check(h.snapshot().primaryAction == .acceptWithWarning, "author short draft needs explicit confirmation route")
                _ = await h.editor.accept(allowShortDraft: true)
                let accepted = try await fixture().requests.filter { $0.path.hasSuffix("/accept") }
                try check(accepted.count == 1, "confirmed short draft should accept once")
                let body = try JSONSerialization.jsonObject(with: Data(accepted[0].bodyText.utf8)) as! [String: Any]
                try check(body["allow_short_draft"] as? Bool == true, "short-draft confirmation must use its dedicated wire field")
                try check(body["override_checker"] as? Bool == false, "a passed short draft must not masquerade as a Checker override")
            } else {
                try check(h.snapshot().primaryAction != .acceptWithWarning && h.snapshot().primaryAction != .accept, "character correctness failure cannot offer override")
                let state = try await fixture()
                try check(!state.requests.contains { $0.path.hasSuffix("/accept") }, "character failure must not accept")
            }
        }
    }

    @MainActor static func acceptPreflight() async throws {
        for violation in ["minimum_length", "unselected_character", "ambiguous_character"] {
            let h = try await Harness("acceptpreflight", ["accept_preflight": violation])
            _ = await h.editor.accept()
            try check(h.editor.currentChapter?.status == "draft_ready", "refused preflight cannot finalize")
            if violation == "minimum_length" {
                try check(h.snapshot().primaryAction == .acceptWithWarning, "accept endpoint length refusal must offer explicit confirmation")
                _ = await h.editor.accept(allowShortDraft: true)
                try check(h.editor.currentChapter?.status == "finalized", "explicit length-only override may accept")
                let writes = try await fixture().requests.filter { $0.path.hasSuffix("/accept") }
                try check(writes.count == 2, "only the explicit second confirmation may resubmit acceptance")
            } else {
                try check(h.snapshot().primaryAction != .acceptWithWarning && h.snapshot().primaryAction != .accept, "accept endpoint character refusal must never offer override")
                let writes = try await fixture().requests.filter { $0.path.hasSuffix("/accept") }
                try check(writes.count == 1, "character refusal must not auto-resubmit")
            }
        }
    }

    @MainActor static func shortDraftAcceptanceConfirmation() async throws {
        let h = try await Harness("short-confirmation", ["accept_short_confirmation": true])
        _ = await h.editor.rerunChecker()
        try check(h.editor.checkerAppliesToVisibleDraft && h.editor.checkerResult?.isPassed == true, "the initial Checker result must pass")
        _ = await h.editor.accept()
        try check(h.snapshot().primaryAction == .acceptWithWarning, "short_draft_confirmation_required must expose an explicit second accept")
        try check(h.editor.checkerAppliesToVisibleDraft && h.editor.checkerResult?.isPassed == true, "short confirmation must retain the passed Checker result")
        _ = await h.editor.accept(allowShortDraft: true)
        try check(h.editor.currentChapter?.status == "finalized", "only explicit allow_short_draft may accept the passed short draft")
        let accepts = try await fixture().requests.filter { $0.path.hasSuffix("/accept") }
        try check(accepts.count == 2, "short confirmation must make exactly one initial and one confirmed accept request")
        let first = try JSONSerialization.jsonObject(with: Data(accepts[0].bodyText.utf8)) as? [String: Any]
        let second = try JSONSerialization.jsonObject(with: Data(accepts[1].bodyText.utf8)) as? [String: Any]
        try check(first?["allow_short_draft"] as? Bool == false && second?["allow_short_draft"] as? Bool == true, "the second request must carry only the dedicated short-draft acknowledgement")
        try check(second?["override_checker"] as? Bool == false, "a passed short draft confirmation must not become a Checker override")
    }

    @MainActor static func readinessConfirmation() async throws {
        let limitations: [[String: Any]] = [[
            "chapter_id": "history-c1", "index": 1, "title": "第一章",
            "reason": "记忆尚未完整", "effective_status": "none",
        ]]
        let h = try await Harness("readiness", [
            "readiness_limitations": limitations,
            // The shared snapshot's established spelling is intentionally
            // exercised here: the public client must decode it safely.
            "check_context_limitations": [[
                "chapter_id": "history-c1", "chapter_index": 1,
                "kind": "missing_archive", "reason": "第 1 章记忆尚未完整",
            ]],
        ])
        _ = await h.editor.rerunChecker()
        let before = try await fixture().requests
        try check(h.editor.pendingProductionContext?.action == .check, "incomplete history must require a visible check confirmation")
        try check(!before.contains { $0.path.hasSuffix("/check") }, "history warning must not silently start Checker")
        guard let capturedConfirmation = h.editor.pendingProductionContext else {
            throw HTTPTestFailure(description: "missing history confirmation")
        }
        // SwiftUI closes confirmationDialog before the action Task resumes.
        // The captured value must still authorize this one request.
        h.editor.dismissProductionContextConfirmation()
        _ = await h.editor.confirmProductionContextAndContinue(capturedConfirmation)
        let after = try await fixture().requests
        guard let checkEvent = after.last(where: { $0.path.hasSuffix("/check") }) else {
            throw HTTPTestFailure(description: "confirmed history context must start the requested check")
        }
        let body = try JSONSerialization.jsonObject(with: Data(checkEvent.bodyText.utf8)) as? [String: Any]
        try check(body?["acknowledged_context_token"] as? String == "synthetic-context-token", "confirmation must send exactly the server token")
        try check(h.editor.pendingProductionContext == nil, "one confirmation must not persist as a hidden bypass")
        try check(
            h.editor.checkerResult?.contextLimitations.first?.index == 1
                && h.editor.checkerResult?.contextLimitations.first?.effectiveStatus == "none"
                && h.editor.checkerResult?.contextLimitations.first?.reason.contains("记忆") == true,
            "Checker's returned context limitations must decode from the shared snapshot wire and remain visible"
        )
    }

    @MainActor static func archiveRecoveryConfirmation() async throws {
        let limitations: [[String: Any]] = [[
            "chapter_id": "history-c1", "index": 1, "title": "第一章",
            "reason": "应先整理前章", "effective_status": "with_state_gaps",
        ]]
        let recovery: [String: Any] = [
            "chapter_id": "history-c1", "index": 1, "title": "第一章", "reason": "前章仍有状态缺口",
        ]
        let h = try await Harness("archiveorder", [
            "archive_failure": true, "readiness_limitations": limitations,
            "readiness_recovery": recovery,
        ])
        _ = await h.editor.retryArchive()
        try check(h.editor.pendingProductionContext?.action == .archiveRetry, "reverse archive retry must expose recovery confirmation")
        let initial = try await fixture().requests
        try check(!initial.contains { $0.path.hasSuffix("/archive/retry") }, "reverse recovery warning must not retry archive before consent")
        guard let capturedConfirmation = h.editor.pendingProductionContext else {
            throw HTTPTestFailure(description: "missing archive recovery confirmation")
        }
        h.editor.dismissProductionContextConfirmation()
        _ = await h.editor.confirmProductionContextAndContinue(capturedConfirmation)
        let requests = try await fixture().requests
        guard let retry = requests.last(where: { $0.path.hasSuffix("/archive/retry") }) else {
            throw HTTPTestFailure(description: "confirmed archive recovery must issue the original retry")
        }
        let body = try JSONSerialization.jsonObject(with: Data(retry.bodyText.utf8)) as? [String: Any]
        try check(body?["acknowledged_context_token"] as? String == "synthetic-context-token", "archive retry must use the one server token")
    }

    @MainActor static func manualCheckerJobColdLoad() async throws {
        let identityIssues: [[String: Any]] = [[
            "kind": "ambiguous_character", "match_id": "same-name-1", "name": "林夕",
            "name_candidates": [
                ["character_id": "detective", "name": "林夕", "role": "侦探", "fixed_profile": "负责调查旧案"],
                ["character_id": "reporter", "name": "林夕", "role": "记者", "fixed_profile": "追踪城市传闻"],
            ],
        ]]
        for phase in ["done", "failed", "cancelled"] {
            let h = try await Harness("manual-check-job", [
                "finalized": true, "job_kind": "check", "job_phase": "idle",
                "check_identity_issues": identityIssues,
            ])
            _ = await h.editor.rerunChecker()
            try check(h.editor.visibleIdentityIssues.first?.candidates.count == 2, "manual Checker response must retain safe identity candidates")
            _ = try await fixture("config", ["job_phase": phase])
            await h.load(0)
            try check(h.editor.currentChapter?.status == "finalized", "manual Checker \(phase) must never change accepted prose into Writer work")
            try check(h.editor.checkerAppliesToVisibleDraft && h.editor.checkerResult?.isPassed == true, "manual Checker \(phase) must restore its visible result after a cold load")
            try check(h.editor.visibleIdentityIssues.first?.candidates.map(\.characterId) == ["detective", "reporter"], "same-name choices must preserve server order and IDs")
            if phase == "failed" {
                guard case .failed(_, _, .bibleChecking) = h.editor.writingPhase else {
                    throw HTTPTestFailure(description: "manual check failure must name the Checker stage")
                }
            }
            if phase == "cancelled" {
                guard case .cancelled(_, .bibleChecking) = h.editor.writingPhase else {
                    throw HTTPTestFailure(description: "manual check cancellation must name the Checker stage")
                }
            }
        }
    }

    @MainActor static func extractorJobKeepsVisibleChecker() async throws {
        for (option, expectedPhase) in [("archive_complete", "done"), ("archive_failure", "failed")] {
            let h = try await Harness("extract-visible-checker", [option: true])
            _ = await h.editor.rerunChecker()
            try check(h.editor.checkerAppliesToVisibleDraft && h.editor.checkerResult?.isPassed == true, "accepted prose must have a current check before the archive cold-load case")
            await h.load(0)
            try check(h.editor.currentChapter?.status == "finalized", "Extractor \(expectedPhase) must retain accepted prose")
            try check(h.editor.checkerAppliesToVisibleDraft && h.editor.checkerResult?.isPassed == true, "Extractor \(expectedPhase) must restore only its visible current Checker result")
            guard case .current(let verdict, _) = h.snapshot().evidence, verdict == .passed else {
                throw HTTPTestFailure(description: "Extractor \(expectedPhase) must not turn an unchanged accepted draft into stale Checker evidence")
            }
        }
    }

    @MainActor static func recheckAfterGenerationFailure() async throws {
        for role in ["memory_selector", "writer", "checker"] {
            let h = try await Harness("recheck-old-prose", [
                "job_phase": "failed", "job_kind": "write", "job_failure_role": role,
                "can_retry_checker": role == "checker",
            ])
            try check(h.editor.writingPhase.isFailed, "fixture must restore the original failed task")
            let prose = h.editor.currentChapter!.draftText
            _ = await h.editor.rerunChecker()
            try check(h.editor.writingPhase == .idle, "fresh visible check must supersede old \(role) failure")
            try check(h.snapshot().primaryAction == .accept, "passed visible prose must be acceptable without rewriting")
            try check(h.snapshot().taskBanner?.kind != .generationFailed, "old failure must not mask the successful check")
            try check(h.editor.currentChapter?.draftText == prose, "recovery must not change the preserved manuscript")
            try check(h.editor.candidateCheckerRetrySourceJobID == nil, "new visible check must clear stale generated retry handle")
            try check(ChapterTaskOutcomeStore.load(chapter: h.editor.currentChapter!) == nil, "obsolete failure must not survive cold loads")
            let requests = try await fixture().requests
            try check(!requests.contains { $0.path.hasSuffix("/write") }, "manual recovery must never start Writer")
        }
        let failedCheck = try await Harness("failed-recheck", [
            "job_phase": "failed", "job_failure_role": "writer", "check_mode": "unavailable",
        ])
        _ = await failedCheck.editor.rerunChecker()
        try check(failedCheck.editor.writingPhase.isFailed, "unavailable check cannot erase the original failure")
        let archive = try await Harness("archive-independent", ["archive_failure": true])
        _ = await archive.editor.rerunChecker()
        guard case .failed(_, _, .extraction) = archive.editor.writingPhase else {
            throw HTTPTestFailure(description: "checking accepted prose cannot repair failed archive")
        }
    }

    @MainActor static func generatedCandidateRetry() async throws {
        let h = try await Harness("candidate-retry", [
            "writing": true, "job_checker_rejected": true, "can_retry_checker": true,
        ])
        try await eventually("candidate checker failure") { h.editor.candidateCheckerRetrySourceJobID != nil }
        let before = try await fixture().requests
        _ = await h.editor.retryGeneratedCandidateChecker()
        let after = try await fixture().requests
        let newRequests = after.dropFirst(before.count)
        try check(newRequests.contains { $0.path.hasSuffix("/checker/retry") }, "retry must use candidate-only endpoint")
        try check(!newRequests.contains { $0.path.hasSuffix("/write") || $0.path.hasSuffix("/check") }, "candidate retry must not start Writer or recheck visible draft")
        guard let retry = newRequests.last(where: { $0.path.hasSuffix("/checker/retry") }) else {
            throw HTTPTestFailure(description: "candidate retry request missing")
        }
        let body = try JSONSerialization.jsonObject(with: Data(retry.bodyText.utf8)) as? [String: Any]
        try check(body?["source_job_id"] as? String == h.chapters[0].id + "-source", "retry must contain only the opaque source job identity")

        let repeated = try await Harness("candidate-repeat-failure", [
            "writing": true, "job_checker_rejected": true, "can_retry_checker": true,
            "checker_retry_failure": true,
        ])
        try await eventually("first retry source available") { repeated.editor.candidateCheckerRetrySourceJobID != nil }
        for _ in 0..<2 {
            _ = await repeated.editor.retryGeneratedCandidateChecker()
            try check(repeated.editor.candidateCheckerRetrySourceJobID == repeated.chapters[0].id + "-source", "failed check retry must retain Writer source for another retry")
            try check(!repeated.editor.checkerAppliesToVisibleDraft && repeated.editor.checkerResult == nil, "hidden check result must never become visible manuscript evidence")
            try check(repeated.notices.history.contains { $0.message.contains("姓名分组") }, "precise checker validation reason must reach notifications")
        }
        let repeatRequests = try await fixture().requests
        try check(repeatRequests.filter { $0.path.hasSuffix("/checker/retry") }.count == 2, "both retries must reach only the candidate checker endpoint")

        for code in ["checker_retry_input_changed", "checker_retry_not_available", "checker_source_not_found", "checker_retry_unavailable", "write_running"] {
            let expired = try await Harness("candidate-expired-" + code, [
                "writing": true, "job_checker_rejected": true, "can_retry_checker": true,
                "checker_retry_reject": true, "checker_retry_reject_code": code,
            ])
            try await eventually("retry source before refusal") { expired.editor.candidateCheckerRetrySourceJobID != nil }
            _ = await expired.editor.retryGeneratedCandidateChecker()
            if code == "write_running" {
                try check(expired.editor.candidateCheckerRetrySourceJobID != nil, "temporary refusal must retain the candidate retry source")
            } else {
                try check(expired.editor.candidateCheckerRetrySourceJobID == nil, "permanently expired source must not leave an endless retry action")
                try check(expired.snapshot().primaryAction == .retryGeneration, "expired source must recover through a fresh generation action")
            }
        }

        let dirty = try await Harness("candidate-dirty", [
            "writing": true, "job_checker_rejected": true, "can_retry_checker": true,
        ])
        try await eventually("dirty candidate checker failure") { dirty.editor.candidateCheckerRetrySourceJobID != nil }
        dirty.editor.editString(\.draftText, value: "作者尚未保存的新正文")
        let dirtyBefore = try await fixture().requests.filter { $0.path.hasSuffix("/checker/retry") }.count
        _ = await dirty.editor.retryGeneratedCandidateChecker()
        let dirtyAfter = try await fixture().requests.filter { $0.path.hasSuffix("/checker/retry") }.count
        try check(dirtyBefore == dirtyAfter, "dirty visible draft must block candidate retry before any candidate-retry request")
        try check(dirty.notices.history.contains { $0.message.contains("尚未与服务器一致") }, "blocked candidate retry must name the required recovery")
    }

    @MainActor static func pollingIdentity() async throws {
      for status in [401, 403] {
        let h = try await Harness("pollidentity", ["writing": true, "job_status": status])
        try await eventually("stopped monitor notice") { h.editor.pollingConnectionInterrupted }
        let reads = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
        try await Task.sleep(nanoseconds: 600_000_000)
        let stableReads = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
        try check(reads == stableReads, "authentication failure must stop automatic polling")
        try check(h.notices.history.contains { $0.message.contains("Token") || $0.message.contains("认证") }, "both 401 and 403 need an authentication diagnosis")
        try check(h.snapshot().taskBanner?.action == .refreshTaskStatus, "authorization failure needs read-only recovery")
        let first = h.notices.history.count
        _ = await h.editor.refreshTaskStatus(); _ = await h.editor.refreshTaskStatus()
        try check(h.notices.history.count == first + 2, "each explicit failed refresh needs a new history entry")
        await h.load(1); await h.load(0)
        try await eventually("new monitor notice") { h.notices.history.count > first + 2 }
        try check(h.editor.writingPhase.isActive, "stopped monitoring must not report server task failed")
        await h.load(1)
      }
    }

    @MainActor static func pollingRecovery() async throws {
        let h = try await Harness("pollretry", ["writing": true, "job_status": 503])
        try await eventually("transient monitor notice") { h.editor.pollingConnectionInterrupted }
        let first = h.notices.history.count
        try await Task.sleep(nanoseconds: 2_700_000_000)
        try check(h.notices.history.count == first, "same observer must not repeat transient failure notices")
        _ = try await fixture("config", ["job_status": 200, "job_phase": "done"])
        try await eventually("monitor recovers", attempts: 600) { !h.editor.pollingConnectionInterrupted }
        await h.load(1)
    }

    @MainActor static func boundedPolling() async throws {
        let h = try await Harness("boundedpoll", ["writing": true, "job_status": 503])
        try await eventually("bounded observer gives up", attempts: 400) {
            h.notices.history.contains { $0.message.contains("自动重试已停止") }
        }
        let before = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
        try await Task.sleep(nanoseconds: 650_000_000)
        let after = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
        // Loading also performs one independent reconciliation GET before the
        // observer starts; four failed observer reads exhaust its budget.
        try check(before == after && before <= 5, "finite retry budget must stop further automatic HTTP")
        try check(h.editor.writingPhase.isActive, "stopping observation cannot fail or cancel the server job")
        try check(h.snapshot().taskBanner?.action == .refreshTaskStatus, "exhausted observer needs read-only manual recovery")
        _ = try await fixture("config", ["job_status": 200, "job_phase": "done"])
        _ = await h.editor.refreshTaskStatus()
        try check(!h.editor.pollingConnectionInterrupted, "explicit refresh must recover after the service returns")
        await h.load(1)
    }

    @MainActor static func malformedPolling() async throws {
        let h = try await Harness("pollschema", ["writing": true, "job_malformed": true])
        try await eventually("schema incompatibility stops observer") { h.editor.taskMonitoringMessage != nil }
        let first = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
        try await Task.sleep(nanoseconds: 200_000_000)
        let second = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
        try check(first == second && h.editor.writingPhase.isActive, "invalid schema must stop only monitoring")
        await h.load(1)
    }

    @MainActor static func inspirationLeaves() async throws {
        let h = try await Harness("inspiration", ["inspirations_delay": 0.25])
        let store = InspirationCreatorStore(session: h.session)
        let before = try await fixture().requests.count
        store.clearIfChapterChanged(to: h.chapters[0].id)
        let after = try await fixture().requests.count
        try check(before == after, "opening inspiration must not request anything")
        store.generate(for: h.chapters[0])
        try await eventually("inspiration starts") { try await fixture().requests.contains { $0.path.hasSuffix("/inspirations") } }
        store.clearIfChapterChanged(to: h.chapters[1].id)
        try await eventually("old inspiration failure in history") { h.notices.history.contains { $0.message.contains("灵感") } }
        try check(store.errorMessage == nil && store.activeChapterID == h.chapters[1].id, "old failure cannot overwrite new chapter panel")
        try check(h.notices.history.last?.message.contains(h.book.title) == true, "failure location must be frozen")
    }

    @MainActor static func inspirationCancel() async throws {
        let h = try await Harness("cancelinspiration", ["inspirations_delay": 0.25])
        let store = InspirationCreatorStore(session: h.session)
        store.generate(for: h.chapters[0])
        try await eventually("inspiration starts") { try await fixture().requests.contains { $0.path.hasSuffix("/inspirations") } }
        store.stop()
        try await Task.sleep(nanoseconds: 350_000_000)
        try check(h.notices.history.isEmpty, "explicit cancellation must not masquerade as model failure")
    }

    @MainActor static func shelfConnection() async throws {
        let h = try await Harness("shelf", load: false)
        let emptyCache = ClientSnapshotCache(root: DebugRuntimeConfiguration.dataRoot!.appendingPathComponent("empty-" + UUID().uuidString))
        let shelf = BookshelfStore(session: h.session, sync: ClientSyncStore(cache: emptyCache))
        h.session.token = "incorrect-synthetic-token"
        let unauthorized = await shelf.load()
        try check(!unauthorized && shelf.books.isEmpty && h.notices.current?.tone == .error, "empty failed shelf cannot report connected")
        h.session.token = "synthetic-test-token"
        let success = await shelf.load()
        try check(success && shelf.books.isEmpty, "genuine empty shelf is a successful connection")
        h.session.baseURL = "http://127.0.0.1:1"
        let unavailable = await shelf.load()
        try check(!unavailable && h.notices.current?.tone == .error, "transport failure is not connection success")
    }

    @MainActor static func lateRefresh() async throws {
        let h = try await Harness("laterefresh")
        _ = try await fixture("config", ["job_delay": 0.25, "job_status": 401])
        let before = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
        let task = Task { await h.editor.refreshTaskStatus() }
        try await eventually("refresh starts") { try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count > before }
        _ = try await fixture("config", ["job_delay": 0, "job_status": 200])
        await h.load(1)
        _ = await task.value
        try check(h.editor.currentChapter?.id == h.chapters[1].id && h.editor.taskMonitoringMessage == nil, "old refresh failure cannot mark the new chapter disconnected")
        try check(!h.notices.history.isEmpty, "late refresh failure must remain discoverable")
    }

    @MainActor static func lateActionRefusals() async throws {
        for action in ["accept", "write", "archive/retry"] {
            var options: [String: Any] = [action.replacingOccurrences(of: "/", with: "_") + "_delay": 0.25]
            let label: String
            if action == "accept" { options["accept_mode"] = "reject"; label = "接受" }
            else if action == "write" { options["write_reject"] = true; label = "写作" }
            else { options["archive_failure"] = true; options["archive_reject"] = true; label = "整理" }
            let h = try await Harness("lateaction", options)
            let initialNotices = h.notices.history.count
            let task = Task {
                if action == "accept" { _ = await h.editor.accept() }
                else if action == "write" { _ = await h.editor.generate() }
                else { _ = await h.editor.retryArchive() }
            }
            try await eventually("action starts before navigation") { try await fixture().requests.contains { $0.method == "POST" && $0.path.hasSuffix("/" + action) } }
            await h.load(1)
            _ = await task.value
            try check(h.editor.currentChapter?.id == h.chapters[1].id && !h.editor.writingPhase.isFailed, "old action failure cannot alter new chapter state")
            let added = h.notices.history.dropFirst(initialNotices)
            try check(added.count == 1, "one late \(action) refusal must produce exactly one history entry")
            try check(added.contains { $0.message.contains(h.book.title) && $0.message.contains("第 1 章") && $0.message.contains(label) }, "late \(action) refusal must keep frozen chapter and action")
        }
    }

    @MainActor static func lateStart() async throws {
        let h = try await Harness("latestart", ["write_delay": 0.25, "writing_second": true])
        let task = Task { await h.editor.generate() }
        try await eventually("write starts") { try await fixture().requests.contains { $0.path.hasSuffix("/write") } }
        await h.load(1)
        _ = await task.value
        let suffix = "/chapters/" + h.chapters[1].id + "/job"
        let before = try await fixture().requests.filter { $0.path == suffix }.count
        try await Task.sleep(nanoseconds: 2_700_000_000)
        let after = try await fixture().requests.filter { $0.path == suffix }.count
        try check(after > before, "late old start response must not cancel current chapter monitoring")
        _ = try await fixture("config", ["job_phase": "done"])
        await h.load(0)
    }
}
