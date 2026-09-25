import Foundation
import SwiftUI

@MainActor
final class AppSession: ObservableObject {
    @Published var baseURL = ""
    @Published var token = ""
    @Published var currentBook: Book?
    @Published var selectedTab: WorkspaceTab = .chapters

    let notices: NoticeBus

    init(notices: NoticeBus) {
        self.notices = notices
    }

    var api: APIClient {
        APIClient(baseURL: baseURL, token: token)
    }

    func bootstrap() async {
        #if DEBUG
        if DebugRuntimeConfiguration.isIsolated {
            // The validation configuration is all-or-nothing: never fill a
            // missing test value from the author's production keychain.
            baseURL = DebugRuntimeConfiguration.value(for: "LINOI_DEBUG_BASE_URL") ?? ""
            token = DebugRuntimeConfiguration.value(for: "LINOI_DEBUG_TOKEN") ?? ""
            return
        }
        #endif
        let migration = ConnectionEndpoint.migratedBaseURL(
            saved: UserDefaults.standard.string(forKey: "linoi.baseURL")
        )
        if migration.shouldPersist {
            UserDefaults.standard.set(migration.value, forKey: "linoi.baseURL")
        }
        let savedToken = KeychainStore.get("appToken")
        #if DEBUG
        baseURL = DebugRuntimeConfiguration.value(for: "LINOI_DEBUG_BASE_URL") ?? migration.value
        token = DebugRuntimeConfiguration.value(for: "LINOI_DEBUG_TOKEN") ?? savedToken
        #else
        baseURL = migration.value
        token = savedToken
        #endif
    }

    func saveConnection() {
        #if DEBUG
        if DebugRuntimeConfiguration.isIsolated { return }
        #endif
        UserDefaults.standard.set(baseURL, forKey: "linoi.baseURL")
        KeychainStore.set(token, for: "appToken")
    }

    func closeBook() {
        currentBook = nil
        selectedTab = .chapters
    }
}

@MainActor
final class BookshelfStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var isLoading = false

    private let session: AppSession
    let sync: ClientSyncStore

    init(session: AppSession, sync: ClientSyncStore = ClientSyncStore()) {
        self.session = session
        self.sync = sync
        books = sync.cache.books()
    }

    /// `true` only means the shelf was actually read from the configured
    /// backend. A warm cache, an empty shelf, or a skipped no-token load must
    /// never be used as proof that a new connection succeeded.
    @discardableResult
    func load() async -> Bool {
        // Cold start is local-first: a Ningbo outage must not turn a book the
        // author already opened into an empty shelf.
        if books.isEmpty { books = sync.cache.books() }
        guard !session.token.isEmpty else { sync.markOffline(); return false }
        isLoading = true
        defer { isLoading = false }
        do {
            await sync.flush(using: session.api)
            books = try await session.api.request("/books")
            sync.cache.saveBooks(books)
            sync.markOnline()
            return true
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
            return false
        }
    }

    @discardableResult
    func createBook(title: String, world: String = "") async -> Book? {
        do {
            let payload = BookPayload(title: title, world_setting: world)
            let book: Book = try await session.api.request("/books", method: "POST", body: payload)
            books.insert(book, at: 0)
            sync.upsertBook(book)
            sync.markOnline()
            session.currentBook = book
            return book
        } catch {
            session.notices.publish(error)
            return nil
        }
    }

    func open(_ book: Book) async {
        session.currentBook = book
        do {
            session.currentBook = try await session.api.request("/books/\(book.id)")
            if let current = session.currentBook { sync.upsertBook(current) }
            sync.markOnline()
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
        }
    }

    func upsert(_ book: Book) {
        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx] = book
        } else {
            books.insert(book, at: 0)
        }
        sync.upsertBook(book)
    }

    func delete(_ book: Book) async {
        do {
            try await session.api.rawRequest("/books/\(book.id)", method: "DELETE", ifMatch: book.contentRevision)
            books.removeAll { $0.id == book.id }
            sync.cache.saveBooks(books)
            sync.markOnline()
            if session.currentBook?.id == book.id {
                session.closeBook()
            }
        } catch {
            if let conflict = error as? APIError,
               case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .book, id: book.id, path: "/books/\(book.id)", method: "DELETE",
                    baseRevision: book.contentRevision, payload: EmptyMutationPayload(), baseSnapshot: book,
                    error: conflict, api: session.api
                )
            } else if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
        }
    }

    /// Full project backups are always prepared by the Backend in one
    /// response. This keeps a many-chapter export from becoming a partial
    /// client-side loop and gives both platforms one file-transfer seam.
    func exportProject(_ book: Book) async -> Data? {
        guard sync.networkActionsAvailable else {
            session.notices.publish("离线时不能创建项目包，请恢复网络后重试。")
            return nil
        }
        do {
            let data = try await session.api.exportProject(bookID: book.id)
            sync.markOnline()
            return data
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
            return nil
        }
    }

    func exportData(_ book: Book) async -> BookExportData? {
        guard sync.networkActionsAvailable else {
            session.notices.publish("离线时不能导出，请恢复网络后重试。")
            return nil
        }
        do {
            let data = try await session.api.exportData(bookID: book.id)
            sync.markOnline()
            return data
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
            return nil
        }
    }

    @discardableResult
    func importProject(_ data: Data) async -> ProjectImportResult? {
        guard sync.networkActionsAvailable else {
            session.notices.publish("离线时不能导入项目包，请恢复网络后重试。")
            return nil
        }
        do {
            let result = try await session.api.importProject(data)
            // Import is explicitly a new book; fetch its public form rather
            // than constructing a partial local Book from the response.
            let book: Book = try await session.api.request("/books/\(result.bookID)")
            upsert(book)
            sync.markOnline()
            return result
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
            return nil
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var chapters: [ChapterSummary] = []
    @Published private(set) var isLoading = false
    /// Bound to `RootView`'s `NavigationStack(path:)` so a freshly created
    /// chapter can be pushed onto the stack programmatically.
    @Published var chapterPath: [ChapterSummary] = []

    private let session: AppSession
    let sync: ClientSyncStore

    init(session: AppSession, sync: ClientSyncStore = ClientSyncStore()) {
        self.session = session
        self.sync = sync
    }

    /// Opens a book's chapter list. Clearing `chapterPath` is part of the
    /// contract here: it unwinds any pushed chapter destination, which is what
    /// makes this the right call after the visible chapter has been deleted.
    func load(bookId: String) async {
        chapterPath = []
        let cached = sync.cache.chapters(bookID: bookId)
        if !cached.isEmpty { chapters = cached }
        await refreshChapters(bookId: bookId)
    }

    /// Re-reads the chapter list **without** touching `chapterPath`. Callers
    /// that only need the rail's rows and staleness markers brought up to date
    /// must use this: `load(bookId:)` would additionally pop the author out of
    /// the chapter they are standing in, which turns "refresh the markers I
    /// just promised you" or "your delete was rejected" into a loss of place.
    func refreshChapters(bookId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            await sync.flush(using: session.api)
            chapters = try await session.api.request("/books/\(bookId)/chapters")
            sync.cache.saveChapters(chapters, bookID: bookId)
            sync.markOnline()
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
        }
    }

    /// Creates an actual new chapter at the end of the book. Chapter-to-chapter reading must
    /// use `replaceCurrentDestination(with:)` instead; it never creates data.
    @discardableResult
    func createChapter(replacingCurrentDestination: Bool = false) async -> ChapterSummary? {
        guard let book = session.currentBook else { return nil }
        do {
            let payload = ChapterCreatePayload(title: "新章节", user_prompt: "")
            let chapter: Chapter = try await session.api.request("/books/\(book.id)/chapters", method: "POST", body: payload)
            sync.cache.saveChapter(chapter)
            upsert(chapter)
            chapters = try await session.api.request("/books/\(book.id)/chapters")
            sync.cache.saveChapters(chapters, bookID: book.id)
            sync.markOnline()
            if let created = chapters.first(where: { $0.id == chapter.id }) {
                replaceCurrentDestination(with: created, orAppend: !replacingCurrentDestination)
                return created
            }
            return nil
        } catch {
            session.notices.publish(error)
            return nil
        }
    }

    /// Replaces the visible chapter destination so continuous reading remains
    /// one navigation level deep. The rail and legacy callers can still append
    /// their first destination through the default behavior.
    func replaceCurrentDestination(with summary: ChapterSummary, orAppend: Bool = true) {
        guard !chapterPath.isEmpty else {
            if orAppend { chapterPath.append(summary) }
            return
        }
        chapterPath[chapterPath.count - 1] = summary
    }

    @discardableResult
    func saveBook(title: String, world: String) async -> Bool {
        guard let book = session.currentBook else { return false }
        let payload = BookPayload(title: title, world_setting: world)
        let baseBook = sync.cache.books().first(where: { $0.id == book.id }) ?? book
        let base = BookPayload(title: baseBook.title, world_setting: baseBook.worldSetting)
        do {
            let updated: Book = try await session.api.request("/books/\(book.id)", method: "PATCH", body: payload, ifMatch: book.contentRevision)
            session.currentBook = updated
            sync.upsertBook(updated)
            sync.acknowledge(kind: .book, id: book.id)
            sync.markOnline()
            return true
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(kind: .book, id: book.id, path: "/books/\(book.id)", method: "PATCH", baseRevision: book.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api)
                session.notices.publish(error)
            } else if !sync.enqueueDirectFailure(
                error, kind: .book, id: book.id, path: "/books/\(book.id)", method: "PATCH",
                baseRevision: book.contentRevision, payload: payload, baseSnapshot: base
            ) {
                session.notices.publish("书籍修改未能安全进入同步队列，请保留当前页面后重试。", critical: true)
            }
            return false
        }
    }

    func upsert(_ chapter: Chapter) {
        let summary = ChapterSummary(
            id: chapter.id,
            bookId: chapter.bookId,
            index: chapter.index,
            title: chapter.title,
            status: chapter.status,
            source: chapter.source,
            updatedAt: chapter.updatedAt,
            archiveStatus: chapter.archive?.status ?? "stale",
            archiveSchema: chapter.archive?.archiveSchema ?? "none",
            archiveCanRetry: chapter.archive?.canRetry ?? false,
            archiveLatestAttemptStatus: chapter.archive?.latestAttemptStatus,
            archiveEffectiveStatus: chapter.archive?.effectiveStatus ?? "none",
            archiveStateStatus: chapter.archive?.stateStatus ?? "none",
            archiveStateUncertaintyCount: chapter.archive?.stateUncertainties.count ?? 0,
            contentRevision: chapter.contentRevision
        )
        upsert(summary)
    }

    func upsert(_ summary: ChapterSummary) {
        if let idx = chapters.firstIndex(where: { $0.id == summary.id }) {
            chapters[idx] = summary
        } else {
            chapters.append(summary)
            chapters.sort { $0.index < $1.index }
        }
    }

    func removeChapter(id: String) {
        chapters.removeAll { $0.id == id }
        if let bookID = session.currentBook?.id { sync.cache.saveChapters(chapters, bookID: bookID) }
    }
}

@MainActor
final class CharactersStore: ObservableObject {
    @Published private(set) var characters: [Character] = []
    @Published var selectedCharacterId: String?
    @Published private(set) var isLoading = false

    private let session: AppSession
    let sync: ClientSyncStore

    init(session: AppSession, sync: ClientSyncStore = ClientSyncStore()) {
        self.session = session
        self.sync = sync
    }

    var selected: Character? {
        if let selectedCharacterId,
           let found = characters.first(where: { $0.id == selectedCharacterId }) {
            return found
        }
        return characters.first
    }

    func load(bookId: String) async {
        let cached = sync.cache.characters(bookID: bookId)
        if !cached.isEmpty { characters = cached; ensureSelection() }
        isLoading = true
        defer { isLoading = false }
        do {
            await sync.flush(using: session.api)
            characters = try await session.api.request("/books/\(bookId)/characters")
            sync.cache.saveCharacters(characters, bookID: bookId)
            sync.markOnline()
            ensureSelection()
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
        }
    }

    @discardableResult
    func create(name: String, role: String = "", fixedProfile: String = "") async -> Character? {
        guard let book = session.currentBook else { return nil }
        do {
            let payload = CharacterPatchPayload(name: name, role: role, fixed_profile: fixedProfile)
            let character: Character = try await session.api.request("/books/\(book.id)/characters", method: "POST", body: payload)
            characters.append(character)
            sync.cache.saveCharacters(characters, bookID: book.id)
            sync.markOnline()
            selectedCharacterId = character.id
            return character
        } catch {
            session.notices.publish(error)
            return nil
        }
    }

    func importCharacter(name: String, role: String, text: String) async {
        guard let book = session.currentBook else { return }
        do {
            let item = CharacterImportItem(name: name, role: role, fixed_profile: text)
            let payload = CharacterImportPayload(items: [item])
            let imported: [Character] = try await session.api.request("/books/\(book.id)/characters/import", method: "POST", body: payload)
            characters.append(contentsOf: imported)
            if let first = imported.first { selectedCharacterId = first.id }
        } catch {
            session.notices.publish(error)
        }
    }

    @discardableResult
    func update(_ character: Character) async -> Bool {
        let payload = CharacterPatchPayload(character)
        let baseCharacter = sync.cache.characters(bookID: character.bookId).first(where: { $0.id == character.id }) ?? character
        let base = CharacterPatchPayload(baseCharacter)
        do {
            let updated: Character = try await session.api.request("/characters/\(character.id)", method: "PATCH", body: payload, ifMatch: character.contentRevision)
            replace(updated)
            sync.cache.saveCharacters(characters, bookID: updated.bookId)
            sync.acknowledge(kind: .character, id: character.id)
            sync.markOnline()
            return true
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(kind: .character, id: character.id, path: "/characters/\(character.id)", method: "PATCH", baseRevision: character.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api)
                session.notices.publish(error)
            } else if !sync.enqueueDirectFailure(
                error, kind: .character, id: character.id, path: "/characters/\(character.id)", method: "PATCH",
                baseRevision: character.contentRevision, payload: payload, baseSnapshot: base
            ) {
                session.notices.publish("人物修改未能安全进入同步队列，请保留当前页面后重试。", critical: true)
            }
            return false
        }
    }

    @discardableResult
    func delete(_ character: Character) async -> Bool {
        do {
            try await session.api.rawRequest("/characters/\(character.id)", method: "DELETE", ifMatch: character.contentRevision)
            characters.removeAll { $0.id == character.id }
            sync.cache.saveCharacters(characters, bookID: character.bookId)
            sync.markOnline()
            ensureSelection()
            return true
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(kind: .character, id: character.id, path: "/characters/\(character.id)", method: "DELETE", baseRevision: character.contentRevision, payload: EmptyMutationPayload(), baseSnapshot: character, error: conflict, api: session.api)
            } else if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
            return false
        }
    }

    func replace(_ character: Character) {
        if let idx = characters.firstIndex(where: { $0.id == character.id }) {
            characters[idx] = character
        } else {
            characters.append(character)
        }
        sync.cache.saveCharacters(characters, bookID: character.bookId)
    }

    @discardableResult
    func updateEvent(_ event: CharacterEvent, text: String) async -> Bool {
        let payload = CharacterEventPatchPayload(event_text: text)
        let base = CharacterEventPatchPayload(event_text: event.eventText)
        do {
            let updated: CharacterEvent = try await session.api.request("/character-events/\(event.id)", method: "PATCH", body: payload, ifMatch: event.contentRevision)
            applyEventUpdate(updated)
            sync.acknowledge(kind: .characterEvent, id: event.id)
            sync.markOnline()
            return true
        } catch {
            if let conflict = error as? APIError,
               case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .characterEvent, id: event.id, path: "/character-events/\(event.id)", method: "PATCH",
                    readPath: "/character-events/\(event.id)", readStrategy: .direct,
                    baseRevision: event.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api
                )
                session.notices.publish(error)
                return false
            }
            guard sync.enqueueDirectFailure(
                error, kind: .characterEvent, id: event.id,
                path: "/character-events/\(event.id)", method: "PATCH",
                baseRevision: event.contentRevision,
                payload: payload, baseSnapshot: base
            ) else {
                session.notices.publish("人物记录未能安全保存在本机，请保留编辑框后重试。", critical: true)
                return false
            }
            if case APIError.transport = error {
                var local = event
                local.eventText = text
                applyEventUpdate(local)
                session.notices.publish("当前离线，人物记录已保存在本机，恢复网络后会安全同步。")
                return true
            }
            var local = event
            local.eventText = text
            applyEventUpdate(local)
            return false
        }
    }

    func deleteEvent(_ event: CharacterEvent) async {
        guard sync.networkActionsAvailable else {
            session.notices.publish("离线时不能删除人物记录；恢复连接后再试。")
            return
        }
        do {
            try await session.api.rawRequest("/character-events/\(event.id)", method: "DELETE", ifMatch: event.contentRevision)
            removeEvent(event)
            sync.markOnline()
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .characterEvent, id: event.id, path: "/character-events/\(event.id)", method: "DELETE",
                    readPath: "/character-events/\(event.id)", readStrategy: .direct,
                    baseRevision: event.contentRevision, payload: EmptyMutationPayload(), baseSnapshot: EmptyMutationPayload(), error: conflict, api: session.api
                )
            }
            session.notices.publish(error)
        }
    }

    private func applyEventUpdate(_ event: CharacterEvent) {
        guard let charIdx = characters.firstIndex(where: { $0.id == event.characterId }) else { return }
        guard let eventIdx = characters[charIdx].events.firstIndex(where: { $0.id == event.id }) else { return }
        characters[charIdx].events[eventIdx] = event
        sync.cache.saveCharacters(characters, bookID: characters[charIdx].bookId)
    }

    private func removeEvent(_ event: CharacterEvent) {
        guard let charIdx = characters.firstIndex(where: { $0.id == event.characterId }) else { return }
        characters[charIdx].events.removeAll { $0.id == event.id }
        sync.cache.saveCharacters(characters, bookID: characters[charIdx].bookId)
    }

    func ensureSelection() {
        if selectedCharacterId == nil || !characters.contains(where: { $0.id == selectedCharacterId }) {
            selectedCharacterId = characters.first?.id
        }
    }
}

@MainActor
final class ChapterEditorStore: ObservableObject {
    enum ProductionContextAction: String, Sendable {
        case write, check, archiveRetry
        var title: String {
            switch self {
            case .write: "开始写作"
            case .check: "复查正文"
            case .archiveRetry: "重新整理记忆"
            }
        }
    }

    struct PendingProductionContext: Identifiable, Sendable {
        let action: ProductionContextAction
        let chapterID: String
        let readiness: ProductionReadiness
        var id: String { "\(action.rawValue)|\(chapterID)|\(readiness.contextToken)" }
    }

    @Published var currentChapter: Chapter?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var writingPhase: ChapterWritingPhase = .idle
    @Published private(set) var saveState: ChapterSaveState = .synced
    @Published private(set) var pollingConnectionInterrupted = false
    /// A stopped monitor is deliberately separate from a failed server job.
    /// It carries a safe reason and enables a read-only refresh without
    /// inventing a terminal outcome.
    @Published private(set) var taskMonitoringMessage: String?
    /// Latest deterministic validation explanation. It never represents a
    /// model edit; failed candidates remain backend-only audit records.
    @Published private(set) var currentValidationReason: String?
    @Published private(set) var memoryContext: MemoryContext?
    @Published private(set) var checkerResult: CheckerResult?
    /// Checker metadata for the latest rejected backend-only candidate. This
    /// is intentionally separate from `checkerResult`, which always belongs
    /// to the text currently visible in the editor.
    @Published private(set) var failedCandidateCheckerResult: CheckerResult?
    @Published private(set) var checkerAppliesToVisibleDraft = false
    @Published private(set) var checkerRefreshing = false
    /// A length-only deterministic preflight can be consciously accepted;
    /// character/empty-body failures never set this value.
    @Published private(set) var preflightAcceptanceMessage: String?
    /// Local-only previous result, retained after edits strictly as stale
    /// context. It can never unlock acceptance or be sent back to Backend.
    @Published private(set) var staleCheckedSnapshot: CheckedDraftSnapshot?
    @Published private(set) var restoredLocalDraft = false
    /// Names the last preflight/job failure reported as unauthorized-but-present.
    /// Non-empty exactly when the editor should offer "本章豁免并重试".
    @Published private(set) var pendingExemptionNames: [String] = []
    @Published private(set) var pendingProductionContext: PendingProductionContext?
    /// Only the opaque server job ID is retained for the candidate retry.
    @Published private(set) var candidateCheckerRetrySourceJobID: String?
    /// Backend-declared Checker object identity. This is never inferred from
    /// parent_job_id because visible prose may have originated from Writer.
    @Published private(set) var checkerTarget: String?

    private let session: AppSession
    let sync: ClientSyncStore
    private let cache = ChapterDraftCache()
    private var pollingTask: Task<Void, Never>?
    private var pollingChapterId: String?
    private var pollingMonitorID: UUID?
    private var pollingErrorNotified = false
    private var actionOperationID: UUID?
    private var taskRefreshRequestID: UUID?
    /// Most recently observed durable task identity for this chapter. A
    /// configuration rejection can occur before a new JobRun exists, so it
    /// records which older terminal run it supersedes.
    private var latestTaskJobID: String?
    private var protectsPreJobCheckerFailure = false
    private var supersededCheckerJobID: String?
    private var localEditRevision: UInt64 = 0

    init(session: AppSession, sync: ClientSyncStore = ClientSyncStore()) {
        self.session = session
        self.sync = sync
    }

    var draftCharCount: Int {
        currentChapter?.draftText.filter { !$0.isWhitespace }.count ?? 0
    }

    /// Identity choices are valid only when they were returned for the text
    /// presently on screen. Hidden generated candidates never reach this
    /// property, so a clarification card cannot reveal or act on them.
    var visibleIdentityIssues: [CheckerIdentityIssue] {
        guard checkerAppliesToVisibleDraft else { return [] }
        return checkerResult?.identityIssues ?? []
    }

    var staleCheckerChangedRanges: [Range<String.Index>] {
        guard let chapter = currentChapter,
              let snapshot = staleCheckedSnapshot,
              snapshot.chapterID == chapter.id,
              CheckerSnapshotPresentationPolicy.shouldShowStaleSnapshot(
                hasConcreteSnapshot: snapshot.checkerResult.hasConcreteVerdict,
                checkerAppliesToVisibleDraft: checkerAppliesToVisibleDraft,
                currentCheckerResult: checkerResult
              ) else { return [] }
        return CheckedDraftSentenceDiff.changedRanges(previous: snapshot.draftText, current: chapter.draftText)
    }

    var hasStaleCheckedSnapshot: Bool {
        CheckerSnapshotPresentationPolicy.shouldShowStaleSnapshot(
            hasConcreteSnapshot: staleCheckedSnapshot?.checkerResult.hasConcreteVerdict == true,
            checkerAppliesToVisibleDraft: checkerAppliesToVisibleDraft,
            currentCheckerResult: checkerResult
        )
    }

    var presentationState: ChapterEditorPresentationState {
        ChapterEditorPresentationState.make(
            phase: writingPhase,
            chapterStatus: currentChapter?.status,
            checkerVerdict: checkerAppliesToVisibleDraft ? checkerResult?.displayVerdict : nil,
            validationReason: currentValidationReason,
            saveState: saveState,
            connectionInterrupted: pollingConnectionInterrupted
        )
    }

    private func beginAction() -> UUID {
        let operationID = UUID()
        actionOperationID = operationID
        return operationID
    }

    private func actionIsCurrent(_ operationID: UUID, chapterID: String, revision: UInt64) -> Bool {
        actionOperationID == operationID
            && currentChapter?.id == chapterID
            && localEditRevision == revision
    }

    private func invalidateInFlightOperations() {
        actionOperationID = nil
        taskRefreshRequestID = nil
    }

    func load(_ summary: ChapterSummary) async {
        guard persistLocalDraftIfNeeded() else { return }
        if currentChapter?.id != summary.id {
            invalidateInFlightOperations()
            if let pollingChapterId, pollingChapterId != summary.id {
                stopPolling(for: pollingChapterId)
            }
        }
        isLoading = true
        restoredLocalDraft = false
        pollingConnectionInterrupted = false
        taskMonitoringMessage = nil
        memoryContext = nil
        checkerResult = nil
        failedCandidateCheckerResult = nil
        candidateCheckerRetrySourceJobID = nil
        checkerTarget = nil
        checkerAppliesToVisibleDraft = false
        checkerRefreshing = false
        preflightAcceptanceMessage = nil
        staleCheckedSnapshot = nil
        latestTaskJobID = nil
        protectsPreJobCheckerFailure = false
        supersededCheckerJobID = nil
        defer { isLoading = false }
        // Offline-first reading. A local snapshot is safe to render because it
        // is explicitly labelled by `sync.state`; a later refresh never
        // replaces an unsent local draft.
        if let cached = sync.cache.chapter(id: summary.id) {
            currentChapter = cached
            let local = cache.load(chapterId: cached.id)
            if let local, local.shouldRestore(over: cached) {
                currentChapter = local.apply(to: cached)
                restoredLocalDraft = true
                saveState = .restoredLocalDraft
            } else {
                saveState = sync.state(for: .chapter, id: cached.id) == .synced ? .synced : .localDraft
            }
        }
        do {
            await sync.flush(using: session.api)
            let remote: Chapter = try await session.api.request("/chapters/\(summary.id)")
            if let pollingChapterId, pollingChapterId != remote.id {
                stopPolling(for: pollingChapterId)
            }
            // Capture the public baseline before applying a local draft. The
            // base revision, not either device's clock, decides whether this
            // draft can be safely restored onto the response.
            sync.cache.saveChapter(remote)
            let local = cache.load(chapterId: remote.id)
            if let local, local.shouldRestore(over: remote) {
                currentChapter = local.apply(to: remote)
                restoredLocalDraft = true
                saveState = .restoredLocalDraft
            } else {
                currentChapter = remote
                cache.saveClean(remote)
                saveState = .synced
            }
            sync.markOnline()
            staleCheckedSnapshot = cache.loadCheckedSnapshot(chapterId: remote.id)
            pendingExemptionNames = []
            currentValidationReason = nil
            if pollingChapterId != remote.id {
                writingPhase = .idle
            }

            // A Checker profile can fail before /check/start creates a new
            // JobRun. Restore that newer local instruction before asking the
            // server about an older terminal run, otherwise the old failure
            // would repaint the same unchanged prose after every cold load.
            if let outcome = ChapterTaskOutcomeStore.load(chapter: remote),
               outcome.isPreJobCheckerFailure {
                writingPhase = outcome.phase
                currentValidationReason = outcome.validationReason
                pendingExemptionNames = outcome.pendingExemptionNames
                checkerTarget = outcome.checkerTarget
                candidateCheckerRetrySourceJobID = outcome.candidateCheckerRetrySourceJobID
                protectsPreJobCheckerFailure = true
                supersededCheckerJobID = outcome.supersededJobID
            }

            let reconciledServerJob = await reconcileLatestJobOnLoad(chapterId: remote.id)
            if !reconciledServerJob {
                resumePollingIfNeeded()
            }
            if !writingPhase.isActive,
               writingPhase == .idle,
               let chapter = currentChapter,
               let outcome = ChapterTaskOutcomeStore.load(chapter: chapter) {
                writingPhase = outcome.phase
                currentValidationReason = outcome.validationReason
                pendingExemptionNames = outcome.pendingExemptionNames
                checkerTarget = outcome.checkerTarget
                candidateCheckerRetrySourceJobID = outcome.candidateCheckerRetrySourceJobID
                protectsPreJobCheckerFailure = outcome.isPreJobCheckerFailure
                supersededCheckerJobID = outcome.supersededJobID
            }
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
        }
    }

    func editString(_ keyPath: WritableKeyPath<Chapter, String>, value: String) {
        guard var chapter = currentChapter else { return }
        guard ChapterEditingPolicy.canEdit(chapter) else { return }
        guard chapter[keyPath: keyPath] != value else { return }
        chapter[keyPath: keyPath] = value
        currentChapter = chapter
        localEditRevision &+= 1
        if keyPath == \Chapter.title || keyPath == \Chapter.userPrompt || keyPath == \Chapter.draftText {
            markCheckerStale()
        }
        preflightAcceptanceMessage = nil
        clearTaskOutcome(chapterID: chapter.id)
        if saveState != .unsaved {
            saveState = .unsaved
        }
    }

    func setCharacterLinks(_ links: [ChapterLink]) {
        guard var chapter = currentChapter else { return }
        guard ChapterEditingPolicy.canEdit(chapter) else { return }
        guard chapter.characterLinks != links else { return }
        chapter.characterLinks = links
        currentChapter = chapter
        localEditRevision &+= 1
        markCheckerStale()
        preflightAcceptanceMessage = nil
        clearTaskOutcome(chapterID: chapter.id)
        if saveState != .unsaved {
            saveState = .unsaved
        }
    }

    /// Flushes the in-memory chapter only at an explicit lifecycle or
    /// navigation boundary. This is synchronous on purpose: once this method
    /// returns, a transition may safely replace or suspend the editor.
    @discardableResult
    func persistLocalDraftIfNeeded() -> Bool {
        guard let chapter = currentChapter else { return true }
        guard ChapterLocalDraftPersistencePolicy.needsPersistence(saveState) else { return true }
        saveState = .savingLocally
        let saved = cache.saveDirty(chapter)
        saveState = saved
            ? .localDraft
            : .localSaveFailed(message: "无法写入本机草稿缓存，请立即复制正文后重试。")
        return saved
    }

    func save() async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        // Persist the exact outgoing snapshot before the network request. If
        // PATCH fails, the UI can truthfully promise the local draft survived.
        let localSnapshotSaved = cache.saveDirty(chapter)
        let payload = ChapterPatchPayload(chapter)
        let baseChapter = sync.cache.chapter(id: chapter.id) ?? chapter
        let base = ChapterPatchPayload(baseChapter)
        let startingRevision = localEditRevision
        isSaving = true
        saveState = .savingRemotely
        defer { isSaving = false }
        do {
            let saved: Chapter = try await session.api.request("/chapters/\(chapter.id)", method: "PATCH", body: payload, ifMatch: chapter.contentRevision)
            guard currentChapter?.id == chapter.id else { return saved }
            // Keystrokes landing during the round trip must survive it. The
            // response reflects the text we sent, so adopting it wholesale
            // would silently roll the editor back and then mark it synced.
            // ChapterRefreshReconciler is not usable here: saveState is
            // `.savingRemotely` for the whole call, which it always reads as
            // divergence. The edit counter is the only signal that matters.
            guard localEditRevision == startingRevision else {
                saveState = .unsaved
                return saved
            }
            currentChapter = saved
            sync.cache.saveChapter(saved)
            sync.acknowledge(kind: .chapter, id: chapter.id)
            sync.markOnline()
            cache.saveClean(saved)
            restoredLocalDraft = false
            saveState = .synced
            return saved
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(kind: .chapter, id: chapter.id, path: "/chapters/\(chapter.id)", method: "PATCH", baseRevision: chapter.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api)
                saveState = .remoteSaveFailed(message: "章节已在另一设备更新；本机内容已保留，等待比较。", localDraftPreserved: localSnapshotSaved)
                session.notices.publish("章节已在另一设备更新；本机内容已保留。")
                return nil
            }
            let presented = LinoErrorPresenter.present(error: error)
            let queued = sync.enqueueDirectFailure(
                error, kind: .chapter, id: chapter.id, path: "/chapters/\(chapter.id)", method: "PATCH",
                baseRevision: chapter.contentRevision, payload: payload, baseSnapshot: base
            )
            switch (localSnapshotSaved, queued) {
            case (false, false):
                saveState = .localSaveFailed(message: "正文和待同步副本都未能安全写入本机，请立即复制正文后重试。")
                session.notices.publish("正文和待同步副本都未能安全写入本机，请立即复制正文后重试。", critical: true)
            case (true, false):
                saveState = .remoteSaveFailed(
                    message: "本机草稿已保存，但未能进入自动同步队列：\(presented.message)",
                    localDraftPreserved: true
                )
                session.notices.publish("本机草稿已保存，但未能进入自动同步队列：\(presented.message)", critical: true, tone: .error)
            case (false, true):
                saveState = .remoteSaveFailed(
                    message: "本机草稿缓存未写入，但待同步副本已保存：\(presented.message)",
                    localDraftPreserved: true
                )
            case (true, true):
                if case APIError.transport = error {
                    saveState = .localDraft
                } else {
                    saveState = .remoteSaveFailed(message: presented.message, localDraftPreserved: true)
                }
            }
            return nil
        }
    }

    func importDraft(_ text: String) async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        do {
            let imported: Chapter = try await session.api.request("/chapters/\(chapter.id)/import", method: "POST", body: ChapterImportPayload(draft_text: text), ifMatch: chapter.contentRevision)
            currentChapter = imported
            sync.cache.saveChapter(imported)
            checkerResult = nil
            failedCandidateCheckerResult = nil
            checkerAppliesToVisibleDraft = false
            preflightAcceptanceMessage = nil
            cache.saveClean(imported)
            ChapterTaskOutcomeStore.clear(chapterID: imported.id)
            writingPhase = .idle
            restoredLocalDraft = false
            saveState = .synced
            return imported
        } catch {
            session.notices.publish(error)
            return nil
        }
    }

    /// Saves current edits, then starts (or restarts) the background write
    /// job and returns immediately once it has been accepted by the server.
    /// Progress is observed via `writingPhase`/`currentChapter`, updated by
    /// the polling task started here.
    func generate(acknowledgedContextToken: String? = nil) async -> Chapter? {
        guard let chapter = currentChapter, !writingPhase.isActive else { return nil }
        guard chapter.status != "finalized" else {
            // Kept as an internal invariant: normal UI flow reaches a
            // finalized chapter only through `rewrite()`, which reopens it
            // first. This message only fires if some other call site skips
            // that step, so it must point at the real path rather than the
            // dead-end "重新编辑本章" instruction v2.0.4 retired.
            session.notices.publish("请改用「重写本章」生成正文。")
            return nil
        }
        let replace = !chapter.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chapter.status == "writing"
        pendingExemptionNames = []
        currentValidationReason = nil
        checkerResult = nil
        failedCandidateCheckerResult = nil
        candidateCheckerRetrySourceJobID = nil
        checkerAppliesToVisibleDraft = false
        preflightAcceptanceMessage = nil
        memoryContext = nil
        guard let saved = await save() else { return nil }
        guard case let .proceed(token) = await productionReadiness(
            for: saved, action: .write, acknowledgedContextToken: acknowledgedContextToken
        ) else { return nil }
        return await startWrite(replaceDraft: replace, acknowledgedContextToken: token)
    }

    /// Saves current edits, then starts the background Extractor job and
    /// returns immediately. Completion (chapter becomes `finalized`) is
    /// observed reactively via `currentChapter`.
    func accept(overrideChecker: Bool = false, allowShortDraft: Bool = false) async -> Chapter? {
        guard !writingPhase.isActive else { return nil }
        guard let saved = await save() else { return nil }
        let operationID = beginAction()
        let startingRevision = localEditRevision
        let noticeLocation = noticeLocation(for: saved)
        pendingExemptionNames = []
        currentValidationReason = nil
        failedCandidateCheckerResult = nil
        preflightAcceptanceMessage = nil
        ChapterTaskOutcomeStore.clear(chapterID: saved.id)
        // No chapter is accepted until the server confirms it. In particular,
        // do not borrow Extractor's finalized semantics for a rejected accept
        // request: that was the root cause of the false “completed” UI.
        writingPhase = .accepting
        do {
            let status = try await session.api.accept(
                chapterId: saved.id, contentRevision: saved.contentRevision,
                overrideChecker: overrideChecker, allowShortDraft: allowShortDraft
            )
            guard actionIsCurrent(operationID, chapterID: saved.id, revision: startingRevision) else { return nil }
            applyJobStatus(status, chapterId: saved.id)
            if !Self.isTerminalPhase(status.phase) {
                pollJob(chapterId: saved.id)
            }
            return currentChapter
        } catch {
            _ = await recordActionRevisionConflictIfNeeded(error, chapter: saved)
            if await adoptRunningJobIfNeeded(
                error, chapterId: saved.id, operationID: operationID, revision: startingRevision
            ) {
                return currentChapter
            }
            if Self.acceptanceResultMayBeUnknown(error) {
                switch await reconcileAcceptanceAfterUncertainResult(
                    chapterId: saved.id, operationID: operationID, revision: startingRevision
                ) {
                case .observed:
                    return actionIsCurrent(operationID, chapterID: saved.id, revision: startingRevision)
                        ? currentChapter
                        : nil
                case .unknown(let observationError):
                    markAcceptanceResultUnknown(
                        observationError,
                        chapter: saved,
                        operationID: operationID,
                        revision: startingRevision,
                        noticeLocation: noticeLocation
                    )
                    return nil
                }
            }
            if let message = Self.preflightAcceptanceOverrideMessage(from: error) {
                _ = publishStartFailure(
                    error,
                    chapter: saved,
                    operationID: operationID,
                    noticeLocation: noticeLocation,
                    action: "接受正文"
                )
                // The server has explicitly rejected this first attempt, so
                // it is safe to leave the request phase. Only the narrow
                // server-approved length rules expose a second, confirmed
                // accept; character and empty-body failures remain blockers.
                guard actionIsCurrent(operationID, chapterID: saved.id, revision: startingRevision) else {
                    return nil
                }
                // A short-draft acknowledgement follows a successful Checker
                // result. It is an independent author confirmation, never a
                // failed recheck, so preserve that result for the dialog and
                // the second request.
                if !Self.isShortDraftConfirmationRequired(error) {
                    checkerResult = nil
                    checkerAppliesToVisibleDraft = false
                }
                preflightAcceptanceMessage = message
                writingPhase = .idle
                return nil
            }
            applyStartFailure(
                error,
                chapter: saved,
                intendedStage: .acceptance,
                operationID: operationID,
                revision: startingRevision,
                noticeLocation: noticeLocation,
                action: "接受正文"
            )
            return nil
        }
    }

    /// Retries only the memory archive for prose the server has already
    /// accepted. This never re-runs Checker or asks the user to accept again.
    func retryArchive(acknowledgedContextToken: String? = nil) async -> Chapter? {
        guard !writingPhase.isActive else { return nil }
        guard let accepted = currentChapter, accepted.status == "finalized" else { return nil }
        // Archive retry has no author-input transition. Calling `save()` here
        // would issue a chapter PATCH before the archive-only endpoint and
        // could submit a local divergence through a recovery button. Keep the
        // accepted revision authoritative and let a normal edit/reopen flow
        // resolve any divergence first.
        guard !hasLocalInputDivergence else {
            session.notices.publish("本机正文或章节输入尚未与服务器一致；请先处理该修改后再重新整理记忆。", tone: .error)
            return nil
        }
        guard case let .proceed(token) = await productionReadiness(
            for: accepted, action: .archiveRetry, acknowledgedContextToken: acknowledgedContextToken
        ) else { return nil }
        let operationID = beginAction()
        let startingRevision = localEditRevision
        let noticeLocation = noticeLocation(for: accepted)
        ChapterTaskOutcomeStore.clear(chapterID: accepted.id)
        writingPhase = .extracting
        do {
            let status = try await session.api.retryArchive(
                chapterId: accepted.id, contentRevision: accepted.contentRevision,
                acknowledgedContextToken: token
            )
            guard actionIsCurrent(operationID, chapterID: accepted.id, revision: startingRevision) else { return nil }
            applyJobStatus(status, chapterId: accepted.id)
            if !Self.isTerminalPhase(status.phase) {
                pollJob(chapterId: accepted.id)
            }
            return currentChapter
        } catch {
            _ = await recordActionRevisionConflictIfNeeded(error, chapter: accepted)
            if await adoptRunningJobIfNeeded(
                error, chapterId: accepted.id, operationID: operationID, revision: startingRevision
            ) {
                return currentChapter
            }
            applyStartFailure(
                error,
                chapter: accepted,
                intendedStage: .extraction,
                operationID: operationID,
                revision: startingRevision,
                noticeLocation: noticeLocation,
                action: "重新整理记忆"
            )
            return nil
        }
    }

    /// Refreshes only public chapter/job state after a response was lost or
    /// automatic monitoring stopped. It never repeats accept/write/archive.
    @discardableResult
    func refreshTaskStatus() async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        let chapterID = chapter.id
        let requestID = UUID()
        let startingRevision = localEditRevision
        let noticeLocation = noticeLocation(for: chapter)
        taskRefreshRequestID = requestID
        do {
            let remote: Chapter = try await session.api.request("/chapters/\(chapterID)")
            guard taskRefreshRequestID == requestID,
                  currentChapter?.id == chapterID,
                  localEditRevision == startingRevision else { return nil }
            if !hasLocalInputDivergence {
                adoptRemoteChapter(remote)
            }
            let status = try await session.api.jobStatus(chapterId: chapterID)
            guard taskRefreshRequestID == requestID,
                  currentChapter?.id == chapterID,
                  localEditRevision == startingRevision else { return nil }
            if shouldDeferCheckerStatus(status) {
                sync.markOnline()
                return currentChapter
            }
            switch ChapterJobReconciler.decide(
                status: status,
                chapter: remote,
                hasLocalInputDivergence: hasLocalInputDivergence
            ) {
            case .active:
                applyJobStatus(status, chapterId: chapterID)
                pollJob(chapterId: chapterID)
            case .currentTerminal:
                applyJobStatus(status, chapterId: chapterID)
            case .obsoleteTerminal:
                // A remote input update makes any terminal Checker result
                // unusable, even when this client still holds an old passed
                // badge. Clear all check-specific recovery state together.
                discardObsoleteTaskOutcome(chapterID: chapterID)
            case .unverifiedTerminal, .none:
                if !writingPhase.isFailed { writingPhase = .idle }
                pollingConnectionInterrupted = false
                taskMonitoringMessage = nil
            }
            sync.markOnline()
            return currentChapter
        } catch {
            let presented = LinoErrorPresenter.present(error: error)
            session.notices.publish(
                noticeLocation + "任务状态暂时无法更新：\(presented.message)",
                critical: presented.critical,
                tone: .error,
                deduplicationKey: ChapterTaskMonitoringNoticeKey.refresh(
                    chapterID: chapterID,
                    requestID: requestID
                )
            )
            guard taskRefreshRequestID == requestID,
                  currentChapter?.id == chapterID,
                  localEditRevision == startingRevision else { return nil }
            pollingConnectionInterrupted = true
            taskMonitoringMessage = presented.message
            return nil
        }
    }

    func rerunChecker(acknowledgedContextToken: String? = nil) async -> CheckerResult? {
        guard !writingPhase.isActive else { return nil }
        let operationID = beginAction()
        checkerRefreshing = true
        defer {
            if actionOperationID == operationID {
                checkerRefreshing = false
            }
        }
        // The editor keeps keystrokes in memory until an explicit transition.
        // Checker must therefore flush that exact text first; otherwise the
        // backend checks the previous server draft while the UI incorrectly
        // presents the result as belonging to the edited text.
        guard let current = currentChapter else { return nil }
        let chapter: Chapter
        if current.status == "finalized" {
            // Accepted prose is immutable. A manual check reads the exact
            // server revision, so it must not send an unrelated PATCH first.
            guard !hasLocalInputDivergence else {
                session.notices.publish("本机仍有未处理的章节修改，暂时不能复查已接受正文。", tone: .error)
                return nil
            }
            chapter = current
        } else {
            guard let saved = await save() else { return nil }
            chapter = saved
        }
        guard case let .proceed(token) = await productionReadiness(
            for: chapter, action: .check, acknowledgedContextToken: acknowledgedContextToken
        ) else { return nil }
        let startingRevision = localEditRevision
        let noticeLocation = noticeLocation(for: chapter)
        clearPreJobCheckerFailure(chapterID: chapter.id)
        do {
            let status = try await session.api.startChecker(
                chapterId: chapter.id, contentRevision: chapter.contentRevision,
                acknowledgedContextToken: token
            )
            guard actionIsCurrent(operationID, chapterID: chapter.id, revision: startingRevision) else {
                if status.phase == "failed" || status.phase == "cancelled" {
                    let presented = LinoErrorPresenter.present(jobFailure: status)
                    session.notices.publish(
                        noticeLocation + presented.message,
                        critical: presented.critical,
                        tone: .error,
                        deduplicationKey: "manual-check-terminal-after-leave:\(chapter.id):\(status.jobId ?? operationID.uuidString)"
                    )
                }
                return nil
            }
            clearPreJobCheckerFailure(chapterID: chapter.id)
            applyJobStatus(status, chapterId: chapter.id)
            if !Self.isTerminalPhase(status.phase) { pollJob(chapterId: chapter.id) }
            return checkerResult
        } catch {
            if await recoverCheckerStartOutcomeIfUnknown(
                error, chapterId: chapter.id, operationID: operationID, revision: startingRevision
            ) {
                return checkerResult
            }
            if await adoptRunningJobIfNeeded(
                error, chapterId: chapter.id, operationID: operationID, revision: startingRevision
            ) {
                return checkerResult
            }
            let code = LinoErrorPresenter.code(for: error)
            if actionIsCurrent(operationID, chapterID: chapter.id, revision: startingRevision),
               LinoErrorPresenter.requiresModelSettings(code) {
                // /check/start can reject before the Backend creates a JobRun
                // (for example while resolving the Checker profile). Preserve
                // the target explicitly so the recovery card leads to settings
                // instead of silently falling back to Writer work.
                checkerTarget = "visible_draft"
                applyStartFailure(
                    error,
                    chapter: chapter,
                    intendedStage: .bibleChecking,
                    operationID: operationID,
                    revision: startingRevision,
                    noticeLocation: noticeLocation,
                    action: "手动复查"
                )
                return nil
            }
            _ = await recordActionRevisionConflictIfNeeded(error, chapter: chapter)
            let presented = LinoErrorPresenter.present(error: error)
            session.notices.publish(
                noticeLocation + "手动复查未完成：\(presented.message)",
                critical: presented.critical,
                tone: .error,
                deduplicationKey: "manual-check-start:\(chapter.id):\(operationID.uuidString)"
            )
            if actionIsCurrent(operationID, chapterID: chapter.id, revision: startingRevision),
               let message = Self.preflightAcceptanceOverrideMessage(from: error) {
                checkerResult = nil
                checkerAppliesToVisibleDraft = false
                preflightAcceptanceMessage = message
            }
            return nil
        }
    }

    /// Rechecks exactly the opaque generated candidate identified by the
    /// server. The implementation deliberately does not route through
    /// `rerunChecker()`, which would save and inspect the visible old draft.
    func retryGeneratedCandidateChecker() async -> Chapter? {
        guard !writingPhase.isActive,
              let chapter = currentChapter,
              let sourceJobID = candidateCheckerRetrySourceJobID else { return nil }
        // A same-candidate retry may eventually promote server-side prose.
        // Do not let that promotion race an author's unsaved visible draft.
        guard !hasLocalInputDivergence else {
            session.notices.publish(
                "本机正文或章节输入尚未与服务器一致；请先保存或处理该修改后再重试检查生成稿。",
                tone: .error
            )
            return nil
        }
        let operationID = beginAction()
        let revision = localEditRevision
        let location = noticeLocation(for: chapter)
        clearPreJobCheckerFailure(chapterID: chapter.id)
        writingPhase = .checking
        do {
            let status = try await session.api.retryCandidateChecker(
                chapterId: chapter.id, sourceJobId: sourceJobID,
                contentRevision: chapter.contentRevision
            )
            guard actionIsCurrent(operationID, chapterID: chapter.id, revision: revision) else { return nil }
            clearPreJobCheckerFailure(chapterID: chapter.id)
            applyJobStatus(status, chapterId: chapter.id)
            if !Self.isTerminalPhase(status.phase) { pollJob(chapterId: chapter.id) }
            return currentChapter
        } catch {
            let permanentRetryErrors = ["checker_retry_input_changed", "checker_retry_not_available", "checker_source_not_found", "checker_retry_unavailable"]
            let code = LinoErrorPresenter.code(for: error)
            if actionIsCurrent(operationID, chapterID: chapter.id, revision: revision),
               permanentRetryErrors.contains(code ?? "") {
                candidateCheckerRetrySourceJobID = nil
                failedCandidateCheckerResult = nil
            }
            if actionIsCurrent(operationID, chapterID: chapter.id, revision: revision),
               LinoErrorPresenter.requiresModelSettings(code) {
                checkerTarget = "generated_candidate"
            }
            applyStartFailure(
                error, chapter: chapter, intendedStage: .bibleChecking,
                operationID: operationID, revision: revision,
                noticeLocation: location, action: "重试检查生成稿"
            )
            return nil
        }
    }

    func dismissProductionContextConfirmation() { pendingProductionContext = nil }

    func confirmProductionContextAndContinue(_ pending: PendingProductionContext) async -> Chapter? {
        guard currentChapter?.id == pending.chapterID else {
            pendingProductionContext = nil
            return nil
        }
        pendingProductionContext = nil
        switch pending.action {
        case .write:
            return await generate(acknowledgedContextToken: pending.readiness.contextToken)
        case .check:
            _ = await rerunChecker(acknowledgedContextToken: pending.readiness.contextToken)
            return currentChapter
        case .archiveRetry:
            return await retryArchive(acknowledgedContextToken: pending.readiness.contextToken)
        }
    }

    func confirmProductionContextAndContinue() async -> Chapter? {
        guard let pending = pendingProductionContext else { return nil }
        return await confirmProductionContextAndContinue(pending)
    }

    private enum ProductionReadinessGate {
        case proceed(String?)
        case confirmationRequired
    }

    private func productionReadiness(
        for chapter: Chapter,
        action: ProductionContextAction,
        acknowledgedContextToken: String?
    ) async -> ProductionReadinessGate {
        if let acknowledgedContextToken { return .proceed(acknowledgedContextToken) }
        do {
            let readiness = try await session.api.productionReadiness(chapterId: chapter.id)
            guard !readiness.limitations.isEmpty else { return .proceed(nil) }
            pendingProductionContext = PendingProductionContext(
                action: action, chapterID: chapter.id, readiness: readiness
            )
            return .confirmationRequired
        } catch {
            // A pre-v2.2 Backend cannot safely stand in for this new gate.
            // Surface its capability failure and leave the requested action
            // untouched; never swap it for a different request.
            session.notices.publish(error)
            return .confirmationRequired
        }
    }

    private func markCheckerStale() {
        if checkerAppliesToVisibleDraft {
            checkerAppliesToVisibleDraft = false
        }
        guard var result = checkerResult else { return }
        guard result.status != "stale" || result.verdict != nil else { return }
        result.status = "stale"
        result.verdict = nil
        checkerResult = result
    }

    private func saveCheckedSnapshotIfCurrent(_ result: CheckerResult?, chapter: Chapter?) {
        guard let result, result.hasConcreteVerdict, let chapter else { return }
        let snapshot = CheckedDraftSnapshot(chapter: chapter, checkerResult: result)
        if cache.saveCheckedSnapshot(snapshot) { staleCheckedSnapshot = snapshot }
    }

    /// Keeps legacy editor surfaces and persisted task recovery in step with
    /// the current visible Checker result. The detailed V2 card reads
    /// `visibleIdentityIssues`; this name list remains only as a safe
    /// compatibility fallback for backends that predate identity rows.
    private func updatePendingIdentityNames(
        from result: CheckerResult?,
        additionalNames: [String] = []
    ) {
        let resultNames = result?.identityIssues.map(\.name) ?? []
        pendingExemptionNames = Array(Set(resultNames + additionalNames)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            .sorted()
    }

    /// Saves an explicit identity decision. It never restarts Writer or
    /// Checker: after the author selects a character or marks a word as an
    /// exemption, the next action remains their deliberate choice.
    func saveNameClarification(
        selectedCharacterIDs: [String] = [],
        exemptedNames: [String] = []
    ) async -> Chapter? {
        guard var chapter = currentChapter else { return nil }
        let links = Set(chapter.characterLinks.map(\.characterId)).union(selectedCharacterIDs)
        chapter.characterLinks = links.sorted().map(ChapterLink.init(characterId:))
        chapter.exemptedCharacterNames = Array(
            Set(chapter.exemptedCharacterNames).union(exemptedNames)
        ).sorted()
        currentChapter = chapter
        guard let saved = await save() else { return nil }
        pendingExemptionNames = []
        currentValidationReason = nil
        return saved
    }

    /// Compatibility entry point for the older editor surface. It now saves
    /// the explicit exemption only; automatic regeneration was the dead path
    /// that made a name decision look like a different writing action.
    func exemptAndRetry() async -> Chapter? {
        await saveNameClarification(exemptedNames: pendingExemptionNames)
    }

    func reopen() async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        do {
            let reopened: Chapter = try await session.api.request("/chapters/\(chapter.id)/reopen", method: "POST", ifMatch: chapter.contentRevision)
            currentChapter = reopened
            sync.cache.saveChapter(reopened)
            checkerResult = nil
            failedCandidateCheckerResult = nil
            checkerAppliesToVisibleDraft = false
            preflightAcceptanceMessage = nil
            cache.saveClean(reopened)
            ChapterTaskOutcomeStore.clear(chapterID: reopened.id)
            writingPhase = .idle
            restoredLocalDraft = false
            saveState = .synced
            return reopened
        } catch {
            session.notices.publish(error)
            return nil
        }
    }

    /// Rewrites the visible chapter: on a finalized chapter this first
    /// reopens it (archives cascade-invalidate server-side, `draftText`
    /// survives), then starts a fresh write job. `generate()` computes
    /// `replace == true` from that surviving text, so the prose is
    /// overwritten in place rather than cleared up front — the old body
    /// stays visible until a new one has passed both deterministic
    /// validation and Checker (hard rule 35).
    ///
    /// This is two network calls; a failure between them is reported
    /// honestly rather than papered over. If `generate()` fails after a
    /// successful reopen, the chapter is left exactly where the two calls put
    /// it — reopened, prose intact, archive already invalidated — with
    /// `writingPhase` carrying the failure. Nothing here rolls the status
    /// back to finalized or swallows the error.
    ///
    /// That middle state is why this returns `ChapterRewriteOutcome` rather
    /// than `Chapter?`: a reopen that landed has already destroyed archives on
    /// the server, and a caller that cannot tell it apart from "nothing
    /// happened" will leave the author looking at a chapter list that still
    /// claims those memories are good.
    func rewrite() async -> ChapterRewriteOutcome {
        guard let chapter = currentChapter, !writingPhase.isActive else { return .notStarted }
        var didReopen = false
        if chapter.status == "finalized" {
            // 失败已 publish 通知，直接停：nothing was invalidated.
            guard await reopen() != nil else { return .notStarted }
            didReopen = true
        }
        // generate() 内部 replace 计算为 true，正文被覆盖而非清空
        guard let rewritten = await generate() else {
            return didReopen ? .reopenedButGenerateFailed : .notStarted
        }
        return .succeeded(rewritten)
    }

    /// Read-only dry-run of which later chapters a rewrite's reopen would
    /// cascade-stale. A failure here must never block the rewrite itself —
    /// callers fall back to a conservative confirmation message when this
    /// returns `nil`, so no notice is published for it.
    func loadRewriteImpact() async -> RewriteImpactPreview? {
        guard let chapter = currentChapter else { return nil }
        return try? await session.api.rewritePreview(chapterId: chapter.id)
    }

    func cancelWriting() async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        let cancelledStage = writingPhase.currentStage ?? .drafting
        stopPolling(for: chapter.id)
        currentValidationReason = nil
        failedCandidateCheckerResult = nil
        do {
            let cancelled = try await session.api.cancelWrite(chapterId: chapter.id)
            currentChapter = cancelled
            cache.saveClean(cancelled)
            writingPhase = .cancelled(
                message: "已停止生成，并恢复生成前草稿。",
                stage: cancelledStage
            )
            ChapterTaskOutcomeStore.save(
                phase: writingPhase,
                chapter: cancelled,
                validationReason: currentValidationReason,
                pendingExemptionNames: pendingExemptionNames
            )
            saveState = .synced
            pendingExemptionNames = []
            return cancelled
        } catch {
            session.notices.publish(error)
            resumePollingIfNeeded()
            return nil
        }
    }

    func deleteCurrentChapter() async -> Bool {
        guard let chapter = currentChapter else { return false }
        let deletingId = chapter.id
        stopPolling(for: deletingId)
        do {
            try await session.api.rawRequest("/chapters/\(deletingId)", method: "DELETE", ifMatch: chapter.contentRevision)
            cache.remove(chapterId: deletingId)
            sync.cache.removeChapter(id: deletingId)
            ChapterTaskOutcomeStore.clear(chapterID: deletingId)
            writingPhase = .idle
            saveState = .synced
            pendingExemptionNames = []
            currentValidationReason = nil
            failedCandidateCheckerResult = nil
            preflightAcceptanceMessage = nil
            if currentChapter?.id == deletingId {
                currentChapter = nil
            }
            return true
        } catch {
            session.notices.publish(error)
            return false
        }
    }

    /// Called when the app returns to the foreground. Resumes polling if the
    /// current chapter's server-side status still shows a job in flight.
    func handleScenePhaseActive() {
        guard let chapter = currentChapter else { return }
        guard chapter.status == "writing"
                || chapter.archive?.status == "pending"
                || chapter.archive?.status == "extracting" else { return }
        guard !writingPhase.isActive else { return }
        resumePollingIfNeeded()
    }

    /// macOS-only foreground recovery. Deliberately **omits** the
    /// `status == writing/extracting` guard that `handleScenePhaseActive()`
    /// carries. Here, whenever there is a `currentChapter`
    /// and no poll is running, we unconditionally fetch one `jobStatus`,
    /// apply it, and resume polling if the phase is still non-terminal. A
    /// missing/never-started job just returns an error we swallow silently so
    /// window activations don't spam Toasts. Terminal snapshots are applied
    /// only when the server marks them current and this client has no newer
    /// local inputs. Reconciliation is silent, so repeated activations never
    /// replay an old failure Toast. Only called from macOS
    /// (`NSApplication.didBecomeActiveNotification`).
    func refreshActiveJobIfNeeded() async {
        guard let chapter = currentChapter else { return }
        guard !writingPhase.isActive else { return }
        do {
            let status = try await session.api.jobStatus(chapterId: chapter.id)
            guard currentChapter?.id == chapter.id else { return }
            // The failed local start can be newer than this persisted job.
            // In that case even an obsolete decision must not discard the
            // settings/recovery instruction before a distinct job is seen.
            if shouldDeferCheckerStatus(status) { return }
            switch ChapterJobReconciler.decide(
                status: status,
                chapter: chapter,
                hasLocalInputDivergence: hasLocalInputDivergence
            ) {
            case .active:
                applyJobStatus(status, chapterId: chapter.id)
                pollJob(chapterId: chapter.id)
            case .currentTerminal:
                applyJobStatus(status, chapterId: chapter.id, announceFailure: false)
            case .obsoleteTerminal:
                discardObsoleteTaskOutcome(chapterID: chapter.id)
            case .none, .unverifiedTerminal:
                break
            }
        } catch {
            // No active job or a transient error — stay quiet.
        }
    }

    private func startWrite(replaceDraft: Bool, acknowledgedContextToken: String?) async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        let operationID = beginAction()
        let startingRevision = localEditRevision
        let noticeLocation = noticeLocation(for: chapter)
        ChapterTaskOutcomeStore.clear(chapterID: chapter.id)
        writingPhase = .selectingMemory
        do {
            let status = try await session.api.startWrite(
                chapterId: chapter.id, replaceDraft: replaceDraft,
                contentRevision: chapter.contentRevision,
                acknowledgedContextToken: acknowledgedContextToken
            )
            guard actionIsCurrent(operationID, chapterID: chapter.id, revision: startingRevision) else { return nil }
            applyJobStatus(status, chapterId: chapter.id)
            if !Self.isTerminalPhase(status.phase) {
                pollJob(chapterId: chapter.id)
            }
            return currentChapter
        } catch {
            _ = await recordActionRevisionConflictIfNeeded(error, chapter: chapter)
            if await adoptRunningJobIfNeeded(
                error, chapterId: chapter.id, operationID: operationID, revision: startingRevision
            ) {
                return currentChapter
            }
            applyStartFailure(
                error,
                chapter: chapter,
                intendedStage: .memorySelection,
                operationID: operationID,
                revision: startingRevision,
                noticeLocation: noticeLocation,
                action: "开始写作"
            )
            return nil
        }
    }

    /// Resumes polling for `currentChapter` if its server status indicates an
    /// in-flight job (used on chapter load, cold start resume, and scene
    /// activation). Cancels any stale poll for a different chapter first.
    private func resumePollingIfNeeded() {
        guard let chapter = currentChapter else { return }
        if let pollingChapterId, pollingChapterId != chapter.id {
            stopPolling(for: pollingChapterId)
        }
        switch chapter.status {
        case "writing":
            if pollingChapterId != chapter.id {
                writingPhase = .writing
                pollJob(chapterId: chapter.id)
            }
        default:
            if chapter.archive?.status == "pending" || chapter.archive?.status == "extracting" {
                if pollingChapterId != chapter.id {
                    writingPhase = .extracting
                    pollJob(chapterId: chapter.id)
                }
            } else if pollingChapterId != chapter.id {
                writingPhase = .idle
            }
        }
    }

    private func pollJob(chapterId: String) {
        pollingTask?.cancel()
        let monitorID = UUID()
        let location = currentChapter.map { noticeLocation(for: $0) } ?? ""
        pollingChapterId = chapterId
        pollingMonitorID = monitorID
        pollingErrorNotified = false
        pollingConnectionInterrupted = false
        taskMonitoringMessage = nil
        pollingTask = Task { [weak self] in
            await self?.runPolling(chapterId: chapterId, monitorID: monitorID, noticeLocation: location)
        }
    }

    private func stopPolling(for chapterId: String) {
        guard pollingChapterId == chapterId else { return }
        pollingTask?.cancel()
        pollingTask = nil
        pollingChapterId = nil
        pollingMonitorID = nil
        pollingConnectionInterrupted = false
        taskMonitoringMessage = nil
    }

    private func runPolling(chapterId: String, monitorID: UUID, noticeLocation: String) async {
        var consecutiveTransientFailures = 0
        while !Task.isCancelled {
            var delayNanoseconds = ChapterTaskPollingPolicy.normalDelayNanoseconds
            do {
                let status = try await session.api.jobStatus(chapterId: chapterId)
                guard !Task.isCancelled,
                      pollingChapterId == chapterId,
                      pollingMonitorID == monitorID else { return }
                pollingErrorNotified = false
                consecutiveTransientFailures = 0
                pollingConnectionInterrupted = false
                taskMonitoringMessage = nil
                applyJobStatus(status, chapterId: chapterId)
                if Self.isTerminalPhase(status.phase) {
                    pollingChapterId = nil
                    pollingMonitorID = nil
                    return
                }
            } catch {
                guard !Task.isCancelled,
                      pollingChapterId == chapterId,
                      pollingMonitorID == monitorID else { return }
                let presented = LinoErrorPresenter.present(error: error)
                if Self.shouldRetryPolling(after: error) {
                    consecutiveTransientFailures += 1
                    pollingConnectionInterrupted = true
                    taskMonitoringMessage = presented.message
                    if !pollingErrorNotified {
                        pollingErrorNotified = true
                        session.notices.publish(
                            noticeLocation + "\(LinoErrorPresenter.connectionInterrupted)\n\(presented.message)",
                            tone: .error,
                            deduplicationKey: ChapterTaskMonitoringNoticeKey.transient(
                                chapterID: chapterId,
                                monitorID: monitorID
                            )
                        )
                    }
                    guard let retryDelay = ChapterTaskPollingPolicy.retryDelayNanoseconds(
                        afterConsecutiveFailures: consecutiveTransientFailures
                    ) else {
                        pollingTask = nil
                        pollingChapterId = nil
                        pollingMonitorID = nil
                        session.notices.publish(
                            noticeLocation + "任务状态自动重试已停止：\(presented.message)",
                            critical: presented.critical,
                            tone: .error,
                            deduplicationKey: ChapterTaskMonitoringNoticeKey.stopped(
                                chapterID: chapterId,
                                monitorID: monitorID
                            )
                        )
                        return
                    }
                    delayNanoseconds = retryDelay
                } else {
                    // Authentication, a missing job, a deterministic 4xx, and
                    // incompatible payloads cannot become healthy by polling
                    // the same endpoint forever. The server job may still be
                    // running, so retain its last known phase and stop only
                    // this local observer.
                    pollingConnectionInterrupted = true
                    taskMonitoringMessage = presented.message
                    pollingTask = nil
                    pollingChapterId = nil
                    pollingMonitorID = nil
                    session.notices.publish(
                        noticeLocation + "任务状态暂时无法更新：\(presented.message)",
                        critical: presented.critical,
                        tone: .error,
                        deduplicationKey: ChapterTaskMonitoringNoticeKey.stopped(
                            chapterID: chapterId,
                            monitorID: monitorID
                        )
                    )
                    return
                }
            }
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
        }
    }

    private static func isTerminalPhase(_ phase: String) -> Bool {
        switch phase {
        case "done", "failed", "cancelled": return true
        default: return false
        }
    }

    private func applyJobStatus(
        _ status: WriteJobStatus,
        chapterId: String,
        announceFailure: Bool = true
    ) {
        guard currentChapter?.id == chapterId else { return }
        // A pre-JobRun failure/unconfirmed response belongs to a newer user
        // action than an already terminal Checker record. This guard is
        // shared by foreground refresh, cold-load reconciliation, and a poll
        // that was already in flight when the newer action failed.
        guard !shouldDeferCheckerStatus(status) else { return }
        if let jobID = status.jobId { latestTaskJobID = jobID }
        if status.kind == "check", Self.isActiveJobPhase(status.phase) {
            clearPreJobCheckerFailure(chapterID: chapterId)
        }
        pollingConnectionInterrupted = false
        taskMonitoringMessage = nil
        if let context = status.memoryContext { memoryContext = context }
        switch status.phase {
        case "selecting_memory":
            failedCandidateCheckerResult = nil
            checkerAppliesToVisibleDraft = false
            writingPhase = .selectingMemory
            setCurrentChapterStatus("writing", chapterId: chapterId)
        case "writing":
            if let attempt = status.attempt {
                writingPhase = .writingAttempt(min(max(attempt, 1), 2))
                if let reason = Self.validationReason(from: status.violations) {
                    currentValidationReason = reason
                }
            } else {
                writingPhase = .writing
            }
            setCurrentChapterStatus("writing", chapterId: chapterId)
        case "validating":
            writingPhase = .validating
            setCurrentChapterStatus("writing", chapterId: chapterId)
            if let reason = Self.validationReason(from: status.violations) {
                currentValidationReason = reason
            }
        case "checking":
            checkerAppliesToVisibleDraft = false
            checkerTarget = status.checkerTarget
            writingPhase = .checking
            // A manual check can target accepted prose. It observes the
            // existing chapter and must never reopen it as Writer work.
            if status.kind != "check" {
                setCurrentChapterStatus("writing", chapterId: chapterId)
            }
        case "revising":
            writingPhase = .legacyRevising
            setCurrentChapterStatus("writing", chapterId: chapterId)
        case "extracting":
            failedCandidateCheckerResult = nil
            writingPhase = .extracting
            setCurrentChapterStatus("finalized", chapterId: chapterId)
        case "done":
            let preservesIndependentExtractorFailure = status.kind == "check"
                && status.checkerTarget == "visible_draft"
                && currentChapter?.status == "finalized"
                && writingPhase.isFailed
                && writingPhase.currentStage == .extraction
            memoryContext = status.memoryContext ?? memoryContext
            failedCandidateCheckerResult = nil
            let visibleResult: CheckerResult?
            switch status.kind {
            case "write":
                // Writer jobs expose only an explicitly projected visible
                // result. `checker_result` can describe a hidden candidate.
                visibleResult = status.visibleCheckerResult
            case "check":
                // Manual Checker jobs only address the text the author can
                // see, so their legacy `checker_result` remains safe too.
                visibleResult = status.visibleCheckerResult
                    ?? status.checkerResult
            case "extract":
                // Extractor never changes accepted prose. Its explicit
                // visible projection is therefore the current manuscript's
                // Checker result and must survive a cold archive reload.
                // Never consult its redacted `checker_result`: that field
                // can describe a hidden candidate on other job kinds.
                visibleResult = status.visibleCheckerResult
            default:
                visibleResult = nil
            }
            if let visibleResult {
                checkerResult = visibleResult
                checkerAppliesToVisibleDraft = true
                updatePendingIdentityNames(from: visibleResult)
            } else if status.kind == "write" || status.kind == "check" {
                // A current terminal Writer/manual-Checker result with no
                // visible projection must not leave the prior manuscript's
                // pass badge attached to newly loaded prose.
                checkerResult = nil
                checkerAppliesToVisibleDraft = false
                pendingExemptionNames = []
            }
            if status.kind == "check" && status.checkerTarget == "visible_draft" {
                // A successful visible-prose check supersedes an older hidden
                // candidate retry handle; the two objects must never share a
                // recovery action.
                candidateCheckerRetrySourceJobID = nil
            }
            if let chapter = status.chapter {
                currentChapter = chapter
                if let visibleResult {
                    saveCheckedSnapshotIfCurrent(visibleResult, chapter: chapter)
                }
                cache.saveClean(chapter)
                saveState = .synced
            } else {
                Task { [weak self] in
                    await self?.refreshChapter(chapterId)
                }
            }
            ChapterTaskOutcomeStore.clear(chapterID: chapterId)
            checkerTarget = nil
            if !preservesIndependentExtractorFailure {
                writingPhase = .idle
            }
            if visibleResult == nil {
                pendingExemptionNames = []
            }
            currentValidationReason = nil
            taskMonitoringMessage = nil
            if let warning = status.completionWarning {
                session.notices.publish(warning)
            }
        case "failed":
            applyJobFailure(status, chapterId: chapterId, announce: announceFailure)
        case "cancelled":
            failedCandidateCheckerResult = nil
            let cancelledStage = status.kind == "check"
                ? .bibleChecking
                : (writingPhase.currentStage ?? .drafting)
            writingPhase = .cancelled(
                message: "任务已取消，当前草稿已保留。",
                stage: cancelledStage
            )
            currentValidationReason = nil
            pendingExemptionNames = []
            checkerTarget = status.kind == "check" ? status.checkerTarget : nil
            if status.kind == "write" || status.kind == "check" || status.kind == "extract" {
                let visibleResult = status.visibleCheckerResult
                checkerResult = visibleResult
                checkerAppliesToVisibleDraft = visibleResult != nil
                updatePendingIdentityNames(from: visibleResult)
                saveCheckedSnapshotIfCurrent(visibleResult, chapter: currentChapter)
            }
            if let chapter = currentChapter {
                ChapterTaskOutcomeStore.save(
                    phase: writingPhase,
                    chapter: chapter,
                    jobID: status.jobId,
                    checkerTarget: status.kind == "check" ? status.checkerTarget : nil
                )
            }
            Task { [weak self] in
                await self?.refreshChapter(chapterId)
            }
        default:
            break
        }
    }

    private func applyJobFailure(
        _ status: WriteJobStatus,
        chapterId: String,
        announce: Bool
    ) {
        let presented = LinoErrorPresenter.present(jobFailure: status)
        // Extractor runs only after the server accepted the manuscript. A
        // terminal Extractor failure can arrive before an intermediate
        // `extracting` snapshot, so carry that authoritative fact into the
        // local chapter before persisting its retryable outcome.
        if status.kind == "extract" {
            setCurrentChapterStatus("finalized", chapterId: chapterId)
        }
        if status.kind == "write" {
            checkerTarget = nil
            failedCandidateCheckerResult = status.failedCandidateCheckerResult
            candidateCheckerRetrySourceJobID = status.canRetryChecker
                ? (status.checkerSourceJobId ?? status.jobId)
                : nil
            checkerResult = status.visibleCheckerResult
            checkerAppliesToVisibleDraft = status.visibleCheckerResult != nil
            updatePendingIdentityNames(from: status.visibleCheckerResult)
            saveCheckedSnapshotIfCurrent(status.visibleCheckerResult, chapter: currentChapter)
        } else if status.kind == "check" {
            checkerTarget = status.checkerTarget
            let visibleResult = status.visibleCheckerResult
            failedCandidateCheckerResult = status.failedCandidateCheckerResult
            candidateCheckerRetrySourceJobID = status.canRetryChecker ? status.checkerSourceJobId : nil
            checkerResult = visibleResult
            checkerAppliesToVisibleDraft = visibleResult != nil
            updatePendingIdentityNames(from: visibleResult)
            saveCheckedSnapshotIfCurrent(visibleResult, chapter: currentChapter)
        } else if status.kind == "extract" {
            checkerTarget = nil
            // A failed archive leaves accepted prose intact. Restore only
            // the server-projected visible Checker result so its evidence
            // remains current after reopening the chapter.
            let visibleResult = status.visibleCheckerResult
            failedCandidateCheckerResult = nil
            candidateCheckerRetrySourceJobID = nil
            checkerResult = visibleResult
            checkerAppliesToVisibleDraft = visibleResult != nil
            updatePendingIdentityNames(from: visibleResult)
            saveCheckedSnapshotIfCurrent(visibleResult, chapter: currentChapter)
        }
        writingPhase = .failed(
            code: status.errorCode,
            message: presented.message,
            stage: Self.failureStage(from: status)
        )
        if let reason = Self.validationReason(from: status.violations) {
            currentValidationReason = reason
        } else if status.errorCode != "writer_minimum_failed" {
            // A provider failure is not a deterministic validation result; do
            // not leave a previous explanation on screen as though it caused it.
            currentValidationReason = nil
        }
        let violationNames = status.violations?
            .filter { ["unselected_character", "ambiguous_character", "uncertain_character"].contains($0.code) }
            .flatMap { $0.names ?? [] } ?? []
        updatePendingIdentityNames(
            from: ["write", "check", "extract"].contains(status.kind)
                ? status.visibleCheckerResult
                : nil,
            additionalNames: violationNames
        )
        if let chapter = currentChapter {
            ChapterTaskOutcomeStore.save(
                phase: writingPhase,
                chapter: chapter,
                validationReason: currentValidationReason,
                pendingExemptionNames: pendingExemptionNames,
                jobID: status.jobId,
                checkerTarget: status.kind == "check" ? status.checkerTarget : nil
            )
        }
        let location = currentChapter.map { chapter in
            let book = session.currentBook.map { "《\($0.title)》" } ?? ""
            return "\(book)第 \(chapter.index) 章\n"
        } ?? ""
        // Restored terminal outcomes go into history without replaying a
        // toast on every chapter load or window activation.
        let noticeKey = "job-failure:\(chapterId):\(status.jobId ?? presented.message)"
        session.notices.publish(
            location + presented.message, critical: presented.critical, tone: .error,
            deduplicationKey: noticeKey, announce: announce
        )
        Task { [weak self] in
            await self?.refreshChapterAfterFailure(chapterId)
        }
    }

    private func applyStartFailure(
        _ error: Error,
        chapter: Chapter,
        intendedStage: ChapterGenerationStage,
        operationID: UUID,
        revision: UInt64,
        noticeLocation: String,
        action: String
    ) {
        let presented = publishStartFailure(
            error,
            chapter: chapter,
            operationID: operationID,
            noticeLocation: noticeLocation,
            action: action
        )
        guard actionIsCurrent(operationID, chapterID: chapter.id, revision: revision) else { return }
        pendingExemptionNames = []
        let code = LinoErrorPresenter.code(for: error)
        let isPreJobCheckerFailure = intendedStage == .bibleChecking
            && LinoErrorPresenter.requiresModelSettings(code)
        if isPreJobCheckerFailure {
            protectsPreJobCheckerFailure = true
            supersededCheckerJobID = latestTaskJobID
            stopPolling(for: chapter.id)
        }
        if let apiError = error as? APIError,
           case let .validation(_, validationCode, _, names, _) = apiError,
           validationCode == "unselected_characters_in_bible" {
            pendingExemptionNames = names
            writingPhase = .failed(code: validationCode, message: presented.message, stage: intendedStage)
        } else {
            writingPhase = .failed(code: code, message: presented.message, stage: intendedStage)
        }
        if let chapter = currentChapter {
            ChapterTaskOutcomeStore.save(
                phase: writingPhase,
                chapter: chapter,
                validationReason: currentValidationReason,
                pendingExemptionNames: pendingExemptionNames,
                checkerTarget: intendedStage == .bibleChecking ? checkerTarget : nil,
                isPreJobCheckerFailure: isPreJobCheckerFailure,
                supersededJobID: isPreJobCheckerFailure ? supersededCheckerJobID : nil,
                candidateCheckerRetrySourceJobID: isPreJobCheckerFailure
                    ? candidateCheckerRetrySourceJobID : nil
            )
        }
    }

    private func publishStartFailure(
        _ error: Error,
        chapter: Chapter,
        operationID: UUID,
        noticeLocation: String,
        action: String
    ) -> (message: String, critical: Bool) {
        let presented = LinoErrorPresenter.present(error: error)
        // An operation can be rejected after its initiating chapter has been
        // left. Its notice remains useful history, but the departed operation
        // must not change the new chapter's local state.
        session.notices.publish(
            noticeLocation + "\(action)未完成：\(presented.message)",
            critical: presented.critical,
            tone: .error,
            deduplicationKey: "start-failure:\(chapter.id):\(operationID.uuidString)"
        )
        return presented
    }

    private static func acceptanceResultMayBeUnknown(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .transport:
            return true
        case .http(let status, _):
            return status == 408 || status == 429 || status >= 500
        case .validation(let status, _, _, _, _):
            return status == 408 || status == 429 || status >= 500
        default:
            return false
        }
    }

    private enum AcceptanceReconciliation {
        case observed
        case unknown(Error)
    }

    /// Resolves an ambiguous accept response without issuing another accept.
    /// A failed read remains explicitly unknown; it is never persisted as a
    /// rejected acceptance because the server may already have finalized the
    /// prose before the response disappeared.
    private func reconcileAcceptanceAfterUncertainResult(
        chapterId: String,
        operationID: UUID,
        revision: UInt64
    ) async -> AcceptanceReconciliation {
        do {
            let remote: Chapter = try await session.api.request("/chapters/\(chapterId)")
            guard actionIsCurrent(operationID, chapterID: chapterId, revision: revision) else {
                return .observed
            }
            if !hasLocalInputDivergence {
                currentChapter = remote
                sync.cache.saveChapter(remote)
                cache.saveClean(remote)
                saveState = .synced
            }
            if let status = try? await session.api.jobStatus(chapterId: chapterId),
               actionIsCurrent(operationID, chapterID: chapterId, revision: revision) {
                switch ChapterJobReconciler.decide(
                    status: status,
                    chapter: remote,
                    hasLocalInputDivergence: hasLocalInputDivergence
                ) {
                case .active:
                    applyJobStatus(status, chapterId: chapterId)
                    pollJob(chapterId: chapterId)
                case .currentTerminal:
                    applyJobStatus(status, chapterId: chapterId)
                case .obsoleteTerminal, .unverifiedTerminal, .none:
                    writingPhase = .idle
                }
            } else if remote.status == "finalized" {
                writingPhase = (remote.archive?.status == "pending" || remote.archive?.status == "extracting")
                    ? .extracting : .idle
            } else {
                writingPhase = .idle
                session.notices.publish(
                    "接受请求没有在服务器完成，正文仍可继续修改后再接受。",
                    tone: .error,
                    deduplicationKey: "accept-not-completed:\(chapterId):\(operationID.uuidString)"
                )
            }
            sync.markOnline()
            return .observed
        } catch {
            return .unknown(error)
        }
    }

    private func markAcceptanceResultUnknown(
        _ observationError: Error,
        chapter: Chapter,
        operationID: UUID,
        revision: UInt64,
        noticeLocation: String
    ) {
        let presented = LinoErrorPresenter.present(error: observationError)
        session.notices.publish(
            noticeLocation + "接受结果暂未确认：\(presented.message)",
            critical: presented.critical,
            tone: .error,
            deduplicationKey: "accept-unknown:\(chapter.id):\(operationID.uuidString)"
        )
        guard actionIsCurrent(operationID, chapterID: chapter.id, revision: revision) else { return }
        // Keep `.accepting`: a second accept could duplicate an operation the
        // server already started. Only the read-only refresh can resolve it.
        pollingConnectionInterrupted = true
        taskMonitoringMessage = "接受结果暂未确认：\(presented.message)"
    }

    private static func preflightAcceptanceOverrideMessage(from error: Error) -> String? {
        guard let apiError = error as? APIError,
              case let .validation(_, code, _, _, violations) = apiError else { return nil }
        if code == "short_draft_confirmation_required" {
            return LinoErrorPresenter.present(error: apiError).message
        }
        guard ["checker_preflight_failed", "accept_preflight_failed", "accept_override_required"].contains(code),
              ChapterPreflightOverridePolicy.permitsExplicitAcceptance(violations) else { return nil }
        return LinoErrorPresenter.present(error: apiError).message
    }

    private static func isShortDraftConfirmationRequired(_ error: Error) -> Bool {
        guard let apiError = error as? APIError,
              case let .validation(_, code, _, _, _) = apiError else { return false }
        return code == "short_draft_confirmation_required"
    }

    private func noticeLocation(for chapter: Chapter) -> String {
        let book = session.currentBook.map { "《\($0.title)》" } ?? ""
        return "\(book)第 \(chapter.index) 章\n"
    }

    private static func shouldRetryPolling(after error: Error) -> Bool {
        if error is DecodingError { return false }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .transport:
            return true
        case .http(let status, _):
            return status == 408 || status == 429 || status >= 500
        case .validation(let status, _, _, _, _):
            return status == 408 || status == 429 || status >= 500
        default:
            return false
        }
    }

    @discardableResult
    private func recordActionRevisionConflictIfNeeded(_ error: Error, chapter: Chapter) async -> Bool {
        guard let apiError = error as? APIError,
              case .writeConflict = apiError else { return false }
        let snapshot = ChapterPatchPayload(chapter)
        await sync.recordWriteConflict(
            kind: .chapter, id: chapter.id,
            path: "/chapters/\(chapter.id)", method: "PATCH",
            baseRevision: chapter.contentRevision,
            payload: snapshot, baseSnapshot: snapshot,
            error: apiError, api: session.api
        )
        return true
    }

    /// A 409 `write_running` means another client (or a previous request whose
    /// response was lost) already owns the chapter job. Adopt its latest
    /// snapshot instead of turning a healthy in-flight job into a local error.
    private func adoptRunningJobIfNeeded(
        _ error: Error,
        chapterId: String,
        operationID: UUID,
        revision: UInt64
    ) async -> Bool {
        guard let apiError = error as? APIError,
              case let .validation(_, code, _, _, _) = apiError,
              code == "write_running" else { return false }
        do {
            let status = try await session.api.jobStatus(chapterId: chapterId)
            guard actionIsCurrent(operationID, chapterID: chapterId, revision: revision) else { return true }
            applyJobStatus(status, chapterId: chapterId)
            if Self.isTerminalPhase(status.phase) {
                if status.chapter == nil {
                    await refreshChapter(chapterId)
                }
            } else if Self.isActiveJobPhase(status.phase) {
                pollJob(chapterId: chapterId)
            } else {
                // An unexpected/stale snapshot such as `idle` is not a job to
                // poll forever. Reconcile the chapter and return to rest.
                writingPhase = .idle
                await refreshChapter(chapterId)
            }
            return true
        } catch {
            return false
        }
    }

    /// A connection drop or response decoding failure after `POST /check/start`
    /// cannot distinguish a server-side start from a local failure.  Observe
    /// the existing job exactly once; do not turn uncertainty into a second
    /// Checker request.
    private func recoverCheckerStartOutcomeIfUnknown(
        _ error: Error,
        chapterId: String,
        operationID: UUID,
        revision: UInt64
    ) async -> Bool {
        guard Self.checkerStartOutcomeMayBeUnknown(error) else { return false }
        var supersededJobID: String?
        do {
            let status = try await session.api.jobStatus(chapterId: chapterId)
            guard actionIsCurrent(operationID, chapterID: chapterId, revision: revision) else { return true }
            // Only an active, explicitly visible Checker job with a durable
            // job ID can be the post that lost its response.  A terminal
            // record (even `outcome_current`) may be an older check of the
            // same prose, and therefore cannot prove this POST succeeded.
            let isMatchingActiveChecker = status.kind == "check"
                && status.phase == "checking"
                && status.checkerTarget == "visible_draft"
                && status.outcomeCurrent == nil
                && status.jobId != nil
            if isMatchingActiveChecker {
                applyJobStatus(status, chapterId: chapterId)
                pollJob(chapterId: chapterId)
                return true
            }
            supersededJobID = status.jobId
        } catch {
            // The monitor state below deliberately remains unresolved.  It
            // gives the author a read-only recovery action instead of posting
            // the same Checker request again after a lost response.
        }
        guard actionIsCurrent(operationID, chapterID: chapterId, revision: revision) else { return true }
        pollingConnectionInterrupted = true
        taskMonitoringMessage = "复查是否已启动暂未确认，请刷新任务状态。"
        checkerTarget = "visible_draft"
        protectsPreJobCheckerFailure = true
        supersededCheckerJobID = supersededJobID ?? latestTaskJobID
        stopPolling(for: chapterId)
        writingPhase = .failed(
            code: "checker_start_unconfirmed",
            message: taskMonitoringMessage ?? "复查是否已启动暂未确认。",
            stage: nil
        )
        if let chapter = currentChapter, chapter.id == chapterId {
            ChapterTaskOutcomeStore.save(
                phase: writingPhase,
                chapter: chapter,
                checkerTarget: checkerTarget,
                isPreJobCheckerFailure: true,
                supersededJobID: supersededCheckerJobID
            )
        }
        return true
    }

    private static func checkerStartOutcomeMayBeUnknown(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        guard let apiError = error as? APIError else { return false }
        if case .transport = apiError { return true }
        return false
    }

    private static func validationReason(from violations: [Violation]?) -> String? {
        let messages = violations?
            .map { $0.message.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard !messages.isEmpty else { return nil }
        return messages.joined(separator: "；")
    }

    private static func failureStage(from status: WriteJobStatus) -> ChapterGenerationStage? {
        status.kind == "check" ? .bibleChecking : ChapterJobFailureStage.resolve(status)
    }

    private static func isActiveJobPhase(_ phase: String) -> Bool {
        switch phase {
        case "selecting_memory", "writing", "validating", "checking", "revising", "extracting": return true
        default: return false
        }
    }

    /// A terminal Checker row only proves the action that created that row.
    /// It cannot resolve a later start request that either failed before a
    /// JobRun was written or lost its response.  Until a new active job is
    /// observed or the author makes another explicit request, preserve the
    /// newer local recovery state through every observer entrance.
    private func shouldDeferCheckerStatus(_ status: WriteJobStatus) -> Bool {
        guard protectsPreJobCheckerFailure,
              status.kind == "check",
              status.checkerTarget == checkerTarget || status.checkerTarget == nil else {
            return false
        }
        // When the preflight saw a durable old job, its active state is just
        // as old as its terminal state. It cannot displace a newer local
        // configuration failure. A different active job confirms a later
        // request and may safely clear this local recovery state.
        if let supersededCheckerJobID {
            return status.jobId == supersededCheckerJobID
        }
        // With no job identity, only a terminal row is provably older. An
        // active visible check may be the POST whose response was lost and is
        // still allowed to establish its own durable identity.
        return Self.isTerminalPhase(status.phase)
    }

    private func clearPreJobCheckerFailure(chapterID: String) {
        protectsPreJobCheckerFailure = false
        supersededCheckerJobID = nil
        guard let chapter = currentChapter, chapter.id == chapterID,
              let outcome = ChapterTaskOutcomeStore.load(chapter: chapter),
              outcome.isPreJobCheckerFailure else { return }
        ChapterTaskOutcomeStore.clear(chapterID: chapterID)
    }

    private func setCurrentChapterStatus(_ status: String, chapterId: String) {
        guard var chapter = currentChapter, chapter.id == chapterId else { return }
        chapter.status = status
        currentChapter = chapter
    }

    /// Performs a silent one-shot `/job` reconciliation after loading the
    /// chapter. This is what recovers failures that completed while the app was
    /// terminated or on another client. A terminal snapshot is applied only
    /// when the server marks it current for the chapter version just loaded.
    private func reconcileLatestJobOnLoad(chapterId: String) async -> Bool {
        guard let chapter = currentChapter, chapter.id == chapterId else { return false }
        do {
            let status = try await session.api.jobStatus(chapterId: chapterId)
            guard let latestChapter = currentChapter, latestChapter.id == chapterId else { return true }
            if shouldDeferCheckerStatus(status) { return true }
            switch ChapterJobReconciler.decide(
                status: status,
                chapter: latestChapter,
                hasLocalInputDivergence: hasLocalInputDivergence
            ) {
            case .active:
                applyJobStatus(status, chapterId: chapterId)
                pollJob(chapterId: chapterId)
                return true
            case .currentTerminal:
                applyJobStatus(status, chapterId: chapterId, announceFailure: false)
                return true
            case .obsoleteTerminal:
                discardObsoleteTaskOutcome(chapterID: chapterId)
                return true
            case .unverifiedTerminal, .none:
                return false
            }
        } catch {
            // Loading the chapter remains useful even if this optional
            // reconciliation request fails. Active chapter.status still falls
            // back to the normal retrying poll path below.
            return false
        }
    }

    private func discardObsoleteTaskOutcome(chapterID: String) {
        ChapterTaskOutcomeStore.clear(chapterID: chapterID)
        clearPreJobCheckerFailure(chapterID: chapterID)
        writingPhase = .idle
        currentValidationReason = nil
        pendingExemptionNames = []
        failedCandidateCheckerResult = nil
        candidateCheckerRetrySourceJobID = nil
        checkerResult = nil
        checkerAppliesToVisibleDraft = false
        checkerTarget = nil
        preflightAcceptanceMessage = nil
        pollingConnectionInterrupted = false
        taskMonitoringMessage = nil
    }

    private var hasLocalInputDivergence: Bool {
        switch saveState {
        case .synced:
            return false
        case .unsaved, .savingLocally, .localDraft, .localSaveFailed, .restoredLocalDraft,
             .savingRemotely, .remoteSaveFailed:
            return true
        }
    }

    private func refreshChapterAfterFailure(_ chapterId: String) async {
        await refreshChapter(chapterId)
    }

    private func refreshChapter(_ chapterId: String) async {
        let startingRevision = localEditRevision
        guard let refreshed: Chapter = try? await session.api.request("/chapters/\(chapterId)") else { return }
        guard currentChapter?.id == chapterId else { return }
        guard ChapterRefreshReconciler.shouldReplaceLocal(
            startingRevision: startingRevision,
            currentRevision: localEditRevision,
            hasLocalInputDivergence: hasLocalInputDivergence
        ) else { return }
        adoptRemoteChapter(refreshed)
    }

    /// A successful chapter read is enough to make old local evidence stale.
    /// The accompanying /job read may fail, so it cannot be the only place
    /// that invalidates a pass attached to the former prose or Bible.
    private func adoptRemoteChapter(_ remote: Chapter) {
        let changedCheckerInput: Bool
        if let current = currentChapter, current.id == remote.id {
            changedCheckerInput = current.draftText != remote.draftText
                || current.title != remote.title
                || current.userPrompt != remote.userPrompt
                || current.characterLinks.map(\.characterId).sorted() != remote.characterLinks.map(\.characterId).sorted()
                || current.exemptedCharacterNames.sorted() != remote.exemptedCharacterNames.sorted()
        } else {
            changedCheckerInput = false
        }
        currentChapter = remote
        sync.cache.saveChapter(remote)
        cache.saveClean(remote)
        saveState = .synced
        guard changedCheckerInput else { return }
        checkerResult = nil
        checkerAppliesToVisibleDraft = false
        failedCandidateCheckerResult = nil
        candidateCheckerRetrySourceJobID = nil
        checkerTarget = nil
        preflightAcceptanceMessage = nil
        clearPreJobCheckerFailure(chapterID: remote.id)
    }

    private func clearTaskOutcome(chapterID: String) {
        let hadPersistedOutcome: Bool
        switch writingPhase {
        case .failed, .cancelled:
            hadPersistedOutcome = true
        default:
            hadPersistedOutcome = failedCandidateCheckerResult != nil
                || currentValidationReason != nil
                || !pendingExemptionNames.isEmpty
        }
        if hadPersistedOutcome {
            ChapterTaskOutcomeStore.clear(chapterID: chapterID)
        }
        clearPreJobCheckerFailure(chapterID: chapterID)
        failedCandidateCheckerResult = nil
        switch writingPhase {
        case .failed, .cancelled:
            writingPhase = .idle
            currentValidationReason = nil
            pendingExemptionNames = []
        default:
            break
        }
    }
}

@MainActor
final class InspirationCreatorStore: ObservableObject {
    @Published private(set) var activeChapterID: String?
    @Published private(set) var snapshot: InspirationSnapshot?
    @Published private(set) var cards: [InspirationCard] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var adoptedCardIDs: Set<String> = []
    @Published var pacingBoundary = ""

    private let session: AppSession
    private var requestTask: Task<Void, Never>?
    private var requestToken = UUID()
    private var undo: InspirationUndo?

    init(session: AppSession) {
        self.session = session
    }

    func generate(for chapter: Chapter) {
        clearIfChapterChanged(to: chapter.id)
        requestTask?.cancel()
        let normalizedBoundary = InspirationDraftPolicy.normalizedPacingBoundary(pacingBoundary)
        pacingBoundary = normalizedBoundary
        let frozen = InspirationSnapshot(chapter, pacingBoundary: normalizedBoundary)
        let token = UUID()
        let noticeLocation = session.currentBook.map { "《\($0.title)》第 \(chapter.index) 章\n" } ?? ""
        requestToken = token
        snapshot = frozen
        cards = []
        adoptedCardIDs = []
        errorMessage = nil
        isLoading = true
        let payload = InspirationRequestPayload(
            title: frozen.title,
            bible: frozen.bible,
            selectedCharacterIds: frozen.selectedCharacterIDs,
            pacingBoundary: frozen.pacingBoundary
        )
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response: InspirationResponse = try await session.api.request(
                    "/chapters/\(frozen.chapterID)/inspirations",
                    method: "POST",
                    body: payload
                )
                guard !Task.isCancelled, requestToken == token, activeChapterID == frozen.chapterID else { return }
                cards = response.cards
                isLoading = false
            } catch {
                // Moving to another chapter only clears that chapter's local
                // panel. It must not silence a real failure from the request
                // the author already started; only explicit stop/cancellation
                // suppresses this completion notice.
                guard !Task.isCancelled else { return }
                let message = InspirationErrorCopy.message(for: error)
                let presented = LinoErrorPresenter.present(error: error)
                session.notices.publish(
                    noticeLocation + "灵感生成未完成：\(message)",
                    critical: presented.critical,
                    tone: .error,
                    deduplicationKey: "inspiration:\(frozen.chapterID):\(token.uuidString)"
                )
                guard requestToken == token, activeChapterID == frozen.chapterID else { return }
                errorMessage = message
                isLoading = false
            }
        }
    }

    func stop() {
        requestToken = UUID()
        requestTask?.cancel()
        requestTask = nil
        isLoading = false
        cards = []
        errorMessage = nil
        snapshot = nil
        adoptedCardIDs = []
    }

    func clearIfChapterChanged(to chapterID: String?) {
        guard activeChapterID != chapterID else { return }
        // Navigation does not cancel an author-initiated request. Its result
        // may no longer belong in this panel, but a failure must still reach
        // the global notice history with the frozen chapter location.
        activeChapterID = chapterID
        snapshot = nil
        cards = []
        isLoading = false
        errorMessage = nil
        adoptedCardIDs = []
        undo = nil
        pacingBoundary = ""
    }

    func isStale(comparedTo chapter: Chapter?) -> Bool {
        InspirationDraftPolicy.isStale(
            snapshot: snapshot,
            current: chapter,
            pacingBoundary: pacingBoundary
        )
    }

    func recordAdoption(card: InspirationCard, chapterID: String, before: String, after: String) {
        undo = InspirationUndo(chapterID: chapterID, before: before, after: after)
        adoptedCardIDs.insert(card.id)
    }

    func canUndo(chapterID: String, currentBible: String) -> Bool {
        undo?.canApply(chapterID: chapterID, currentBible: currentBible) == true
    }

    func consumeUndo(chapterID: String, currentBible: String) -> String? {
        guard let undo, undo.canApply(chapterID: chapterID, currentBible: currentBible) else { return nil }
        self.undo = nil
        adoptedCardIDs.removeAll()
        return undo.before
    }
}

@MainActor
final class AgentSettingsStore: ObservableObject {
    @Published private(set) var personas: [AgentPersona] = []
    @Published private(set) var profiles: [LLMProfile] = []
    @Published private(set) var bindings: [AgentBinding] = []
    @Published private(set) var isLoading = false
    @Published private(set) var bookPersonas: [BookAgentPersona] = []
    @Published private(set) var bookPersonasBookID: String?
    @Published private(set) var bookModelBindings: [BookAgentModelBinding] = []
    @Published private(set) var bookModelBindingsBookID: String?

    private let session: AppSession
    let sync: ClientSyncStore

    init(session: AppSession, sync: ClientSyncStore = ClientSyncStore()) {
        self.session = session
        self.sync = sync
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            personas = try await session.api.request("/agent-personas")
            profiles = try await session.api.request("/llm_profiles")
            bindings = try await session.api.request("/agent-model-bindings")
            sync.markOnline()
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
        }
    }

    /// Configuration-only read. This endpoint does not create a task or call
    /// a model, so opening a persona screen is safe by construction.
    @discardableResult
    func loadBookPersonas(bookID: String) async -> Bool {
        guard session.currentBook?.id == bookID else { return false }
        if bookPersonasBookID != bookID {
            bookPersonas = []
            bookPersonasBookID = bookID
        }
        do {
            let values: [BookAgentPersona] = try await session.api.request("/books/\(bookID)/agent-personas")
            guard BookPersonaResponsePolicy.accepts(
                responseBookID: bookID, activeBookID: session.currentBook?.id, targetBookID: bookPersonasBookID
            ) else { return false }
            bookPersonas = values
            bookPersonasBookID = bookID
            sync.markOnline()
            return true
        } catch {
            session.notices.publish(error)
            return false
        }
    }

    @discardableResult
    func saveBookPersona(bookID: String, role: String, editablePersona: String) async -> Bool {
        guard BookPersonaResponsePolicy.accepts(
            responseBookID: bookID, activeBookID: session.currentBook?.id, targetBookID: bookPersonasBookID
        ) else { return false }
        let payload = BookAgentPersonaPayload(editable_persona: editablePersona)
        let current = bookPersonas.first(where: { $0.agentRole == role })
        let base = BookAgentPersonaPayload(editable_persona: current?.bookPersona ?? current?.globalPersona ?? "")
        let revision = current?.contentRevision
        do {
            let saved: BookAgentPersona = try await session.api.request(
                "/books/\(bookID)/agent-personas/\(role)", method: "PUT", body: payload,
                ifMatch: revision ?? 0, allowZeroRevision: revision == nil
            )
            guard BookPersonaResponsePolicy.accepts(
                responseBookID: bookID, activeBookID: session.currentBook?.id, targetBookID: bookPersonasBookID
            ) else { return false }
            replaceBookPersona(saved, bookID: bookID)
            return true
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(kind: .agentPersona, id: role, path: "/books/\(bookID)/agent-personas/\(role)", method: "PUT", readPath: "/books/\(bookID)/agent-personas/\(role)", readStrategy: .direct, baseRevision: revision ?? 0, payload: payload, baseSnapshot: base, error: conflict, api: session.api)
            }
            session.notices.publish(error)
            return false
        }
    }

    @discardableResult
    func resetBookPersona(bookID: String, role: String) async -> Bool {
        guard BookPersonaResponsePolicy.accepts(
            responseBookID: bookID, activeBookID: session.currentBook?.id, targetBookID: bookPersonasBookID
        ) else { return false }
        let revision = bookPersonas.first(where: { $0.agentRole == role })?.contentRevision
        do {
            try await session.api.rawRequest("/books/\(bookID)/agent-personas/\(role)", method: "DELETE", ifMatch: revision)
            // DELETE deliberately carries no response. Reload so source stays
            // server-authoritative instead of inferring global vs default from
            // equal text values.
            return await loadBookPersonas(bookID: bookID)
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(kind: .agentPersona, id: role, path: "/books/\(bookID)/agent-personas/\(role)", method: "DELETE", readPath: "/books/\(bookID)/agent-personas/\(role)", readStrategy: .direct, baseRevision: revision ?? 0, payload: EmptyMutationPayload(), baseSnapshot: EmptyMutationPayload(), error: conflict, api: session.api)
            }
            session.notices.publish(error)
            return false
        }
    }

    private func replaceBookPersona(_ persona: BookAgentPersona, bookID: String) {
        bookPersonasBookID = bookID
        if let index = bookPersonas.firstIndex(where: { $0.agentRole == persona.agentRole }) {
            bookPersonas[index] = persona
        } else {
            bookPersonas.append(persona)
        }
    }

    /// Configuration-only read: opening this screen cannot call a model or
    /// alter a binding. An absent book row is represented by `source=global`.
    @discardableResult
    func loadBookModelBindings(bookID: String) async -> Bool {
        guard session.currentBook?.id == bookID else { return false }
        if bookModelBindingsBookID != bookID {
            bookModelBindings = []
            bookModelBindingsBookID = bookID
        }
        do {
            let values: [BookAgentModelBinding] = try await session.api.request("/books/\(bookID)/agent-model-bindings")
            guard session.currentBook?.id == bookID, bookModelBindingsBookID == bookID else { return false }
            bookModelBindings = values
            sync.markOnline()
            return true
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
            return false
        }
    }

    @discardableResult
    func saveBookModelBinding(bookID: String, role: String, binding: AgentModelBindingValues) async -> Bool {
        guard session.currentBook?.id == bookID, bookModelBindingsBookID == bookID else { return false }
        let current = bookModelBindings.first(where: { $0.agentRole == role })
        let revision = current?.contentRevision
        let base = current?.bookBinding ?? current?.globalBinding ?? binding
        do {
            let saved: BookAgentModelBinding = try await session.api.request(
                "/books/\(bookID)/agent-model-bindings/\(role)", method: "PUT", body: binding,
                ifMatch: revision ?? 0, allowZeroRevision: revision == nil
            )
            guard session.currentBook?.id == bookID, bookModelBindingsBookID == bookID else { return false }
            replaceBookModelBinding(saved, bookID: bookID)
            sync.markOnline()
            return true
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(kind: .modelBinding, id: role, path: "/books/\(bookID)/agent-model-bindings/\(role)", method: "PUT", readPath: "/books/\(bookID)/agent-model-bindings/\(role)", readStrategy: .direct, baseRevision: revision ?? 0, payload: binding, baseSnapshot: base, error: conflict, api: session.api)
            }
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
            return false
        }
    }

    @discardableResult
    func clearBookModelBinding(bookID: String, role: String) async -> Bool {
        guard session.currentBook?.id == bookID, bookModelBindingsBookID == bookID else { return false }
        let revision = bookModelBindings.first(where: { $0.agentRole == role })?.contentRevision
        do {
            try await session.api.rawRequest(
                "/books/\(bookID)/agent-model-bindings/\(role)", method: "DELETE", ifMatch: revision
            )
            return await loadBookModelBindings(bookID: bookID)
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(kind: .modelBinding, id: role, path: "/books/\(bookID)/agent-model-bindings/\(role)", method: "DELETE", readPath: "/books/\(bookID)/agent-model-bindings/\(role)", readStrategy: .direct, baseRevision: revision ?? 0, payload: EmptyMutationPayload(), baseSnapshot: EmptyMutationPayload(), error: conflict, api: session.api)
            }
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
            return false
        }
    }

    private func replaceBookModelBinding(_ binding: BookAgentModelBinding, bookID: String) {
        bookModelBindingsBookID = bookID
        if let index = bookModelBindings.firstIndex(where: { $0.agentRole == binding.agentRole }) {
            bookModelBindings[index] = binding
        } else {
            bookModelBindings.append(binding)
        }
    }

    @discardableResult
    func createProfile(name: String, baseURL: String, apiKey: String, model: String) async -> Bool {
        do {
            let payload = LLMProfileCreatePayload(name: name, provider: "openai-compatible", base_url: baseURL, api_key: apiKey, model_name: model)
            let profile: LLMProfile = try await session.api.request("/llm_profiles", method: "POST", body: payload)
            profiles.append(profile)
            return true
        } catch {
            session.notices.publish(error)
            return false
        }
    }

    @discardableResult
    func updateProfile(_ profile: LLMProfile, apiKey: String?) async -> Bool {
        let payload = LLMProfilePatchPayload(profile: profile, apiKey: apiKey)
        let baseProfile = profiles.first(where: { $0.id == profile.id }) ?? profile
        // Do not queue `payload`: it may carry api_key. The conflict record is
        // intentionally author-visible configuration only.
        let conflictPayload = LLMProfileConflictPayload(profile: profile)
        let conflictBase = LLMProfileConflictPayload(profile: baseProfile)
        let includesNewAPIKey = !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        do {
            let updated: LLMProfile = try await session.api.request("/llm_profiles/\(profile.id)", method: "PATCH", body: payload, ifMatch: profile.contentRevision)
            if let idx = profiles.firstIndex(where: { $0.id == updated.id }) {
                profiles[idx] = updated
            }
            bindings = try await session.api.request("/agent-model-bindings")
            return true
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .llmProfile, id: profile.id, path: "/llm_profiles/\(profile.id)", method: "PATCH",
                    readPath: "/llm_profiles/\(profile.id)", readStrategy: .direct,
                    baseRevision: profile.contentRevision, payload: conflictPayload, baseSnapshot: conflictBase,
                    // The memory-only key cannot be requeued. Endpoint
                    // changes are the mandatory re-entry case, and treating
                    // any newly supplied key the same avoids silently
                    // dropping a credential update after conflict recovery.
                    requiresSecretReentry: includesNewAPIKey,
                    error: conflict, api: session.api
                )
            }
            session.notices.publish(error)
            return false
        }
    }

    func deleteProfile(_ profile: LLMProfile) async {
        do {
            try await session.api.rawRequest("/llm_profiles/\(profile.id)", method: "DELETE", ifMatch: profile.contentRevision)
            profiles.removeAll { $0.id == profile.id }
            bindings = try await session.api.request("/agent-model-bindings")
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .llmProfile, id: profile.id, path: "/llm_profiles/\(profile.id)", method: "DELETE",
                    readPath: "/llm_profiles/\(profile.id)", readStrategy: .direct,
                    baseRevision: profile.contentRevision, payload: EmptyMutationPayload(), baseSnapshot: EmptyMutationPayload(),
                    error: conflict, api: session.api
                )
            }
            session.notices.publish(error)
        }
    }

    func testProfile(_ profile: LLMProfile) async {
        do {
            try await session.api.rawRequest("/llm_profiles/\(profile.id)/test", method: "POST")
            session.notices.publish("模型连接测试成功")
        } catch {
            session.notices.publish(error)
        }
    }

    func bind(role: String, profileId: String?) async {
        let payload = AgentBindingProfilePayload(llmProfileId: profileId)
        let current = bindings.first(where: { $0.agentRole == role })
        let revision = current?.contentRevision
        let base = AgentBindingProfilePayload(llmProfileId: current?.llmProfileId)
        do {
            // Binding a profile must not restate thinking/effort/temperature.
            // The server treats an explicitly encoded `null` as "clear this
            // field", so reusing AgentBindingPayload here would wipe settings
            // the caller never intended to touch.
            let binding: AgentBinding = try await session.api.request("/agent-model-bindings/\(role)", method: "PATCH", body: payload, ifMatch: revision)
            if let idx = bindings.firstIndex(where: { $0.agentRole == role }) {
                bindings[idx] = binding
            } else {
                bindings.append(binding)
            }
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .modelBinding, id: role, path: "/agent-model-bindings/\(role)", method: "PATCH",
                    readPath: "/agent-model-bindings/\(role)", readStrategy: .direct,
                    baseRevision: revision ?? 0, payload: payload, baseSnapshot: base, error: conflict, api: session.api
                )
            }
            session.notices.publish(error)
        }
    }

    func configureThinking(role: String, enabled: Bool?, effort: String?) async {
        guard let current = bindings.first(where: { $0.agentRole == role }) else { return }
        let payload = AgentBindingPayload(
            llmProfileId: current.llmProfileId,
            thinkingEnabled: enabled,
            reasoningEffort: enabled == false ? nil : effort,
            temperature: enabled == true ? nil : current.temperature
        )
        let base = AgentBindingPayload(
            llmProfileId: current.llmProfileId,
            thinkingEnabled: current.thinkingEnabled,
            reasoningEffort: current.reasoningEffort,
            temperature: current.temperature
        )
        do {
            let binding: AgentBinding = try await session.api.request("/agent-model-bindings/\(role)", method: "PATCH", body: payload, ifMatch: current.contentRevision)
            if let idx = bindings.firstIndex(where: { $0.agentRole == role }) {
                bindings[idx] = binding
            } else {
                bindings.append(binding)
            }
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .modelBinding, id: role, path: "/agent-model-bindings/\(role)", method: "PATCH",
                    readPath: "/agent-model-bindings/\(role)", readStrategy: .direct,
                    baseRevision: current.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api
                )
            }
            session.notices.publish(error)
        }
    }

    func configureTemperature(role: String, temperature: Double?) async {
        guard let current = bindings.first(where: { $0.agentRole == role }) else { return }
        let payload = AgentBindingPayload(
            llmProfileId: current.llmProfileId,
            thinkingEnabled: current.thinkingEnabled,
            reasoningEffort: current.reasoningEffort,
            temperature: temperature
        )
        let base = AgentBindingPayload(
            llmProfileId: current.llmProfileId,
            thinkingEnabled: current.thinkingEnabled,
            reasoningEffort: current.reasoningEffort,
            temperature: current.temperature
        )
        do {
            let binding: AgentBinding = try await session.api.request("/agent-model-bindings/\(role)", method: "PATCH", body: payload, ifMatch: current.contentRevision)
            if let idx = bindings.firstIndex(where: { $0.agentRole == role }) {
                bindings[idx] = binding
            } else {
                bindings.append(binding)
            }
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .modelBinding, id: role, path: "/agent-model-bindings/\(role)", method: "PATCH",
                    readPath: "/agent-model-bindings/\(role)", readStrategy: .direct,
                    baseRevision: current.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api
                )
            }
            session.notices.publish(error)
        }
    }

    func savePersona(_ persona: AgentPersona) async {
        let payload = AgentPersonaPayload(editable_persona: persona.editablePersona)
        let base = AgentPersonaPayload(editable_persona: personas.first(where: { $0.agentRole == persona.agentRole })?.editablePersona ?? persona.editablePersona)
        do {
            let saved: AgentPersona = try await session.api.request("/agent-personas/\(persona.agentRole)", method: "PATCH", body: payload, ifMatch: persona.contentRevision)
            if let idx = personas.firstIndex(where: { $0.agentRole == saved.agentRole }) {
                personas[idx] = saved
            }
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .agentPersona, id: persona.agentRole, path: "/agent-personas/\(persona.agentRole)", method: "PATCH",
                    readPath: "/agent-personas/\(persona.agentRole)", readStrategy: .direct,
                    baseRevision: persona.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api
                )
            }
            session.notices.publish(error)
        }
    }

    func resetPersona(role: String) async {
        let revision = personas.first(where: { $0.agentRole == role })?.contentRevision
        do {
            let saved: AgentPersona = try await session.api.request("/agent-personas/\(role)/reset", method: "POST", ifMatch: revision)
            if let idx = personas.firstIndex(where: { $0.agentRole == saved.agentRole }) {
                personas[idx] = saved
            }
        } catch {
            if let conflict = error as? APIError, case .writeConflict = conflict {
                await sync.recordWriteConflict(
                    kind: .agentPersona, id: role, path: "/agent-personas/\(role)/reset", method: "POST",
                    readPath: "/agent-personas/\(role)", readStrategy: .direct,
                    baseRevision: revision ?? 0, payload: EmptyMutationPayload(), baseSnapshot: EmptyMutationPayload(), error: conflict, api: session.api
                )
            }
            session.notices.publish(error)
        }
    }
}

private struct BookPayload: Encodable, Sendable {
    let title: String
    let world_setting: String
}

private struct EmptyMutationPayload: Encodable, Sendable {}

private struct ChapterCreatePayload: Encodable, Sendable {
    let title: String
    let user_prompt: String
}

struct ChapterPatchPayload: Encodable, Sendable {
    var title: String
    var user_prompt: String
    var draft_text: String
    var headline: String
    var long_summary: String
    var state_changes: [JSONValue]
    var unresolved_items: [JSONValue]
    var atomic_memories: [JSONValue]
    var character_links: [ChapterLink]
    var exempted_character_names: [String]

    init(_ chapter: Chapter) {
        title = chapter.title
        user_prompt = chapter.userPrompt
        draft_text = chapter.draftText
        headline = chapter.headline
        long_summary = chapter.longSummary
        state_changes = chapter.stateChanges
        unresolved_items = chapter.unresolvedItems
        atomic_memories = chapter.atomicMemories
        character_links = chapter.characterLinks
        exempted_character_names = chapter.exemptedCharacterNames
    }
}

private struct ChapterImportPayload: Encodable, Sendable {
    let draft_text: String
}

private struct CharacterImportItem: Encodable, Sendable {
    let name: String
    let role: String
    let fixed_profile: String
}

private struct CharacterImportPayload: Encodable, Sendable {
    let items: [CharacterImportItem]
}

private struct CharacterEventPatchPayload: Encodable, Sendable {
    let event_text: String
}

private struct CharacterPatchPayload: Encodable, Sendable {
    var name: String
    var role: String
    var fixed_profile: String

    init(name: String, role: String, fixed_profile: String) {
        self.name = name
        self.role = role
        self.fixed_profile = fixed_profile
    }

    init(_ character: Character) {
        name = character.name
        role = character.role
        fixed_profile = character.fixedProfile
    }
}

private struct LLMProfileCreatePayload: Encodable, Sendable {
    let name: String
    let provider: String
    let base_url: String
    let api_key: String
    let model_name: String
}

private struct LLMProfilePatchPayload: Encodable, Sendable {
    let profile: LLMProfile
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case name, provider
        case baseURL = "base_url"
        case apiKey = "api_key"
        case modelName = "model_name"
    }

    init(profile: LLMProfile, apiKey: String?) {
        self.profile = profile
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : apiKey
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profile.name, forKey: .name)
        try container.encode(profile.provider, forKey: .provider)
        try container.encode(profile.baseURL, forKey: .baseURL)
        try container.encode(profile.modelName, forKey: .modelName)
        if let apiKey {
            try container.encode(apiKey, forKey: .apiKey)
        }
    }
}

/// Deliberately separate from the network PATCH body. Pending mutations and
/// three-way conflict records are persisted, so an API key must never be
/// representable by their profile payload.
private struct LLMProfileConflictPayload: Encodable, Sendable {
    let name: String
    let provider: String
    let base_url: String
    let model_name: String

    init(profile: LLMProfile) {
        name = profile.name
        provider = profile.provider
        base_url = profile.baseURL
        model_name = profile.modelName
    }
}

/// Profile-only binding patch. Encodes exactly one key so the server's
/// `model_fields_set` check leaves thinking, effort and temperature alone.
private struct AgentBindingProfilePayload: Encodable, Sendable {
    let llmProfileId: String?

    enum CodingKeys: String, CodingKey {
        case llmProfileId = "llm_profile_id"
    }
}

private struct AgentBindingPayload: Encodable, Sendable {
    let llmProfileId: String?
    let thinkingEnabled: Bool?
    let reasoningEffort: String?
    let temperature: Double?

    enum CodingKeys: String, CodingKey {
        case llmProfileId = "llm_profile_id"
        case thinkingEnabled = "thinking_enabled"
        case reasoningEffort = "reasoning_effort"
        case temperature
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(llmProfileId, forKey: .llmProfileId)
        try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(temperature, forKey: .temperature)
    }
}

private struct AgentPersonaPayload: Encodable, Sendable {
    let editable_persona: String
}
