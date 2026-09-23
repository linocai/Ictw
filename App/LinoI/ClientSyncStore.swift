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
    case failed(Int)

    var label: String {
        switch self {
        case .synced: "已同步"
        case .offline: "离线"
        case .pending: "未同步"
        case .conflict: "需要处理冲突"
        case .persistenceFailed: "本机未能安全保存待同步内容"
        case .failed(let count): count == 1 ? "1 项同步需要处理" : "\(count) 项同步需要处理"
        }
    }
}

/// Persisted, bounded diagnosis for a queued mutation. It deliberately keeps
/// only the public error classification and never the response body/payload.
enum PendingMutationFailureKind: String, Codable, Sendable {
    case retryable
    case permanent
    case authentication
    case configuration

    var blocksAllFlushes: Bool { self == .authentication || self == .configuration }
}

struct PendingMutationFailure: Codable, Hashable, Sendable {
    var kind: PendingMutationFailureKind
    var statusCode: Int?
    var code: String?
    var message: String
    var recordedAt: Date
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
    var failure: PendingMutationFailure? = nil

    enum CodingKeys: String, CodingKey {
        case id, resourceKind, resourceID, path, method, readPath, readStrategy, baseRevision, payload, baseSnapshot, createdAt, failure
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
        failure = try container.decodeIfPresent(PendingMutationFailure.self, forKey: .failure)
    }

    var resourceLabel: String { resourceLabel(bookTitle: nil) }

    /// Derive a compact author-facing location from the already persisted
    /// edit/base JSON. This avoids storing a second display copy of content
    /// while still distinguishing failed writes across books and chapters.
    func resourceLabel(bookTitle: String?) -> String {
        let base = jsonObject(from: baseSnapshot) ?? [:]
        let object = base.merging(jsonObject(from: payload) ?? [:]) { _, newer in newer }
        let resolvedBookTitle = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch resourceKind {
        case .book:
            return labelled("书籍", name: string("title", in: object))
        case .chapter:
            return scoped("章节", name: chapterName(in: object), bookTitle: resolvedBookTitle)
        case .character:
            return scoped("人物", name: string("name", in: object), bookTitle: resolvedBookTitle)
        case .characterEvent:
            return scoped("人物记录", name: nil, bookTitle: resolvedBookTitle)
        case .agentPersona:
            return labelled("Agent 人格", name: string("agent_role", in: object) ?? resourceID)
        case .modelBinding:
            return labelled("模型设置", name: string("agent_role", in: object) ?? resourceID)
        case .llmProfile:
            return labelled("模型 Profile", name: string("name", in: object) ?? resourceID)
        }
    }

    private func scoped(_ kind: String, name: String?, bookTitle: String?) -> String {
        let item = name ?? resourceID
        guard let bookTitle, !bookTitle.isEmpty else { return "\(kind)：\(item)" }
        return "《\(bookTitle)》\(kind)：\(item)"
    }

    private func labelled(_ kind: String, name: String?) -> String {
        guard let name, !name.isEmpty else { return "\(kind)：\(resourceID)" }
        return "\(kind)：\(name)"
    }

    private func chapterName(in object: [String: Any]?) -> String? {
        let title = string("title", in: object)
        let index = (object?["index"] as? NSNumber)?.intValue
        switch (index, title) {
        case let (.some(index), .some(title)) where !title.isEmpty: return "第 \(index) 章《\(title)》"
        case let (.some(index), _): return "第 \(index) 章"
        case let (_, .some(title)) where !title.isEmpty: return "《\(title)》"
        default: return nil
        }
    }

    private func string(_ key: String, in object: [String: Any]?) -> String? {
        guard let value = object?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func jsonObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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
        } else if let debugRoot = DebugRuntimeConfiguration.dataRoot {
            self.root = debugRoot.appendingPathComponent("SyncCache/v1", isDirectory: true)
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
    private weak var notices: NoticeBus?

    init(cache: ClientSnapshotCache = ClientSnapshotCache(), notices: NoticeBus? = nil) {
        self.cache = cache
        self.notices = notices
        pendingMutations = cache.mutations()
        conflicts = cache.conflicts()
        persistenceFailure = nil
    }

    var pendingCount: Int { pendingMutations.count }
    /// Permanent and authentication refusals remain visible but never count
    /// as an automatic "will sync when online" promise. Retryable failures
    /// remain eligible for the next connectivity-driven flush.
    var automaticallyFlushableMutationCount: Int {
        pendingMutations.filter { $0.failure == nil || $0.failure?.kind == .retryable }.count
    }
    var networkActionsAvailable: Bool { isOnline }
    var hasPersistentSyncFailure: Bool { persistenceFailure != nil }
    var failedMutations: [PendingMutation] { pendingMutations.filter { $0.failure != nil } }
    var failedMutationCount: Int { failedMutations.count }

    func state(for kind: SyncResourceKind, id: String) -> ClientSyncState {
        if hasPersistentSyncFailure { return .persistenceFailed }
        if conflicts.contains(where: { $0.resourceKind == kind && $0.resourceID == id }) { return .conflict }
        if pendingMutations.contains(where: { $0.resourceKind == kind && $0.resourceID == id && $0.failure != nil }) { return .failed(1) }
        let pending = pendingMutations.filter { $0.resourceKind == kind && $0.resourceID == id }.count
        if pending > 0 { return .pending(pending) }
        return isOnline ? .synced : .offline
    }

    func markOnline() { isOnline = true }
    func markOffline() { isOnline = false }

    func resourceLabel(for mutation: PendingMutation) -> String {
        let booksByID = Dictionary(uniqueKeysWithValues: cache.books().map { ($0.id, $0.title) })
        if mutation.resourceKind == .chapter,
           let chapter = cache.chapter(id: mutation.resourceID) {
            return mutation.resourceLabel(bookTitle: booksByID[chapter.bookId])
        }
        let base = Self.jsonObject(from: mutation.baseSnapshot) ?? [:]
        let object = base.merging(Self.jsonObject(from: mutation.payload) ?? [:]) { _, newer in newer }
        let bookID = object["book_id"] as? String
        return mutation.resourceLabel(bookTitle: bookID.flatMap { booksByID[$0] })
    }

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
            // A fresh explicit edit is the user's requested retry with a new
            // payload. Preserve the original conflict baseline but discard the
            // stale refusal diagnosis.
            pendingMutations[index].failure = nil
            return persistPending()
        }
        pendingMutations.append(PendingMutation(
            id: UUID(), resourceKind: kind, resourceID: id, path: path, method: method,
            readPath: readPath ?? path, readStrategy: readStrategy,
            baseRevision: baseRevision, payload: payloadData, baseSnapshot: baseData, createdAt: Date()
        ))
        return persistPending()
    }

    /// A direct edit that the server rejected still becomes a durable sync
    /// item. This coalesces a newer author edit into an older failed payload,
    /// keeps the original conflict baseline, then records the current failure
    /// on that latest payload for the sync centre and next cold start.
    @discardableResult
    func enqueueDirectFailure(
        _ error: Error,
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
        guard enqueue(
            kind: kind, id: id, path: path, method: method,
            readPath: readPath, readStrategy: readStrategy,
            baseRevision: baseRevision, payload: payload, baseSnapshot: baseSnapshot
        ) else { return false }
        guard let mutation = pendingMutations.last(where: {
            $0.resourceKind == kind && $0.resourceID == id
        }) else { return false }
        recordFailure(error, for: mutation.id)
        return !pendingPersistenceFailed
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
        let promotion = await promoteConflict(
            mutation,
            submittedRevision: submitted,
            currentRevision: current,
            requiresSecretReentry: requiresSecretReentry,
            api: api
        )
        switch promotion {
        case .promoted:
            return
        case .failed(let observationError) where !requiresSecretReentry:
            if let index = pendingMutations.lastIndex(where: {
                $0.resourceKind == mutation.resourceKind && $0.resourceID == mutation.resourceID
            }) {
                pendingMutations[index] = mutation
            } else {
                pendingMutations.append(mutation)
            }
            guard persistPending() else { return }
            recordFailure(observationError, for: mutation.id)
        case .failed(let observationError):
            let presented = LinoErrorPresenter.present(error: observationError)
            notices?.publish(
                "无法读取服务器当前内容，暂时不能比较该配置：\(presented.message)",
                critical: presented.critical,
                tone: .error
            )
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

    /// Makes one author-selected pending resource eligible for another flush.
    /// It does not drop the local payload or change its original revision.
    @discardableResult
    func retry(_ mutation: PendingMutation) -> Bool {
        guard let index = pendingMutations.firstIndex(where: { $0.id == mutation.id }) else { return false }
        pendingMutations[index].failure = nil
        return persistPending()
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

        if pendingMutations.contains(where: { $0.failure?.kind.blocksAllFlushes == true }) {
            return applied
        }

        while let index = nextFlushableMutationIndex() {
            let mutation = pendingMutations[index]
            do {
                let payload = try RawJSONPayload(data: mutation.payload)
                let response = try await api.rawRequest(
                    mutation.path, method: mutation.method, body: payload, ifMatch: mutation.baseRevision
                )
                try applySuccessfulResponse(response, for: mutation)
                applied.append(AppliedSyncMutation(resourceKind: mutation.resourceKind, resourceID: mutation.resourceID))
                pendingMutations.remove(at: index)
                persistPending()
                markOnline()
            } catch let conflict as APIError {
                guard case let .writeConflict(_, _, submitted, current) = conflict else {
                    recordFailure(conflict, for: mutation.id)
                    let kind = failureKind(for: conflict)
                    if kind.blocksAllFlushes || kind == .retryable { return applied }
                    continue
                }
                switch await promoteConflict(
                    mutation, submittedRevision: submitted, currentRevision: current, api: api
                ) {
                case .promoted:
                    pendingMutations.remove(at: index)
                    persistPending()
                case .failed(let observationError):
                    recordFailure(observationError, for: mutation.id)
                    let kind = failureKind(for: observationError)
                    if kind.blocksAllFlushes || kind == .retryable { return applied }
                    continue
                }
            } catch {
                recordFailure(error, for: mutation.id)
                if failureKind(for: error).blocksAllFlushes || failureKind(for: error) == .retryable {
                    return applied
                }
                // A permanently rejected resource remains visible but must
                // not prevent unrelated resources from reaching the server.
                continue
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

    private enum ConflictPromotionResult {
        case promoted
        case failed(Error)
    }

    private func promoteConflict(
        _ mutation: PendingMutation,
        submittedRevision: Int,
        currentRevision: Int,
        requiresSecretReentry: Bool = false,
        api: APIClient
    ) async -> ConflictPromotionResult {
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
                return .failed(APIError.http(500, "本机未能保存冲突比较内容"))
            }
            markOnline()
            return .promoted
        } catch {
            if case APIError.transport = error { markOffline() }
            return .failed(error)
        }
    }

    /// A 2xx response acknowledges a pending mutation only when it carries the
    /// expected public resource for this exact ID. Treat malformed or
    /// cross-resource bodies as failures so the sole durable local payload is
    /// never discarded merely because an intermediary returned HTTP success.
    private func applySuccessfulResponse(_ data: Data, for mutation: PendingMutation) throws {
        if data.isEmpty {
            // The current API uses empty bodies only for DELETE. No queued
            // mutation currently relies on this branch, but retaining the
            // endpoint contract prevents a future 204 deletion from being
            // falsely marked malformed.
            guard mutation.method.uppercased() == "DELETE" else {
                throw invalidSuccessfulResponse()
            }
            return
        }
        switch mutation.resourceKind {
        case .book:
            let book = try JSONDecoder.lino.decode(Book.self, from: data)
            guard book.id == mutation.resourceID else { throw invalidSuccessfulResponse() }
            upsertBook(book)
        case .chapter:
            let chapter = try JSONDecoder.lino.decode(Chapter.self, from: data)
            guard chapter.id == mutation.resourceID else { throw invalidSuccessfulResponse() }
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
                    archiveEffectiveStatus: previous.archiveEffectiveStatus,
                    archiveStateStatus: previous.archiveStateStatus,
                    archiveStateUncertaintyCount: previous.archiveStateUncertaintyCount,
                    contentRevision: chapter.contentRevision
                )
                cache.saveChapters(summaries, bookID: chapter.bookId)
            }
        case .character:
            let character = try JSONDecoder.lino.decode(Character.self, from: data)
            guard character.id == mutation.resourceID else { throw invalidSuccessfulResponse() }
            var values = cache.characters(bookID: character.bookId)
            if let index = values.firstIndex(where: { $0.id == character.id }) { values[index] = character }
            else { values.append(character) }
            cache.saveCharacters(values, bookID: character.bookId)
        case .characterEvent:
            let event = try JSONDecoder.lino.decode(CharacterEvent.self, from: data)
            guard event.id == mutation.resourceID else { throw invalidSuccessfulResponse() }
            var values = cache.characters(bookID: event.bookId)
            if let characterIndex = values.firstIndex(where: { $0.id == event.characterId }),
               let eventIndex = values[characterIndex].events.firstIndex(where: { $0.id == event.id }) {
                values[characterIndex].events[eventIndex] = event
                cache.saveCharacters(values, bookID: event.bookId)
            }
        case .agentPersona, .modelBinding, .llmProfile:
            // These kinds are not queued today because their payloads may
            // contain credentials. If a future caller adds them, it must also
            // add a resource-specific public response validator here.
            throw invalidSuccessfulResponse()
        }
    }

    private func invalidSuccessfulResponse() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "服务器未返回刚提交的资源"))
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func isolateCurrentResource(_ data: Data, for mutation: PendingMutation) throws -> Data {
        switch mutation.readStrategy {
        case .direct:
            // A successful HTTP status alone is not enough to replace a
            // durable pending edit with a comparison record. Verify that the
            // body is the expected public resource and belongs to this exact
            // mutation; otherwise retain the pending payload with the real
            // read failure instead of creating a fake conflict.
            switch mutation.resourceKind {
            case .book:
                let value = try JSONDecoder.lino.decode(Book.self, from: data)
                guard value.id == mutation.resourceID else { throw invalidConflictRead() }
                return try JSONEncoder.lino.encode(value)
            case .chapter:
                let value = try JSONDecoder.lino.decode(Chapter.self, from: data)
                guard value.id == mutation.resourceID else { throw invalidConflictRead() }
                return try JSONEncoder.lino.encode(value)
            case .character:
                let value = try JSONDecoder.lino.decode(Character.self, from: data)
                guard value.id == mutation.resourceID else { throw invalidConflictRead() }
                return try JSONEncoder.lino.encode(value)
            case .characterEvent:
                let value = try JSONDecoder.lino.decode(CharacterEvent.self, from: data)
                guard value.id == mutation.resourceID else { throw invalidConflictRead() }
                return try JSONEncoder.lino.encode(value)
            case .agentPersona:
                if let value = try? JSONDecoder.lino.decode(AgentPersona.self, from: data), value.agentRole == mutation.resourceID {
                    return try JSONEncoder.lino.encode(value)
                }
                if let value = try? JSONDecoder.lino.decode(BookAgentPersona.self, from: data), value.agentRole == mutation.resourceID {
                    return try JSONEncoder.lino.encode(value)
                }
                throw invalidConflictRead()
            case .modelBinding:
                if let value = try? JSONDecoder.lino.decode(AgentBinding.self, from: data), value.agentRole == mutation.resourceID {
                    return try JSONEncoder.lino.encode(value)
                }
                if let value = try? JSONDecoder.lino.decode(BookAgentModelBinding.self, from: data), value.agentRole == mutation.resourceID {
                    return try JSONEncoder.lino.encode(value)
                }
                throw invalidConflictRead()
            case .llmProfile:
                let value = try JSONDecoder.lino.decode(LLMProfile.self, from: data)
                guard value.id == mutation.resourceID else { throw invalidConflictRead() }
                return try JSONEncoder.lino.encode(value)
            }
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

    private func invalidConflictRead() -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "服务器未返回当前待比较资源"))
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

    private func nextFlushableMutationIndex() -> Int? {
        for (index, mutation) in pendingMutations.enumerated() {
            if mutation.failure?.kind == .permanent { continue }
            if pendingMutations[..<index].contains(where: {
                $0.resourceKind == mutation.resourceKind && $0.resourceID == mutation.resourceID
            }) { continue }
            return index
        }
        return nil
    }

    private func recordFailure(_ error: Error, for mutationID: UUID) {
        guard let index = pendingMutations.firstIndex(where: { $0.id == mutationID }) else { return }
        let presented = LinoErrorPresenter.present(error: error)
        let kind = failureKind(for: error)
        let statusCode = httpStatus(for: error)
        let attemptStartedAt = pendingMutations[index].failure?.recordedAt ?? Date()
        pendingMutations[index].failure = PendingMutationFailure(
            kind: kind,
            statusCode: statusCode,
            code: LinoErrorPresenter.code(for: error),
            message: presented.message,
            recordedAt: attemptStartedAt
        )
        _ = persistPending()
        if case APIError.transport = error { markOffline() }
        let mutation = pendingMutations[index]
        notices?.publish(
            "\(resourceLabel(for: mutation))同步未完成：\(presented.message)",
            critical: presented.critical,
            tone: .error,
            deduplicationKey: "sync-failure:\(mutation.id.uuidString):\(mutation.failure?.recordedAt.timeIntervalSince1970 ?? 0)"
        )
    }

    private func failureKind(for error: Error) -> PendingMutationFailureKind {
        guard let apiError = error as? APIError else { return .permanent }
        switch apiError {
        case .notConfigured, .badURL:
            return .configuration
        case .transport:
            return .retryable
        case .http(let status, _):
            if status == 401 || status == 403 { return .authentication }
            return (status == 408 || status == 429 || status >= 500) ? .retryable : .permanent
        case .validation(let status, _, _, _, _):
            if status == 401 || status == 403 { return .authentication }
            return (status == 408 || status == 429 || status >= 500) ? .retryable : .permanent
        default:
            return .permanent
        }
    }

    private func httpStatus(for error: Error) -> Int? {
        guard let apiError = error as? APIError else { return nil }
        switch apiError {
        case .http(let status, _): return status
        case .validation(let status, _, _, _, _): return status
        default: return nil
        }
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
