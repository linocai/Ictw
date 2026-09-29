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
    let other_book: Book
    let character: Character
    let chapters: [String: Chapter]
    let requests: [RequestEvent]
}

/// A shortened transport clock exercises the real APIClient/Store without
/// spending minutes in every regression. 60s -> 60ms; 420s -> 420ms.
private final class ScaledTimeoutURLProtocol: URLProtocol, @unchecked Sendable {
    private var completion: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "timeout.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let budget = request.timeoutInterval / 1_000
        let delay = 0.12
        let work = DispatchWorkItem { [weak self] in
            guard let self, completion?.isCancelled != true else { return }
            if budget < delay {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            } else {
                let data = Data("{\"cards\":[{\"title\":\"方向一\",\"body\":\"合成灵感正文\",\"history_chapter_indexes\":[]}]}".utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        completion = work
        DispatchQueue.global().asyncAfter(deadline: .now() + min(budget, delay), execute: work)
    }
    override func stopLoading() { completion?.cancel() }
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
            canRetryGeneratedCandidateChecker: editor.candidateCheckerRetrySourceJobID != nil,
                generatedCandidateCheckerUnavailable: editor.failedCandidateCheckerResult?.status == "unavailable",
            checkerTarget: editor.checkerTarget,
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
            ("Build71 settings late reads cannot roll back successful writes", build71SettingsReadOrdering),
            ("Build71 deleted events revoke queued patches and stale cache reads", build71EventDeletion),
            ("Build71 queued book deletion clears cache and current context", build71QueuedDeletion),
            ("Build71 successful Writer survives offline reopening", build71OfflineWriter),
            ("Build70 late chapter refresh rejects ABA and older revisions", build70RefreshOwnership),
            ("Build70 scoped settings conflicts survive restart and resolve independently", build70SettingsScopes),
            ("Build70 settings keep-local acknowledges public successful responses", build70SettingsSuccess),
            ("Build70 export checks cold drafts, selected scope, pending and conflicts", build70ExportPreflight),
            ("Build70 export invalidates preparation when local content changes", build70ExportRace),
            ("Build70 confirmed deletion revokes pending, conflict and in-flight callbacks", build70DeletionRevocation),
            ("Build70 deletion failures and new input preserve local recovery", build70DeletionRecovery),
            ("Build70 deleted drafts recover cold, copy fully and complete with exact CAS", build70RetainedRecovery),
            ("Build70 offline book edits survive cold shelf and detail refresh", build70BookOverlay),
            ("Build70 inspiration ABA revokes stale display but retains failure history", build70InspirationNavigation),
            ("Build69 queued response versions preserve successors and rebase only own chain", queuedResponseOwnership),
            ("Build69 real character saves recover newest pending and separate server baseline", characterPendingRecovery),
            ("Build69 direct save acknowledgements/refusals preserve newer edits", directMutationOwnership),
            ("Build69 own concurrent 409 rebases only with exact acknowledged server proof", ownConcurrentConflict),
            ("Build69 late successor 409 inherits earlier ancestor acknowledgement", lateOwnConflictAfterAcknowledgement),
            ("Build69 late delete retains another chapter's durable edit", deleteOwnership),
            ("Build69 book reads and offline empty contexts retain ownership", bookReadOwnership),
            ("Build69 late book mutations cannot retarget current lists", bookMutationOwnership),
            ("Build69 committed list mutations survive older reads in UI and cold cache", sameResourceListMutationOwnership),
            ("Build69 newest same-resource list reads win without losing full chapter loads", sameResourceListReadOwnership),
            ("Build69 late open cannot reopen closed or newer book", shelfOpenOwnership),
            ("Build69 actual conflict refresh retains book ownership after every read", conflictRefreshOwnership),
            ("Build69 chapter path identity changes synchronously through ABA navigation", chapterNavigationOwnership),
            ("Build69 settings Bool, null unbind and in-place key update are truthful", settingsMutationContracts),
            ("Build69 book persona responses belong to frozen book session", bookPersonaContext),
            ("Build69 inspiration alone outlives regular timeout and keeps frozen inputs", inspirationTimeoutAndStaleness),
            ("Build68 chapter load preserves edits made during GET", loadPreservesNewEdits),
            ("Build68 older load cannot retarget a newer navigation", loadKeepsLatestNavigation),
            ("Build68 late load error cannot mark another chapter offline", lateLoadFailure),
            ("Build68 terminal poll preserves edits made between polls", pollPreservesNewEdits),
            ("Build68 unknown visible Checker start has explicit recovery", unknownVisibleCheckerRecovery),
            ("Build68 explicit conflict decisions preserve subsequent edits", conflictDecisionOwnership),
            ("Build68 keep-local conflict submission can finish synced", conflictKeepLocal),
            ("Build68 preserved draft survives offline revision mismatch", offlineDraftRevisionMismatch),
            ("Build68 server conflict choice survives failed follow-up", serverDecisionReadFailure),
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
            ("Build64 Checker configuration failure opens settings and survives reload", checkerConfigurationStartFailure),
            ("Build64 hidden Checker configuration failure keeps its newer local recovery", hiddenCheckerConfigurationStartFailure),
            ("Build64 unknown Checker start does not adopt an older terminal job", unknownCheckerStartStaysUnconfirmed),
            ("Build66 author actions retain initiating chapter through saves and readiness", actionChapterOwnership),
            ("Build66 later job observations win across observer entrances", latestJobObservationWins),
            ("Build66 late save failure stays with its chapter", lateSaveFailureIsolation),
            ("Build66 retry identity survives overlapping refresh and cold load", hiddenRetryOverlappingRefresh),
            ("Build65 manual verdict retains author acceptance", manualVerdictAllowsAcceptance),
            ("Build65 hidden retry response loss uses read-only recovery", hiddenRetryLostResponse),
            ("Build65 iOS foreground discovers cross-device checks", iosForegroundChecks),
            ("Build65 legacy visible retry flag is ignored", legacyVisibleRetryFlag),
            ("Build65 historical archive errors are readable at every outlet", historicalArchiveErrors),
            ("Build64 obsolete remote Checker outcome clears old evidence", obsoleteRemoteCheckerClearsEvidence),
            ("Build64 remote input invalidates Checker evidence before a failed job read", remoteInputInvalidatesCheckerBeforeJobRead),
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
        let filter = ProcessInfo.processInfo.environment["LINOI_STORE_TEST_FILTER"]
        let selectedTests = filter.map { needle in tests.filter { $0.0.contains(needle) } } ?? tests
        var failures = 0
        for (name, test) in selectedTests {
            do { try await test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name): \(error)") }
        }
        if let suite = ProcessInfo.processInfo.environment["LINOI_DEBUG_DEFAULTS_SUITE"] {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        print("Store HTTP regressions: \(selectedTests.count - failures) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor static func build71SettingsReadOrdering() async throws {
        for model in [false, true] {
            let h = try await Harness("b71-settings-\(model)")
            let agents = AgentSettingsStore(session: h.session, sync: h.sync)
            _ = await agents.loadBookPersonas(bookID: h.book.id)
            _ = await agents.loadBookModelBindings(bookID: h.book.id)
            let route = "/books/" + h.book.id + (model ? "/agent-model-bindings" : "/agent-personas")
            let gateKey = model ? "book_bindings_read_gate" : "book_personas_read_gate"
            let before = try await fixture().requests.filter { $0.path == route && $0.method == "GET" }.count
            _ = try await fixture("config", [gateKey: "old-settings"])
            let old = Task { @MainActor in
                if model { return await agents.loadBookModelBindings(bookID: h.book.id) }
                return await agents.loadBookPersonas(bookID: h.book.id)
            }
            try await eventually("old settings read") { try await fixture().requests.filter { $0.path == route && $0.method == "GET" }.count > before }
            if model {
                h.session.currentBook = try await fixture().other_book
                h.session.currentBook = h.book
                let saved = await agents.saveBookModelBinding(bookID: h.book.id, role: "writer", binding: agents.bookModelBindings[0].effectiveBinding!)
                try check(saved, "model write succeeds")
            } else {
                let saved = await agents.saveBookPersona(bookID: h.book.id, role: "writer", editablePersona: "新保存人格")
                try check(saved, "persona write succeeds")
            }
            _ = try await fixture("release", ["gate": "old-settings"])
            let accepted = await old.value
            try check(!accepted, "old response is rejected")
            try check(model ? agents.bookModelBindings[0].source == "book" : agents.bookPersonas[0].effectivePersona == "新保存人格", "saved settings remain visible")
        }
    }

    @MainActor static func build71EventDeletion() async throws {
        let h = try await Harness("b71-event", ["with_event": true, "event_patch_status": 503])
        let store = CharactersStore(session: h.session, sync: h.sync)
        await store.load(bookId: h.book.id)
        let event = h.character.events[0]
        _ = await store.updateEvent(event, text: "修改事件")
        try check(h.sync.pendingMutations.contains { $0.resourceID == event.id }, "failed update retained")
        h.sync.markOnline()
        let unrelatedBook = try await fixture().other_book
        h.sync.cache.saveBooks([h.book, unrelatedBook])
        let unrelatedRead = h.sync.cache.beginListRead(.characters(unrelatedBook.id))
        await store.deleteEvent(event)
        try check(h.sync.cache.saveCharacters([], bookID: unrelatedBook.id, ifCurrent: unrelatedRead), "deletion leaves unrelated reads valid")
        try check(h.sync.cache.isDeleted(kind: .characterEvent, id: event.id), "deletion tombstone")
        try check(!h.sync.pendingMutations.contains { $0.resourceID == event.id }, "queued patch revoked")
        h.sync.cache.saveCharacters([h.character], bookID: h.book.id)
        try check(h.sync.cache.characters(bookID: h.book.id)[0].events.isEmpty, "late parent snapshot cannot resurrect deleted event")
        let cold = ClientSyncStore(cache: ClientSnapshotCache(root: h.cacheRoot))
        try check(!cold.pendingMutations.contains { $0.resourceID == event.id }, "cold queue remains clear")
    }

    @MainActor static func build71QueuedDeletion() async throws {
        let h = try await Harness("b71-book-delete", ["books_with_rows": true])
        let shelf = BookshelfStore(session: h.session, sync: h.sync)
        let workspace = WorkspaceStore(session: h.session, sync: h.sync)
        let people = CharactersStore(session: h.session, sync: h.sync)
        let agents = AgentSettingsStore(session: h.session, sync: h.sync)
        await workspace.load(bookId: h.book.id)
        try check(h.sync.enqueue(kind: .book, id: h.book.id, path: "/books/" + h.book.id, method: "DELETE", baseRevision: h.book.contentRevision, payload: [String: String](), baseSnapshot: h.book), "queue deletion")
        let applied = await h.sync.flush(using: h.session.api)
        try check(h.sync.cache.isDeleted(kind: .book, id: h.book.id), "book deletion recorded")
        try check(!h.sync.visibleBooks().contains { $0.id == h.book.id }, "deleted book absent from cold cache")
        try check(h.sync.cache.isDeleted(kind: .chapter, id: h.chapters[0].id), "child chapter revoked")
        await V2DeskConflictRefresh.run(applied, session: h.session, bookshelf: shelf, workspace: workspace, editor: h.editor, characters: people, agents: agents)
        try check(h.session.currentBook == nil, "deleted current book is closed")
    }

    @MainActor static func build71OfflineWriter() async throws {
        let h = try await Harness("b71-offline-writer", ["writing": true])
        let newText = "已经完成的新正文。"
        _ = try await fixture("config", ["remote_draft_text": newText, "job_phase": "done", "job_advances_revision": true])
        _ = await h.editor.refreshTaskStatus()
        try check(h.editor.currentChapter?.draftText == newText, "terminal writer displays new prose")
        try check(h.sync.cache.chapter(id: h.chapters[0].id)?.draftText == newText, "terminal chapter persisted to reading cache")
        try check(h.editor.resetBookContext(), "close chapter")
        _ = try await fixture("config", ["get_status": 503])
        await h.load(0)
        try check(h.editor.currentChapter?.draftText == newText, "offline reopen preserves completed prose")
    }

    @MainActor static func build70RefreshOwnership() async throws {
        for navigate in [true, false] {
            let h = try await Harness("refresh70")
            let before = try await fixture().requests.filter { $0.path == "/chapters/" + h.chapters[0].id }.count
            _ = try await fixture("config", ["job_phase": "failed", "job_kind": "write", "get_gate": "refresh-old"])
            await h.editor.refreshActiveJobIfNeeded()
            try await eventually("failure's chapter refresh held") {
                try await fixture().requests.filter { $0.path == "/chapters/" + h.chapters[0].id }.count > before
            }
            _ = try await fixture("config", ["get_gate": "", "job_phase": "idle", "remote_draft_text": "最新服务器正文。"])
            if navigate { await h.load(1) }
            await h.load(0)
            _ = await h.editor.rerunChecker()
            let text = h.editor.currentChapter!.draftText
            let revision = h.editor.currentChapter!.contentRevision
            let checker = h.editor.checkerResult
            _ = try await fixture("release", ["gate": "refresh-old"])
            try await Task.sleep(nanoseconds: 120_000_000)
            try check(h.editor.currentChapter?.draftText == text && h.editor.currentChapter?.contentRevision == revision,
                      "obsolete refresh cannot roll the current editor backward")
            try check(h.editor.checkerResult == checker && h.editor.checkerAppliesToVisibleDraft,
                      "obsolete refresh cannot discard the newest Checker evidence")
        }
        let h = try await Harness("refresh70-normal")
        _ = try await fixture("config", ["job_phase": "failed", "job_kind": "write", "remote_draft_text": "真实当前刷新内容。"])
        await h.editor.refreshActiveJobIfNeeded()
        try await eventually("current failure refresh still synchronizes") { h.editor.currentChapter?.draftText == "真实当前刷新内容。" }
        try check(h.editor.saveState == .synced, "normal owned refresh must remain usable")
    }

    @MainActor static func build70SettingsScopes() async throws {
        let h = try await Harness("settings70-scopes")
        let state = try await fixture()
        h.sync.upsertBook(state.other_book)
        let settings = AgentSettingsStore(session: h.session, sync: h.sync)
        await settings.load()
        _ = try await fixture("config", ["settings_status": 409, "strict_settings_revisions": true])
        for book in [h.book, state.other_book] {
            h.session.currentBook = book
            _ = await settings.loadBookPersonas(bookID: book.id)
            _ = await settings.saveBookPersona(bookID: book.id, role: "writer", editablePersona: "人格：" + book.id)
            _ = await settings.loadBookModelBindings(bookID: book.id)
            let values = AgentModelBindingValues(llmProfileId: settings.profiles[0].id, thinkingEnabled: false, reasoningEffort: nil, temperature: 0.7)
            _ = await settings.saveBookModelBinding(bookID: book.id, role: "writer", binding: values)
        }
        var global = settings.personas[0]
        global.editablePersona = "全局人格修改"
        _ = await settings.savePersona(global)
        await settings.bind(role: "writer", profileId: nil)
        try check(h.sync.conflicts.count == 6, "two books and global Writer/persona bindings are six distinct resources")
        let cold = ClientSyncStore(cache: ClientSnapshotCache(root: h.cacheRoot), notices: h.notices)
        try check(cold.conflicts.count == 6 && Set(cold.conflicts.map(\.identity)).count == 6,
                  "legacy path-based scope identity must survive a cold cache decode")
        try check(cold.conflict(for: .agentPersona, id: "writer", bookID: h.book.id) != nil,
                  "book-scoped conflict queries use exact scope")
        guard let chosen = cold.conflict(for: .agentPersona, id: "writer", bookID: h.book.id) else { return }
        try check(cold.resourceLabel(for: chosen).contains(h.book.title) && cold.resourceLabel(for: chosen).contains("writer"),
                  "conflict display identifies book and role")
        let others = Set(cold.conflicts.filter { $0.id != chosen.id }.map(\.id))
        try check(cold.keepLocal(chosen), "author can retain this book's persona")
        _ = try await fixture("config", ["settings_status": 200])
        let applied = await cold.flush(using: h.session.api)
        try check(applied.count == 1 && cold.pendingMutations.isEmpty,
                  "successful book persona is acknowledged exactly once")
        try check(Set(cold.conflicts.map(\.id)) == others,
                  "resolving book A cannot clear book B or global input")
        let remaining = cold.conflicts[0]
        cold.keepServer(remaining)
        try check(cold.conflicts.count == 4, "explicit server choice removes only one exact scoped conflict")
        guard let binding = cold.conflict(for: .modelBinding, id: "writer", bookID: state.other_book.id) else {
            throw HTTPTestFailure(description: "other book binding must still exist")
        }
        try check(cold.keepLocal(binding), "other book can retry its own binding")
        _ = try await fixture("config", ["settings_response": "wrong_scope"])
        let wrongScope = await cold.flush(using: h.session.api)
        try check(wrongScope.isEmpty && cold.pendingMutations.count == 1, "global response cannot acknowledge a book override")
        try check(cold.retry(cold.pendingMutations[0]), "invalid scope remains recoverable")
        _ = try await fixture("config", ["settings_response": ""])
        _ = await cold.flush(using: h.session.api)
        guard let unconfirmed = cold.conflict(for: .modelBinding, id: "writer", bookID: state.other_book.id) else {
            throw HTTPTestFailure(description: "unknown committed response requires exact server comparison")
        }
        try check(cold.keepLocal(unconfirmed), "author resolves the uncertain scoped response")
        let validScope = await cold.flush(using: h.session.api)
        try check(validScope.count == 1 && cold.pendingMutations.isEmpty && cold.conflicts.count == 3,
                  "correct book response clears only the exact pending override")
        let unknown = PendingMutation(id: UUID(), resourceKind: .agentPersona, resourceID: "writer",
            path: "/legacy-persona/writer", method: "PATCH", readPath: "/legacy-persona/writer", readStrategy: .direct,
            baseRevision: 7, payload: Data("{\"editable_persona\":\"旧稿\"}".utf8), baseSnapshot: Data("{}".utf8), createdAt: Date())
        let isolatedCache = ClientSnapshotCache(root: h.cacheRoot.appendingPathComponent("unknown-scope"))
        try check(isolatedCache.saveMutations([unknown]), "legacy unknown record saved for recovery test")
        let unresolved = ClientSyncStore(cache: isolatedCache)
        let dispatched = await unresolved.flush(using: h.session.api)
        try check(dispatched.isEmpty && unresolved.pendingMutations.first?.id == unknown.id
                  && unresolved.pendingMutations.first?.failure?.code == "sync_scope_unresolved",
                  "unresolvable legacy scope remains visible and never guesses a request")
    }

    @MainActor static func build70SettingsSuccess() async throws {
        for kind in [SyncResourceKind.agentPersona, .modelBinding, .llmProfile] {
            let h = try await Harness("settings70-success")
            let settings = AgentSettingsStore(session: h.session, sync: h.sync)
            await settings.load()
            _ = try await fixture("config", ["settings_status": 409, "strict_settings_revisions": true])
            switch kind {
            case .agentPersona:
                var value = settings.personas[0]; value.editablePersona = "作者新人格"
                _ = await settings.savePersona(value)
            case .modelBinding: await settings.bind(role: "writer", profileId: nil)
            case .llmProfile:
                var value = settings.profiles[0]; value.name = "作者新配置名"
                _ = await settings.updateProfile(value, apiKey: nil)
            default: break
            }
            guard let conflict = h.sync.conflicts.first else { throw HTTPTestFailure(description: "settings conflict missing") }
            try check(h.sync.keepLocal(conflict), "public settings payload can retry")
            _ = try await fixture("config", ["settings_status": 200, "settings_response": "wrong_id"])
            let invalid = await h.sync.flush(using: h.session.api)
            try check(invalid.isEmpty && h.sync.pendingMutations.count == 1, "wrong resource cannot acknowledge saved settings")
            try check(h.sync.retry(h.sync.pendingMutations[0]), "failed payload can explicitly retry")
            _ = try await fixture("config", ["settings_response": ""])
            _ = await h.sync.flush(using: h.session.api)
            guard let uncertain = h.sync.conflicts.first else { throw HTTPTestFailure(description: "unknown committed response must compare current server revision") }
            try check(h.sync.keepLocal(uncertain), "explicit comparison resolves malformed/wrong-id response uncertainty")
            let applied = await h.sync.flush(using: h.session.api)
            try check(applied.count == 1 && h.sync.pendingMutations.isEmpty && h.sync.conflicts.isEmpty,
                      "valid settings success must finish instead of inventing a permanent failure")
            let cold = ClientSyncStore(cache: ClientSnapshotCache(root: h.cacheRoot))
            try check(cold.pendingMutations.isEmpty && cold.conflicts.isEmpty, "acknowledgement survives restart")
            await settings.load()
            if kind == .agentPersona { try check(settings.personas[0].editablePersona == "作者新人格", "visible persona refreshes") }
            if kind == .llmProfile { try check(settings.profiles[0].name == "作者新配置名", "visible profile refreshes") }
        }
        let h = try await Harness("settings70-secret")
        let settings = AgentSettingsStore(session: h.session, sync: h.sync)
        await settings.load()
        _ = try await fixture("config", ["settings_status": 409])
        var profile = settings.profiles[0]; profile.name = "需重新输入密钥的配置"
        _ = await settings.updateProfile(profile, apiKey: "synthetic-memory-only-key")
        guard let conflict = h.sync.conflicts.first else { throw HTTPTestFailure(description: "secret-reentry conflict missing") }
        try check(conflict.requiresSecretReentry && !h.sync.keepLocal(conflict), "new credentials require explicit memory-only re-entry")
        try check(!String(data: conflict.localPayload, encoding: .utf8)!.contains("synthetic-memory-only-key"),
                  "conflict persistence never retains the entered secret")
    }

    @MainActor static func seedExportRows(_ h: Harness) throws {
        let rows = try h.chapters.map { try JSONDecoder.lino.decode(ChapterSummary.self, from: JSONEncoder.lino.encode($0)) }
        h.sync.cache.saveChapters(rows, bookID: h.book.id)
    }

    @MainActor static func build70ExportPreflight() async throws {
        let h = try await Harness("export70")
        try seedExportRows(h)
        let shelf = BookshelfStore(session: h.session, sync: h.sync)
        let selected = ExportSelection.prose(scope: .current, currentChapterID: h.chapters[0].id, includeWorldview: false, includeCharacters: false)
        h.editor.editString(\.draftText, value: "本机作者新稿。")
        try check(h.editor.persistLocalDraftIfNeeded(), "in-memory export snapshot is persisted")
        let build70Assertion1 = await shelf.exportProject(h.book) == nil
        try check(build70Assertion1, "full backup cannot omit current local draft")
        let build70Assertion2 = !(try await fixture().requests.contains { $0.path.hasSuffix("/project-export") })
        try check(build70Assertion2, "preflight blocks before exporting stale data")
        _ = await h.editor.save()
        let build70Assertion3 = await shelf.exportProject(h.book) != nil
        try check(build70Assertion3, "save without generation/check/accept makes project backup usable")
        await h.load(1)
        h.editor.editString(\.draftText, value: "另一章的冷草稿。")
        try check(h.editor.persistLocalDraftIfNeeded(), "other chapter dirty draft is durable")
        await h.load(0)
        let build70Assertion4 = await shelf.exportProject(h.book) == nil
        try check(build70Assertion4, "cold non-current dirty chapter prevents incomplete backup")
        let build70Assertion5 = await shelf.exportData(h.book, selection: selected) != nil
        try check(build70Assertion5, "current-only export ignores unrelated unaccepted chapter")
        let other = try await fixture().other_book
        let build70Assertion6 = await shelf.exportProject(other) != nil
        try check(build70Assertion6, "another book's drafts do not block export")
        await h.load(1); _ = await h.editor.save(); await h.load(0)
        let payload = ["title": "待同步标题", "world_setting": "待同步世界观"]
        try check(h.sync.enqueue(kind: .book, id: h.book.id, path: "/books/" + h.book.id, method: "PATCH",
                                 baseRevision: h.book.contentRevision, payload: payload, baseSnapshot: h.book), "book pending entered")
        let build70Assertion7 = await shelf.exportProject(h.book) == nil
        try check(build70Assertion7, "pending book edits cannot be omitted")
        _ = await h.sync.flush(using: h.session.api)
        let build70Assertion8 = await shelf.exportProject(h.book) != nil
        try check(build70Assertion8, "syncing local intent unblocks backup")
        let eventBase = ["id": "cold-event", "character_id": h.character.id, "event_text": "旧记录"]
        try check(h.sync.enqueue(kind: .characterEvent, id: "cold-event", path: "/character-events/cold-event", method: "PATCH",
                                 baseRevision: 7, payload: ["event_text": "待同步记录"], baseSnapshot: eventBase), "cold event pending admitted")
        do { _ = try shelf.prepareExport(bookID: h.book.id, selection: .project); throw HTTPTestFailure(description: "cold character event was omitted") }
        catch is HTTPTestFailure { throw HTTPTestFailure(description: "cold character event was omitted") }
        catch { }
        h.sync.confirmDeletion(kind: .characterEvent, id: "cold-event") // Isolated fixture cleanup, no business deletion.
        try check(h.sync.enqueue(kind: .chapter, id: "unknown-cold-chapter", path: "/chapters/unknown-cold-chapter", method: "PATCH",
                                 baseRevision: 7, payload: ["draft_text": "仅队列留存的作者稿。"], baseSnapshot: ["draft_text": "旧稿。"]), "unknown-owner pending retained")
        do { _ = try shelf.prepareExport(bookID: h.book.id, selection: .project); throw HTTPTestFailure(description: "unknown-owner pending was omitted") }
        catch is HTTPTestFailure { throw HTTPTestFailure(description: "unknown-owner pending was omitted") }
        catch { }
        _ = try shelf.prepareExport(bookID: h.book.id, selection: selected)
        h.sync.confirmDeletion(kind: .chapter, id: "unknown-cold-chapter") // This invocation's isolated pending-only fixture.
        _ = try await fixture("config", ["patch_status": 409, "remote_draft_text": "另一设备的正文。"])
        h.editor.editString(\.draftText, value: "明确冲突的本机稿。")
        _ = await h.editor.save()
        let build70Assertion9 = await shelf.exportData(h.book, selection: selected) == nil && !h.sync.conflicts.isEmpty
        try check(build70Assertion9,
                  "explicit prose conflict blocks stale selected export")
    }

    @MainActor static func build70ExportRace() async throws {
        let h = try await Harness("export70-race")
        try seedExportRows(h)
        let shelf = BookshelfStore(session: h.session, sync: h.sync)
        let receipt = try shelf.prepareExport(bookID: h.book.id, selection: .project)
        try check(ChapterDraftCache().saveClean(h.editor.currentChapter!), "same-text clean cache refresh")
        try shelf.validateExport(receipt)
        _ = try await fixture("config", ["export_gate": "export-held"])
        let exporting = Task { await shelf.exportProject(h.book) }
        try await eventually("export response captured") { try await fixture().requests.contains { $0.path.hasSuffix("/project-export") } }
        h.editor.editString(\.draftText, value: "等待导出期间新增的文字。")
        try check(h.editor.persistLocalDraftIfNeeded(), "late input gets its recovery file")
        _ = try await fixture("release", ["gate": "export-held"])
        let build70Assertion10 = await exporting.value == nil
        try check(build70Assertion10, "network completion cannot output an already stale project snapshot")
        do { try shelf.validateExport(receipt); throw HTTPTestFailure(description: "receipt wrongly remained valid") }
        catch is HTTPTestFailure { throw HTTPTestFailure(description: "receipt wrongly remained valid") }
        catch { }
        try check(h.editor.currentChapter?.draftText == "等待导出期间新增的文字。", "export failure preserves author input")
    }

    @MainActor static func build70DeletionRevocation() async throws {
        for outcome in [200, 422, 409] {
            let h = try await Harness("delete70-late")
            let chapter = h.chapters[0]
            try check(h.sync.enqueue(kind: .chapter, id: chapter.id, path: "/chapters/" + chapter.id, method: "PATCH",
                                     baseRevision: chapter.contentRevision, payload: ["draft_text": "待同步版本。"], baseSnapshot: chapter), "pending chapter admitted")
            let options: [String: Any] = outcome == 200
                ? ["patch_response_gate": "old-patch", "patch_status": 200]
                : ["patch_failure_gate": "old-patch", "patch_status": outcome]
            _ = try await fixture("config", options)
            let flushing = Task { await h.sync.flush(using: h.session.api) }
            try await eventually("old patch admitted") { try await fixture().requests.contains { $0.method == "PATCH" } }
            if outcome == 200 {
                // PATCH committed before its reply; DELETE observes that
                // committed revision, then revokes the held acknowledgement.
                let remote: Chapter = try await h.session.api.request("/chapters/" + chapter.id)
                _ = try await h.session.api.rawRequest("/chapters/" + chapter.id, method: "DELETE", ifMatch: remote.contentRevision)
                h.sync.confirmDeletion(kind: .chapter, id: chapter.id)
                h.sync.cache.removeChapter(id: chapter.id, bookID: chapter.bookId)
            } else {
                let build70Assertion11 = await h.editor.deleteCurrentChapter()
                try check(build70Assertion11, "actual editor DELETE succeeds before late refusal")
            }
            _ = try await fixture("release", ["gate": "old-patch"])
            let applied = await flushing.value
            try check(applied.isEmpty && h.sync.pendingMutations.isEmpty && h.sync.conflicts.isEmpty,
                      "late success/failure/conflict must not resurrect a confirmed deleted resource")
            try check(h.sync.cache.chapter(id: chapter.id) == nil, "late success cannot restore deleted chapter cache")
            let cold = ClientSyncStore(cache: ClientSnapshotCache(root: h.cacheRoot))
            try check(cold.pendingMutations.isEmpty && cold.conflicts.isEmpty && cold.cache.isDeleted(kind: .chapter, id: chapter.id),
                      "deletion revocation survives restart")
            try check(h.sync.cache.chapter(id: h.chapters[1].id) != nil, "delete A preserves B")
        }
        let h = try await Harness("delete70-pending")
        h.editor.editString(\.draftText, value: "冲突删除的本机稿。")
        _ = try await fixture("config", ["patch_status": 409])
        _ = await h.editor.save()
        try check(!h.sync.conflicts.isEmpty, "conflict exists before delete")
        let build70Assertion12 = await h.editor.deleteCurrentChapter()
        try check(build70Assertion12, "explicit confirmed deletion owns that conflict")
        try check(h.sync.conflicts.isEmpty && h.sync.pendingMutations.isEmpty, "successful delete removes exact conflict and queue")
        let followup = try await Harness("delete70-conflict-read")
        let chapter = followup.chapters[0]
        try check(followup.sync.enqueue(kind: .chapter, id: chapter.id, path: "/chapters/" + chapter.id, method: "PATCH",
                                       baseRevision: 7, payload: ["draft_text": "比较中的稿。"], baseSnapshot: chapter), "comparison payload admitted")
        _ = try await fixture("config", ["patch_status": 409, "get_gate": "old-conflict-read"])
        let flushing = Task { await followup.sync.flush(using: followup.session.api) }
        let initialReads = 1
        try await eventually("old conflict read is held") {
            try await fixture().requests.filter { $0.path == "/chapters/" + chapter.id && $0.method == "GET" }.count > initialReads
        }
        let deleted = await followup.editor.deleteCurrentChapter()
        try check(deleted, "delete succeeds while conflict GET is held")
        _ = try await fixture("release", ["gate": "old-conflict-read"])
        _ = await flushing.value
        try check(followup.sync.conflicts.isEmpty && followup.sync.pendingMutations.isEmpty,
                  "late comparison snapshot cannot recreate deleted conflict")
        followup.sync.cache.saveChapter(chapter)
        let row = try JSONDecoder.lino.decode(ChapterSummary.self, from: JSONEncoder.lino.encode(chapter))
        followup.sync.cache.saveChapters([row], bookID: chapter.bookId)
        try check(followup.sync.cache.chapter(id: chapter.id) == nil && followup.sync.cache.chapters(bookID: chapter.bookId).isEmpty,
                  "older detail and list snapshots cannot revive tombstoned membership")
    }

    @MainActor static func build70DeletionRecovery() async throws {
        let h = try await Harness("delete70-failed")
        try check(h.sync.enqueue(kind: .chapter, id: h.chapters[0].id, path: "/chapters/" + h.chapters[0].id, method: "PATCH",
                                 baseRevision: 7, payload: ["draft_text": "不可丢的本机稿。"], baseSnapshot: h.chapters[0]), "pending source exists")
        _ = try await fixture("config", ["delete_status": 503])
        let build70Assertion13 = !(await h.editor.deleteCurrentChapter())
        try check(build70Assertion13, "failed delete remains failed")
        try check(h.sync.pendingMutations.count == 1 && !h.sync.cache.isDeleted(kind: .chapter, id: h.chapters[0].id),
                  "failed DELETE must preserve pending edit")
        _ = try await fixture("config", ["delete_status": 204, "delete_gate": "delete-new-input"])
        let deleting = Task { await h.editor.deleteCurrentChapter() }
        try await eventually("delete waiting") { try await fixture().requests.filter { $0.method == "DELETE" }.count >= 2 }
        h.editor.editString(\.draftText, value: "删除期间的新输入。")
        _ = try await fixture("release", ["gate": "delete-new-input"])
        let build70Assertion14 = await deleting.value
        try check(build70Assertion14, "server deletion is confirmed")
        try check(ChapterDraftCache().load(chapterId: h.chapters[0].id)?.draftText == "删除期间的新输入。",
                  "new input outside delete snapshot is kept as recovery draft")
        let build70Assertion15 = await h.editor.save() == nil && h.sync.pendingMutations.isEmpty
        try check(build70Assertion15,
                  "deleted ID cannot queue new input into an endless 404 loop")
        try check(h.notices.history.contains { $0.message.contains("原章节已删除") }, "recovery location is explained")
    }

    @MainActor static func build70RetainedRecovery() async throws {
        let h = try await Harness("retained70")
        try seedExportRows(h)
        let drafts = ChapterDraftCache()
        let original = h.chapters[0]
        let otherBook = try await fixture().other_book
        var otherObject = try JSONSerialization.jsonObject(with: JSONEncoder.lino.encode(original)) as! [String: Any]
        otherObject["id"] = otherBook.id + "-retained"
        otherObject["book_id"] = otherBook.id
        otherObject["title"] = "另一书保留稿"
        otherObject["draft_text"] = "另一书不可误删的文字。"
        let other = try JSONDecoder.lino.decode(Chapter.self, from: JSONSerialization.data(withJSONObject: otherObject))
        try check(drafts.saveDirty(other, bookTitle: otherBook.title), "other retained copy exists")
        h.sync.confirmDeletion(kind: .chapter, id: other.id)

        _ = try await fixture("config", ["delete_gate": "retain-full-input"])
        let deleting = Task { await h.editor.deleteCurrentChapter() }
        try await eventually("deleted draft source is frozen") { try await fixture().requests.contains { $0.method == "DELETE" } }
        h.editor.editString(\.title, value: "作者新标题")
        h.editor.editString(\.userPrompt, value: "作者完整 Bible\n含原始换行。")
        h.editor.editString(\.authorNote, value: "作者备注不能丢。")
        h.editor.editString(\.draftText, value: "删除等待期间的新正文。\n第二段也要保留。")
        _ = try await fixture("release", ["gate": "retain-full-input"])
        let deleted = await deleting.value
        try check(deleted && h.sync.hasRetainedChapterDrafts && h.sync.pendingMutations.isEmpty,
                  "deleted new input remains reachable without pending work")
        let visible = h.editor.currentChapter!
        let before = try await fixture().requests.count
        let cold = ClientSyncStore(cache: ClientSnapshotCache(root: h.cacheRoot))
        // The original book may also disappear; the draft owns its frozen
        // label rather than needing a new server/cache chapter to recover.
        cold.cache.saveBooks([])
        let copies = try cold.retainedChapterDrafts()
        guard let copy = copies.first(where: { $0.chapterID == original.id }) else {
            throw HTTPTestFailure(description: "cold recovery copy missing")
        }
        try check(cold.hasRetainedChapterDrafts && cold.pendingMutations.isEmpty && copies.count == 2,
                  "cold online Store has a recovery entry and only tombstoned dirty candidates")
        try check(copy.bookID == h.book.id && copy.bookTitle == h.book.title && copy.chapterIndex == original.index
                  && copy.chapterTitle == visible.title && copy.draftText == visible.draftText
                  && copy.userPrompt == visible.userPrompt && copy.authorNote == visible.authorNote,
                  "original source labels and all author input survive cold recovery")
        try check(copy.copyText.contains(visible.title) && copy.copyText.contains(visible.userPrompt)
                  && copy.copyText.contains(visible.authorNote) && copy.copyText.contains(visible.draftText)
                  && !copy.copyText.contains(original.id), "full copy includes all input without internal IDs")
        let afterRead = try await fixture().requests.count
        try check(afterRead == before && cold.cache.chapter(id: original.id) == nil,
                  "enumerating and preparing copy never writes old ID or restores server baseline")
        let shelf = BookshelfStore(session: h.session, sync: h.sync)
        let blocked = await shelf.exportProject(h.book)
        try check(blocked == nil && h.notices.history.contains { $0.message.contains("同步中心 → 本机保留稿") },
                  "retained copy blocks omission and gives a reachable action")

        // A different on-disk identity/content must reject the displayed CAS.
        var updated = visible
        updated.authorNote = "外部保存的更新备注。"
        try check(drafts.saveDirty(updated, bookTitle: h.book.title), "updated recovery file saved")
        var rejected = false
        do { try cold.removeRetainedChapterDraft(copy) } catch { rejected = true }
        try check(rejected && drafts.load(chapterId: original.id)?.authorNote == updated.authorNote,
                  "stale displayed file cannot delete newer on-disk input")
        let sameContentCopy = try cold.retainedChapterDrafts().first { $0.chapterID == original.id }!
        let identityFile = DebugRuntimeConfiguration.dataRoot!.appendingPathComponent("ChapterDrafts")
            .appendingPathComponent(original.id + ".json")
        let identicalBytes = try Data(contentsOf: identityFile)
        try identicalBytes.write(to: identityFile, options: .atomic)
        rejected = false
        do { try cold.removeRetainedChapterDraft(sameContentCopy) } catch { rejected = true }
        let remainingBytes = try Data(contentsOf: identityFile)
        try check(rejected && remainingBytes == identicalBytes,
                  "even identical replacement bytes require a freshly displayed file identity")

        // An in-memory edit is also newer than the last displayed file.
        h.editor.editString(\.authorNote, value: "编辑器里更新的备注。")
        rejected = false
        do { try h.editor.removeRetainedChapterDraft(copy) } catch { rejected = true }
        try check(rejected && h.editor.currentChapter?.authorNote == "编辑器里更新的备注。"
                  && drafts.load(chapterId: original.id)?.authorNote == "编辑器里更新的备注。",
                  "completion preserves and refuses later in-memory author input")
        let latest = try h.sync.retainedChapterDrafts().first { $0.chapterID == original.id }!
        let requestBeforeRemoval = try await fixture().requests.count
        try h.editor.removeRetainedChapterDraft(latest)
        try check(h.editor.currentChapter == nil && h.editor.persistLocalDraftIfNeeded()
                  && drafts.load(chapterId: original.id) == nil,
                  "same-page confirmed completion retires editor without recreating the copy")
        try check(h.sync.cache.isDeleted(kind: .chapter, id: original.id)
                  && drafts.load(chapterId: other.id)?.draftText == other.draftText
                  && h.sync.cache.chapter(id: h.chapters[1].id) != nil,
                  "completion preserves tombstone, another book's copy and normal chapters")
        let afterRemoval = try await fixture().requests.count
        try check(afterRemoval == requestBeforeRemoval && h.sync.pendingMutations.isEmpty,
                  "completion never PATCHes deleted ID or calls a model")
        let exported = await shelf.exportProject(h.book)
        try check(exported != nil, "normal export preflight recovers after precise explicit completion")

        // Completing another book's copy cannot clear the current normal/new
        // chapter, even if it has author input not yet saved.
        await h.load(1)
        h.editor.editString(\.draftText, value: "新章节自己的输入。")
        let otherCopy = try h.sync.retainedChapterDrafts().first { $0.chapterID == other.id }!
        try h.editor.removeRetainedChapterDraft(otherCopy)
        try check(h.editor.currentChapter?.id == h.chapters[1].id
                  && h.editor.currentChapter?.draftText == "新章节自己的输入。"
                  && !h.sync.hasRetainedChapterDrafts, "completing another copy preserves current chapter")
        await h.load(0) // Deleted source cannot be restored by an old summary.
        try check(h.sync.cache.chapter(id: original.id) == nil && drafts.load(chapterId: original.id) == nil,
                  "deleted source still cannot resurrect after completion")

        // Malformed retained bytes remain discoverable as a load failure.
        let draftRoot = DebugRuntimeConfiguration.dataRoot!.appendingPathComponent("ChapterDrafts")
        let file = draftRoot.appendingPathComponent(original.id + ".json")
        try Data("{malformed author file".utf8).write(to: file, options: .atomic)
        let unreadable = ClientSyncStore(cache: ClientSnapshotCache(root: h.cacheRoot))
        rejected = false
        do { _ = try unreadable.retainedChapterDrafts() } catch { rejected = true }
        try check(unreadable.hasRetainedChapterDrafts && rejected && FileManager.default.fileExists(atPath: file.path),
                  "read failure is not misrepresented as no local copies")
        try FileManager.default.removeItem(at: file) // Exact owned synthetic malformed fixture.

        var legacy = LocalChapterDraft(chapter: original, dirty: true)
        legacy.bookID = nil; legacy.bookTitle = nil; legacy.chapterIndex = nil
        try JSONEncoder().encode(legacy).write(to: file, options: .atomic)
        let legacyCopy = try unreadable.retainedChapterDrafts().first!
        try check(legacyCopy.bookID == nil && legacyCopy.bookTitle == "原书信息不可用"
                  && legacyCopy.chapterIndex == nil, "missing old ownership is not guessed")
        try unreadable.removeRetainedChapterDraft(legacyCopy)
        rejected = false
        do { try unreadable.removeRetainedChapterDraft(legacyCopy) } catch { rejected = true }
        try check(rejected && unreadable.cache.isDeleted(kind: .chapter, id: original.id),
                  "missing-file removal cannot report success or clear tombstone")

        // The usual recovery route uses a genuinely new chapter and its real
        // save action, with no special acceptance/checking exemption.
        let recovery = try await Harness("retained70-new-chapter")
        try seedExportRows(recovery)
        _ = try await fixture("config", ["delete_gate": "new-chapter-source"])
        let deleteSource = Task { await recovery.editor.deleteCurrentChapter() }
        try await eventually("new chapter recovery source waiting") { try await fixture().requests.contains { $0.method == "DELETE" } }
        recovery.editor.editString(\.draftText, value: "要另存到新章节的正文。")
        recovery.editor.editString(\.userPrompt, value: "需要恢复的 Bible。")
        recovery.editor.editString(\.authorNote, value: "需要恢复的作者备注。")
        _ = try await fixture("release", ["gate": "new-chapter-source"])
        let sourceDeleted = await deleteSource.value
        try check(sourceDeleted, "recovery source deletion succeeds")
        let source = try recovery.sync.retainedChapterDrafts().first!
        let workspace = WorkspaceStore(session: recovery.session, sync: recovery.sync)
        await workspace.load(bookId: recovery.book.id)
        guard let newChapter = await workspace.createChapter() else {
            throw HTTPTestFailure(description: "explicit new chapter failed")
        }
        await recovery.editor.load(newChapter)
        recovery.editor.editString(\.title, value: source.chapterTitle)
        recovery.editor.editString(\.draftText, value: source.draftText)
        recovery.editor.editString(\.userPrompt, value: source.userPrompt)
        recovery.editor.editString(\.authorNote, value: source.authorNote)
        let saved = await recovery.editor.save()
        try check(saved?.draftText == source.draftText && saved?.userPrompt == source.userPrompt
                  && saved?.authorNote == source.authorNote && saved?.id != source.chapterID,
                  "explicit new chapter saves all recovered input through ordinary Store")
        let reloaded: Chapter = try await recovery.session.api.request("/chapters/" + newChapter.id)
        let patch = try await fixture().requests.first { $0.method == "PATCH" && $0.path == "/chapters/" + newChapter.id }!
        let sent = try JSONSerialization.jsonObject(with: Data(patch.bodyText.utf8)) as! [String: Any]
        try check(sent["author_note"] as? String == source.authorNote && reloaded.authorNote == source.authorNote
                  && reloaded.draftText == source.draftText && reloaded.userPrompt == source.userPrompt,
                  "ordinary PATCH and subsequent independent read both preserve recovered notes")
        let completedSource = try recovery.sync.retainedChapterDrafts().first { $0.chapterID == source.chapterID }!
        try recovery.editor.removeRetainedChapterDraft(completedSource)
        let restoredShelf = BookshelfStore(session: recovery.session, sync: recovery.sync)
        let restoredBackup = await restoredShelf.exportProject(recovery.book)
        let requests = try await fixture().requests
        try check(restoredBackup != nil && recovery.editor.currentChapter?.id == newChapter.id
                  && drafts.load(chapterId: source.chapterID) == nil,
                  "explicit completion restores full backup while preserving the new chapter")
        try check(!requests.contains { $0.method == "PATCH" && $0.path == "/chapters/" + source.chapterID }
                  && !requests.contains { $0.path.hasSuffix("/write") || $0.path.hasSuffix("/check") },
                  "manual recovery never writes deleted source or asks a model")
    }

    @MainActor static func build70BookOverlay() async throws {
        let h = try await Harness("book70-overlay")
        let workspace = WorkspaceStore(session: h.session, sync: h.sync)
        await workspace.load(bookId: h.book.id)
        h.session.baseURL = "http://127.0.0.1:1"
        let build70Assertion16 = !(await workspace.saveBook(title: "离线作者新书名", world: "离线作者新世界观"))
        try check(build70Assertion16, "offline direct save is not server success")
        let cold = ClientSyncStore(cache: ClientSnapshotCache(root: h.cacheRoot))
        let coldSession = AppSession(notices: h.notices)
        coldSession.baseURL = "http://127.0.0.1:1"; coldSession.token = "synthetic-test-token"
        let shelf = BookshelfStore(session: coldSession, sync: cold)
        try check(shelf.books[0].title == "离线作者新书名" && cold.cache.books()[0].title == h.book.title,
                  "cold shelf overlays author intent without corrupting baseline")
        await shelf.open(h.book)
        try check(coldSession.currentBook?.worldSetting == "离线作者新世界观", "cold open shows local worldview")
        coldSession.baseURL = ProcessInfo.processInfo.environment["LINOI_DEBUG_BASE_URL"]!
        await shelf.open(h.book)
        try check(coldSession.currentBook?.title == "离线作者新书名", "fresh server read cannot hide a pending book edit")
        _ = await cold.flush(using: coldSession.api)
        await shelf.open(h.book)
        try check(cold.pendingMutations.isEmpty && cold.cache.books()[0].title == "离线作者新书名"
                  && coldSession.currentBook?.worldSetting == "离线作者新世界观", "successful sync refreshes baseline and drops overlay")
    }

    @MainActor static func build70InspirationNavigation() async throws {
        for success in [true, false] {
            let h = try await Harness("inspiration70-aba", ["inspirations_delay": 0.2, "inspiration_success": success])
            let store = InspirationCreatorStore(session: h.session)
            store.pacingBoundary = "初始边界"; store.generate(for: h.chapters[0])
            try await eventually("old inspiration starts") { try await fixture().requests.contains { $0.path.hasSuffix("/inspirations") } }
            store.clearIfChapterChanged(to: h.chapters[1].id)
            store.clearIfChapterChanged(to: h.chapters[0].id)
            store.pacingBoundary = "返回后的新边界"
            try await Task.sleep(nanoseconds: 350_000_000)
            try check(store.cards.isEmpty && store.snapshot == nil && store.errorMessage == nil,
                      "departed request cannot re-enter the same-ID panel after ABA")
            if !success { try check(h.notices.history.contains { $0.message.contains("灵感生成未完成") }, "departed failure still enters global history") }
            let before = try await fixture().requests.count
            store.clearIfChapterChanged(to: h.chapters[0].id)
            let build70Assertion17 = try await fixture().requests.count == before
            try check(build70Assertion17, "navigation never implicitly calls a model")
        }
    }

    @MainActor static func queuedResponseOwnership() async throws {
        for outcome in [200, 409, 422, 0] {
            let gate = "queue-" + String(outcome)
            let h = try await Harness("generation", ["strict_revisions": true])
            _ = try await fixture("config", outcome == 200
                ? ["patch_response_gate": gate]
                : ["patch_failure_gate": gate, "patch_status": outcome == 0 ? 200 : outcome,
                   "patch_lost": outcome == 0, "patch_only_first": true])
            try h.enqueue(0, text: "旧版本A")
            let sent = h.sync.pendingMutations[0]
            let flushing = Task { await h.sync.flush(using: h.session.api) }
            try await eventually("frozen queued PATCH") { try await fixture().requests.contains { $0.method == "PATCH" } }
            try h.enqueue(0, text: "最新版本B")
            try h.enqueue(1, text: "独立章节")
            let successor = h.sync.pendingMutations[0]
            try check(successor.id != sent.id && successor.lineageID == sent.lineageID, "every queued payload must have immutable version identity")
            let cold = ClientSyncStore(cache: h.sync.cache)
            try check(cold.overlayChapter(h.chapters[0]).draftText == "最新版本B", "latest queue payload must already survive a cold store")
            _ = try await fixture("config", ["patch_response_gate": "", "patch_failure_gate": "", "patch_status": 200, "patch_lost": false])
            _ = try await fixture("release", ["gate": gate])
            _ = await flushing.value
            if outcome == 409 {
                let restored = ClientSyncStore(cache: h.sync.cache)
                try check(restored.conflicts.count == 1 && restored.pendingCount == 0, "old conflict may promote newest chain while independent resources finish")
                let payload = try JSONSerialization.jsonObject(with: restored.conflicts[0].localPayload) as! [String: Any]
                try check(payload["draft_text"] as? String == "最新版本B", "old 409 must compare newest payload, never replace it with A")
                try check(restored.overlayChapter(h.chapters[0]).draftText == "最新版本B", "conflicted latest content must remain locally visible")
            } else {
                if outcome == 0 {
                    try check(h.sync.pendingMutations.first?.id == successor.id, "old transport failure must not consume or diagnose newer payload")
                    _ = await h.sync.flush(using: h.session.api)
                }
                let state = try await fixture()
                try check(h.sync.pendingCount == 0 && state.chapters[h.chapters[0].id]?.draftText == "最新版本B", "success/refusal must preserve then synchronize successor")
                try check(state.chapters[h.chapters[1].id]?.draftText == "独立章节", "other resources must remain flushable")
                if outcome == 200 {
                    let revisions = state.requests.filter { $0.path == "/chapters/" + h.chapters[0].id && $0.method == "PATCH" }.map(\.ifMatch)
                    try check(revisions == ["\"7\"", "\"8\""], "own old success must advance successor base without manufacturing 409")
                }
            }
        }
    }

    @MainActor static func characterPendingRecovery() async throws {
        let h = try await Harness("character-recovery")
        let store = CharactersStore(session: h.session, sync: h.sync)
        await store.load(bookId: h.book.id)
        var old = h.character
        old.fixedProfile = "先前人物修改"
        _ = try await fixture("config", ["patch_lost": true])
        _ = await store.update(old)
        _ = try await fixture("config", ["patch_lost": false, "strict_revisions": true, "patch_response_gate": "old-character"])
        let flushing = Task { await h.sync.flush(using: h.session.api) }
        try await eventually("old character flush admitted") {
            try await fixture().requests.filter { $0.method == "PATCH" && $0.path == "/characters/" + h.character.id }.count >= 2
        }
        var newest = h.character
        newest.name = "本机新人物名"
        newest.fixedProfile = "必须冷启动恢复的最新人物设定"
        _ = try await fixture("config", ["patch_lost": true, "patch_response_gate": ""])
        _ = await store.update(newest)
        try check(store.selected?.fixedProfile == newest.fixedProfile, "pending author value must remain on screen")
        try check(h.sync.cache.characters(bookID: h.book.id)[0].fixedProfile == "", "optimistic edit must not impersonate server baseline")
        let coldSync = ClientSyncStore(cache: h.sync.cache)
        let coldStore = CharactersStore(session: h.session, sync: coldSync)
        _ = try await fixture("config", ["characters_list_status": 503])
        await coldStore.load(bookId: h.book.id)
        try check(coldStore.selected?.name == newest.name && coldStore.selected?.fixedProfile == newest.fixedProfile, "offline cold load must overlay durable latest values")
        _ = try await fixture("config", ["patch_lost": false, "characters_list_status": 200])
        _ = try await fixture("release", ["gate": "old-character"])
        _ = await flushing.value
        let state = try await fixture()
        try check(state.character.fixedProfile == newest.fixedProfile && h.sync.pendingCount == 0, "old success must rebase/sync latest character")
        let requests = state.requests.filter { $0.method == "PATCH" && $0.path == "/characters/" + h.character.id }
        try check(requests.last?.ifMatch == "\"8\"", "latest character must inherit only acknowledged own revision")
        let restored = ClientSyncStore(cache: h.sync.cache)
        try check(restored.visibleCharacters(bookID: h.book.id)[0].fixedProfile == newest.fixedProfile, "final snapshot must preserve latest visible value")
    }

    @MainActor static func directMutationOwnership() async throws {
        for outcome in [200, 409, 422] {
            let h = try await Harness("direct-generation")
            let store = CharactersStore(session: h.session, sync: h.sync)
            await store.load(bookId: h.book.id)
            var old = h.character
            old.fixedProfile = "旧直接请求"
            let submitted = old
            let gate = "direct-" + String(outcome)
            _ = try await fixture("config", outcome == 200
                ? ["patch_response_gate": gate, "strict_revisions": true]
                : ["patch_failure_gate": gate, "patch_status": outcome])
            let saving = Task { await store.update(submitted) }
            try await eventually("direct request frozen") { try await fixture().requests.contains { $0.method == "PATCH" } }
            var newest = h.character
            newest.fixedProfile = "直接请求期间的最新输入"
            _ = try await fixture("config", ["patch_response_gate": "", "patch_failure_gate": "", "patch_lost": true])
            _ = await store.update(newest)
            let pendingID = h.sync.pendingMutations[0].id
            _ = try await fixture("config", ["patch_lost": false, "patch_status": 200])
            _ = try await fixture("release", ["gate": gate])
            _ = await saving.value
            try check(h.sync.pendingMutations.first?.id == pendingID, "direct old completion cannot clear/replace successor")
            try check(h.sync.conflicts.isEmpty, "obsolete direct 409 must not manufacture conflict for newest edit")
            let cold = ClientSyncStore(cache: h.sync.cache)
            try check(cold.visibleCharacters(bookID: h.book.id)[0].fixedProfile == newest.fixedProfile, "direct successor must survive restart")
            _ = await h.sync.flush(using: h.session.api)
            try check(h.sync.pendingCount == 0, "direct successor remains independently synchronizable")
            let state = try await fixture()
            try check(state.character.fixedProfile == newest.fixedProfile, "latest direct edit must reach server")
        }
    }

    @MainActor static func ownConcurrentConflict() async throws {
        for direct in [false, true] {
            for delayedRead in [false, true] {
                let h = try await Harness("own-conflict")
                let store = CharactersStore(session: h.session, sync: h.sync)
                await store.load(bookId: h.book.id)
                var old = h.character
                old.fixedProfile = "本机先前保存"
                if !direct {
                    _ = try await fixture("config", ["patch_lost": true])
                    _ = await store.update(old)
                }
                _ = try await fixture("config", ["patch_lost": false, "strict_revisions": true, "patch_response_gate": "own-ancestor"])
                let submitted = old
                let priorCount = try await fixture().requests.filter { $0.method == "PATCH" }.count
                let ancestor = Task {
                    if direct { _ = await store.update(submitted) }
                    else { _ = await h.sync.flush(using: h.session.api) }
                }
                try await eventually("ancestor committed with response held") { try await fixture().requests.filter { $0.method == "PATCH" }.count > priorCount }
                _ = try await fixture("config", ["patch_response_gate": "", "get_gate": delayedRead ? "own-conflict-read" : ""])
                var edited = h.character
                edited.fixedProfile = "409期间的最新本机编辑"
                let newest = edited
                let readCount = try await fixture().requests.filter { $0.method == "GET" && $0.path == "/characters/" + h.character.id }.count
                let successor = Task { await store.update(newest) }
                try await eventually("new direct 409 follow-up read captured") { try await fixture().requests.filter { $0.method == "GET" && $0.path == "/characters/" + h.character.id }.count > readCount }
                if !delayedRead {
                    _ = await successor.value
                    try check(h.sync.conflicts.count == 1, "before acknowledgement the competing revision must remain explicit")
                }
                _ = try await fixture("release", ["gate": "own-ancestor"])
                await ancestor.value
                if delayedRead {
                    _ = try await fixture("release", ["gate": "own-conflict-read"])
                    _ = await successor.value
                }
                try check(h.sync.conflicts.isEmpty, "acknowledged same-chain snapshot must remove artificial 409")
                if let pending = h.sync.pendingMutations.first {
                    try check(pending.baseRevision == 8, "own success must advance successor base while preserving its payload")
                }
                _ = await h.sync.flush(using: h.session.api)
                let state = try await fixture()
                try check(h.sync.pendingCount == 0 && state.character.fixedProfile == newest.fixedProfile, "latest payload must synchronize without extra author conflict choice")
                try check(state.requests.last { $0.method == "PATCH" && $0.path == "/characters/" + h.character.id }?.ifMatch == "\"8\"", "rebase must use proven own revision")
            }
        }
        let h = try await Harness("real-third-party-conflict")
        let store = CharactersStore(session: h.session, sync: h.sync)
        await store.load(bookId: h.book.id)
        var old = h.character
        old.fixedProfile = "本机先前保存"
        let submitted = old
        _ = try await fixture("config", ["strict_revisions": true, "patch_response_gate": "real-ancestor"])
        let ancestor = Task { await store.update(submitted) }
        try await eventually("own response held before external write") { try await fixture().requests.contains { $0.method == "PATCH" } }
        _ = try await fixture("config", ["patch_response_gate": "", "remote_character_profile": "另一设备新值"])
        var newest = h.character
        newest.fixedProfile = "最新本机值"
        _ = await store.update(newest)
        _ = try await fixture("release", ["gate": "real-ancestor"])
        _ = await ancestor.value
        try check(h.sync.conflicts.count == 1 && h.sync.pendingCount == 0, "different server snapshot must remain an explicit true conflict")
        let state = try await fixture()
        try check(state.character.fixedProfile == "另一设备新值", "lineage alone must never overwrite third-party content")
        let cold = ClientSyncStore(cache: h.sync.cache)
        try check(cold.visibleCharacters(bookID: h.book.id)[0].fixedProfile == newest.fixedProfile, "true conflict still preserves author value after restart")
    }

    @MainActor static func lateOwnConflictAfterAcknowledgement() async throws {
        for direct in [false, true] {
            let h = try await Harness("late-own-409")
            let store = CharactersStore(session: h.session, sync: h.sync)
            await store.load(bookId: h.book.id)
            var old = h.character
            old.fixedProfile = "先前本机版本A"
            if !direct {
                _ = try await fixture("config", ["patch_lost": true])
                _ = await store.update(old)
            }
            _ = try await fixture("config", ["patch_lost": false, "strict_revisions": true, "patch_response_gate": "late-ancestor"])
            let submitted = old
            let previous = try await fixture().requests.filter { $0.method == "PATCH" }.count
            let ancestor = Task {
                if direct { _ = await store.update(submitted) }
                else { _ = await h.sync.flush(using: h.session.api) }
            }
            try await eventually("ancestor commits with response held") { try await fixture().requests.filter { $0.method == "PATCH" }.count > previous }
            _ = try await fixture("config", ["patch_response_gate": "", "patch_failure_gate": "late-successor"])
            var edited = h.character
            edited.fixedProfile = "必须保留的本机最新版本B"
            let newest = edited
            let successor = Task { await store.update(newest) }
            try await eventually("new direct submitted before 409 check") { try await fixture().requests.filter { $0.method == "PATCH" }.count > previous + 1 }
            _ = try await fixture("release", ["gate": "late-ancestor"])
            await ancestor.value
            try check(h.sync.pendingCount == 0 && h.sync.conflicts.isEmpty, "ancestor acknowledgement must finish before B becomes pending")
            _ = try await fixture("release", ["gate": "late-successor"])
            _ = await successor.value
            try check(h.sync.conflicts.isEmpty && h.sync.pendingCount == 1, "late same-chain 409 must retain pending B without artificial comparison")
            let pending = h.sync.pendingMutations[0]
            try check(pending.baseRevision == 8, "newly queued B must inherit previously acknowledged own revision")
            let cold = ClientSyncStore(cache: h.sync.cache)
            try check(cold.visibleCharacters(bookID: h.book.id)[0].fixedProfile == newest.fixedProfile
                      && cold.pendingMutations[0].baseRevision == 8, "rebased payload and revision must survive restart")
            _ = try await fixture("config", ["patch_failure_gate": ""])
            _ = await h.sync.flush(using: h.session.api)
            let state = try await fixture()
            try check(h.sync.pendingCount == 0 && state.character.fixedProfile == newest.fixedProfile, "late B must synchronize normally")
            try check(state.requests.last { $0.method == "PATCH" && $0.path == "/characters/" + h.character.id }?.ifMatch == "\"8\"", "late B must send proven own revision")
        }
    }

    @MainActor static func deleteOwnership() async throws {
        for status in [204, 503] {
            let h = try await Harness("delete-generation")
            _ = try await fixture("config", ["delete_gate": "delete-A", "delete_status": status])
            let deleting = Task { await h.editor.deleteCurrentChapter() }
            try await eventually("delete A admitted") { try await fixture().requests.contains { $0.method == "DELETE" } }
            await h.load(1)
            let text = "删除另一章期间写下的新正文"
            h.editor.editString(\.draftText, value: text)
            _ = try await fixture("release", ["gate": "delete-A"])
            let result = await deleting.value
            try check(result == (status == 204), "delete must report real HTTP outcome")
            try check(h.editor.currentChapter?.id == h.chapters[1].id && h.editor.saveState == .unsaved, "late delete cannot mark chapter B synced or reset editor")
            try check(h.editor.persistLocalDraftIfNeeded(), "B must still persist at lifecycle boundary")
            let cold = ChapterEditorStore(session: h.session, sync: h.sync)
            let summary = try JSONDecoder.lino.decode(ChapterSummary.self, from: JSONEncoder.lino.encode(h.chapters[1]))
            await cold.load(summary)
            try check(cold.currentChapter?.draftText == text, "B must restore full body after deletion completion")
            if status == 204 {
                try check(h.sync.cache.chapter(id: h.chapters[0].id) == nil && ChapterDraftCache().load(chapterId: h.chapters[0].id) == nil, "deleted chapter must leave no ghost cache")
            }
        }
        let h = try await Harness("delete-current")
        let deleted = await h.editor.deleteCurrentChapter()
        try check(deleted, "own chapter deletion succeeds")
        try check(h.editor.currentChapter == nil && h.editor.saveState == .synced, "own deletion clears editor")
    }

    @MainActor static func bookReadOwnership() async throws {
        for oldStatus in [200, 503] {
            let h = try await Harness("books-read")
            let other = try await fixture().other_book
            let workspace = WorkspaceStore(session: h.session, sync: h.sync)
            let characters = CharactersStore(session: h.session, sync: h.sync)
            let text = "切书前必须持久保存的A正文"
            h.editor.editString(\.draftText, value: text)
            _ = try await fixture("config", ["chapters_list_gate": "A-chapters", "characters_list_gate": "A-characters",
                                             "chapters_list_status": oldStatus, "characters_list_status": oldStatus])
            let loadingA = Task { await workspace.load(bookId: h.book.id) }
            let charactersA = Task { await characters.load(bookId: h.book.id) }
            try await eventually("book A reads captured") {
                let events = try await fixture().requests
                return events.contains { $0.path == "/books/" + h.book.id + "/chapters" }
                    && events.contains { $0.path == "/books/" + h.book.id + "/characters" }
            }
            try check(h.editor.resetBookContext(), "switch must synchronously preserve A draft")
            workspace.resetBookContext()
            characters.resetBookContext()
            h.session.currentBook = other
            _ = try await fixture("config", ["chapters_list_gate": "", "characters_list_gate": "",
                                             "chapters_list_status": 200, "characters_list_status": 200])
            await workspace.load(bookId: other.id)
            await characters.load(bookId: other.id)
            await h.editor.load(workspace.chapters[0])
            _ = try await fixture("release", ["gate": "A-chapters"])
            _ = try await fixture("release", ["gate": "A-characters"])
            await loadingA.value
            await charactersA.value
            try check(workspace.chapters.allSatisfy { $0.bookId == other.id } && characters.characters.allSatisfy { $0.bookId == other.id }, "late A success/failure must not replace B lists")
            try check(h.editor.currentChapter?.bookId == other.id && h.session.currentBook?.id == other.id, "title/editor must still belong to B")
            try check(!workspace.isLoading && !characters.isLoading, "old request cannot repaint current loading state")
            h.session.currentBook = h.book
            let cold = ChapterEditorStore(session: h.session, sync: h.sync)
            let summary = try JSONDecoder.lino.decode(ChapterSummary.self, from: JSONEncoder.lino.encode(h.chapters[0]))
            await cold.load(summary)
            try check(cold.currentChapter?.draftText == text, "A draft must remain recoverable after switching")
        }
        let h = try await Harness("empty-offline-book")
        let other = try await fixture().other_book
        let workspace = WorkspaceStore(session: h.session, sync: h.sync)
        let characters = CharactersStore(session: h.session, sync: h.sync)
        await workspace.load(bookId: h.book.id)
        await characters.load(bookId: h.book.id)
        h.session.currentBook = other
        try check(h.editor.resetBookContext(), "empty book transition must clear editor after persistence")
        _ = try await fixture("config", ["other_book_empty": true, "chapters_list_status": 503, "characters_list_status": 503])
        await workspace.load(bookId: other.id)
        await characters.load(bookId: other.id)
        try check(workspace.chapters.isEmpty && workspace.chapterPath.isEmpty && characters.characters.isEmpty && characters.selectedCharacterId == nil, "empty offline cache must not preserve A list/selection")
        try check(h.editor.currentChapter == nil, "empty B must not expose A editor")
        _ = try await fixture("config", ["chapters_list_status": 200])
        await workspace.load(bookId: other.id)
        try check(workspace.chapters.isEmpty && h.editor.currentChapter == nil, "online empty book also stays empty")
    }

    @MainActor static func bookMutationOwnership() async throws {
        for kind in ["chapters", "characters", "book", "delete-character"] {
            let h = try await Harness("book-mutation")
            let other = try await fixture().other_book
            let workspace = WorkspaceStore(session: h.session, sync: h.sync)
            let characters = CharactersStore(session: h.session, sync: h.sync)
            await workspace.load(bookId: h.book.id)
            await characters.load(bookId: h.book.id)
            let gate = "mutation-A"
            if kind == "book" { _ = try await fixture("config", ["patch_response_gate": gate]) }
            else if kind == "delete-character" { _ = try await fixture("config", ["delete_gate": gate]) }
            else { _ = try await fixture("config", [kind + "_create_gate": gate]) }
            let action = Task { () -> Bool in
                switch kind {
                case "chapters": return await workspace.createChapter() != nil
                case "characters": return await characters.create(name: "迟到A人物") != nil
                case "delete-character": return await characters.delete(h.character)
                default: return await workspace.saveBook(title: "A新书名", world: "A新世界")
                }
            }
            try await eventually("book mutation captured") { try await fixture().requests.contains { ["POST", "PATCH", "DELETE"].contains($0.method) } }
            try check(h.editor.resetBookContext(), "mutating book can still switch after safe persistence")
            workspace.resetBookContext()
            characters.resetBookContext()
            h.session.currentBook = other
            _ = try await fixture("config", ["chapters_create_gate": "", "characters_create_gate": "", "patch_response_gate": "", "delete_gate": ""])
            await workspace.load(bookId: other.id)
            await characters.load(bookId: other.id)
            _ = try await fixture("release", ["gate": gate])
            let acceptedIntoCurrentContext = await action.value
            try check(!acceptedIntoCurrentContext, "late mutation must not navigate/close current B")
            try check(h.session.currentBook?.id == other.id && workspace.chapters.allSatisfy { $0.bookId == other.id }, "late write cannot restore book A")
            try check(characters.characters.allSatisfy { $0.bookId == other.id } && characters.selected?.bookId == other.id, "late character create/delete cannot contaminate B cache or selection")
            try check(h.sync.cache.characters(bookID: other.id).allSatisfy { $0.bookId == other.id }, "B durable cache must only contain B resources")
        }
    }

    @MainActor static func sameResourceListMutationOwnership() async throws {
        for kind in ["characters", "chapters", "books"] {
            for deletion in [false, true] {
                let h = try await Harness("list-mutation", ["books_with_rows": true])
                let workspace = WorkspaceStore(session: h.session, sync: h.sync)
                let characters = CharactersStore(session: h.session, sync: h.sync)
                let shelf = BookshelfStore(session: h.session, sync: h.sync)
                let path = kind == "books" ? "/books" : "/books/" + h.book.id + "/" + kind
                let gateOption = kind == "books" ? "books_read_gate" : kind + "_list_gate"
                switch kind {
                case "characters": await characters.load(bookId: h.book.id)
                case "chapters": await workspace.load(bookId: h.book.id)
                default: _ = await shelf.load()
                }
                let count = try await fixture().requests.filter { $0.method == "GET" && $0.path == path }.count
                _ = try await fixture("config", [gateOption: "old-list"])
                let loading = Task {
                    switch kind {
                    case "characters": await characters.load(bookId: h.book.id)
                    case "chapters": await workspace.refreshChapters(bookId: h.book.id)
                    default: _ = await shelf.load()
                    }
                }
                try await eventually("old list captured before committed mutation") {
                    try await fixture().requests.filter { $0.method == "GET" && $0.path == path }.count > count
                }
                _ = try await fixture("config", [gateOption: ""])
                let target: String
                if deletion {
                    switch kind {
                    case "characters":
                        target = h.character.id
                        let result = await characters.delete(h.character)
                        try check(result, "character deletion must commit")
                    case "chapters":
                        target = h.chapters[0].id
                        let result = await h.editor.deleteCurrentChapter()
                        try check(result, "chapter deletion must commit")
                    default:
                        target = h.book.id
                        await shelf.delete(h.book)
                    }
                } else {
                    switch kind {
                    case "characters":
                        guard let value = await characters.create(name: "成功新增人物") else { throw HTTPTestFailure(description: "character creation failed") }
                        target = value.id
                    case "chapters":
                        guard let value = await workspace.createChapter() else { throw HTTPTestFailure(description: "chapter creation failed") }
                        target = value.id
                    default:
                        guard let value = await shelf.createBook(title: "成功新增书籍") else { throw HTTPTestFailure(description: "book creation failed") }
                        target = value.id
                    }
                }
                _ = try await fixture("release", ["gate": "old-list"])
                await loading.value
                let cold = ClientSnapshotCache(root: h.cacheRoot)
                let serverHasTarget: Bool
                let visibleHasTarget: Bool
                let coldHasTarget: Bool
                switch kind {
                case "characters":
                    let fresh: [Character] = try await h.session.api.request(path)
                    serverHasTarget = fresh.contains { $0.id == target }
                    visibleHasTarget = characters.characters.contains { $0.id == target }
                    coldHasTarget = ClientSyncStore(cache: cold).visibleCharacters(bookID: h.book.id).contains { $0.id == target }
                case "chapters":
                    let fresh: [ChapterSummary] = try await h.session.api.request(path)
                    serverHasTarget = fresh.contains { $0.id == target }
                    visibleHasTarget = workspace.chapters.contains { $0.id == target }
                    coldHasTarget = cold.chapters(bookID: h.book.id).contains { $0.id == target }
                default:
                    let fresh: [Book] = try await h.session.api.request(path)
                    serverHasTarget = fresh.contains { $0.id == target }
                    visibleHasTarget = shelf.books.contains { $0.id == target }
                    coldHasTarget = cold.books().contains { $0.id == target }
                }
                try check(serverHasTarget == !deletion, "synthetic server must reflect committed " + kind + " mutation")
                try check(visibleHasTarget == serverHasTarget && coldHasTarget == serverHasTarget,
                          "older " + kind + " GET must not erase a committed addition or resurrect a deletion")
                try check(!workspace.isLoading && !characters.isLoading && !shelf.isLoading, "superseded lists must finish loading")
            }
        }
    }

    @MainActor static func sameResourceListReadOwnership() async throws {
        for kind in ["characters", "chapters", "books"] {
            let h = try await Harness("list-read", ["books_with_rows": true], load: false)
            let workspace = WorkspaceStore(session: h.session, sync: h.sync)
            let characters = CharactersStore(session: h.session, sync: h.sync)
            let shelf = BookshelfStore(session: h.session, sync: h.sync)
            let path = kind == "books" ? "/books" : "/books/" + h.book.id + "/" + kind
            let gateOption = kind == "books" ? "books_read_gate" : kind + "_list_gate"
            _ = try await fixture("config", [gateOption: "older-list"])
            let older = Task {
                switch kind {
                case "characters": await characters.load(bookId: h.book.id)
                case "chapters": await workspace.refreshChapters(bookId: h.book.id)
                default: _ = await shelf.load()
                }
            }
            try await eventually("older same-resource list captured") { try await fixture().requests.contains { $0.method == "GET" && $0.path == path } }
            let target: String
            switch kind {
            case "characters":
                let value: Character = try await h.session.api.request(path, method: "POST",
                    body: ["name": "外部新增人物", "role": "", "fixed_profile": ""])
                target = value.id
            case "chapters":
                let value: Chapter = try await h.session.api.request(path, method: "POST",
                    body: ["title": "外部新增章节", "user_prompt": ""])
                target = value.id
            default:
                let value: Book = try await h.session.api.request(path, method: "POST",
                    body: ["title": "外部新增书籍", "world_setting": ""])
                target = value.id
            }
            _ = try await fixture("config", [gateOption: ""])
            switch kind {
            case "characters": await characters.load(bookId: h.book.id)
            case "chapters": await workspace.refreshChapters(bookId: h.book.id)
            default: _ = await shelf.load()
            }
            _ = try await fixture("release", ["gate": "older-list"])
            await older.value
            let cold = ClientSnapshotCache(root: h.cacheRoot)
            switch kind {
            case "characters":
                try check(characters.characters.contains { $0.id == target } && cold.characters(bookID: h.book.id).contains { $0.id == target }, "older character read cannot overwrite newer UI/cold rows")
            case "chapters":
                try check(workspace.chapters.contains { $0.id == target } && cold.chapters(bookID: h.book.id).contains { $0.id == target }, "older chapter read cannot overwrite newer UI/cold rows")
            default:
                try check(shelf.books.contains { $0.id == target } && cold.books().contains { $0.id == target }, "older book read cannot overwrite newer UI/cold rows")
            }
        }

        // A detail GET is not a chapter-list write. It must leave a complete
        // in-flight list eligible, including rows absent from the warm cache.
        let h = try await Harness("complete-chapter-list", load: false)
        let workspace = WorkspaceStore(session: h.session, sync: h.sync)
        let path = "/books/" + h.book.id + "/chapters"
        let added: Chapter = try await h.session.api.request(path, method: "POST",
            body: ["title": "完整目录新增章", "user_prompt": ""])
        try check(h.sync.cache.chapters(bookID: h.book.id).isEmpty, "normal cold list starts without cached summaries")
        let count = try await fixture().requests.filter { $0.path == path }.count
        _ = try await fixture("config", ["chapters_list_gate": "full-list"])
        let loading = Task { await workspace.load(bookId: h.book.id) }
        try await eventually("full list including new row captured") { try await fixture().requests.filter { $0.path == path }.count > count }
        await h.load(0)
        workspace.upsert(h.editor.currentChapter!)
        try check(workspace.chapters.count == 1, "real UI detail projection may arrive before cold full list")
        _ = try await fixture("release", ["gate": "full-list"])
        await loading.value
        try check(workspace.chapters.count == 3 && workspace.chapters.contains { $0.id == added.id }
                  && ClientSnapshotCache(root: h.cacheRoot).chapters(bookID: h.book.id).contains { $0.id == added.id },
                  "ordinary detail GET and real UI upsert must not invalidate or shrink a complete cold chapter list")
    }

    @MainActor static func shelfOpenOwnership() async throws {
        for close in [false, true] {
            let h = try await Harness("book-open")
            let other = try await fixture().other_book
            let shelf = BookshelfStore(session: h.session, sync: h.sync)
            _ = try await fixture("config", ["get_gate": "open-A"])
            let opening = Task { await shelf.open(h.book) }
            try await eventually("book open captured") { try await fixture().requests.contains { $0.path == "/books/" + h.book.id } }
            if close { h.session.closeBook() }
            else {
                _ = try await fixture("config", ["get_gate": ""])
                await shelf.open(other)
            }
            _ = try await fixture("release", ["gate": "open-A"])
            await opening.value
            try check(h.session.currentBook?.id == (close ? nil : other.id), "late open cannot reopen closed book or supersede newer book")
        }
    }

    @MainActor static func conflictRefreshOwnership() async throws {
        for conflictRoute in [false, true] {
            for close in [false, true] {
                let h = try await Harness("conflict-book-refresh", load: false)
                let other = try await fixture().other_book
                let shelf = BookshelfStore(session: h.session, sync: h.sync)
                let workspace = WorkspaceStore(session: h.session, sync: h.sync)
                let characters = CharactersStore(session: h.session, sync: h.sync)
                let agents = AgentSettingsStore(session: h.session, sync: h.sync)
                let snapshot = try JSONEncoder.lino.encode(h.book)
                let conflict = ContentConflict(id: UUID(), resourceKind: .book, resourceID: h.book.id,
                    submittedRevision: 7, currentRevision: 8, path: "/books/" + h.book.id, method: "PATCH",
                    readPath: "/books/" + h.book.id, readStrategy: .direct,
                    baseSnapshot: snapshot, localPayload: snapshot, serverSnapshot: snapshot,
                    requiresSecretReentry: false, createdAt: Date())
                _ = try await fixture("config", ["books_with_rows": true, "books_read_gate": "conflict-book-list"])
                let refreshing = Task {
                    if conflictRoute {
                        await V2DeskConflictRefresh.run(conflict, session: h.session, bookshelf: shelf,
                            workspace: workspace, editor: h.editor, characters: characters, agents: agents)
                    } else {
                        await V2DeskConflictRefresh.run([AppliedSyncMutation(resourceKind: .book, resourceID: h.book.id)],
                            session: h.session, bookshelf: shelf, workspace: workspace,
                            editor: h.editor, characters: characters, agents: agents)
                    }
                }
                try await eventually("book list response held") { try await fixture().requests.contains { $0.path == "/books" } }
                try check(h.editor.resetBookContext(), "conflict refresh switch must preserve current draft")
                workspace.resetBookContext()
                characters.resetBookContext()
                if close { h.session.closeBook() } else { h.session.currentBook = other }
                _ = try await fixture("release", ["gate": "conflict-book-list"])
                await refreshing.value
                try check(h.session.currentBook?.id == (close ? nil : other.id), "late actual helper cannot reopen A after close or switch")
                try check(workspace.chapters.isEmpty && workspace.chapterPath.isEmpty && h.editor.currentChapter == nil,
                          "old helper must not refresh or navigate stale book after losing its context")
                let requests = try await fixture().requests
                try check(!requests.contains { $0.path == "/books/" + h.book.id + "/chapters" }, "late conflict decision cannot fetch old chapter list after losing book")
            }
        }
    }

    @MainActor static func chapterNavigationOwnership() async throws {
        let h = try await Harness("navigation-epoch")
        let workspace = WorkspaceStore(session: h.session, sync: h.sync)
        await workspace.load(bookId: h.book.id)
        let a = workspace.chapters[0]
        let b = workspace.chapters[1]
        workspace.chapterPath = [a]
        let original = workspace.chapterNavigationID
        workspace.chapterPath = [b]
        let middle = workspace.chapterNavigationID
        workspace.chapterPath = [a]
        try check(original != middle && workspace.chapterNavigationID != original
                  && workspace.chapterNavigationID != middle, "setter must synchronously distinguish A to B to A")
        let current = workspace.chapterNavigationID
        await workspace.refreshChapters(bookId: h.book.id)
        try check(workspace.chapterNavigationID == current && workspace.chapterPath.map(\.id) == [a.id], "ordinary list refresh must preserve navigation ownership")
        var sameIdentity = a
        sameIdentity.title = "更新行标题"
        workspace.replaceCurrentDestination(with: sameIdentity)
        try check(workspace.chapterNavigationID == current, "metadata refresh of same path identity must not invent navigation")
        workspace.resetBookContext()
        try check(workspace.chapterPath.isEmpty && workspace.chapterNavigationID != current, "reset must synchronously invalidate previous destination")
    }

    @MainActor static func settingsMutationContracts() async throws {
        let h = try await Harness("settings-contract")
        let settings = AgentSettingsStore(session: h.session, sync: h.sync)
        await settings.load()
        await settings.bind(role: "writer", profileId: nil)
        let bindings: [AgentBinding] = try await h.session.api.request("/agent-model-bindings")
        try check(bindings[0].llmProfileId == nil, "explicit unbind must read back nil")
        var state = try await fixture()
        let unbind = state.requests.first { $0.method == "PATCH" && $0.path == "/agent-model-bindings/writer" }!
        let nullBody = try JSONSerialization.jsonObject(with: Data(unbind.bodyText.utf8)) as! [String: Any]
        try check(nullBody["llm_profile_id"] is NSNull && nullBody.count == 1, "profile nil must encode JSON null, without touching other fields")
        let originalID = settings.profiles[0].id
        await settings.bind(role: "writer", profileId: originalID)
        var profile = settings.profiles[0]
        profile.name = "原位新名称"
        profile.modelName = "synthetic-new-model"
        let noKey = await settings.updateProfile(profile, apiKey: "")
        try check(noKey && settings.profiles[0].id == originalID, "in-place public update must retain ID")
        state = try await fixture()
        let firstPatch = state.requests.last { $0.path == "/llm_profiles/" + originalID && $0.method == "PATCH" }!
        let firstBody = try JSONSerialization.jsonObject(with: Data(firstPatch.bodyText.utf8)) as! [String: Any]
        try check(firstBody["api_key"] == nil, "blank key must preserve existing server key")
        let withKey = await settings.updateProfile(settings.profiles[0], apiKey: "synthetic-memory-only-key")
        try check(withKey, "new memory-only key must be sent in same-ID PATCH")
        state = try await fixture()
        let keyPatch = state.requests.last { $0.path == "/llm_profiles/" + originalID && $0.method == "PATCH" }!
        let keyBody = try JSONSerialization.jsonObject(with: Data(keyPatch.bodyText.utf8)) as! [String: Any]
        try check(keyBody["api_key"] as? String == "synthetic-memory-only-key", "nonempty replacement key must be explicitly transmitted")
        let afterBindings: [AgentBinding] = try await h.session.api.request("/agent-model-bindings")
        try check(afterBindings[0].llmProfileId == originalID, "in-place profile updates must preserve bindings")
        for status in [503, 422, 409] {
            _ = try await fixture("config", ["settings_status": status])
            var persona = settings.personas[0]
            let originalPersona = persona.editablePersona
            persona.editablePersona = "失败后仍需保留的作者输入"
            let saved = await settings.savePersona(persona)
            let reset = await settings.resetPersona(role: "writer")
            let created = await settings.createProfile(name: "保留名称", baseURL: "https://synthetic.invalid", apiKey: "synthetic-memory-only-key", model: "preserved-model")
            let updated = await settings.updateProfile(settings.profiles[0], apiKey: "synthetic-memory-only-key")
            try check(!saved && !reset && !created && !updated, "every refusal must return false so UI retains input")
            try check(settings.personas[0].editablePersona == originalPersona, "failed persona result must not replace server value")
            try check(!h.sync.pendingMutations.contains { $0.resourceKind == .llmProfile }, "secrets must never enter pending queue")
            let conflicts = try JSONEncoder.lino.encode(h.sync.conflicts)
            try check(!String(decoding: conflicts, as: UTF8.self).contains("synthetic-memory-only-key"), "conflict persistence must exclude memory-only key")
        }
        _ = try await fixture("config", ["settings_status": 200])
        var persona = settings.personas[0]
        persona.editablePersona = "成功人格"
        let saved = await settings.savePersona(persona)
        let reset = await settings.resetPersona(role: "writer")
        try check(saved && reset && settings.personas[0].editablePersona == "默认人格", "successful save/reset must return true and refresh public value")
        let emptySettings = AgentSettingsStore(session: h.session, sync: h.sync)
        let emptyReset = await emptySettings.resetPersona(role: "writer")
        try check(!emptyReset, "unloaded persona cannot claim a successful blank reset")
    }

    @MainActor static func bookPersonaContext() async throws {
        for reopenSame in [false, true] {
            let h = try await Harness("book-persona-context")
            let other = try await fixture().other_book
            let settings = AgentSettingsStore(session: h.session, sync: h.sync)
            await settings.load()
            let loaded = await settings.loadBookPersonas(bookID: h.book.id)
            try check(loaded, "persona fixture must load resolved current book")
            _ = try await fixture("config", ["book_personas_write_gate": "persona-A"])
            let saving = Task { await settings.saveBookPersona(bookID: h.book.id, role: "writer", editablePersona: "A作者人格输入") }
            try await eventually("book persona request frozen") { try await fixture().requests.contains { $0.method == "PUT" } }
            h.session.closeBook()
            let target = reopenSame ? h.book : other
            h.session.currentBook = target
            _ = await settings.loadBookPersonas(bookID: target.id)
            let before = settings.bookPersonas
            _ = try await fixture("release", ["gate": "persona-A"])
            let saved = await saving.value
            try check(!saved && settings.bookPersonas == before && settings.bookPersonasBookID == target.id, "late same-ID/new-book save must not refresh another settings session")
            try check(settings.personas[0].editablePersona == "原人格", "book save can never fall back to global")
            let unloaded = AgentSettingsStore(session: h.session, sync: h.sync)
            let savedWithoutContext = await unloaded.saveBookPersona(bookID: target.id, role: "writer", editablePersona: "未加载草稿")
            try check(!savedWithoutContext, "unloaded context must retain draft rather than claiming saved")
        }
    }

    @MainActor static func inspirationTimeoutAndStaleness() async throws {
        let h = try await Harness("inspiration-clock", load: false)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScaledTimeoutURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let session = AppSession(notices: h.notices, requestSession: transport)
        session.baseURL = "https://timeout.invalid"
        session.token = "synthetic-test-token"
        session.currentBook = h.book
        let ordinary = try session.api.preparedRequest("/books")
        let inspiration = try session.api.preparedRequest("/chapters/" + h.chapters[0].id + "/inspirations", method: "POST", timeout: APIClient.inspirationRequestTimeout)
        try check(ordinary.timeoutInterval == 60 && inspiration.timeoutInterval == 420, "prepared request timeouts must be endpoint-specific")
        do {
            let _: Book = try await session.api.request("/books/regular")
            throw HTTPTestFailure(description: "ordinary request must time out on shortened transport clock")
        } catch APIError.transport { }
        let store = InspirationCreatorStore(session: session)
        store.pacingBoundary = "原推进边界"
        store.generate(for: h.chapters[0])
        store.pacingBoundary = "请求途中修改的边界"
        try await eventually("scaled inspiration completes after ordinary budget") { !store.isLoading }
        try check(store.cards.count == 1 && store.errorMessage == nil, "inspiration must survive beyond regular request budget")
        try check(store.isStale(comparedTo: h.chapters[0]), "input changed during generation must mark returned cards stale")
        store.pacingBoundary = "原推进边界"
        var changed = h.chapters[0]
        changed.title = "后来标题"
        try check(store.isStale(comparedTo: changed), "title change must mark frozen inspiration stale")
        changed = h.chapters[0]
        changed.userPrompt = "后来Bible"
        try check(store.isStale(comparedTo: changed), "Bible change must mark frozen inspiration stale")
        changed = h.chapters[0]
        changed.characterLinks = [ChapterLink(characterId: "new-selected-character")]
        try check(store.isStale(comparedTo: changed), "selection change must mark frozen inspiration stale")
        let card = store.cards[0]
        store.recordAdoption(card: card, chapterID: changed.id, before: "原Bible", after: "原Bible\n新卡")
        try check(!store.canUndo(chapterID: changed.id, currentBible: "采用后再编辑Bible"), "Undo may never overwrite later Bible edits")
        try check(store.consumeUndo(chapterID: changed.id, currentBible: "采用后再编辑Bible") == nil, "stale Undo must not change current input")
    }

    @MainActor static func loadPreservesNewEdits() async throws {
        let h = try await Harness("loadedit")
        _ = try await fixture("config", ["chapter_get_delay": 0.25])
        let path = "/chapters/" + h.chapters[1].id
        let task = Task { await h.load(1) }
        try await eventually("chapter GET pending") { try await fixture().requests.contains { $0.path == path } }
        let text = "读取期间作者刚输入的新段落。"
        h.editor.editString(\.draftText, value: text)
        await task.value
        try check(h.editor.currentChapter?.draftText == text && h.editor.saveState == .unsaved, "GET must not overwrite new input or mark it synced")
        try check(!h.editor.isLoading, "own load must finish its indicator")
        try check(h.editor.persistLocalDraftIfNeeded(), "new input must persist")
        _ = try await fixture("config", ["chapter_get_delay": 0])
        let cold = ChapterEditorStore(session: h.session, sync: h.sync)
        let data = try JSONEncoder.lino.encode(h.chapters[1])
        await cold.load(try JSONDecoder.lino.decode(ChapterSummary.self, from: data))
        try check(cold.currentChapter?.draftText == text && cold.saveState != .synced, "cold load must restore preserved edits")
    }

    @MainActor static func loadKeepsLatestNavigation() async throws {
        let h = try await Harness("loadorder")
        _ = try await fixture("config", ["chapter_get_delay": 0.25])
        let before = try await fixture().requests.count
        let task = Task { await h.load(0) }
        try await eventually("old reload starts") { try await fixture().requests.count > before }
        _ = try await fixture("config", ["chapter_get_delay": 0])
        await h.load(1)
        await task.value
        try check(h.editor.currentChapter?.id == h.chapters[1].id && !h.editor.isLoading, "old response must not retarget latest chapter")
    }

    @MainActor static func lateLoadFailure() async throws {
        let h = try await Harness("loaderror")
        _ = try await fixture("config", ["chapter_get_delay": 0.25, "get_status": 503])
        let before = try await fixture().requests.count
        let task = Task { await h.load(0) }
        try await eventually("old failed read starts") { try await fixture().requests.count > before }
        _ = try await fixture("config", ["chapter_get_delay": 0, "get_status": 200])
        await h.load(1)
        await task.value
        try check(h.editor.currentChapter?.id == h.chapters[1].id && h.notices.history.isEmpty, "superseded load failure must not paint new chapter")
    }

    @MainActor static func pollPreservesNewEdits() async throws {
        let h = try await Harness("polledit", ["writing": true])
        try await eventually("normal poll received") { try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count >= 2 }
        // Finish the in-flight read, then edit before a subsequent observation.
        try await Task.sleep(nanoseconds: 100_000_000)
        let text = "生成期间作者保留的最新段落。"
        h.editor.editString(\.draftText, value: text)
        _ = try await fixture("config", ["job_phase": "done", "job_advances_revision": true])
        try await eventually("job terminal with author edits", attempts: 200) { !h.editor.writingPhase.isActive }
        try check(h.editor.currentChapter?.draftText == text && h.editor.saveState != .synced, "terminal poll must preserve local prose and dirty state")
        try check(h.editor.currentChapter?.status == "draft_ready", "local preserved draft cannot remain stuck writing")
        try check(!h.editor.checkerAppliesToVisibleDraft, "server result cannot approve locally edited prose")
        let cold = ChapterEditorStore(session: h.session, sync: h.sync)
        let data = try JSONEncoder.lino.encode(h.chapters[0])
        await cold.load(try JSONDecoder.lino.decode(ChapterSummary.self, from: data))
        try check(cold.currentChapter?.draftText == text && cold.saveState != .synced, "terminal poll must preserve the recovery copy too")
        try check(cold.currentChapter?.contentRevision == h.chapters[0].contentRevision, "local draft must retain its old conditional-write base")
        _ = await cold.save()
        guard let conflict = h.sync.conflict(for: .chapter, id: h.chapters[0].id) else {
            throw HTTPTestFailure(description: "saving retained edits must require explicit conflict resolution")
        }
        h.sync.keepServer(conflict)
        cold.applyServerConflictDecision(conflict)
        await cold.load(try JSONDecoder.lino.decode(ChapterSummary.self, from: data), replacingLocalPayload: conflict.localPayload)
        try check(cold.currentChapter?.draftText == h.chapters[0].draftText && cold.saveState == .synced, "explicit server choice must still replace the compared local draft")
    }

    @MainActor static func conflictDecisionOwnership() async throws {
        for inactive in [false, true] {
            for newEdit in [false, true] {
                let h = try await Harness("decision")
                h.editor.editString(\.draftText, value: "已比较的本机版本。")
                _ = try await fixture("config", ["remote_draft_text": "服务器新版本。", "patch_status": 409])
                _ = await h.editor.save()
                guard let conflict = h.sync.conflict(for: .chapter, id: h.chapters[0].id) else {
                    throw HTTPTestFailure(description: "expected comparison")
                }
                if newEdit { h.editor.editString(\.draftText, value: "比较后又输入的文字。") }
                if inactive { await h.load(1) }
                h.sync.keepServer(conflict)
                h.editor.applyServerConflictDecision(conflict)
                h.editor.discardInactiveDraft(after: conflict)
                let data = try JSONEncoder.lino.encode(h.chapters[0])
                await h.editor.load(try JSONDecoder.lino.decode(ChapterSummary.self, from: data), replacingLocalPayload: conflict.localPayload)
                let expected = newEdit ? "比较后又输入的文字。" : "服务器新版本。"
                try check(h.editor.currentChapter?.draftText == expected, "decision must apply only to compared payload (inactive=\(inactive), newEdit=\(newEdit))")
                try check((h.editor.saveState == .synced) == !newEdit, "only explicitly resolved prose is synced")
            }
        }
    }

    @MainActor static func offlineDraftRevisionMismatch() async throws {
        let h = try await Harness("offlinebase")
        let text = "服务器更新后仍须保留的本机正文。"
        h.editor.editString(\.draftText, value: text)
        try check(h.editor.persistLocalDraftIfNeeded(), "draft persisted")
        var cached = h.chapters[0]
        cached.contentRevision += 1
        cached.draftText = "不同的服务器缓存。"
        h.sync.cache.saveChapter(cached)
        _ = try await fixture("config", ["get_status": 503])
        let cold = ChapterEditorStore(session: h.session, sync: h.sync)
        let data = try JSONEncoder.lino.encode(h.chapters[0])
        await cold.load(try JSONDecoder.lino.decode(ChapterSummary.self, from: data))
        try check(cold.currentChapter?.draftText == text && cold.currentChapter?.contentRevision == h.chapters[0].contentRevision, "offline cache refresh must keep dirty text and its original base")
        try check(cold.saveState != .synced, "offline divergence cannot look synced")
    }

    @MainActor static func serverDecisionReadFailure() async throws {
        let h = try await Harness("serverchoice")
        h.editor.editString(\.draftText, value: "明确放弃的本机正文。")
        _ = try await fixture("config", ["remote_draft_text": "明确选择的服务器正文。", "patch_status": 409])
        _ = await h.editor.save()
        guard let conflict = h.sync.conflict(for: .chapter, id: h.chapters[0].id) else {
            throw HTTPTestFailure(description: "expected conflict")
        }
        h.sync.keepServer(conflict)
        h.editor.applyServerConflictDecision(conflict)
        _ = try await fixture("config", ["get_status": 503])
        let data = try JSONEncoder.lino.encode(h.chapters[0])
        await h.editor.load(try JSONDecoder.lino.decode(ChapterSummary.self, from: data), replacingLocalPayload: conflict.localPayload)
        let cold = ChapterEditorStore(session: h.session, sync: h.sync)
        await cold.load(try JSONDecoder.lino.decode(ChapterSummary.self, from: data))
        try check(cold.currentChapter?.draftText == "明确选择的服务器正文。", "failed GET and cold load cannot revive an explicitly discarded draft")
    }

    @MainActor static func conflictKeepLocal() async throws {
        let h = try await Harness("keeplocal")
        let text = "明确选择保留的本机正文。"
        h.editor.editString(\.draftText, value: text)
        _ = try await fixture("config", ["remote_draft_text": "服务器版本。", "patch_status": 409])
        _ = await h.editor.save()
        guard let conflict = h.sync.conflict(for: .chapter, id: h.chapters[0].id) else {
            throw HTTPTestFailure(description: "expected conflict")
        }
        try check(h.sync.keepLocal(conflict), "explicit local choice must be durable")
        _ = try await fixture("config", ["patch_status": 200])
        _ = await h.sync.flush(using: h.session.api)
        let data = try JSONEncoder.lino.encode(h.chapters[0])
        await h.editor.load(try JSONDecoder.lino.decode(ChapterSummary.self, from: data), replacingLocalPayload: conflict.localPayload)
        try check(h.editor.currentChapter?.draftText == text && h.editor.saveState == .synced, "successful explicit resubmit must clear the old dirty copy")
    }

    @MainActor static func unknownVisibleCheckerRecovery() async throws {
        let h = try await Harness("checkrecover", ["job_kind": "check", "job_phase": "done", "checker_target": "visible_draft"])
        _ = try await fixture("config", ["check_start_lost": true])
        _ = await h.editor.rerunChecker()
        let count = try await fixture().requests.filter { $0.path.hasSuffix("/check/start") }.count
        _ = try await fixture("config", ["check_start_lost": false])
        for _ in 0..<3 { _ = await h.editor.refreshTaskStatus() }
        await h.load(0)
        try check(h.snapshot().primaryAction == .rerunChecker, "Mac primary action must offer explicit visible recheck")
        try check(h.snapshot().taskBanner?.action == .refreshTaskStatus, "read-only refresh remains available")
        let beforeRetry = try await fixture().requests.filter { $0.path.hasSuffix("/check/start") }.count
        try check(beforeRetry == count, "refresh and cold load cannot create another model call")
        _ = await h.editor.rerunChecker()
        try check(h.editor.checkerAppliesToVisibleDraft, "explicit retry must recover a visible conclusion")
        let after = try await fixture().requests.filter { $0.path.hasSuffix("/check/start") }.count
        try check(after == count + 1, "one click starts exactly one check")
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
        try await eventually("check begins") { try await fixture().requests.contains { $0.path.hasSuffix("/check/start") } }
        await h.load(1)
        _ = await task.value
        try check(h.editor.currentChapter?.id == h.chapters[1].id && h.editor.checkerResult == nil, "old failure must not contaminate new chapter")
        try check(h.notices.history.contains { $0.message.contains("拦截") && $0.message.contains(h.book.title) }, "late unavailable must remain in located history")
    }

    @MainActor static func editedChecker() async throws {
        let h = try await Harness("editcheck", ["check_mode": "unavailable", "check_delay": 0.25])
        let task = Task { await h.editor.rerunChecker() }
        try await eventually("check begins") { try await fixture().requests.contains { $0.path.hasSuffix("/check/start") } }
        h.editor.editString(\.draftText, value: "本次新修改")
        _ = await task.value
        try check(h.editor.currentChapter?.draftText == "本次新修改" && !h.editor.checkerAppliesToVisibleDraft, "late check cannot authorize edited prose")
        try check(h.notices.history.contains { $0.message.contains("拦截") }, "editing must not swallow unavailable notice")
    }

    @MainActor static func checkerFailureShapes() async throws {
        for (mode, expected) in [("timeout", "超时"), ("invalid", "尚未得到可用结论"), ("legacy", "尚未得到可用结论")] {
            let h = try await Harness("checkshape", ["check_mode": mode])
            _ = await h.editor.rerunChecker()
            try check(h.editor.checkerResult?.hasConcreteVerdict == false, "unavailable cannot become an effective verdict")
            try check(h.notices.history.contains { $0.message.contains(expected) && $0.tone == .error }, "each unavailable shape needs a safe error notice")
            if mode == "invalid" {
                try check(!h.notices.history.contains { $0.message.contains("格式无效") }, "Checker protocol details must not leak into author notices")
            }
            try check(h.snapshot().primaryAction == .rerunChecker, "failed check must offer recheck, never normal acceptance")
            _ = try await fixture("config", ["check_mode": "passed"])
            _ = await h.editor.rerunChecker()
            try check(h.snapshot().primaryAction == .accept, "fresh successful recheck must recover")
        }
    }

    @MainActor static func checkerConfigurationStartFailure() async throws {
        let h = try await Harness("checker-config-start", [
            "job_kind": "check", "job_phase": "failed",
        ])
        // First record the durable old check identity, then make this new
        // start fail before the server can create another JobRun. Its old
        // terminal row turns obsolete on a later foreground read.
        _ = try await fixture("config", [
            "check_start_reject": true,
            "check_start_reject_code": "api_key_undecryptable",
            "job_outcome_current": false,
        ])
        _ = await h.editor.rerunChecker()
        guard case let .failed(code, _, .bibleChecking) = h.editor.writingPhase else {
            throw HTTPTestFailure(description: "a Checker configuration refusal before JobRun must persist Checker-stage failure")
        }
        try check(code == "api_key_undecryptable", "configuration refusal must retain the stable backend code")
        try check(h.editor.checkerTarget == "visible_draft", "pre-JobRun manual Checker failure must retain its visible-draft target")
        try check(h.snapshot().primaryAction == .openSettings, "manual Checker configuration failure must lead to settings")
        await h.editor.refreshActiveJobIfNeeded()
        try check(h.snapshot().primaryAction == .openSettings, "foreground reconciliation must not discard a newer local Checker configuration recovery")
        _ = await h.editor.refreshTaskStatus()
        try check(h.snapshot().primaryAction == .openSettings, "foreground refresh must not let an older failed Checker job overwrite the newer configuration recovery")
        let requests = try await fixture().requests
        try check(requests.filter { $0.path.hasSuffix("/check/start") }.count == 1, "configuration failure must never repeat the Checker POST")

        await h.load(0)
        guard case let .failed(restoredCode, _, .bibleChecking) = h.editor.writingPhase else {
            throw HTTPTestFailure(description: "configuration failure must survive a cold load as a visible Checker task")
        }
        try check(restoredCode == "api_key_undecryptable" && h.editor.checkerTarget == "visible_draft", "cold load must retain the Checker configuration recovery target")
        try check(h.snapshot().primaryAction == .openSettings, "cold-loaded Checker configuration failure must still open settings")
    }

    @MainActor static func historicalArchiveErrors() async throws {
        let reason = "relationship fact must have exactly two participants"
        let payload: [String: Any] = [
            "status": "partial", "error_code": "archive_validation_failed", "error_message": reason,
            "latest_attempt": ["status": "failed", "error_code": "archive_validation_failed", "error_message": reason],
            "diagnostics": [["code": "archive_validation_failed", "message": reason]],
        ]
        let archive = try JSONDecoder.lino.decode(ChapterArchive.self, from: JSONSerialization.data(withJSONObject: payload))
        for text in [archive.errorMessage, archive.latestAttempt?.errorMessage, archive.diagnostics.first?.message, archive.attentionSummary] {
            try check(text?.contains("两个人物") == true && text?.contains("participants") == false, "cached and server archive explanations must use readable Chinese")
        }
        try check(!LinoErrorPresenter.archiveValidationReason("unknown_private_protocol_field").contains("private_protocol"), "unknown technical text needs a safe fallback")
    }

    @MainActor static func actionChapterOwnership() async throws {
        for operation in ["generate-save", "generate-readiness", "accept"] {
            let h = try await Harness("owner-" + operation, [
                "patch_delay": operation == "generate-readiness" ? 0 : 0.4,
                "production-readiness_delay": operation == "generate-readiness" ? 0.4 : 0,
                "job_phase": "failed", "job_failure_role": "writer",
            ])
            if operation.hasPrefix("generate") {
                try check(h.snapshot().primaryAction == .retryGeneration, "test must start from a reachable V2 retry action")
            }
            let pending = Task { operation == "accept" ? await h.editor.accept() : await h.editor.generate() }
            try await eventually("action preflight begins") {
                try await fixture().requests.contains {
                    operation == "generate-readiness" ? $0.path.hasSuffix("/production-readiness") : $0.method == "PATCH"
                }
            }
            await h.load(1)
            _ = await pending.value
            let requests = try await fixture().requests
            try check(!requests.contains { $0.path.hasSuffix("/write") || $0.path.hasSuffix("/accept") }, "leaving the initiating chapter before admission must not start either chapter")
            try check(h.editor.currentChapter?.id == h.chapters[1].id && !h.editor.writingPhase.isActive, "late save must preserve B and its idle/error actions")
        }
        let h = try await Harness("owner-edit", ["production-readiness_delay": 0.3])
        let pending = Task { await h.editor.generate() }
        try await eventually("readiness starts") { try await fixture().requests.contains { $0.path.hasSuffix("/production-readiness") } }
        h.editor.editString(\.userPrompt, value: "作者在等待期间修改了剧情要求")
        _ = await pending.value
        let state = try await fixture()
        try check(!state.requests.contains { $0.path.hasSuffix("/write") }, "new local input must revoke the old action")
    }

    @MainActor static func latestJobObservationWins() async throws {
        for manual in [false, true] {
            let h = try await Harness("ordered-observer")
            _ = try await fixture("config", ["job_phase": "failed", "job_failure_role": "writer", "job_id_suffix": "-old", "job_delay": 0.4])
            let count = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
            let old = Task { await h.editor.refreshActiveJobIfNeeded() }
            try await eventually("old status request begins") { try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count > count }
            _ = try await fixture("config", ["job_phase": "done", "job_id_suffix": "-new", "job_delay": 0])
            if manual { _ = await h.editor.refreshTaskStatus() }
            else { await h.editor.refreshActiveJobIfNeeded() }
            try check(!h.editor.writingPhase.isFailed, "new run must be shown as completed")
            await old.value
            try check(!h.editor.writingPhase.isFailed, "late failed old run must not repaint a newer completed run")
        }
    }

    @MainActor static func lateSaveFailureIsolation() async throws {
        let h = try await Harness("late-save-failure", [
            "patch_status": 503, "patch_failure_delay": 0.35,
            "job_phase": "failed", "job_failure_role": "writer",
        ])
        h.editor.editString(\.draftText, value: "A章待保存的本地修改")
        let pending = Task { await h.editor.generate() }
        try await eventually("A save request begins") {
            try await fixture().requests.contains { $0.method == "PATCH" }
        }
        await h.load(1)
        try check(h.editor.currentChapter?.id == h.chapters[1].id,
                  "fixture must finish navigating to B before A fails")
        _ = await pending.value
        try check(h.editor.currentChapter?.id == h.chapters[1].id,
                  "late A failure cannot navigate away from B")
        try check(!h.snapshot().showsUnsavedLocalDraft,
                  "late A save failure must not mark synced B as locally divergent")
    }

    @MainActor static func hiddenRetryOverlappingRefresh() async throws {
        let h = try await Harness("hidden-overlap", [
            "job_kind": "write", "job_phase": "failed", "job_failure_role": "checker",
            "can_retry_checker": true,
        ])
        try await eventually("hidden retry source ready") {
            h.editor.candidateCheckerRetrySourceJobID != nil
        }
        let chapterID = h.chapters[0].id
        _ = try await fixture("config", [
            "chapter_get_delay": 0.15,
            "checker_retry_delay": 0.45,
            "checker_retry_lost": true,
            "checker_retry_admitted": false,
        ])
        let refresh = Task { await h.editor.refreshTaskStatus() }
        try await eventually("read-only refresh begins") {
            try await fixture().requests.contains {
                $0.method == "GET" && $0.path == "/chapters/" + chapterID
            }
        }
        let retry = Task { await h.editor.retryGeneratedCandidateChecker() }
        _ = await refresh.value
        _ = await retry.value
        try check(h.editor.candidateCheckerRetrySourceJobID != nil,
                  "unknown retry must retain its source after an overlapping read")
        await h.load(0)
        try check(h.snapshot().primaryAction == .retryGeneratedCandidateChecker,
                  "cold load must retain the explicit hidden retry")
        _ = try await fixture("config", [
            "chapter_get_delay": 0,
            "checker_retry_delay": 0,
            "checker_retry_lost": false,
        ])
        _ = await h.editor.retryGeneratedCandidateChecker()
        let retries = try await fixture().requests.filter { $0.path.hasSuffix("/checker/retry") }
        let ids = try retries.map {
            try JSONSerialization.jsonObject(with: Data($0.bodyText.utf8)) as! [String: Any]
        }.map { $0["request_id"] as? String }
        try check(ids.count == 2 && ids[0] != nil && ids[0] == ids[1],
                  "overlapping read must not replace the original idempotency UUID: \(ids)")
    }

    @MainActor static func manualVerdictAllowsAcceptance() async throws {
        for verdict in ["suspect", "violation"] {
            let h = try await Harness("manual-verdict-\(verdict)", ["check_mode": verdict])
            _ = await h.editor.rerunChecker()
            try check(h.snapshot().primaryAction == .acceptWithWarning, "a completed visible verdict must retain informed acceptance")
            try check(!h.editor.writingPhase.isFailed, "a concrete verdict is not an execution failure")
        }
    }

    @MainActor static func hiddenRetryLostResponse() async throws {
        for recovery in ["unconfirmed", "active", "done"] {
            let admitted = recovery != "unconfirmed"
            let h = try await Harness("hidden-lost-\(recovery)", [
                "job_kind": "write", "job_phase": "failed", "job_failure_role": "checker",
                "can_retry_checker": true, "checker_retry_lost": true,
                "checker_retry_admitted": admitted,
                "checker_retry_terminal": recovery == "done",
            ])
            try await eventually("hidden source ready") { h.editor.candidateCheckerRetrySourceJobID != nil }
            let before = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
            _ = await h.editor.retryGeneratedCandidateChecker()
            let reads = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
            try check(reads > before, "lost retry must query the server before prescribing a second POST")
            if recovery == "active" {
                try check(h.editor.writingPhase.isActive, "admitted hidden check must resume monitoring")
            } else if recovery == "done" {
                try check(!h.editor.writingPhase.isActive && !h.editor.writingPhase.isFailed, "a distinct current completed check must be adopted")
                try check(h.editor.candidateCheckerRetrySourceJobID == nil, "completed retry retires the previous retry handle")
            } else {
                try check(h.snapshot().primaryAction == .retryGeneratedCandidateChecker, "unconfirmed hidden request retains an idempotent explicit retry")
                _ = await h.editor.refreshTaskStatus()
                await h.load(0)
                try check(h.snapshot().primaryAction == .retryGeneratedCandidateChecker, "retry identity and source must survive cold load")
                _ = try await fixture("config", ["checker_retry_lost": false])
            }
            _ = await h.editor.retryGeneratedCandidateChecker()
            let posts = try await fixture().requests.filter { $0.path.hasSuffix("/checker/retry") }.count
            try check(posts == (admitted ? 1 : 2), "only an explicit unconfirmed retry may repeat the request")
            if !admitted {
                let retries = try await fixture().requests.filter { $0.path.hasSuffix("/checker/retry") }
                let ids = try retries.map { try JSONSerialization.jsonObject(with: Data($0.bodyText.utf8)) as! [String: Any] }.map { $0["request_id"] as? String }
                try check(ids.count == 2 && ids[0] != nil && ids[0] == ids[1], "restart must preserve the same idempotency identity")
            }
            _ = try await fixture("config", ["job_phase": "done", "checker_retry_lost": false])
            if admitted { try await eventually("hidden monitor ended") { !h.editor.writingPhase.isActive } }
        }
    }

    @MainActor static func iosForegroundChecks() async throws {
        for finalized in [false, true] {
            let h = try await Harness("ios-foreground-\(finalized)", ["finalized": finalized])
            _ = try await fixture("config", ["job_kind": "check", "job_phase": "failed", "checker_target": "visible_draft"])
            let before = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
            h.editor.handleScenePhaseActive()
            try await eventually("foreground adopts cross-device check") { h.editor.writingPhase.isFailed }
            let reads = try await fixture().requests.filter { $0.path.hasSuffix("/job") }.count
            try check(reads > before && h.snapshot().primaryAction == .rerunChecker, "foreground must discover a check without changing the chapter status")
        }
    }

    @MainActor static func legacyVisibleRetryFlag() async throws {
        let h = try await Harness("legacy-visible-retry", [
            "job_kind": "check", "job_phase": "failed", "checker_target": "visible_draft", "can_retry_checker": true,
        ])
        try await eventually("visible failure loaded") { h.editor.writingPhase.isFailed }
        try check(h.editor.candidateCheckerRetrySourceJobID == nil, "visible draft must never acquire a hidden retry handle")
        try check(h.snapshot().primaryAction == .rerunChecker, "visible failure must recheck the visible draft")
    }

    @MainActor static func unknownCheckerStartStaysUnconfirmed() async throws {
        let h = try await Harness("checker-start-lost", [
            "job_kind": "check", "job_phase": "failed", "check_start_lost": true,
        ])
        _ = await h.editor.rerunChecker()
        guard case let .failed(code, _, nil) = h.editor.writingPhase else {
            throw HTTPTestFailure(description: "lost Checker start must remain an unconfirmed start, not an old terminal job")
        }
        try check(code == "checker_start_unconfirmed" && h.editor.checkerTarget == "visible_draft", "unconfirmed start must retain its visible Checker target")
        try check(h.snapshot().primaryAction == .rerunChecker && h.snapshot().taskBanner?.action == .refreshTaskStatus, "unconfirmed start offers explicit recheck and read-only refresh")
        _ = await h.editor.refreshTaskStatus()
        guard case let .failed(refreshedCode, _, nil) = h.editor.writingPhase else {
            throw HTTPTestFailure(description: "refresh must not adopt a pre-existing terminal Checker job as this request")
        }
        try check(refreshedCode == "checker_start_unconfirmed", "refresh must preserve the unconfirmed start state")
        await h.load(0)
        guard case let .failed(reloadedCode, _, nil) = h.editor.writingPhase else {
            throw HTTPTestFailure(description: "cold load must preserve the unconfirmed start state")
        }
        try check(reloadedCode == "checker_start_unconfirmed" && h.snapshot().primaryAction == .rerunChecker, "cold load must not turn the old terminal job into a result for the lost POST")
        let requests = try await fixture().requests
        try check(requests.filter { $0.path.hasSuffix("/check/start") }.count == 1, "unconfirmed start recovery must never repeat the POST")
    }

    @MainActor static func hiddenCheckerConfigurationStartFailure() async throws {
        let h = try await Harness("hidden-checker-config-start", [
            "job_kind": "check", "job_phase": "failed",
            "checker_target": "generated_candidate", "can_retry_checker": true,
            "checker_retry_reject": true,
            "checker_retry_reject_code": "api_key_undecryptable",
        ])
        try await eventually("hidden retry source before configuration refusal") {
            h.editor.candidateCheckerRetrySourceJobID != nil
        }
        _ = await h.editor.retryGeneratedCandidateChecker()
        guard case let .failed(code, _, .bibleChecking) = h.editor.writingPhase else {
            throw HTTPTestFailure(description: "a hidden Checker configuration refusal must keep Checker-stage recovery")
        }
        try check(code == "api_key_undecryptable", "hidden configuration refusal must retain the backend code")
        try check(h.snapshot().primaryAction == .openSettings, "hidden configuration refusal must lead to settings")
        try check(h.editor.candidateCheckerRetrySourceJobID != nil, "configuration refusal must retain the private retry handle")
        _ = await h.editor.refreshTaskStatus()
        try check(h.snapshot().primaryAction == .openSettings, "foreground refresh must not restore the older hidden terminal result")
        await h.load(0)
        guard case let .failed(reloadedCode, _, .bibleChecking) = h.editor.writingPhase else {
            throw HTTPTestFailure(description: "hidden configuration recovery must survive a cold load")
        }
        try check(reloadedCode == "api_key_undecryptable" && h.snapshot().primaryAction == .openSettings, "cold load must retain hidden Checker configuration recovery")
        try check(h.editor.candidateCheckerRetrySourceJobID != nil, "cold load must retain the private retry handle")
        let requests = try await fixture().requests
        try check(requests.filter { $0.path.hasSuffix("/checker/retry") }.count == 1, "hidden configuration recovery must never repeat its POST")
        // Repair settings after a cold load, then lose the response of a new
        // retry that has already completed. Its distinct ID must resolve the
        // action, not become the next permanently ignored terminal record.
        _ = try await fixture("config", [
            "checker_retry_reject": false, "checker_retry_lost": true,
            "checker_retry_admitted": true, "checker_retry_terminal": true,
        ])
        _ = await h.editor.retryGeneratedCandidateChecker()
        try check(!h.editor.writingPhase.isFailed && !h.editor.writingPhase.isActive,
                  "cold-loaded configuration recovery must recognize a distinct completed retry")
        try check(h.editor.candidateCheckerRetrySourceJobID == nil, "completed retry must retire the restored handle")
    }

    @MainActor static func obsoleteRemoteCheckerClearsEvidence() async throws {
        let h = try await Harness("obsolete-visible-check")
        _ = await h.editor.rerunChecker()
        try check(h.editor.checkerAppliesToVisibleDraft && h.editor.checkerResult?.isPassed == true, "fixture must establish current visible Checker evidence")

        _ = try await fixture("config", [
            "remote_draft_text": "另一台设备已更新的正文。",
            "job_kind": "check",
            "job_phase": "done",
            "job_outcome_current": false,
        ])
        _ = await h.editor.refreshTaskStatus()
        try check(h.editor.currentChapter?.draftText == "另一台设备已更新的正文。", "refresh must accept the remote chapter before reconciling its stale job")
        try check(h.editor.checkerResult == nil && !h.editor.checkerAppliesToVisibleDraft, "obsolete terminal Checker status must clear the old pass instead of leaving it on remote prose")
        try check(h.editor.checkerTarget == nil && h.editor.candidateCheckerRetrySourceJobID == nil, "obsolete terminal Checker status must also clear recovery handles")
        try check(h.snapshot().primaryAction == .rerunChecker, "remote replacement with an obsolete check result must require a fresh visible recheck")
    }

    @MainActor static func remoteInputInvalidatesCheckerBeforeJobRead() async throws {
        let h = try await Harness("remote-input-job-down")
        _ = await h.editor.rerunChecker()
        try check(h.editor.checkerAppliesToVisibleDraft && h.snapshot().primaryAction == .accept, "fixture must establish a current pass before the remote replacement")
        _ = try await fixture("config", [
            "remote_draft_text": "远端已替换正文。",
            "job_status": 503,
        ])
        _ = await h.editor.refreshTaskStatus()
        try check(h.editor.currentChapter?.draftText == "远端已替换正文。", "successful chapter refresh must expose authoritative remote prose")
        try check(h.editor.checkerResult == nil && !h.editor.checkerAppliesToVisibleDraft, "remote input replacement must clear old Checker evidence even when /job fails")
        try check(h.snapshot().primaryAction == .rerunChecker, "old pass cannot keep accept enabled after remote prose replacement")
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
        try check(!before.contains { $0.path.hasSuffix("/check/start") }, "history warning must not silently start Checker")
        guard let capturedConfirmation = h.editor.pendingProductionContext else {
            throw HTTPTestFailure(description: "missing history confirmation")
        }
        // SwiftUI closes confirmationDialog before the action Task resumes.
        // The captured value must still authorize this one request.
        h.editor.dismissProductionContextConfirmation()
        _ = await h.editor.confirmProductionContextAndContinue(capturedConfirmation)
        let after = try await fixture().requests
        guard let checkEvent = after.last(where: { $0.path.hasSuffix("/check/start") }) else {
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
                try check(h.snapshot().primaryAction == .rerunChecker, "failed manual Checker must restore a recheck action instead of Writer generation")
            }
            if phase == "cancelled" {
                guard case .cancelled(_, .bibleChecking) = h.editor.writingPhase else {
                    throw HTTPTestFailure(description: "manual check cancellation must name the Checker stage")
                }
                try check(h.snapshot().primaryAction == .rerunChecker, "cancelled manual Checker must restore a recheck action instead of Writer generation")
                try check(h.snapshot().taskBanner?.action == .rerunChecker, "cancelled manual Checker banner must restore the same recheck action")
            }
        }

        let missingProjection = try await Harness("manual-check-no-projection", [
            "job_kind": "check", "job_phase": "idle",
        ])
        _ = await missingProjection.editor.rerunChecker()
        try check(missingProjection.editor.checkerAppliesToVisibleDraft, "fixture must first establish current visible Checker evidence")
        _ = try await fixture("config", ["job_kind": "check", "job_phase": "done", "job_without_visible_checker": true])
        await missingProjection.load(0)
        try check(!missingProjection.editor.checkerAppliesToVisibleDraft && missingProjection.editor.checkerResult == nil, "a current done check without visible evidence must clear an old pass badge")
        try check(missingProjection.snapshot().primaryAction == .rerunChecker, "a done check without a visible result must require a fresh recheck")
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
        try check(!newRequests.contains { $0.path.hasSuffix("/write") || $0.path.hasSuffix("/check/start") }, "candidate retry must not start Writer or recheck visible draft")
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
            try check(repeated.notices.history.contains { $0.message.contains("尚未得到可用结论") }, "candidate Checker protocol failure must offer a safe recovery reason")
            try check(!repeated.notices.history.contains { $0.message.contains("姓名分组") }, "candidate Checker protocol diagnostics must remain private")
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

        let retryStartFailure = try await Harness("candidate-retry-start-failure", [
            "writing": true, "job_checker_rejected": true, "can_retry_checker": true,
            "checker_retry_failure": true,
            "checker_retry_error_code": "checker_retry_start_failed",
        ])
        try await eventually("retry-start source available") { retryStartFailure.editor.candidateCheckerRetrySourceJobID != nil }
        _ = await retryStartFailure.editor.retryGeneratedCandidateChecker()
        try check(retryStartFailure.snapshot().taskBanner?.text == "检查未能完成，生成稿已保留，当前正文未变", "retry start failure must be unavailable, never a rejected generated draft")
        try check(retryStartFailure.snapshot().primaryAction == .retryGeneratedCandidateChecker, "retry start failure must keep the generated-candidate retry action")

        let retryExecutionFailure = try await Harness("candidate-retry-execution-failure", [
            "writing": true, "job_checker_rejected": true, "can_retry_checker": true,
            "checker_retry_failure": true,
            "checker_retry_error_code": "checker_retry_failed",
        ])
        try await eventually("retry-execution source available") { retryExecutionFailure.editor.candidateCheckerRetrySourceJobID != nil }
        _ = await retryExecutionFailure.editor.retryGeneratedCandidateChecker()
        try check(retryExecutionFailure.snapshot().taskBanner?.text == "检查未能完成，生成稿已保留，当前正文未变", "structured unavailable Checker result must outrank an execution error code")
        try check(retryExecutionFailure.snapshot().primaryAction == .retryGeneratedCandidateChecker, "unavailable candidate retry execution must remain a candidate-only retry")

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
