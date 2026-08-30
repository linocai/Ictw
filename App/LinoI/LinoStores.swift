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
        let migration = ConnectionEndpoint.migratedBaseURL(
            saved: UserDefaults.standard.string(forKey: "linoi.baseURL")
        )
        if migration.shouldPersist {
            UserDefaults.standard.set(migration.value, forKey: "linoi.baseURL")
        }
        let savedToken = KeychainStore.get("appToken")
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        baseURL = environment["LINOI_DEBUG_BASE_URL"] ?? migration.value
        token = environment["LINOI_DEBUG_TOKEN"] ?? savedToken
        #else
        baseURL = migration.value
        token = savedToken
        #endif
    }

    func saveConnection() {
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

    func load() async {
        // Cold start is local-first: a Ningbo outage must not turn a book the
        // author already opened into an empty shelf.
        if books.isEmpty { books = sync.cache.books() }
        guard !session.token.isEmpty else { sync.markOffline(); return }
        isLoading = true
        defer { isLoading = false }
        do {
            await sync.flush(using: session.api)
            books = try await session.api.request("/books")
            sync.cache.saveBooks(books)
            sync.markOnline()
        } catch {
            if case APIError.transport = error { sync.markOffline() }
            session.notices.publish(error)
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
            if case let conflict as APIError = error {
                await sync.recordWriteConflict(kind: .book, id: book.id, path: "/books/\(book.id)", method: "PATCH", baseRevision: book.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api)
            } else if case APIError.transport = error {
                sync.markOffline()
                sync.enqueue(kind: .book, id: book.id, path: "/books/\(book.id)", method: "PATCH", baseRevision: book.contentRevision, payload: payload, baseSnapshot: base)
            }
            session.notices.publish(error)
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
            if case let conflict as APIError = error {
                await sync.recordWriteConflict(kind: .character, id: character.id, path: "/characters/\(character.id)", method: "PATCH", baseRevision: character.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api)
            } else if case APIError.transport = error {
                sync.markOffline()
                sync.enqueue(kind: .character, id: character.id, path: "/characters/\(character.id)", method: "PATCH", baseRevision: character.contentRevision, payload: payload, baseSnapshot: base)
            }
            session.notices.publish(error)
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
            if case let conflict as APIError = error {
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
            if case APIError.transport = error {
                sync.markOffline()
                guard sync.enqueue(
                    kind: .characterEvent, id: event.id,
                    path: "/character-events/\(event.id)", method: "PATCH",
                    baseRevision: event.contentRevision,
                    payload: payload, baseSnapshot: base
                ) else {
                    session.notices.publish("人物记录未能安全保存在本机，请保留编辑框后重试。", critical: true)
                    return false
                }
                var local = event
                local.eventText = text
                applyEventUpdate(local)
                session.notices.publish("当前离线，人物记录已保存在本机，恢复网络后会安全同步。")
                return true
            }
            session.notices.publish(error)
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
            if case let conflict as APIError = error {
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
    @Published var currentChapter: Chapter?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var writingPhase: ChapterWritingPhase = .idle
    @Published private(set) var saveState: ChapterSaveState = .synced
    @Published private(set) var pollingConnectionInterrupted = false
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
    /// Local-only previous result, retained after edits strictly as stale
    /// context. It can never unlock acceptance or be sent back to Backend.
    @Published private(set) var staleCheckedSnapshot: CheckedDraftSnapshot?
    @Published private(set) var restoredLocalDraft = false
    /// Names the last preflight/job failure reported as unauthorized-but-present.
    /// Non-empty exactly when the editor should offer "本章豁免并重试".
    @Published private(set) var pendingExemptionNames: [String] = []

    private let session: AppSession
    let sync: ClientSyncStore
    private let cache = ChapterDraftCache()
    private var pollingTask: Task<Void, Never>?
    private var pollingChapterId: String?
    private var pollingErrorNotified = false
    private var localEditRevision: UInt64 = 0

    init(session: AppSession, sync: ClientSyncStore = ClientSyncStore()) {
        self.session = session
        self.sync = sync
    }

    var draftCharCount: Int {
        currentChapter?.draftText.filter { !$0.isWhitespace }.count ?? 0
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

    func load(_ summary: ChapterSummary) async {
        guard persistLocalDraftIfNeeded() else { return }
        isLoading = true
        restoredLocalDraft = false
        pollingConnectionInterrupted = false
        memoryContext = nil
        checkerResult = nil
        failedCandidateCheckerResult = nil
        checkerAppliesToVisibleDraft = false
        staleCheckedSnapshot = nil
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
            if case let conflict as APIError = error {
                await sync.recordWriteConflict(kind: .chapter, id: chapter.id, path: "/chapters/\(chapter.id)", method: "PATCH", baseRevision: chapter.contentRevision, payload: payload, baseSnapshot: base, error: conflict, api: session.api)
                saveState = .remoteSaveFailed(message: "章节已在另一设备更新；本机内容已保留，等待比较。", localDraftPreserved: localSnapshotSaved)
                session.notices.publish("章节已在另一设备更新；本机内容已保留。")
                return nil
            }
            if case APIError.transport = error {
                sync.markOffline()
                sync.enqueue(kind: .chapter, id: chapter.id, path: "/chapters/\(chapter.id)", method: "PATCH", baseRevision: chapter.contentRevision, payload: payload, baseSnapshot: base)
                saveState = .localDraft
                session.notices.publish("当前离线，修改已保存在本机，恢复网络后会安全同步。")
                return nil
            }
            let presented = LinoErrorPresenter.present(error: error)
            saveState = .remoteSaveFailed(
                message: presented.message,
                localDraftPreserved: localSnapshotSaved
            )
            session.notices.publish(presented.message, critical: presented.critical, tone: .error)
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
    func generate() async -> Chapter? {
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
        checkerAppliesToVisibleDraft = false
        memoryContext = nil
        guard await save() != nil else { return nil }
        return await startWrite(replaceDraft: replace)
    }

    /// Saves current edits, then starts the background Extractor job and
    /// returns immediately. Completion (chapter becomes `finalized`) is
    /// observed reactively via `currentChapter`.
    func accept(overrideChecker: Bool = false) async -> Chapter? {
        guard !writingPhase.isActive else { return nil }
        guard let saved = await save() else { return nil }
        pendingExemptionNames = []
        currentValidationReason = nil
        failedCandidateCheckerResult = nil
        ChapterTaskOutcomeStore.clear(chapterID: saved.id)
        writingPhase = .extracting
        do {
            let status = try await session.api.accept(
                chapterId: saved.id, contentRevision: saved.contentRevision,
                overrideChecker: overrideChecker
            )
            applyJobStatus(status, chapterId: saved.id)
            if !Self.isTerminalPhase(status.phase) {
                pollJob(chapterId: saved.id)
            }
            return currentChapter
        } catch {
            _ = await recordActionRevisionConflictIfNeeded(error, chapter: saved)
            if await adoptRunningJobIfNeeded(error, chapterId: saved.id) {
                return currentChapter
            }
            applyStartFailure(error, chapterId: saved.id, intendedStage: .extraction)
            return nil
        }
    }

    /// Retries only the memory archive for prose the server has already
    /// accepted. This never re-runs Checker or asks the user to accept again.
    func retryArchive() async -> Chapter? {
        guard !writingPhase.isActive else { return nil }
        guard let saved = await save(), saved.status == "finalized" else { return nil }
        ChapterTaskOutcomeStore.clear(chapterID: saved.id)
        writingPhase = .extracting
        do {
            let status = try await session.api.retryArchive(
                chapterId: saved.id, contentRevision: saved.contentRevision
            )
            applyJobStatus(status, chapterId: saved.id)
            if !Self.isTerminalPhase(status.phase) {
                pollJob(chapterId: saved.id)
            }
            return currentChapter
        } catch {
            _ = await recordActionRevisionConflictIfNeeded(error, chapter: saved)
            if await adoptRunningJobIfNeeded(error, chapterId: saved.id) {
                return currentChapter
            }
            applyStartFailure(error, chapterId: saved.id, intendedStage: .extraction)
            return nil
        }
    }

    func rerunChecker() async -> CheckerResult? {
        guard !writingPhase.isActive else { return nil }
        checkerRefreshing = true
        defer { checkerRefreshing = false }
        // The editor keeps keystrokes in memory until an explicit transition.
        // Checker must therefore flush that exact text first; otherwise the
        // backend checks the previous server draft while the UI incorrectly
        // presents the result as belonging to the edited text.
        guard let chapter = await save() else { return nil }
        let startingRevision = localEditRevision
        do {
            let response = try await session.api.rerunChecker(
                chapterId: chapter.id, contentRevision: chapter.contentRevision
            )
            guard currentChapter?.id == chapter.id else { return nil }
            guard ChapterRefreshReconciler.shouldReplaceLocal(
                startingRevision: startingRevision,
                currentRevision: localEditRevision,
                hasLocalInputDivergence: hasLocalInputDivergence
            ) else { return nil }
            checkerResult = response.checkerResult
            failedCandidateCheckerResult = nil
            checkerAppliesToVisibleDraft = response.checkerResult != nil
            if let result = response.checkerResult, let checked = currentChapter, result.hasConcreteVerdict {
                let snapshot = CheckedDraftSnapshot(chapter: checked, checkerResult: result)
                if cache.saveCheckedSnapshot(snapshot) { staleCheckedSnapshot = snapshot }
            }
            return response.checkerResult
        } catch {
            _ = await recordActionRevisionConflictIfNeeded(error, chapter: chapter)
            session.notices.publish(error)
            return nil
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

    /// Adds the names from the last unauthorized-character failure to this
    /// chapter's exemption list, persists it, then retries generation.
    func exemptAndRetry() async -> Chapter? {
        guard !pendingExemptionNames.isEmpty, var chapter = currentChapter else { return nil }
        let merged = Array(Set(chapter.exemptedCharacterNames).union(pendingExemptionNames)).sorted()
        chapter.exemptedCharacterNames = merged
        currentChapter = chapter
        pendingExemptionNames = []
        guard await save() != nil else { return nil }
        return await generate()
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

    private func startWrite(replaceDraft: Bool) async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        ChapterTaskOutcomeStore.clear(chapterID: chapter.id)
        writingPhase = .selectingMemory
        do {
            let status = try await session.api.startWrite(
                chapterId: chapter.id, replaceDraft: replaceDraft,
                contentRevision: chapter.contentRevision
            )
            applyJobStatus(status, chapterId: chapter.id)
            if !Self.isTerminalPhase(status.phase) {
                pollJob(chapterId: chapter.id)
            }
            return currentChapter
        } catch {
            _ = await recordActionRevisionConflictIfNeeded(error, chapter: chapter)
            if await adoptRunningJobIfNeeded(error, chapterId: chapter.id) {
                return currentChapter
            }
            applyStartFailure(error, chapterId: chapter.id, intendedStage: .memorySelection)
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
        pollingChapterId = chapterId
        pollingErrorNotified = false
        pollingConnectionInterrupted = false
        pollingTask = Task { [weak self] in
            await self?.runPolling(chapterId: chapterId)
        }
    }

    private func stopPolling(for chapterId: String) {
        guard pollingChapterId == chapterId else { return }
        pollingTask?.cancel()
        pollingTask = nil
        pollingChapterId = nil
        pollingConnectionInterrupted = false
    }

    private func runPolling(chapterId: String) async {
        while !Task.isCancelled {
            do {
                let status = try await session.api.jobStatus(chapterId: chapterId)
                guard !Task.isCancelled, pollingChapterId == chapterId else { return }
                pollingErrorNotified = false
                pollingConnectionInterrupted = false
                applyJobStatus(status, chapterId: chapterId)
                if Self.isTerminalPhase(status.phase) {
                    pollingChapterId = nil
                    return
                }
            } catch {
                guard !Task.isCancelled, pollingChapterId == chapterId else { return }
                pollingConnectionInterrupted = true
                if !pollingErrorNotified {
                    pollingErrorNotified = true
                    session.notices.publish(LinoErrorPresenter.connectionInterrupted)
                }
            }
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
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
        pollingConnectionInterrupted = false
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
            writingPhase = .checking
            setCurrentChapterStatus("writing", chapterId: chapterId)
        case "revising":
            writingPhase = .legacyRevising
            setCurrentChapterStatus("writing", chapterId: chapterId)
        case "extracting":
            failedCandidateCheckerResult = nil
            writingPhase = .extracting
            setCurrentChapterStatus("finalized", chapterId: chapterId)
        case "done":
            memoryContext = status.memoryContext ?? memoryContext
            failedCandidateCheckerResult = nil
            if status.kind == "write" {
                checkerResult = status.visibleCheckerResult ?? status.checkerResult
                checkerAppliesToVisibleDraft = status.visibleCheckerResult != nil
            }
            if let chapter = status.chapter {
                currentChapter = chapter
                if status.kind == "write", status.visibleCheckerResult != nil {
                    saveCheckedSnapshotIfCurrent(status.visibleCheckerResult, chapter: chapter)
                }
                cache.saveClean(chapter)
                saveState = .synced
            } else {
                Task { [weak self] in
                    await self?.refreshChapter(chapterId)
                }
            }
            ChapterTaskOutcomeStore.clear(chapterID: chapterId)
            writingPhase = .idle
            pendingExemptionNames = []
            currentValidationReason = nil
            if let warning = status.completionWarning {
                session.notices.publish(warning)
            }
        case "failed":
            applyJobFailure(status, chapterId: chapterId, announce: announceFailure)
        case "cancelled":
            failedCandidateCheckerResult = nil
            let cancelledStage = writingPhase.currentStage ?? .drafting
            writingPhase = .cancelled(
                message: "任务已取消，当前草稿已保留。",
                stage: cancelledStage
            )
            currentValidationReason = nil
            pendingExemptionNames = []
            if status.kind == "write" {
                checkerResult = status.visibleCheckerResult
                checkerAppliesToVisibleDraft = status.visibleCheckerResult != nil
                saveCheckedSnapshotIfCurrent(status.visibleCheckerResult, chapter: currentChapter)
            }
            if let chapter = currentChapter {
                ChapterTaskOutcomeStore.save(
                    phase: writingPhase,
                    chapter: chapter,
                    jobID: status.jobId
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
        if status.kind == "write" {
            failedCandidateCheckerResult = status.failedCandidateCheckerResult
            checkerResult = status.visibleCheckerResult
            checkerAppliesToVisibleDraft = status.visibleCheckerResult != nil
            saveCheckedSnapshotIfCurrent(status.visibleCheckerResult, chapter: currentChapter)
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
        pendingExemptionNames = []
        if let violation = status.violations?.first(where: { $0.code == "unselected_character" }),
           let names = violation.names, !names.isEmpty {
            pendingExemptionNames = names
        }
        if let chapter = currentChapter {
            ChapterTaskOutcomeStore.save(
                phase: writingPhase,
                chapter: chapter,
                validationReason: currentValidationReason,
                pendingExemptionNames: pendingExemptionNames,
                jobID: status.jobId
            )
        }
        if announce {
            session.notices.publish(presented.message, critical: presented.critical, tone: .error)
        }
        Task { [weak self] in
            await self?.refreshChapterAfterFailure(chapterId)
        }
    }

    private func applyStartFailure(
        _ error: Error,
        chapterId: String,
        intendedStage: ChapterGenerationStage
    ) {
        guard currentChapter?.id == chapterId else {
            session.notices.publish(error)
            return
        }
        pendingExemptionNames = []
        let presented = LinoErrorPresenter.present(error: error)
        let code = LinoErrorPresenter.code(for: error)
        if let apiError = error as? APIError,
           case let .validation(validationCode, _, names) = apiError,
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
                pendingExemptionNames: pendingExemptionNames
            )
        }
        session.notices.publish(presented.message, critical: presented.critical, tone: .error)
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
    private func adoptRunningJobIfNeeded(_ error: Error, chapterId: String) async -> Bool {
        guard let apiError = error as? APIError,
              case let .validation(code, _, _) = apiError,
              code == "write_running" else { return false }
        do {
            let status = try await session.api.jobStatus(chapterId: chapterId)
            guard currentChapter?.id == chapterId else { return true }
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

    private static func validationReason(from violations: [Violation]?) -> String? {
        let messages = violations?
            .map { $0.message.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard !messages.isEmpty else { return nil }
        return messages.joined(separator: "；")
    }

    private static func failureStage(from status: WriteJobStatus) -> ChapterGenerationStage {
        if ["writer_validation_failed", "writer_minimum_failed"].contains(status.errorCode) {
            return .deterministicValidation
        }
        switch status.errorContext?.agentRole {
        case "memory_selector": return .memorySelection
        case "writer": return .drafting
        case "checker": return .bibleChecking
        case "extractor": return .extraction
        default:
            if status.kind == "extract" { return .extraction }
            switch status.errorCode {
            case "checker_failed": return .bibleChecking
            default: return .drafting
            }
        }
    }

    private static func isActiveJobPhase(_ phase: String) -> Bool {
        switch phase {
        case "selecting_memory", "writing", "validating", "checking", "revising", "extracting": return true
        default: return false
        }
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
        writingPhase = .idle
        currentValidationReason = nil
        pendingExemptionNames = []
        failedCandidateCheckerResult = nil
        pollingConnectionInterrupted = false
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
        currentChapter = refreshed
        cache.saveClean(refreshed)
        saveState = .synced
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
                guard !Task.isCancelled, requestToken == token, activeChapterID == frozen.chapterID else { return }
                errorMessage = InspirationErrorCopy.message(for: error)
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
        requestToken = UUID()
        requestTask?.cancel()
        requestTask = nil
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
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
            replaceBookModelBinding(saved, bookID: bookID)
            sync.markOnline()
            return true
        } catch {
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
            if case let conflict as APIError = error {
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
