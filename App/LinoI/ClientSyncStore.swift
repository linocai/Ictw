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

/// A role is unique only inside its settings scope. Paths are persisted in
/// the pre-scope cache format, so old records retain their exact identity.
struct SyncResourceIdentity: Codable, Hashable, Sendable {
    let kind: SyncResourceKind
    let id: String
    let scope: String

    init(kind: SyncResourceKind, id: String, path: String? = nil, bookID: String? = nil) {
        self.kind = kind
        self.id = id
        if kind == .agentPersona || kind == .modelBinding {
            if let bookID { scope = "book:" + bookID }
            else if let path {
                let parts = path.split(separator: "/").map(String.init)
                let route = kind == .agentPersona ? "agent-personas" : "agent-model-bindings"
                if parts.count >= 3, parts[0] == "books", parts[2] == route {
                    scope = "book:" + parts[1]
                } else if parts.first == route {
                    scope = "global"
                } else {
                    // Preserve unresolvable records independently; never
                    // pretend that an unknown legacy route was global.
                    scope = "unresolved:" + path
                }
            } else { scope = "global" }
        } else { scope = "resource" }
    }

    var bookID: String? { scope.hasPrefix("book:") ? String(scope.dropFirst(5)) : nil }
    var isResolved: Bool { !scope.hasPrefix("unresolved:") }
    var key: String { [kind.rawValue, scope, id].map { "\($0.utf8.count):\($0)" }.joined() }
}

struct PendingMutation: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// The ID identifies one immutable payload. Coalesced descendants retain
    /// this lineage so only our own earlier success may advance their base.
    var lineageID: UUID
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
        case id, lineageID, resourceKind, resourceID, path, method, readPath, readStrategy, baseRevision, payload, baseSnapshot, createdAt, failure
    }

    init(
        id: UUID, resourceKind: SyncResourceKind, resourceID: String, path: String, method: String,
        readPath: String, readStrategy: ConflictReadStrategy, baseRevision: Int, payload: Data,
        baseSnapshot: Data, createdAt: Date, lineageID: UUID? = nil
    ) {
        self.id = id
        self.lineageID = lineageID ?? id
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
        lineageID = try container.decodeIfPresent(UUID.self, forKey: .lineageID) ?? id
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

    var identity: SyncResourceIdentity { SyncResourceIdentity(kind: resourceKind, id: resourceID, path: path) }

    var resourceLabel: String { resourceLabel(bookTitle: nil) }

    /// Derive a compact author-facing location from the already persisted
    /// edit/base JSON. This avoids storing a second display copy of content
    /// while still distinguishing failed writes across books and chapters.
    func resourceLabel(bookTitle: String?) -> String {
        let base = jsonObject(from: baseSnapshot) ?? [:]
        let object = base.merging(jsonObject(from: payload) ?? [:]) { _, newer in newer }
        let resolvedBookTitle = (bookTitle ?? identity.bookID)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return scoped(identity.bookID == nil ? "全局 Agent 人格" : "本书 Agent 人格", name: string("agent_role", in: object) ?? resourceID, bookTitle: resolvedBookTitle)
        case .modelBinding:
            return scoped(identity.bookID == nil ? "全局模型设置" : "本书模型设置", name: string("agent_role", in: object) ?? resourceID, bookTitle: resolvedBookTitle)
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

/// A direct request may cover the pending version visible when it started,
/// but never a version that arrived during its network round trip.
struct DirectMutationReceipt: Sendable {
    let mutation: PendingMutation
    let coveredMutationID: UUID?
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
    var mutationID: UUID? = nil
    var lineageID: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, resourceKind, resourceID, submittedRevision, currentRevision, path, method, readPath, readStrategy
        case baseSnapshot, localPayload, serverSnapshot, requiresSecretReentry, createdAt, mutationID, lineageID
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
        mutationID = try container.decodeIfPresent(UUID.self, forKey: .mutationID)
        lineageID = try container.decodeIfPresent(UUID.self, forKey: .lineageID)
    }

    var identity: SyncResourceIdentity { SyncResourceIdentity(kind: resourceKind, id: resourceID, path: path) }

    var resourceLabel: String {
        if !identity.isResolved { return "旧设置作用域无法确认（本机内容已保留，请回设置页重新保存）" }
        return switch resourceKind {
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
    var scope: String = "resource"
}

/// Per-record files deliberately keep one corrupt local snapshot from hiding
/// a whole bookshelf. The legacy ChapterDrafts directory remains untouched;
/// it is a second, compatible layer for existing unsaved drafts.
final class ClientSnapshotCache {
    enum SnapshotList: Hashable {
        case books
        case chapters(String)
        case characters(String)
    }

    private let root: URL
    private let encoder = JSONEncoder.lino
    private let decoder = JSONDecoder.lino
    private var listReadIDs: [SnapshotList: UUID] = [:]
    private lazy var deletedResources: Set<SyncResourceIdentity> = Set(load([SyncResourceIdentity].self, at: "deleted-resources.json") ?? [])

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

    /// A newer read or any write to this exact list supersedes an in-flight
    /// snapshot before it can replace either visible rows or the cold cache.
    func beginListRead(_ list: SnapshotList) -> UUID {
        let id = UUID()
        listReadIDs[list] = id
        return id
    }

    private func canSaveList(_ list: SnapshotList, readID: UUID?) -> Bool {
        guard readID == nil || listReadIDs[list] == readID else { return false }
        listReadIDs[list] = UUID()
        return true
    }

    func books() -> [Book] { load([Book].self, at: "books.json") ?? [] }
    @discardableResult
    func saveBooks(_ value: [Book], ifCurrent readID: UUID? = nil) -> Bool {
        guard canSaveList(.books, readID: readID) else { return false }
        let current = books()
        return save(value.filter { !isDeleted(kind: .book, id: $0.id) }.map { item in
            current.first { $0.id == item.id && $0.contentRevision > item.contentRevision } ?? item
        }, at: "books.json")
    }

    func chapters(bookID: String) -> [ChapterSummary] {
        load([ChapterSummary].self, at: "chapter-lists/\(safe(bookID)).json") ?? []
    }
    @discardableResult
    func saveChapters(_ value: [ChapterSummary], bookID: String, ifCurrent readID: UUID? = nil,
                      preservingInFlightRead: Bool = false) -> Bool {
        // A detail projection is a partial read, not a committed membership
        // change. A complete list may still fill its other rows afterwards.
        guard (preservingInFlightRead && readID == nil)
                || canSaveList(.chapters(bookID), readID: readID) else { return false }
        let current = chapters(bookID: bookID)
        return save(value.filter { !isDeleted(kind: .chapter, id: $0.id) }.map { item in
            current.first { $0.id == item.id && $0.contentRevision > item.contentRevision } ?? item
        }, at: "chapter-lists/\(safe(bookID)).json")
    }

    func characters(bookID: String) -> [Character] {
        load([Character].self, at: "characters/\(safe(bookID)).json") ?? []
    }
    @discardableResult
    func saveCharacters(_ value: [Character], bookID: String, ifCurrent readID: UUID? = nil) -> Bool {
        guard canSaveList(.characters(bookID), readID: readID) else { return false }
        let current = characters(bookID: bookID)
        return save(value.filter { !isDeleted(kind: .character, id: $0.id) }.map { item in
            var visible = current.first { $0.id == item.id && $0.contentRevision > item.contentRevision } ?? item
            visible.events.removeAll { isDeleted(kind: .characterEvent, id: $0.id) }
            return visible
        }, at: "characters/\(safe(bookID)).json")
    }

    func chapter(id: String) -> Chapter? {
        guard !isDeleted(kind: .chapter, id: id) else { return nil }
        return load(Chapter.self, at: "chapters/\(safe(id)).json")
    }
    func saveChapter(_ value: Chapter) {
        guard !isDeleted(kind: .chapter, id: value.id), !isDeleted(kind: .book, id: value.bookId) else { return }
        guard chapter(id: value.id).map({ $0.contentRevision <= value.contentRevision }) ?? true else { return }
        save(value, at: "chapters/\(safe(value.id)).json")
    }
    func removeChapter(id: String, bookID: String? = nil) {
        if let bookID = bookID ?? chapter(id: id)?.bookId {
            saveChapters(chapters(bookID: bookID).filter { $0.id != id }, bookID: bookID)
        }
        remove("chapters/\(safe(id)).json")
    }

    func isDeleted(kind: SyncResourceKind, id: String) -> Bool {
        deletedResources.contains(SyncResourceIdentity(kind: kind, id: id))
    }

    var deletedChapterIDs: Set<String> {
        Set(deletedResources.filter { $0.kind == .chapter }.map(\.id))
    }

    @discardableResult
    func markDeleted(_ identity: SyncResourceIdentity) -> Bool {
        deletedResources.insert(identity)
        return save(Array(deletedResources), at: "deleted-resources.json")
    }

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

struct RetainedChapterDraft: Identifiable, Sendable {
    var id: String { chapterID }
    let chapterID: String
    let bookID: String?
    let bookTitle: String
    let chapterTitle: String
    let chapterIndex: Int?
    let draftText: String
    let userPrompt: String
    let authorNote: String
    let updatedAt: Date
    fileprivate let removalSnapshot: LocalDraftFileSnapshot

    var copyText: String {
        let position = chapterIndex.map { "第 \($0) 章 · " } ?? "原章节 · "
        return "\(bookTitle)\n\(position)\(chapterTitle)\n\n本章 Bible\n\(userPrompt)\n\n作者备注\n\(authorNote)\n\n正文\n\(draftText)"
    }

    func matchesVisibleInputs(_ chapter: Chapter) -> Bool {
        guard chapter.id == chapterID,
              let source = try? JSONDecoder().decode(LocalChapterDraft.self, from: removalSnapshot.data) else { return false }
        return (source.bookID == nil || source.bookID == chapter.bookId)
            && source.title == chapter.title && source.userPrompt == chapter.userPrompt
            && source.authorNote == chapter.authorNote && source.draftText == chapter.draftText
            && source.targetWordCount == chapter.targetWordCount
            && source.characterLinks == chapter.characterLinks
            && source.exemptedCharacterNames == chapter.exemptedCharacterNames
    }
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
    /// Also keeps the recovery entry reachable when a retained file cannot be
    /// read. The explicit list load reports that failure instead of claiming
    /// there were no author inputs.
    @Published private(set) var hasRetainedChapterDrafts = false

    private var pendingPersistenceFailed = false
    private var conflictPersistenceFailed = false
    private var deletionPersistenceFailed = false
    private var directMutations: [UUID: DirectMutationReceipt] = [:]
    private var latestIntentIDs: [String: UUID] = [:]
    private var acknowledgedLineages: [UUID: Data] = [:]

    let cache: ClientSnapshotCache
    private let retainedDraftCache = ChapterDraftCache()
    private weak var notices: NoticeBus?

    init(cache: ClientSnapshotCache = ClientSnapshotCache(), notices: NoticeBus? = nil) {
        self.cache = cache
        self.notices = notices
        pendingMutations = cache.mutations()
        conflicts = cache.conflicts()
        persistenceFailure = nil
        pendingMutations.removeAll { isDeleted($0.identity) }
        conflicts.removeAll { isDeleted($0.identity) }
        for index in pendingMutations.indices where !pendingMutations[index].identity.isResolved {
            pendingMutations[index].failure = PendingMutationFailure(kind: .permanent, statusCode: nil,
                code: "sync_scope_unresolved", message: "旧设置记录的作用域无法确认，请回到对应设置页重新保存；本机内容仍保留。", recordedAt: Date())
        }
        _ = persistPending()
        _ = persistConflicts()
        refreshRetainedChapterDraftAvailability()
    }

    func refreshRetainedChapterDraftAvailability() {
        do { hasRetainedChapterDrafts = !(try retainedDraftCache.retainedDraftFiles(chapterIDs: cache.deletedChapterIDs)).isEmpty }
        catch { hasRetainedChapterDrafts = true }
    }

    /// This reads the existing local files only. It cannot recreate an old
    /// resource, enqueue a save, or consult a model.
    func retainedChapterDrafts() throws -> [RetainedChapterDraft] {
        do {
            let books = cache.books()
            let drafts = try retainedDraftCache.retainedDraftFiles(chapterIDs: cache.deletedChapterIDs).map { draft, snapshot in
                let title = draft.bookTitle ?? draft.bookID.flatMap { id in books.first { $0.id == id }?.title }
                return RetainedChapterDraft(chapterID: draft.chapterId, bookID: draft.bookID,
                    bookTitle: title.flatMap { $0.isEmpty ? nil : $0 } ?? "原书信息不可用",
                    chapterTitle: draft.title.isEmpty ? "原章标题不可用" : draft.title,
                    chapterIndex: draft.chapterIndex, draftText: draft.draftText,
                    userPrompt: draft.userPrompt, authorNote: draft.authorNote, updatedAt: draft.updatedAt,
                    removalSnapshot: snapshot)
            }
            hasRetainedChapterDrafts = !drafts.isEmpty
            return drafts
        } catch {
            hasRetainedChapterDrafts = true
            throw error
        }
    }

    /// Explicit completion uses the exact file the author viewed. Copying,
    /// closing the sheet, or another chapter's save never calls this method.
    func removeRetainedChapterDraft(_ draft: RetainedChapterDraft) throws {
        guard cache.isDeleted(kind: .chapter, id: draft.chapterID),
              draft.removalSnapshot.chapterID == draft.chapterID else {
            throw RetainedDraftError(message: "这份稿件不再符合本机保留稿身份；未移除任何内容，请刷新后核对。")
        }
        try retainedDraftCache.removeRetained(draft.removalSnapshot)
        refreshRetainedChapterDraftAvailability()
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

    func state(for kind: SyncResourceKind, id: String, bookID: String? = nil) -> ClientSyncState {
        let identity = SyncResourceIdentity(kind: kind, id: id, bookID: bookID)
        if hasPersistentSyncFailure { return .persistenceFailed }
        if conflicts.contains(where: { $0.identity == identity }) { return .conflict }
        if pendingMutations.contains(where: { $0.identity == identity && $0.failure != nil }) { return .failed(1) }
        let pending = pendingMutations.filter { $0.identity == identity }.count
        if pending > 0 { return .pending(pending) }
        return isOnline ? .synced : .offline
    }

    func markOnline() { isOnline = true }
    func markOffline() { isOnline = false }

    func isDeleted(_ identity: SyncResourceIdentity) -> Bool {
        cache.isDeleted(kind: identity.kind, id: identity.id)
            || identity.bookID.map { cache.isDeleted(kind: .book, id: $0) } == true
    }

    /// A confirmed deletion permanently revokes all outstanding callbacks for
    /// this exact resource. Queue records are removed only after server success.
    func confirmDeletion(kind: SyncResourceKind, id: String) {
        let identity = SyncResourceIdentity(kind: kind, id: id)
        deletionPersistenceFailed = !cache.markDeleted(identity)
        if deletionPersistenceFailed {
            notices?.publish("服务器已删除该资源，但本机未能保存删除标记；请保留当前页面，释放存储空间后重试。", critical: true, tone: .error)
        }
        let lineages = Set(pendingMutations.filter { $0.identity == identity }.map(\.lineageID))
            .union(conflicts.filter { $0.identity == identity }.compactMap(\.lineageID))
        pendingMutations.removeAll { $0.identity == identity || (kind == .book && $0.identity.bookID == id) }
        conflicts.removeAll { $0.identity == identity || (kind == .book && $0.identity.bookID == id) }
        directMutations = directMutations.filter { $0.value.mutation.identity != identity && !(kind == .book && $0.value.mutation.identity.bookID == id) }
        latestIntentIDs.removeValue(forKey: identity.key)
        acknowledgedLineages = acknowledgedLineages.filter { !lineages.contains($0.key) }
        _ = persistPending()
        _ = persistConflicts()
        refreshRetainedChapterDraftAvailability()
    }

    /// Use the same post-delete cleanup for direct requests and conflict retries.
    func confirmResourceDeletion(kind: SyncResourceKind, id: String) {
        let books = cache.books()
        if kind == .book {
            for chapter in cache.chapters(bookID: id) {
                confirmResourceDeletion(kind: .chapter, id: chapter.id)
            }
            for character in cache.characters(bookID: id) {
                for event in character.events { confirmDeletion(kind: .characterEvent, id: event.id) }
                confirmDeletion(kind: .character, id: character.id)
            }
            cache.saveCharacters([], bookID: id)
            confirmDeletion(kind: kind, id: id)
            cache.saveBooks(books.filter { $0.id != id })
            return
        }
        let chapterBookID = kind == .chapter ? cache.chapter(id: id)?.bookId : nil
        if kind == .character {
            for book in books {
                for character in cache.characters(bookID: book.id) where character.id == id {
                    for event in character.events { confirmDeletion(kind: .characterEvent, id: event.id) }
                }
            }
        }
        confirmDeletion(kind: kind, id: id)
        if kind == .chapter {
            cache.removeChapter(id: id, bookID: chapterBookID)
            for book in books where book.id != chapterBookID {
                let rows = cache.chapters(bookID: book.id)
                if rows.contains(where: { $0.id == id }) {
                    cache.saveChapters(rows.filter { $0.id != id }, bookID: book.id)
                }
            }
        }
        if kind == .character || kind == .characterEvent {
            for book in books {
                let rows = cache.characters(bookID: book.id)
                let containsDeleted = rows.contains { character in
                    kind == .character ? character.id == id : character.events.contains { $0.id == id }
                }
                if containsDeleted { cache.saveCharacters(rows, bookID: book.id) }
            }
        }
    }

    func visibleBooks() -> [Book] { cache.books().map(overlayBook) }
    func overlayBook(_ book: Book) -> Book { overlay(book, kind: .book, id: book.id) }

    func resourceLabel(for conflict: ContentConflict) -> String {
        let mutation = PendingMutation(
            id: conflict.mutationID ?? conflict.id, resourceKind: conflict.resourceKind, resourceID: conflict.resourceID,
            path: conflict.path, method: conflict.method, readPath: conflict.readPath, readStrategy: conflict.readStrategy,
            baseRevision: conflict.submittedRevision, payload: conflict.localPayload, baseSnapshot: conflict.baseSnapshot,
            createdAt: conflict.createdAt, lineageID: conflict.lineageID
        )
        return conflict.identity.isResolved ? resourceLabel(for: mutation) : conflict.resourceLabel
    }

    func resourceLabel(for mutation: PendingMutation) -> String {
        let booksByID = Dictionary(uniqueKeysWithValues: cache.books().map { ($0.id, $0.title) })
        if mutation.resourceKind == .chapter,
           let chapter = cache.chapter(id: mutation.resourceID) {
            return mutation.resourceLabel(bookTitle: booksByID[chapter.bookId])
        }
        let base = Self.jsonObject(from: mutation.baseSnapshot) ?? [:]
        let object = base.merging(Self.jsonObject(from: mutation.payload) ?? [:]) { _, newer in newer }
        let bookID = mutation.identity.bookID ?? object["book_id"] as? String
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
        let identity = SyncResourceIdentity(kind: kind, id: id, path: path)
        guard !isDeleted(identity) else { return false }
        guard let payloadData = try? JSONEncoder.lino.encode(AnyEncodable(payload)),
              let baseData = try? JSONEncoder.lino.encode(AnyEncodable(baseSnapshot)) else {
            persistenceFailure = "本机未能准备待同步内容，请保留此页面并重试。"
            return false
        }
        // A later local save supersedes an unsent earlier save for the same
        // resource. Keep the original base so a conflict still compares the
        // server snapshot against the true editing baseline.
        if let index = pendingMutations.lastIndex(where: { $0.identity == identity }) {
            pendingMutations[index].id = UUID()
            pendingMutations[index].payload = payloadData
            pendingMutations[index].path = path
            pendingMutations[index].method = method
            pendingMutations[index].readPath = readPath ?? path
            pendingMutations[index].readStrategy = readStrategy
            // A fresh explicit edit is the user's requested retry with a new
            // payload. Preserve the original conflict baseline but discard the
            // stale refusal diagnosis.
            pendingMutations[index].failure = nil
            latestIntentIDs[identity.key] = pendingMutations[index].id
            return persistPending()
        }
        let active = directMutations.values.first(where: {
            $0.mutation.identity == identity
                && latestIntentIDs[identity.key] == $0.mutation.id
                && $0.mutation.baseRevision == baseRevision
        })
        let mutation = PendingMutation(
            id: UUID(), resourceKind: kind, resourceID: id, path: path, method: method,
            readPath: readPath ?? path, readStrategy: readStrategy,
            baseRevision: baseRevision, payload: payloadData, baseSnapshot: baseData, createdAt: Date(),
            lineageID: active?.mutation.lineageID
        )
        pendingMutations.append(mutation)
        latestIntentIDs[identity.key] = mutation.id
        return persistPending()
    }

    func beginDirectMutation(
        kind: SyncResourceKind, id: String, path: String, method: String,
        baseRevision: Int, payload: some Encodable, baseSnapshot: some Encodable
    ) -> DirectMutationReceipt? {
        let identity = SyncResourceIdentity(kind: kind, id: id, path: path)
        guard !isDeleted(identity) else { return nil }
        guard let payloadData = try? JSONEncoder.lino.encode(AnyEncodable(payload)),
              let baseData = try? JSONEncoder.lino.encode(AnyEncodable(baseSnapshot)) else { return nil }
        let pending = pendingMutations.last { $0.identity == identity }
        let active = directMutations.values.first {
            $0.mutation.identity == identity
                && latestIntentIDs[identity.key] == $0.mutation.id
                && $0.mutation.baseRevision == baseRevision
        }
        let mutation = PendingMutation(
            id: UUID(), resourceKind: kind, resourceID: id, path: path, method: method,
            readPath: path, readStrategy: .direct, baseRevision: baseRevision,
            payload: payloadData, baseSnapshot: baseData, createdAt: Date(),
            lineageID: pending?.lineageID ?? active?.mutation.lineageID
        )
        let receipt = DirectMutationReceipt(mutation: mutation, coveredMutationID: pending?.id)
        directMutations[mutation.id] = receipt
        latestIntentIDs[identity.key] = mutation.id
        return receipt
    }

    func finishDirectMutation(_ receipt: DirectMutationReceipt?) {
        if let receipt { directMutations.removeValue(forKey: receipt.mutation.id) }
        pruneAcknowledgements()
    }

    private func pruneAcknowledgements() {
        let live = Set(pendingMutations.map(\.lineageID))
            .union(conflicts.compactMap(\.lineageID))
            .union(directMutations.values.map { $0.mutation.lineageID })
        acknowledgedLineages = acknowledgedLineages.filter { live.contains($0.key) }
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
        baseSnapshot: some Encodable,
        receipt: DirectMutationReceipt? = nil
    ) -> Bool {
        let identity = SyncResourceIdentity(kind: kind, id: id, path: path)
        guard !isDeleted(identity) else { return false }
        if let receipt {
            let mutation = receipt.mutation
            guard latestIntentIDs[identity.key] == mutation.id else {
                // A late refusal belongs to the submitted version. The newer
                // author payload must keep its own failure/success lifecycle.
                return !pendingPersistenceFailed
            }
            storePending(mutation)
            guard persistPending() else { return false }
            recordFailure(error, for: mutation.id)
            return !pendingPersistenceFailed
        }
        guard enqueue(
            kind: kind, id: id, path: path, method: method,
            readPath: readPath, readStrategy: readStrategy,
            baseRevision: baseRevision, payload: payload, baseSnapshot: baseSnapshot
        ) else { return false }
        guard let mutation = pendingMutations.last(where: {
            $0.identity == identity
        }) else { return false }
        recordFailure(error, for: mutation.id)
        return !pendingPersistenceFailed
    }

    func acknowledge(_ receipt: DirectMutationReceipt?, response: some Encodable) {
        guard let receipt, let data = try? JSONEncoder.lino.encode(AnyEncodable(response)) else { return }
        acknowledge(receipt.mutation, response: data, coveredID: receipt.coveredMutationID)
    }

    private func acknowledge(_ sent: PendingMutation, response: Data, coveredID: UUID? = nil) {
        guard !isDeleted(sent.identity) else { return }
        let canonical = (try? isolateCurrentResource(response, for: sent)) ?? response
        acknowledgedLineages[sent.lineageID] = canonical
        pendingMutations.removeAll { $0.id == sent.id || $0.id == coveredID }
        if let index = pendingMutations.firstIndex(where: {
            $0.identity == sent.identity
                && $0.lineageID == sent.lineageID && $0.baseRevision == sent.baseRevision
        }), let revision = (Self.jsonObject(from: response)?["content_revision"] as? NSNumber)?.intValue {
            // This server response acknowledges an ancestor in this exact
            // local editing chain. Advance only the base, never its payload.
            pendingMutations[index].baseRevision = revision
            pendingMutations[index].baseSnapshot = response
        }
        if let conflict = conflicts.first(where: {
            $0.identity == sent.identity
                && $0.lineageID == sent.lineageID && Self.sameSnapshot($0.serverSnapshot, canonical)
        }), let revision = (Self.jsonObject(from: response)?["content_revision"] as? NSNumber)?.intValue {
            // A newer request raced our ancestor's committed write and saw
            // its revision as a 409. The read snapshot proves it was our own
            // response, so retain/rebase the newest payload without requiring
            // a fictitious third-party comparison.
            if !pendingMutations.contains(where: { $0.identity == sent.identity }) {
                pendingMutations.append(PendingMutation(
                    id: conflict.mutationID ?? UUID(), resourceKind: conflict.resourceKind, resourceID: conflict.resourceID,
                    path: conflict.path, method: conflict.method, readPath: conflict.readPath, readStrategy: conflict.readStrategy,
                    baseRevision: revision, payload: conflict.localPayload, baseSnapshot: response, createdAt: conflict.createdAt,
                    lineageID: sent.lineageID
                ))
            }
            guard persistPending() else { return }
            conflicts.removeAll { $0.id == conflict.id }
            _ = persistConflicts()
        }
        _ = persistPending()
        pruneAcknowledgements()
    }

    private static func sameSnapshot(_ lhs: Data, _ rhs: Data) -> Bool {
        guard let left = try? JSONDecoder.lino.decode(JSONValue.self, from: lhs),
              let right = try? JSONDecoder.lino.decode(JSONValue.self, from: rhs) else { return false }
        return left == right
    }

    private func storePending(_ mutation: PendingMutation) {
        guard !isDeleted(mutation.identity) else { return }
        if let index = pendingMutations.lastIndex(where: {
            $0.identity == mutation.identity
        }) {
            var replacement = mutation
            replacement.lineageID = pendingMutations[index].lineageID
            replacement.baseRevision = pendingMutations[index].baseRevision
            replacement.baseSnapshot = pendingMutations[index].baseSnapshot
            pendingMutations[index] = replacement
        } else {
            pendingMutations.append(mutation)
        }
    }

    func conflict(for kind: SyncResourceKind, id: String, bookID: String? = nil) -> ContentConflict? {
        let identity = SyncResourceIdentity(kind: kind, id: id, bookID: bookID)
        return conflicts.first { $0.identity == identity }
    }

    /// The disk snapshot remains a server baseline. Recover author edits by
    /// overlaying durable pending/conflict payloads only when presenting them.
    func visibleCharacters(bookID: String) -> [Character] {
        overlayCharacters(cache.characters(bookID: bookID))
    }

    func overlayCharacters(_ values: [Character]) -> [Character] {
        values.map { value in
            var character = overlay(value, kind: .character, id: value.id)
            character.events = character.events.map { overlay($0, kind: .characterEvent, id: $0.id) }
            return character
        }
    }

    func overlayChapter(_ value: Chapter) -> Chapter { overlay(value, kind: .chapter, id: value.id) }

    private func overlay<T: Codable>(_ value: T, kind: SyncResourceKind, id: String) -> T {
        let identity = SyncResourceIdentity(kind: kind, id: id)
        let pending = pendingMutations.last { $0.identity == identity }
        let conflict = conflicts.last { $0.identity == identity }
        let payload = pending?.payload ?? conflict?.localPayload
        guard let payload, let data = try? JSONEncoder.lino.encode(value),
              let base = Self.jsonObject(from: data), let patch = Self.jsonObject(from: payload) else { return value }
        var object = base.merging(patch) { _, newer in newer }
        object["content_revision"] = pending?.baseRevision ?? conflict?.submittedRevision
        guard let merged = try? JSONSerialization.data(withJSONObject: object),
              let decoded = try? JSONDecoder.lino.decode(T.self, from: merged) else { return value }
        return decoded
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
        receipt: DirectMutationReceipt? = nil,
        error: APIError,
        api: APIClient
    ) async {
        let identity = SyncResourceIdentity(kind: kind, id: id, path: path)
        guard !isDeleted(identity) else { return }
        guard case let .writeConflict(_, _, submitted, current) = error,
              let payloadData = try? JSONEncoder.lino.encode(AnyEncodable(payload)),
              let baseData = try? JSONEncoder.lino.encode(AnyEncodable(baseSnapshot)) else { return }
        if let receipt, latestIntentIDs[identity.key] != receipt.mutation.id { return }
        let mutation = receipt?.mutation ?? PendingMutation(
            id: UUID(), resourceKind: kind, resourceID: id, path: path, method: method,
            readPath: readPath ?? path, readStrategy: readStrategy,
            baseRevision: baseRevision, payload: payloadData, baseSnapshot: baseData, createdAt: Date()
        )
        if receipt != nil { storePending(mutation); _ = persistPending() }
        let promotion = await promoteConflict(
            mutation,
            submittedRevision: submitted,
            currentRevision: current,
            requiresSecretReentry: requiresSecretReentry,
            requiresPendingOwnership: receipt != nil,
            api: api
        )
        switch promotion {
        case .promoted(let promotedID):
            pendingMutations.removeAll { $0.id == promotedID }
            _ = persistPending()
            return
        case .superseded:
            return
        case .rebased:
            return
        case .failed(let observationError) where !requiresSecretReentry:
            if let receipt, latestIntentIDs[identity.key] != receipt.mutation.id { return }
            storePending(mutation)
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
        latestIntentIDs[conflict.identity.key] = UUID()
        pendingMutations.removeAll { $0.identity == conflict.identity }
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
        guard conflict.identity.isResolved, !isDeleted(conflict.identity), !conflict.requiresSecretReentry else { return false }
        let mutation = PendingMutation(
            id: UUID(), resourceKind: conflict.resourceKind, resourceID: conflict.resourceID,
            path: conflict.path, method: conflict.method,
            readPath: conflict.readPath, readStrategy: conflict.readStrategy,
            baseRevision: conflict.currentRevision,
            payload: conflict.localPayload, baseSnapshot: conflict.serverSnapshot, createdAt: Date()
        )
        if let index = pendingMutations.lastIndex(where: {
            $0.identity == mutation.identity
        }) {
            pendingMutations[index] = mutation
        } else {
            pendingMutations.append(mutation)
        }
        latestIntentIDs[mutation.identity.key] = mutation.id
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
                    mutation.path, method: mutation.method, body: payload, ifMatch: mutation.baseRevision,
                    allowZeroRevision: mutation.identity.bookID != nil && mutation.baseRevision == 0
                )
                guard !isDeleted(mutation.identity) else { continue }
                try applySuccessfulResponse(response, for: mutation)
                applied.append(AppliedSyncMutation(resourceKind: mutation.resourceKind, resourceID: mutation.resourceID, scope: mutation.identity.scope))
                acknowledge(mutation, response: response)
                markOnline()
            } catch let conflict as APIError {
                guard case let .writeConflict(_, _, submitted, current) = conflict else {
                    recordFailure(conflict, for: mutation.id)
                    let kind = failureKind(for: conflict)
                    if kind.blocksAllFlushes || kind == .retryable { return applied }
                    continue
                }
                switch await promoteConflict(
                    mutation, submittedRevision: submitted, currentRevision: current, requiresPendingOwnership: true, api: api
                ) {
                case .promoted(let promotedID):
                    pendingMutations.removeAll { $0.id == promotedID }
                    _ = persistPending()
                case .superseded:
                    // The author has a newer direct request in flight. Its
                    // result owns the resource; stop this flush for now.
                    return applied
                case .rebased:
                    continue
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
        guard !isDeleted(mutation.identity) else { return false }
        if let index = pendingMutations.lastIndex(where: {
            $0.identity == mutation.identity
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
        case promoted(UUID)
        case superseded
        case rebased
        case failed(Error)
    }

    private func promoteConflict(
        _ mutation: PendingMutation,
        submittedRevision: Int,
        currentRevision: Int,
        requiresSecretReentry: Bool = false,
        requiresPendingOwnership: Bool = false,
        api: APIClient
    ) async -> ConflictPromotionResult {
        do {
            guard !isDeleted(mutation.identity) else { return .superseded }
            guard mutation.identity.isResolved else {
                return .failed(APIError.http(409, "旧设置记录的作用域无法确认，请回到对应设置页重新保存；本机内容仍保留。"))
            }
            let response = try await api.rawRequest(mutation.readPath)
            guard !isDeleted(mutation.identity) else { return .superseded }
            let server = try isolateCurrentResource(response, for: mutation)
            let key = mutation.identity.key
            if let latest = latestIntentIDs[key], latest != mutation.id,
               directMutations[latest] != nil { return .superseded }
            let latest = pendingMutations.last {
                $0.identity == mutation.identity
            }
            if requiresPendingOwnership, latest == nil, directMutations[mutation.id] == nil { return .superseded }
            // A conflict from an obsolete or explicitly replaced chain has
            // no authority over the author's current mutation.
            if let latest, latest.lineageID != mutation.lineageID { return .superseded }
            let local = latest ?? mutation
            if let ownResponse = acknowledgedLineages[local.lineageID], Self.sameSnapshot(ownResponse, server),
               let revision = (Self.jsonObject(from: server)?["content_revision"] as? NSNumber)?.intValue,
               local.baseRevision <= revision,
               let index = pendingMutations.firstIndex(where: { $0.id == local.id }) {
                // The ancestor can finish before this 409 even enters the
                // queue. Its exact acknowledged snapshot proves the new
                // pending version may inherit this base, regardless of the
                // order in which the two responses reached the Store.
                pendingMutations[index].baseRevision = revision
                pendingMutations[index].baseSnapshot = server
                guard persistPending() else {
                    return .failed(APIError.http(500, "本机未能保存重基后的待同步内容"))
                }
                return .rebased
            }
            let previousConflicts = conflicts
            conflicts.removeAll { $0.identity == local.identity }
            conflicts.append(ContentConflict(
                id: UUID(), resourceKind: local.resourceKind, resourceID: local.resourceID,
                submittedRevision: local.baseRevision,
                currentRevision: (Self.jsonObject(from: server)?["content_revision"] as? NSNumber)?.intValue ?? currentRevision,
                path: local.path, method: local.method,
                readPath: local.readPath, readStrategy: local.readStrategy,
                baseSnapshot: local.baseSnapshot, localPayload: local.payload,
                serverSnapshot: server, requiresSecretReentry: requiresSecretReentry, createdAt: Date()
            ))
            conflicts[conflicts.count - 1].mutationID = local.id
            conflicts[conflicts.count - 1].lineageID = local.lineageID
            guard persistConflicts() else {
                conflicts = previousConflicts
                return .failed(APIError.http(500, "本机未能保存冲突比较内容"))
            }
            markOnline()
            return .promoted(local.id)
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
            // A conflict retry is a real deletion and owns identical cleanup.
            guard mutation.method.uppercased() == "DELETE" else {
                throw invalidSuccessfulResponse()
            }
            switch mutation.resourceKind {
            case .book, .chapter, .character, .characterEvent, .llmProfile:
                confirmResourceDeletion(kind: mutation.resourceKind, id: mutation.resourceID)
            case .agentPersona, .modelBinding:
                break // Overrides can be recreated under the same scoped identity.
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
            _ = try settingsResource(data, for: mutation, writeResult: true)
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
            case .agentPersona, .modelBinding, .llmProfile:
                return try settingsResource(data, for: mutation)

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
            return try settingsResource(JSONEncoder.lino.encode(value), for: mutation)
        case .bookPersonas:
            let values = try JSONDecoder.lino.decode([BookAgentPersona].self, from: data)
            guard let value = values.first(where: { $0.agentRole == mutation.resourceID }) else {
                throw APIError.http(404, "本书人格已不存在")
            }
            return try settingsResource(JSONEncoder.lino.encode(value), for: mutation)
        case .profiles:
            let values = try JSONDecoder.lino.decode([LLMProfile].self, from: data)
            guard let value = values.first(where: { $0.id == mutation.resourceID }) else {
                throw APIError.http(404, "模型 Profile 已不存在")
            }
            return try settingsResource(JSONEncoder.lino.encode(value), for: mutation)
        case .globalModelBindings:
            let values = try JSONDecoder.lino.decode([AgentBinding].self, from: data)
            guard let value = values.first(where: { $0.agentRole == mutation.resourceID }) else {
                throw APIError.http(404, "全局模型设置已不存在")
            }
            return try settingsResource(JSONEncoder.lino.encode(value), for: mutation)
        case .bookModelBindings:
            let values = try JSONDecoder.lino.decode([BookAgentModelBinding].self, from: data)
            guard let value = values.first(where: { $0.agentRole == mutation.resourceID }) else {
                throw APIError.http(404, "本书模型设置已不存在")
            }
            return try settingsResource(JSONEncoder.lino.encode(value), for: mutation)
        }
    }

    private func settingsResource(_ data: Data, for mutation: PendingMutation, writeResult: Bool = false) throws -> Data {
        guard mutation.identity.isResolved, let object = Self.jsonObject(from: data) else { throw invalidConflictRead() }
        if mutation.resourceKind == .agentPersona || mutation.resourceKind == .modelBinding {
            let readIdentity = SyncResourceIdentity(kind: mutation.resourceKind, id: mutation.resourceID, path: mutation.readPath)
            guard readIdentity == mutation.identity else { throw invalidConflictRead() }
        }
        if let returnedBook = object["book_id"] as? String, returnedBook != mutation.identity.bookID { throw invalidConflictRead() }
        let revision = (object["content_revision"] as? NSNumber)?.intValue
        if writeResult, revision == nil || revision! < max(1, mutation.baseRevision) { throw invalidSuccessfulResponse() }
        switch mutation.resourceKind {
        case .agentPersona:
            guard object["agent_role"] as? String == mutation.resourceID else { throw invalidConflictRead() }
            if mutation.identity.bookID != nil {
                guard object["source"] != nil, object["global_persona"] is String,
                      object["effective_persona"] is String else { throw invalidConflictRead() }
                let value = try JSONDecoder.lino.decode(BookAgentPersona.self, from: data)
                if writeResult, value.source != "book" || value.bookPersona == nil { throw invalidSuccessfulResponse() }
                return try JSONEncoder.lino.encode(value)
            }
            guard object["source"] == nil, object["editable_persona"] is String || object["system_prompt"] is String,
                  revision != nil else { throw invalidConflictRead() }
            return try JSONEncoder.lino.encode(JSONDecoder.lino.decode(AgentPersona.self, from: data))
        case .modelBinding:
            guard object["agent_role"] as? String == mutation.resourceID else { throw invalidConflictRead() }
            if mutation.identity.bookID != nil {
                guard object["source"] != nil, object.keys.contains("book_binding"),
                      object.keys.contains("effective_binding") else { throw invalidConflictRead() }
                let value = try JSONDecoder.lino.decode(BookAgentModelBinding.self, from: data)
                if writeResult, value.source != "book" || value.bookBinding == nil { throw invalidSuccessfulResponse() }
                return try JSONEncoder.lino.encode(value)
            }
            guard object["source"] == nil, object.keys.contains("llm_profile_id"), revision != nil else { throw invalidConflictRead() }
            return try JSONEncoder.lino.encode(JSONDecoder.lino.decode(AgentBinding.self, from: data))
        case .llmProfile:
            guard object["id"] as? String == mutation.resourceID, object["name"] is String,
                  object["base_url"] is String, object["model_name"] is String, revision != nil else { throw invalidConflictRead() }
            return try JSONEncoder.lino.encode(JSONDecoder.lino.decode(LLMProfile.self, from: data))
        default: throw invalidConflictRead()
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
            if directMutations.values.contains(where: {
                $0.mutation.identity == mutation.identity
            }) { continue }
            if mutation.failure?.kind == .permanent { continue }
            if pendingMutations[..<index].contains(where: {
                $0.identity == mutation.identity
            }) { continue }
            return index
        }
        return nil
    }

    private func recordFailure(_ error: Error, for mutationID: UUID) {
        if case APIError.transport = error { markOffline() }
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
        if deletionPersistenceFailed {
            persistenceFailure = "本机未能安全保存删除标记；请保留当前页面，释放存储空间后重试。"
        } else if pendingPersistenceFailed || conflictPersistenceFailed {
            persistenceFailure = "本机未能安全保存待同步内容；请保留当前页面，释放存储空间后重试。"
        } else {
            persistenceFailure = nil
        }
    }
}
