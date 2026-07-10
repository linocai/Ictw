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
        baseURL = UserDefaults.standard.string(forKey: "linoi.baseURL") ?? "https://linoi.neluvee.top"
        let savedToken = KeychainStore.get("appToken")
        #if DEBUG
        token = savedToken.isEmpty
            ? ProcessInfo.processInfo.environment["LINOI_DEBUG_TOKEN"] ?? ""
            : savedToken
        #else
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

    init(session: AppSession) {
        self.session = session
    }

    func load() async {
        guard !session.token.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            books = try await session.api.request("/books")
        } catch {
            session.notices.publish(error)
        }
    }

    func createBook(title: String) async {
        do {
            let payload = BookPayload(title: title, world_setting: "")
            let book: Book = try await session.api.request("/books", method: "POST", body: payload)
            books.insert(book, at: 0)
            session.currentBook = book
        } catch {
            session.notices.publish(error)
        }
    }

    func open(_ book: Book) async {
        do {
            session.currentBook = try await session.api.request("/books/\(book.id)")
        } catch {
            session.notices.publish(error)
        }
    }

    func upsert(_ book: Book) {
        if let idx = books.firstIndex(where: { $0.id == book.id }) {
            books[idx] = book
        } else {
            books.insert(book, at: 0)
        }
    }

    func delete(_ book: Book) async {
        do {
            try await session.api.rawRequest("/books/\(book.id)", method: "DELETE")
            books.removeAll { $0.id == book.id }
            if session.currentBook?.id == book.id {
                session.closeBook()
            }
        } catch {
            session.notices.publish(error)
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

    init(session: AppSession) {
        self.session = session
    }

    func load(bookId: String) async {
        chapterPath = []
        isLoading = true
        defer { isLoading = false }
        do {
            chapters = try await session.api.request("/books/\(bookId)/chapters")
        } catch {
            session.notices.publish(error)
        }
    }

    func createChapter() async {
        guard let book = session.currentBook else { return }
        do {
            let payload = ChapterCreatePayload(title: "新章节", user_prompt: "")
            let chapter: Chapter = try await session.api.request("/books/\(book.id)/chapters", method: "POST", body: payload)
            upsert(chapter)
            chapters = try await session.api.request("/books/\(book.id)/chapters")
            if let created = chapters.first(where: { $0.id == chapter.id }) {
                chapterPath.append(created)
            }
        } catch {
            session.notices.publish(error)
        }
    }

    func saveBook(title: String, world: String) async {
        guard let book = session.currentBook else { return }
        do {
            let payload = BookPayload(title: title, world_setting: world)
            let updated: Book = try await session.api.request("/books/\(book.id)", method: "PATCH", body: payload)
            session.currentBook = updated
        } catch {
            session.notices.publish(error)
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
            updatedAt: chapter.updatedAt
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
    }
}

@MainActor
final class CharactersStore: ObservableObject {
    @Published private(set) var characters: [Character] = []
    @Published var selectedCharacterId: String?
    @Published private(set) var isLoading = false

    private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    var selected: Character? {
        if let selectedCharacterId,
           let found = characters.first(where: { $0.id == selectedCharacterId }) {
            return found
        }
        return characters.first
    }

    func load(bookId: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            characters = try await session.api.request("/books/\(bookId)/characters")
            ensureSelection()
        } catch {
            session.notices.publish(error)
        }
    }

    func create(name: String) async {
        guard let book = session.currentBook else { return }
        do {
            let payload = CharacterPatchPayload(name: name, role: "", fixed_profile: "", dynamic_fields: [:])
            let character: Character = try await session.api.request("/books/\(book.id)/characters", method: "POST", body: payload)
            characters.append(character)
            selectedCharacterId = character.id
        } catch {
            session.notices.publish(error)
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

    func update(_ character: Character) async {
        do {
            let payload = CharacterPatchPayload(character)
            let updated: Character = try await session.api.request("/characters/\(character.id)", method: "PATCH", body: payload)
            replace(updated)
        } catch {
            session.notices.publish(error)
        }
    }

    func delete(_ character: Character) async {
        do {
            try await session.api.rawRequest("/characters/\(character.id)", method: "DELETE")
            characters.removeAll { $0.id == character.id }
            ensureSelection()
        } catch {
            session.notices.publish(error)
        }
    }

    func replace(_ character: Character) {
        if let idx = characters.firstIndex(where: { $0.id == character.id }) {
            characters[idx] = character
        } else {
            characters.append(character)
        }
    }

    func updateEvent(_ event: CharacterEvent, text: String) async {
        do {
            let payload = CharacterEventPatchPayload(event_text: text)
            let updated: CharacterEvent = try await session.api.request("/character-events/\(event.id)", method: "PATCH", body: payload)
            applyEventUpdate(updated)
        } catch {
            session.notices.publish(error)
        }
    }

    func deleteEvent(_ event: CharacterEvent) async {
        do {
            try await session.api.rawRequest("/character-events/\(event.id)", method: "DELETE")
            removeEvent(event)
        } catch {
            session.notices.publish(error)
        }
    }

    private func applyEventUpdate(_ event: CharacterEvent) {
        guard let charIdx = characters.firstIndex(where: { $0.id == event.characterId }) else { return }
        guard let eventIdx = characters[charIdx].events.firstIndex(where: { $0.id == event.id }) else { return }
        characters[charIdx].events[eventIdx] = event
    }

    private func removeEvent(_ event: CharacterEvent) {
        guard let charIdx = characters.firstIndex(where: { $0.id == event.characterId }) else { return }
        characters[charIdx].events.removeAll { $0.id == event.id }
    }

    func ensureSelection() {
        if selectedCharacterId == nil || !characters.contains(where: { $0.id == selectedCharacterId }) {
            selectedCharacterId = characters.first?.id
        }
    }
}

@MainActor
final class ChapterEditorStore: ObservableObject {
    enum WritingPhase: Equatable {
        case idle
        case selectingMemory
        case writing
        case revising(attempt: Int)
        case extracting
        case failed(code: String?, message: String)

        var isActive: Bool {
            switch self {
            case .selectingMemory, .writing, .revising, .extracting: return true
            case .idle, .failed: return false
            }
        }

        /// True only for the write-side sub-phases (selecting memory / writing /
        /// revising) — used to decide whether the "停止" (cancel write) control
        /// should be offered, since there is no cancel endpoint for extraction.
        var isGenerating: Bool {
            switch self {
            case .selectingMemory, .writing, .revising: return true
            default: return false
            }
        }

        var label: String? {
            switch self {
            case .selectingMemory: return "正在选择相关记忆"
            case .writing: return "正在生成正文"
            case .revising(let attempt): return "Reviser 第 \(attempt)/2 次修订"
            case .extracting: return "Extractor 正在整理本章记忆"
            case .failed(_, let message): return message
            case .idle: return nil
            }
        }

        var pillStatus: String {
            switch self {
            case .extracting: return "extracting"
            case .selectingMemory, .writing, .revising: return "writing"
            case .failed: return "failed"
            case .idle: return "idle"
            }
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published var currentChapter: Chapter?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var writingPhase: WritingPhase = .idle
    @Published private(set) var restoredLocalDraft = false
    /// Names the last preflight/job failure reported as unauthorized-but-present.
    /// Non-empty exactly when the editor should offer "本章豁免并重试".
    @Published private(set) var pendingExemptionNames: [String] = []

    private let session: AppSession
    private let cache = ChapterDraftCache()
    private var cacheTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var pollingChapterId: String?
    private var pollingErrorNotified = false

    init(session: AppSession) {
        self.session = session
    }

    var draftCharCount: Int {
        currentChapter?.draftText.filter { !$0.isWhitespace }.count ?? 0
    }

    func load(_ summary: ChapterSummary) async {
        isLoading = true
        restoredLocalDraft = false
        defer { isLoading = false }
        do {
            let remote: Chapter = try await session.api.request("/chapters/\(summary.id)")
            let local = cache.load(chapterId: remote.id)
            if let local, local.shouldRestore(over: remote) {
                currentChapter = local.apply(to: remote)
                restoredLocalDraft = true
                session.notices.publish("已恢复本地草稿")
            } else {
                currentChapter = remote
                cache.saveClean(remote)
            }
            pendingExemptionNames = []
            resumePollingIfNeeded()
        } catch {
            session.notices.publish(error)
        }
    }

    func editString(_ keyPath: WritableKeyPath<Chapter, String>, value: String) {
        guard var chapter = currentChapter else { return }
        chapter[keyPath: keyPath] = value
        currentChapter = chapter
        scheduleCacheSave()
    }

    func editTargetWordCount(_ value: Int) {
        guard var chapter = currentChapter else { return }
        chapter.targetWordCount = max(1, value)
        currentChapter = chapter
        scheduleCacheSave()
    }

    func setCharacterLinks(_ links: [ChapterLink]) {
        guard var chapter = currentChapter else { return }
        chapter.characterLinks = links
        currentChapter = chapter
        scheduleCacheSave()
    }

    func save() async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        cacheTask?.cancel()
        isSaving = true
        defer { isSaving = false }
        do {
            let payload = ChapterPatchPayload(chapter)
            let saved: Chapter = try await session.api.request("/chapters/\(chapter.id)", method: "PATCH", body: payload)
            currentChapter = saved
            cache.saveClean(saved)
            return saved
        } catch {
            session.notices.publish(error)
            return nil
        }
    }

    func importDraft(_ text: String) async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        do {
            let imported: Chapter = try await session.api.request("/chapters/\(chapter.id)/import", method: "POST", body: ChapterImportPayload(draft_text: text))
            currentChapter = imported
            cache.saveClean(imported)
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
            session.notices.publish("请先选择“重新编辑本章”，再生成正文。")
            return nil
        }
        let replace = !chapter.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chapter.status == "writing"
        pendingExemptionNames = []
        guard await save() != nil else { return nil }
        return await startWrite(replaceDraft: replace)
    }

    /// Saves current edits, then starts the background Extractor job and
    /// returns immediately. Completion (chapter becomes `finalized`) is
    /// observed reactively via `currentChapter`.
    func accept() async -> Chapter? {
        guard !writingPhase.isActive, !writingPhase.isFailed else { return nil }
        guard let saved = await save() else { return nil }
        pendingExemptionNames = []
        writingPhase = .extracting
        do {
            let status = try await session.api.accept(chapterId: saved.id)
            applyJobStatus(status, chapterId: saved.id)
            if !Self.isTerminalPhase(status.phase) {
                pollJob(chapterId: saved.id)
            }
            return currentChapter
        } catch {
            applyStartFailure(error, chapterId: saved.id)
            return nil
        }
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
            let reopened: Chapter = try await session.api.request("/chapters/\(chapter.id)/reopen", method: "POST")
            currentChapter = reopened
            cache.saveClean(reopened)
            return reopened
        } catch {
            session.notices.publish(error)
            return nil
        }
    }

    func cancelWriting() async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        stopPolling(for: chapter.id)
        writingPhase = .idle
        do {
            let cancelled = try await session.api.cancelWrite(chapterId: chapter.id)
            currentChapter = cancelled
            cache.saveClean(cancelled)
            pendingExemptionNames = []
            return cancelled
        } catch {
            session.notices.publish(error)
            return nil
        }
    }

    func deleteCurrentChapter() async -> Bool {
        guard let chapter = currentChapter else { return false }
        let deletingId = chapter.id
        stopPolling(for: deletingId)
        cacheTask?.cancel()
        do {
            try await session.api.rawRequest("/chapters/\(deletingId)", method: "DELETE")
            cache.remove(chapterId: deletingId)
            writingPhase = .idle
            pendingExemptionNames = []
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
        guard chapter.status == "writing" || chapter.status == "extracting" else { return }
        guard !writingPhase.isActive else { return }
        resumePollingIfNeeded()
    }

    private func startWrite(replaceDraft: Bool) async -> Chapter? {
        guard let chapter = currentChapter else { return nil }
        writingPhase = .selectingMemory
        do {
            let status = try await session.api.startWrite(chapterId: chapter.id, replaceDraft: replaceDraft)
            applyJobStatus(status, chapterId: chapter.id)
            if !Self.isTerminalPhase(status.phase) {
                pollJob(chapterId: chapter.id)
            }
            return currentChapter
        } catch {
            applyStartFailure(error, chapterId: chapter.id)
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
        case "extracting":
            if pollingChapterId != chapter.id {
                writingPhase = .extracting
                pollJob(chapterId: chapter.id)
            }
        default:
            if pollingChapterId != chapter.id {
                writingPhase = .idle
            }
        }
    }

    private func pollJob(chapterId: String) {
        pollingTask?.cancel()
        pollingChapterId = chapterId
        pollingErrorNotified = false
        pollingTask = Task { [weak self] in
            await self?.runPolling(chapterId: chapterId)
        }
    }

    private func stopPolling(for chapterId: String) {
        guard pollingChapterId == chapterId else { return }
        pollingTask?.cancel()
        pollingTask = nil
        pollingChapterId = nil
    }

    private func runPolling(chapterId: String) async {
        while !Task.isCancelled {
            do {
                let status = try await session.api.jobStatus(chapterId: chapterId)
                guard !Task.isCancelled, pollingChapterId == chapterId else { return }
                pollingErrorNotified = false
                applyJobStatus(status, chapterId: chapterId)
                if Self.isTerminalPhase(status.phase) {
                    pollingChapterId = nil
                    return
                }
            } catch {
                guard !Task.isCancelled, pollingChapterId == chapterId else { return }
                if !pollingErrorNotified {
                    pollingErrorNotified = true
                    session.notices.publish("与服务器的连接暂时中断，正在自动重试。")
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

    private func applyJobStatus(_ status: WriteJobStatus, chapterId: String) {
        guard currentChapter?.id == chapterId else { return }
        switch status.phase {
        case "selecting_memory":
            writingPhase = .selectingMemory
        case "writing":
            writingPhase = .writing
        case "revising":
            writingPhase = .revising(attempt: min(max(status.attempt ?? 1, 1), 2))
        case "extracting":
            writingPhase = .extracting
        case "done":
            if let chapter = status.chapter {
                currentChapter = chapter
                cache.saveClean(chapter)
            }
            writingPhase = .idle
            pendingExemptionNames = []
        case "failed":
            applyJobFailure(status, chapterId: chapterId)
        case "cancelled":
            writingPhase = .idle
        default:
            break
        }
    }

    private func applyJobFailure(_ status: WriteJobStatus, chapterId: String) {
        let message = status.errorMessage ?? "任务失败"
        writingPhase = .failed(code: status.errorCode, message: message)
        pendingExemptionNames = []
        if let violation = status.violations?.first(where: { $0.code == "unselected_character" }),
           let names = violation.names, !names.isEmpty {
            pendingExemptionNames = names
        }
        session.notices.publish(message, critical: status.errorCode == "revision_failed")
        Task { [weak self] in
            await self?.refreshChapterAfterFailure(chapterId)
        }
    }

    private func applyStartFailure(_ error: Error, chapterId: String) {
        guard currentChapter?.id == chapterId else {
            session.notices.publish(error)
            return
        }
        pendingExemptionNames = []
        if let apiError = error as? APIError,
           case let .validation(code, message, names) = apiError,
           code == "unselected_characters_in_bible" {
            pendingExemptionNames = names
            writingPhase = .failed(code: code, message: message)
        } else {
            writingPhase = .failed(code: nil, message: error.localizedDescription)
        }
        session.notices.publish(error)
    }

    private func refreshChapterAfterFailure(_ chapterId: String) async {
        guard let refreshed: Chapter = try? await session.api.request("/chapters/\(chapterId)") else { return }
        cache.saveClean(refreshed)
        if currentChapter?.id == chapterId {
            currentChapter = refreshed
        }
    }

    private func scheduleCacheSave() {
        guard let chapter = currentChapter else { return }
        cacheTask?.cancel()
        cacheTask = Task { [weak self, chapter] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.cache.saveDirty(chapter)
            }
        }
    }
}

@MainActor
final class AgentSettingsStore: ObservableObject {
    @Published private(set) var personas: [AgentPersona] = []
    @Published private(set) var profiles: [LLMProfile] = []
    @Published private(set) var bindings: [AgentBinding] = []
    @Published private(set) var isLoading = false

    private let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            personas = try await session.api.request("/agent-personas")
            profiles = try await session.api.request("/llm_profiles")
            bindings = try await session.api.request("/agent-model-bindings")
        } catch {
            session.notices.publish(error)
        }
    }

    func createProfile(name: String, baseURL: String, apiKey: String, model: String) async {
        do {
            let payload = LLMProfileCreatePayload(name: name, provider: "openai-compatible", base_url: baseURL, api_key: apiKey, model_name: model)
            let profile: LLMProfile = try await session.api.request("/llm_profiles", method: "POST", body: payload)
            profiles.append(profile)
        } catch {
            session.notices.publish(error)
        }
    }

    func updateProfile(_ profile: LLMProfile, apiKey: String?) async {
        do {
            let payload = LLMProfilePatchPayload(profile: profile, apiKey: apiKey)
            let updated: LLMProfile = try await session.api.request("/llm_profiles/\(profile.id)", method: "PATCH", body: payload)
            if let idx = profiles.firstIndex(where: { $0.id == updated.id }) {
                profiles[idx] = updated
            }
            bindings = try await session.api.request("/agent-model-bindings")
        } catch {
            session.notices.publish(error)
        }
    }

    func deleteProfile(_ profile: LLMProfile) async {
        do {
            try await session.api.rawRequest("/llm_profiles/\(profile.id)", method: "DELETE")
            profiles.removeAll { $0.id == profile.id }
            bindings = try await session.api.request("/agent-model-bindings")
        } catch {
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
        do {
            let payload = AgentBindingPayload(
                llmProfileId: profileId,
                thinkingEnabled: nil,
                reasoningEffort: nil
            )
            let binding: AgentBinding = try await session.api.request("/agent-model-bindings/\(role)", method: "PATCH", body: payload)
            if let idx = bindings.firstIndex(where: { $0.agentRole == role }) {
                bindings[idx] = binding
            } else {
                bindings.append(binding)
            }
        } catch {
            session.notices.publish(error)
        }
    }

    func configureThinking(role: String, enabled: Bool?, effort: String?) async {
        guard let current = bindings.first(where: { $0.agentRole == role }) else { return }
        do {
            let payload = AgentBindingPayload(
                llmProfileId: current.llmProfileId,
                thinkingEnabled: enabled,
                reasoningEffort: enabled == false ? nil : effort
            )
            let binding: AgentBinding = try await session.api.request("/agent-model-bindings/\(role)", method: "PATCH", body: payload)
            if let idx = bindings.firstIndex(where: { $0.agentRole == role }) {
                bindings[idx] = binding
            } else {
                bindings.append(binding)
            }
        } catch {
            session.notices.publish(error)
        }
    }

    func savePersona(_ persona: AgentPersona) async {
        do {
            let payload = AgentPersonaPayload(system_prompt: persona.systemPrompt)
            let saved: AgentPersona = try await session.api.request("/agent-personas/\(persona.agentRole)", method: "PATCH", body: payload)
            if let idx = personas.firstIndex(where: { $0.agentRole == saved.agentRole }) {
                personas[idx] = saved
            }
        } catch {
            session.notices.publish(error)
        }
    }

    func resetPersona(role: String) async {
        do {
            let saved: AgentPersona = try await session.api.request("/agent-personas/\(role)/reset", method: "POST")
            if let idx = personas.firstIndex(where: { $0.agentRole == saved.agentRole }) {
                personas[idx] = saved
            }
        } catch {
            session.notices.publish(error)
        }
    }
}

private struct BookPayload: Encodable, Sendable {
    let title: String
    let world_setting: String
}

private struct ChapterCreatePayload: Encodable, Sendable {
    let title: String
    let user_prompt: String
}

struct ChapterPatchPayload: Encodable, Sendable {
    var title: String
    var user_prompt: String
    var target_word_count: Int
    var author_note: String
    var draft_text: String
    var summary: String
    var headline: String
    var character_links: [ChapterLink]
    var exempted_character_names: [String]

    init(_ chapter: Chapter) {
        title = chapter.title
        user_prompt = chapter.userPrompt
        target_word_count = chapter.targetWordCount
        author_note = chapter.authorNote
        draft_text = chapter.draftText
        summary = chapter.summary
        headline = chapter.headline
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
    var dynamic_fields: [String: JSONValue]

    init(name: String, role: String, fixed_profile: String, dynamic_fields: [String: JSONValue]) {
        self.name = name
        self.role = role
        self.fixed_profile = fixed_profile
        self.dynamic_fields = dynamic_fields
    }

    init(_ character: Character) {
        name = character.name
        role = character.role
        fixed_profile = character.fixedProfile
        dynamic_fields = character.dynamicFields
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

private struct AgentBindingPayload: Encodable, Sendable {
    let llmProfileId: String?
    let thinkingEnabled: Bool?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case llmProfileId = "llm_profile_id"
        case thinkingEnabled = "thinking_enabled"
        case reasoningEffort = "reasoning_effort"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(llmProfileId, forKey: .llmProfileId)
        try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
    }
}

private struct AgentPersonaPayload: Encodable, Sendable {
    let system_prompt: String
}
