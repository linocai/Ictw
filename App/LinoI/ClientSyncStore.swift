import Foundation
import SwiftUI

/// The sync state is intentionally small and presentation-neutral. Platform
/// views may choose their own copy, but they must never infer “saved” merely
/// from a local edit being visible.
enum ClientSyncState: Equatable, Sendable {
    case synced
    case offline
    case pending(Int)
    case conflict
    case persistenceFailed

    var label: String {
        switch self {
        case .synced: "已同步"
        case .offline: "离线"
        case .pending: "未同步"
        case .conflict: "需要处理冲突"
        case .persistenceFailed: "本机未能安全保存待同步内容"
        }
    }
}

enum SyncResourceKind: String, Codable, Sendable {
    case book, chapter, character, characterEvent, agentPersona, modelBinding, llmProfile
}

/// Some mutation endpoints are action routes or collection-backed settings
/// routes and cannot be read back by changing their method to GET. The route
/// is persisted with the mutation so recovery never guesses an endpoint.
enum ConflictReadStrategy: String, Codable, Sendable {
    case direct
    case characterEventInCharacter
    case globalPersonas
    case bookPersonas
    case profiles
    case globalModelBindings
    case bookModelBindings
}

struct PendingMutation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var resourceKind: SyncResourceKind
    var resourceID: String
    var path: String
    var method: String
    var readPath: String
    var readStrategy: ConflictReadStrategy
    var baseRevision: Int
    /// Author-visible JSON only. The cache never receives API keys, candidates
    /// or rejected evidence because only edit payloads are allowed here.
    var payload: Data
    var baseSnapshot: Data
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, resourceKind, resourceID, path, method, readPath, readStrategy, baseRevision, payload, baseSnapshot, createdAt
    }

    init(
        id: UUID, resourceKind: SyncResourceKind, resourceID: String, path: String, method: String,
        readPath: String, readStrategy: ConflictReadStrategy, baseRevision: Int, payload: Data,
        baseSnapshot: Data, createdAt: Date
    ) {
        self.id = id
        self.resourceKind = resourceKind
        self.resourceID = resourceID
        self.path = path
        self.method = method
        self.readPath = readPath
        self.readStrategy = readStrategy
        self.baseRevision = baseRevision
        self.payload = payload
        self.baseSnapshot = baseSnapshot
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        resourceKind = try container.decode(SyncResourceKind.self, forKey: .resourceKind)
        resourceID = try container.decode(String.self, forKey: .resourceID)
        path = try container.decode(String.self, forKey: .path)
        method = try container.decode(String.self, forKey: .method)
        readPath = try container.decodeIfPresent(String.self, forKey: .readPath) ?? path
        readStrategy = try container.decodeIfPresent(ConflictReadStrategy.self, forKey: .readStrategy) ?? .direct
        baseRevision = try container.decode(Int.self, forKey: .baseRevision)
        payload = try container.decode(Data.self, forKey: .payload)
        baseSnapshot = try container.decode(Data.self, forKey: .baseSnapshot)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

struct ContentConflict: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var resourceKind: SyncResourceKind
    var resourceID: String
    var submittedRevision: Int
    var currentRevision: Int
    var path: String
    var method: String
    var readPath: String
    var readStrategy: ConflictReadStrategy
    var baseSnapshot: Data
    var localPayload: Data
    var serverSnapshot: Data
    /// Secrets are deliberately never persisted. A profile conflict carrying
    /// a newly entered key must be retried from the edit screen after the
    /// author re-enters it (endpoint changes are the mandatory case).
    var requiresSecretReentry: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, resourceKind, resourceID, submittedRevision, currentRevision, path, method, readPath, readStrategy
        case baseSnapshot, localPayload, serverSnapshot, requiresSecretReentry, createdAt
    }

    init(
        id: UUID, resourceKind: SyncResourceKind, resourceID: String, submittedRevision: Int, currentRevision: Int,
        path: String, method: String, readPath: String, readStrategy: ConflictReadStrategy,
        baseSnapshot: Data, localPayload: Data, serverSnapshot: Data, requiresSecretReentry: Bool, createdAt: Date
    ) {
        self.id = id
        self.resourceKind = resourceKind
        self.resourceID = resourceID
        self.submittedRevision = submittedRevision
        self.currentRevision = currentRevision
        self.path = path
        self.method = method
        self.readPath = readPath
        self.readStrategy = readStrategy
        self.baseSnapshot = baseSnapshot
        self.localPayload = localPayload
        self.serverSnapshot = serverSnapshot
        self.requiresSecretReentry = requiresSecretReentry
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        resourceKind = try container.decode(SyncResourceKind.self, forKey: .resourceKind)
        resourceID = try container.decode(String.self, forKey: .resourceID)
        submittedRevision = try container.decode(Int.self, forKey: .submittedRevision)
        currentRevision = try container.decode(Int.self, forKey: .currentRevision)
        path = try container.decode(String.self, forKey: .path)
        method = try container.decode(String.self, forKey: .method)
        readPath = try container.decodeIfPresent(String.self, forKey: .readPath) ?? path
        readStrategy = try container.decodeIfPresent(ConflictReadStrategy.self, forKey: .readStrategy) ?? .direct
        baseSnapshot = try container.decode(Data.self, forKey: .baseSnapshot)
        localPayload = try container.decode(Data.self, forKey: .localPayload)
        serverSnapshot = try container.decode(Data.self, forKey: .serverSnapshot)
        requiresSecretReentry = try container.decodeIfPresent(Bool.self, forKey: .requiresSecretReentry) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    var resourceLabel: String {
        switch resourceKind {
        case .book: "书籍"
        case .chapter: "章节"
        case .character: "人物"
        case .characterEvent: "人物记录"
        case .agentPersona: "Agent 人格"
        case .modelBinding: "模型设置"
        case .llmProfile: "模型 Profile"
        }
    }
}

/// `JSONValue` keeps the pending queue schema-free while still guaranteeing
/// that bytes written to disk are JSON rather than an arbitrary archive.
struct RawJSONPayload: Encodable, Sendable {
    let value: JSONValue

    init(data: Data) throws {
        value = try JSONDecoder.lino.decode(JSONValue.self, from: data)
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

struct AppliedSyncMutation: Hashable, Sendable {
    let resourceKind: SyncResourceKind
    let resourceID: String
}

/// Per-record files deliberately keep one corrupt local snapshot from hiding
/// a whole bookshelf. The legacy ChapterDrafts directory remains untouched;
/// it is a second, compatible layer for existing unsaved drafts.
final class ClientSnapshotCache {
    private let root: URL
    private let encoder = JSONEncoder.lino
    private let decoder = JSONDecoder.lino

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.root = base.appendingPathComponent("LinoI/SyncCache/v1", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func books() -> [Book] { load([Book].self, at: "books.json") ?? [] }
    func saveBooks(_ value: [Book]) { save(value, at: "books.json") }

    func chapters(bookID: String) -> [ChapterSummary] {
        load([ChapterSummary].self, at: "chapter-lists/\(safe(bookID)).json") ?? []
    }
    func saveChapters(_ value: [ChapterSummary], bookID: String) {
        save(value, at: "chapter-lists/\(safe(bookID)).json")
    }

    func characters(bookID: String) -> [Character] {
        load([Character].self, at: "characters/\(safe(bookID)).json") ?? []
    }
    func saveCharacters(_ value: [Character], bookID: String) {
        save(value, at: "characters/\(safe(bookID)).json")
    }

    func chapter(id: String) -> Chapter? { load(Chapter.self, at: "chapters/\(safe(id)).json") }
    func saveChapter(_ value: Chapter) { save(value, at: "chapters/\(safe(value.id)).json") }
    func removeChapter(id: String) { remove("chapters/\(safe(id)).json") }

    func mutations() -> [PendingMutation] { load([PendingMutation].self, at: "pending.json") ?? [] }
    @discardableResult
    func saveMutations(_ value: [PendingMutation]) -> Bool { save(value, at: "pending.json") }
    func conflicts() -> [ContentConflict] { load([ContentConflict].self, at: "conflicts.json") ?? [] }
    @discardableResult
    func saveConflicts(_ value: [ContentConflict]) -> Bool { save(value, at: "conflicts.json") }

    private func load<T: Decodable>(_ type: T.Type, at relative: String) -> T? {
        let url = file(relative)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? decoder.decode(T.self, from: data) else {
            // Corruption is isolated to this single entry. A later online
            // refresh reconstructs it; no other book, draft or pending write
            // is sacrificed.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return decoded
    }

    @discardableResult
    private func save<T: Encodable>(_ value: T, at relative: String) -> Bool {
        let url = file(relative)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private func remove(_ relative: String) { try? FileManager.default.removeItem(at: file(relative)) }
    private func file(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    private func safe(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "_") }
}

@MainActor
final class ClientSyncStore: ObservableObject {
    @Published private(set) var isOnline = true
    @Published private(set) var pendingMutations: [PendingMutation]
    @Published private(set) var conflicts: [ContentConflict]
    @Published private(set) var isFlushing = false
    /// A pending queue that only lives in RAM must never be presented as a
    /// durable offline save. Views use this to replace reassuring copy with a
    /// clear recovery warning.
    @Published private(set) var persistenceFailure: String?

    private var pendingPersistenceFailed = false
    private var conflictPersistenceFailed = false

    let cache: ClientSnapshotCache

    init(cache: ClientSnapshotCache = ClientSnapshotCache()) {
        self.cache = cache
        pendingMutations = cache.mutations()
        conflicts = cache.conflicts()
        persistenceFailure = nil
    }

    var pendingCount: Int { pendingMutations.count }
    var networkActionsAvailable: Bool { isOnline }
    var hasPersistentSyncFailure: Bool { persistenceFailure != nil }

    func state(for kind: SyncResourceKind, id: String) -> ClientSyncState {
        if hasPersistentSyncFailure { return .persistenceFailed }
        if conflicts.contains(where: { $0.resourceKind == kind && $0.resourceID == id }) { return .conflict }
        let pending = pendingMutations.filter { $0.resourceKind == kind && $0.resourceID == id }.count
        if pending > 0 { return .pending(pending) }
        return isOnline ? .synced : .offline
    }

    func markOnline() { isOnline = true }
    func markOffline() { isOnline = false }

    @discardableResult
    func enqueue(
        kind: SyncResourceKind,
        id: String,
        path: String,
        method: String,
        readPath: String? = nil,
        readStrategy: ConflictReadStrategy = .direct,
        baseRevision: Int,
        payload: some Encodable,
        baseSnapshot: some Encodable
    ) -> Bool {
        guard let payloadData = try? JSONEncoder.lino.encode(AnyEncodable(payload)),
              let baseData = try? JSONEncoder.lino.encode(AnyEncodable(baseSnapshot)) else {
            persistenceFailure = "本机未能准备待同步内容，请保留此页面并重试。"
            return false
        }
        // A later local save supersedes an unsent earlier save for the same
        // resource. Keep the original base so a conflict still compares the
        // server snapshot against the true editing baseline.
        if let index = pendingMutations.lastIndex(where: { $0.resourceKind == kind && $0.resourceID == id }) {
            pendingMutations[index].payload = payloadData
            pendingMutations[index].path = path
            pendingMutations[index].method = method
            pendingMutations[index].readPath = readPath ?? path
            pendingMutations[index].readStrategy = readStrategy
            return persistPending()
        }
        pendingMutations.append(PendingMutation(
            id: UUID(), resourceKind: kind, resourceID: id, path: path, method: method,
            readPath: readPath ?? path, readStrategy: readStrategy,
            baseRevision: baseRevision, payload: payloadData, baseSnapshot: baseData, createdAt: Date()
        ))
        return persistPending()
    }

    /// Called after a successful direct save so stale queue records cannot
    /// replay over the freshly returned server content.
    func acknowledge(kind: SyncResourceKind, id: String) {
        pendingMutations.removeAll { $0.resourceKind == kind && $0.resourceID == id }
        persistPending()
    }

    func conflict(for kind: SyncResourceKind, id: String) -> ContentConflict? {
        conflicts.first { $0.resourceKind == kind && $0.resourceID == id }
    }

    /// Direct saves use this after their first conditional request returns a
    /// conflict. It retains the exact outgoing payload and obtains the public
    /// competing resource before the UI is told there is something to compare.
    func recordWriteConflict(
        kind: SyncResourceKind,
        id: String,
        path: String,
        method: String,
        readPath: String? = nil,
        readStrategy: ConflictReadStrategy = .direct,
        baseRevision: Int,
        payload: some Encodable,
        baseSnapshot: some Encodable,
        requiresSecretReentry: Bool = false,
        error: APIError,
        api: APIClient
    ) async {
        guard case let .writeConflict(_, _, submitted, current) = error,
              let payloadData = try? JSONEncoder.lino.encode(AnyEncodable(payload)),
              let baseData = try? JSONEncoder.lino.encode(AnyEncodable(baseSnapshot)) else { return }
        let mutation = PendingMutation(
            id: UUID(), resourceKind: kind, resourceID: id, path: path, method: method,
            readPath: readPath ?? path, readStrategy: readStrategy,
            baseRevision: baseRevision, payload: payloadData, baseSnapshot: baseData, createdAt: Date()
        )
        let promoted = await promoteConflict(
            mutation,
            submittedRevision: submitted,
            currentRevision: current,
            requiresSecretReentry: requiresSecretReentry,
            api: api
        )
        if !promoted, !requiresSecretReentry {
            if let index = pendingMutations.lastIndex(where: {
                $0.resourceKind == mutation.resourceKind && $0.resourceID == mutation.resourceID
            }) {
                pendingMutations[index] = mutation
            } else {
                pendingMutations.append(mutation)
            }
            persistPending()
        }
    }

    /// Choosing the server is the only destructive conflict choice. The
    /// platform UI must confirm before calling it; this method only clears the
    /// local queued copy after that explicit decision.
    func keepServer(_ conflict: ContentConflict) {
        pendingMutations.removeAll { $0.resourceKind == conflict.resourceKind && $0.resourceID == conflict.resourceID }
        conflicts.removeAll { $0.id == conflict.id }
        persistPending()
        persistConflicts()
    }

    /// Re-queues the user's local payload with the newly read server revision.
    /// The caller is responsible for an explicit confirmation on same-field or
    /// prose conflicts; automatic merge is attempted separately and only for
    /// disjoint JSON fields.
    @discardableResult
    func keepLocal(_ conflict: ContentConflict) -> Bool {
        guard !conflict.requiresSecretReentry else { return false }
        let mutation = PendingMutation(
            id: UUID(), resourceKind: conflict.resourceKind, resourceID: conflict.resourceID,
            path: conflict.path, method: conflict.method,
            readPath: conflict.readPath, readStrategy: conflict.readStrategy,
            baseRevision: conflict.currentRevision,
            payload: conflict.localPayload, baseSnapshot: conflict.serverSnapshot, createdAt: Date()
        )
        if let index = pendingMutations.lastIndex(where: {
            $0.resourceKind == mutation.resourceKind && $0.resourceID == mutation.resourceID
        }) {
            pendingMutations[index] = mutation
        } else {
            pendingMutations.append(mutation)
        }
        // Persist the replacement before deleting the durable conflict. If the
        // second file cannot be updated, both records remain visible and the
        // author's local value is still recoverable after a restart.
        guard persistPending() else { return false }
        let previousConflicts = conflicts
        conflicts.removeAll { $0.id == conflict.id }
        guard persistConflicts() else {
            conflicts = previousConflicts
            return false
        }
        return true
    }

    /// Flushes persisted writes in creation order. A failing transport leaves
    /// the queue intact. A 409 reads the current public resource and promotes
    /// it to a three-way conflict; no conflict path ever writes the local copy
    /// automatically.
    @discardableResult
    func flush(using api: APIClient) async -> [AppliedSyncMutation] {
        guard !isFlushing, !pendingMutations.isEmpty else { return [] }
        isFlushing = true
        defer { isFlushing = false }
        var applied: [AppliedSyncMutation] = []

        while let mutation = pendingMutations.first {
            do {
                let payload = try RawJSONPayload(data: mutation.payload)
                let response = try await api.rawRequest(
                    mutation.path, method: mutation.method, body: payload, ifMatch: mutation.baseRevision
                )
                applySuccessfulResponse(response, for: mutation)
                applied.append(AppliedSyncMutation(resourceKind: mutation.resourceKind, resourceID: mutation.resourceID))
                pendingMutations.removeFirst()
                persistPending()
                markOnline()
            } catch let conflict as APIError {
                guard case let .writeConflict(_, _, submitted, current) = conflict else {
                    handleFailure(conflict)
                    return applied
                }
                guard await promoteConflict(
                    mutation, submittedRevision: submitted, currentRevision: current, api: api
                ) else { return applied }
                pendingMutations.removeFirst()
                persistPending()
            } catch {
                handleFailure(error)
                return applied
            }
        }
        return applied
    }

    /// Attempts a three-way JSON merge. It returns a mutation only when each
    /// side changed distinct top-level fields. Draft text remains a normal
    /// field, so concurrent prose edits always intersect and require choice.
    func automaticMergeCandidate(for conflict: ContentConflict) -> PendingMutation? {
        guard conflict.method.uppercased() == "PATCH",
              let base = try? JSONDecoder.lino.decode([String: JSONValue].self, from: conflict.baseSnapshot),
              let local = try? JSONDecoder.lino.decode([String: JSONValue].self, from: conflict.localPayload),
              let server = try? JSONDecoder.lino.decode([String: JSONValue].self, from: conflict.serverSnapshot) else { return nil }
        let localChanged = changedKeys(from: base, to: local)
        let serverChanged = changedKeys(from: base, to: server)
        guard localChanged.isDisjoint(with: serverChanged) else { return nil }
        // The server snapshot contains read-only identity/lifecycle fields.
        // A PATCH must contain only the fields accepted by the original local
        // payload, otherwise a safe merge would be rejected as an accidental
        // attempt to edit status/index/archive data.
        var merged = server.filter { local.keys.contains($0.key) }
        for key in localChanged { merged[key] = local[key] }
        guard let payload = try? JSONEncoder.lino.encode(merged) else { return nil }
        return PendingMutation(
            id: UUID(), resourceKind: conflict.resourceKind, resourceID: conflict.resourceID,
            path: conflict.path, method: "PATCH",
            readPath: conflict.readPath, readStrategy: conflict.readStrategy,
            baseRevision: conflict.currentRevision,
            payload: payload, baseSnapshot: conflict.serverSnapshot, createdAt: Date()
        )
    }

    @discardableResult
    func acceptAutomaticMerge(_ mutation: PendingMutation, replacing conflict: ContentConflict) -> Bool {
        if let index = pendingMutations.lastIndex(where: {
            $0.resourceKind == mutation.resourceKind && $0.resourceID == mutation.resourceID
        }) {
            pendingMutations[index] = mutation
        } else {
            pendingMutations.append(mutation)
        }
        guard persistPending() else { return false }
        let previousConflicts = conflicts
        conflicts.removeAll { $0.id == conflict.id }
        guard persistConflicts() else {
            conflicts = previousConflicts
            return false
        }
        return true
    }

    @discardableResult
    func queueAutomaticMerge(for conflict: ContentConflict) -> Bool {
        guard let mutation = automaticMergeCandidate(for: conflict) else { return false }
        return acceptAutomaticMerge(mutation, replacing: conflict)
    }

    private func promoteConflict(
        _ mutation: PendingMutation,
        submittedRevision: Int,
        currentRevision: Int,
        requiresSecretReentry: Bool = false,
        api: APIClient
    ) async -> Bool {
        let previousConflicts = conflicts
        do {
            let response = try await api.rawRequest(mutation.readPath)
            let server = try isolateCurrentResource(response, for: mutation)
            conflicts.append(ContentConflict(
                id: UUID(), resourceKind: mutation.resourceKind, resourceID: mutation.resourceID,
                submittedRevision: submittedRevision, currentRevision: currentRevision,
                path: mutation.path, method: mutation.method,
                readPath: mutation.readPath, readStrategy: mutation.readStrategy,
                baseSnapshot: mutation.baseSnapshot, localPayload: mutation.payload,
                serverSnapshot: server, requiresSecretReentry: requiresSecretReentry, createdAt: Date()
            ))
            guard persistConflicts() else {
                conflicts = previousConflicts
                return false
            }
            markOnline()
            return true
        } catch {
            handleFailure(error)
            return false
        }
    }

    private func applySuccessfulResponse(_ data: Data, for mutation: PendingMutation) {
        switch mutation.resourceKind {
        case .book:
            if let book = try? JSONDecoder.lino.decode(Book.self, from: data) { upsertBook(book) }
        case .chapter:
            if let chapter = try? JSONDecoder.lino.decode(Chapter.self, from: data) {
                cache.saveChapter(chapter)
                var summaries = cache.chapters(bookID: chapter.bookId)
                if let index = summaries.firstIndex(where: { $0.id == chapter.id }) {
                    let previous = summaries[index]
                    summaries[index] = ChapterSummary(
                        id: chapter.id, bookId: chapter.bookId, index: chapter.index,
                        title: chapter.title, status: chapter.status, source: chapter.source,
                        updatedAt: chapter.updatedAt, archiveStatus: previous.archiveStatus,
                        archiveSchema: previous.archiveSchema, archiveCanRetry: previous.archiveCanRetry,
                        archiveLatestAttemptStatus: previous.archiveLatestAttemptStatus,
                        contentRevision: chapter.contentRevision
                    )
                    cache.saveChapters(summaries, bookID: chapter.bookId)
                }
            }
        case .character:
            if let character = try? JSONDecoder.lino.decode(Character.self, from: data) {
                var values = cache.characters(bookID: character.bookId)
                if let index = values.firstIndex(where: { $0.id == character.id }) { values[index] = character }
                else { values.append(character) }
                cache.saveCharacters(values, bookID: character.bookId)
            }
        case .characterEvent:
            if let event = try? JSONDecoder.lino.decode(CharacterEvent.self, from: data) {
                var values = cache.characters(bookID: event.bookId)
                if let characterIndex = values.firstIndex(where: { $0.id == event.characterId }),
                   let eventIndex = values[characterIndex].events.firstIndex(where: { $0.id == event.id }) {
                    values[characterIndex].events[eventIndex] = event
                    cache.saveCharacters(values, bookID: event.bookId)
                }
            }
        case .agentPersona, .modelBinding, .llmProfile:
            break
        }
    }

    private func isolateCurrentResource(_ data: Data, for mutation: PendingMutation) throws -> Data {
        switch mutation.readStrategy {
        case .direct:
            return data
        case .characterEventInCharacter:
            let character = try JSONDecoder.lino.decode(Character.self, from: data)
            guard let event = character.events.first(where: { $0.id == mutation.resourceID }) else {
                throw APIError.http(404, "人物记录已不存在")
            }
            return try JSONEncoder.lino.encode(event)
        case .globalPersonas:
            let values = try JSONDecoder.lino.decode([AgentPersona].self, from: data)
            guard let value = values.first(where: { $0.agentRole == mutation.resourceID }) else {
                throw APIError.http(404, "Agent 人格已不存在")
            }
            return try JSONEncoder.lino.encode(value)
        case .bookPersonas:
            let values = try JSONDecoder.lino.decode([BookAgentPersona].self, from: data)
            guard let value = values.first(where: { $0.agentRole == mutation.resourceID }) else {
                throw APIError.http(404, "本书人格已不存在")
            }
            return try JSONEncoder.lino.encode(value)
        case .profiles:
            let values = try JSONDecoder.lino.decode([LLMProfile].self, from: data)
            guard let value = values.first(where: { $0.id == mutation.resourceID }) else {
                throw APIError.http(404, "模型 Profile 已不存在")
            }
            return try JSONEncoder.lino.encode(value)
        case .globalModelBindings:
            let values = try JSONDecoder.lino.decode([AgentBinding].self, from: data)
            guard let value = values.first(where: { $0.agentRole == mutation.resourceID }) else {
                throw APIError.http(404, "全局模型设置已不存在")
            }
            return try JSONEncoder.lino.encode(value)
        case .bookModelBindings:
            let values = try JSONDecoder.lino.decode([BookAgentModelBinding].self, from: data)
            guard let value = values.first(where: { $0.agentRole == mutation.resourceID }) else {
                throw APIError.http(404, "本书模型设置已不存在")
            }
            return try JSONEncoder.lino.encode(value)
        }
    }

    func upsertBook(_ book: Book) {
        var values = cache.books()
        if let index = values.firstIndex(where: { $0.id == book.id }) { values[index] = book }
        else { values.insert(book, at: 0) }
        cache.saveBooks(values)
    }

    private func changedKeys(from base: [String: JSONValue], to other: [String: JSONValue]) -> Set<String> {
        Set(base.keys).union(other.keys).filter { base[$0] != other[$0] }
    }

    private func handleFailure(_ error: Error) {
        if case APIError.transport = error { markOffline() }
    }

    @discardableResult
    private func persistPending() -> Bool {
        pendingPersistenceFailed = !cache.saveMutations(pendingMutations)
        updatePersistenceFailure()
        return !pendingPersistenceFailed
    }

    @discardableResult
    private func persistConflicts() -> Bool {
        conflictPersistenceFailed = !cache.saveConflicts(conflicts)
        updatePersistenceFailure()
        return !conflictPersistenceFailed
    }

    private func updatePersistenceFailure() {
        if pendingPersistenceFailed || conflictPersistenceFailed {
            persistenceFailure = "本机未能安全保存待同步内容；请保留当前页面，释放存储空间后重试。"
        } else {
            persistenceFailure = nil
        }
    }
}
