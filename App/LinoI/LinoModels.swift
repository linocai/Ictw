import Foundation

/// Debug validation must never read a real connection, Keychain token, draft,
/// sync queue or task outcome. The isolated bundle used by UI verification
/// supplies all four values in `LSEnvironment`; command-line launches may
/// override those same values through the process environment.
enum DebugRuntimeConfiguration {
    static func value(for key: String) -> String? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        if let environment = Bundle.main.object(forInfoDictionaryKey: "LSEnvironment") as? [String: Any],
           let value = environment[key] as? String,
           !value.isEmpty {
            return value
        }
        #endif
        return nil
    }

    static var dataRoot: URL? {
        guard let value = self.value(for: "LINOI_DEBUG_DATA_ROOT") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    static var defaults: UserDefaults? {
        guard let suite = value(for: "LINOI_DEBUG_DEFAULTS_SUITE") else { return nil }
        return UserDefaults(suiteName: suite)
    }

    static var isIsolated: Bool {
        dataRoot != nil || defaults != nil || value(for: "LINOI_DEBUG_BASE_URL") != nil || value(for: "LINOI_DEBUG_TOKEN") != nil
    }
}

/// Connection persistence policy is Foundation-only so its migration contract
/// can be tested without constructing SwiftUI application state.
enum ConnectionEndpoint {
    static let currentDefault = "https://ictw.linotsai.top"
    static let legacyDefault = "https://linoi.neluvee.top"

    static func migratedBaseURL(saved: String?) -> (value: String, shouldPersist: Bool) {
        guard let saved else { return (currentDefault, true) }
        if saved == legacyDefault { return (currentDefault, true) }
        return (saved, false)
    }
}

/// Turns the backend's wire timestamp into quiet, author-facing shelf copy.
/// Only the calendar date is used: older backends return a timezone-less
/// value, so interpreting the clock portion would create false day changes.
enum BookUpdatedAtPresentation {
    static func label(
        _ rawValue: String,
        currentDate: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let datePart = rawValue.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard datePart.count == 3,
              let year = Int(datePart[0]),
              let month = Int(datePart[1]),
              let day = Int(datePart[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return "最近更新"
        }

        let today = calendar.dateComponents([.year, .month, .day], from: currentDate)
        if today.year == year, today.month == month, today.day == day {
            return "今天更新"
        }
        if today.year == year {
            return "\(month)月\(day)日更新"
        }
        return "\(year)年\(month)月\(day)日更新"
    }
}

enum JSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var description: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object(let value):
            return value
                .sorted { $0.key < $1.key }
                .map { "\($0.key)：\($0.value.description)" }
                .joined(separator: "\n")
        case .array(let value):
            return value.map(\.description).joined(separator: "、")
        case .null:
            return ""
        }
    }
}

struct Book: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var worldSetting: String
    var chapterCount: Int
    var characterCount: Int
    var archivePendingCount: Int
    var archiveAttentionCount: Int
    var updatedAt: String
    /// Server-issued monotonic write baseline. `0` is reserved for a response
    /// from a pre-v2.1 backend during the rolling Backend-first upgrade.
    var contentRevision: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, title
        case worldSetting = "world_setting"
        case chapterCount = "chapter_count"
        case characterCount = "character_count"
        case archivePendingCount = "archive_pending_count"
        case archiveAttentionCount = "archive_attention_count"
        case updatedAt = "updated_at"
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        worldSetting = try container.decodeIfPresent(String.self, forKey: .worldSetting) ?? ""
        chapterCount = try container.decodeIfPresent(Int.self, forKey: .chapterCount) ?? 0
        characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount) ?? 0
        archivePendingCount = try container.decodeIfPresent(Int.self, forKey: .archivePendingCount) ?? 0
        archiveAttentionCount = try container.decodeIfPresent(Int.self, forKey: .archiveAttentionCount) ?? 0
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
    }
}

/// A server-side search never returns a full hidden candidate or rejected
/// evidence. The snippet is only the small, author-visible context needed to
/// choose a destination.
struct SearchResult: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var resultType: String
    var bookId: String
    var chapterId: String?
    var characterId: String?
    var title: String
    var snippet: String?

    enum CodingKeys: String, CodingKey {
        case id, title, snippet
        case resultType = "result_type"
        case bookId = "book_id"
        case chapterId = "chapter_id"
        case characterId = "character_id"
    }

    var type: String { resultType }
}

struct SearchResponse: Decodable, Hashable, Sendable {
    var query: String
    var items: [SearchResult]
    var total: Int

    enum CodingKeys: String, CodingKey { case query, items, results, total }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        items = try container.decodeIfPresent([SearchResult].self, forKey: .items)
            ?? container.decodeIfPresent([SearchResult].self, forKey: .results)
            ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? items.count
    }
}

struct ProjectImportResult: Codable, Hashable, Sendable {
    var bookID: String
    var title: String
    var warnings: [ProjectImportWarning]

    enum CodingKeys: String, CodingKey { case bookID = "book_id", title, warnings }
}

struct ProjectImportWarning: Codable, Hashable, Sendable {
    var code: String
    var message: String
}

/// One bounded, public aggregation for text export. It intentionally omits
/// author-hidden candidates and rejected evidence, and replaces the old
/// client-side N+1 chapter fetch loop.
struct BookExportData: Codable, Hashable, Sendable {
    var bookID: String
    var title: String
    var worldSetting: String
    var chapters: [BookExportChapter]
    var characters: [BookExportCharacter]

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case title, chapters, characters
        case worldSetting = "world_setting"
    }
}

struct BookExportChapter: Codable, Hashable, Sendable {
    var id: String
    var index: Int
    var title: String
    var draftText: String
    var status: String
    enum CodingKeys: String, CodingKey { case id, index, title, status; case draftText = "draft_text" }
}

struct BookExportCharacter: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var role: String
    var fixedProfile: String
    enum CodingKeys: String, CodingKey { case id, name, role; case fixedProfile = "fixed_profile" }
}

struct ChapterLink: Codable, Hashable, Sendable {
    var characterId: String

    enum CodingKeys: String, CodingKey {
        case characterId = "character_id"
    }
}

struct ChapterArchiveFact: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var type: String
    var importance: Int
    var text: String
    var participantIds: [String]
    var startId: String
    var endId: String

    enum CodingKeys: String, CodingKey {
        case id, type, importance, text
        case participantIds = "participant_ids"
        case startId = "start_id"
        case endId = "end_id"
    }
}

/// A bounded public explanation of a state slot that could not be safely
/// projected. It deliberately contains identifiers and author-facing copy,
/// never hidden model output or a rejected candidate.
struct ChapterArchiveDiagnostic: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(code)|\(scope)|\(slot)|\(message)" }
    var code: String
    var severity: String
    var characterId: String?
    var characterName: String?
    var otherCharacterId: String?
    var otherCharacterName: String?
    var scope: String
    var slot: String
    var factRefs: [String]
    var spanIds: [String]
    var variants: [Variant]
    var message: String
    var recovery: String

    struct Variant: Codable, Hashable, Sendable {
        var operation: String
        var value: String
    }

    enum CodingKeys: String, CodingKey {
        case code, severity, scope, slot, variants, message, recovery
        case characterId = "character_id"
        case characterName = "character_name"
        case otherCharacterId = "other_character_id"
        case otherCharacterName = "other_character_name"
        case factRefs = "fact_refs"
        case spanIds = "span_ids"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? "archive_attention"
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? "warning"
        characterId = try c.decodeIfPresent(String.self, forKey: .characterId)
        characterName = try c.decodeIfPresent(String.self, forKey: .characterName)
        otherCharacterId = try c.decodeIfPresent(String.self, forKey: .otherCharacterId)
        otherCharacterName = try c.decodeIfPresent(String.self, forKey: .otherCharacterName)
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? "chapter"
        slot = try c.decodeIfPresent(String.self, forKey: .slot) ?? ""
        factRefs = try c.decodeIfPresent([String].self, forKey: .factRefs) ?? []
        spanIds = try c.decodeIfPresent([String].self, forKey: .spanIds) ?? []
        variants = try c.decodeIfPresent([Variant].self, forKey: .variants) ?? []
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? "这部分状态暂时无法确定。"
        recovery = try c.decodeIfPresent(String.self, forKey: .recovery) ?? "可重新整理这一章的记忆。"
    }
}

struct ChapterArchiveLatestAttempt: Codable, Hashable, Sendable {
    var revisionId: String?
    var revision: Int?
    var status: String
    var errorCode: String?
    var errorMessage: String?
    var finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case revision, status
        case revisionId = "revision_id"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case finishedAt = "finished_at"
    }
}

struct ChapterArchive: Codable, Hashable, Sendable {
    var status: String
    var archiveSchema: String
    var revisionId: String?
    var revision: Int?
    var summary: String
    var facts: [ChapterArchiveFact]
    var stateDeltaCount: Int
    var errorCode: String?
    var errorMessage: String?
    var canRetry: Bool
    var latestAttemptStatus: String?
    var inactivePreview: ChapterArchiveInactivePreview?
    /// Effective memory and the most recent attempt are separate facts. A
    /// later failed attempt must not erase older usable facts.
    var effectiveStatus: String = "none"
    var stateStatus: String = "none"
    var stateUncertainties: [ChapterArchiveDiagnostic] = []
    var diagnostics: [ChapterArchiveDiagnostic] = []
    var latestAttempt: ChapterArchiveLatestAttempt?

    enum CodingKeys: String, CodingKey {
        case status, summary, facts, revision
        case archiveSchema = "schema"
        case revisionId = "revision_id"
        case stateDeltaCount = "state_delta_count"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case canRetry = "can_retry"
        case latestAttemptStatus = "latest_attempt_status"
        case inactivePreview = "inactive_preview"
        case effectiveStatus = "effective_status"
        case stateStatus = "state_status"
        case stateUncertainties = "state_uncertainties"
        case diagnostics
        case latestAttempt = "latest_attempt"
    }

    init(
        status: String, archiveSchema: String, revisionId: String?, revision: Int?,
        summary: String, facts: [ChapterArchiveFact], stateDeltaCount: Int,
        errorCode: String?, errorMessage: String?, canRetry: Bool,
        latestAttemptStatus: String?, inactivePreview: ChapterArchiveInactivePreview?,
        effectiveStatus: String = "none", stateStatus: String = "none",
        stateUncertainties: [ChapterArchiveDiagnostic] = [],
        diagnostics: [ChapterArchiveDiagnostic] = [],
        latestAttempt: ChapterArchiveLatestAttempt? = nil
    ) {
        self.status = status; self.archiveSchema = archiveSchema
        self.revisionId = revisionId; self.revision = revision
        self.summary = summary; self.facts = facts; self.stateDeltaCount = stateDeltaCount
        self.errorCode = errorCode; self.errorMessage = errorMessage; self.canRetry = canRetry
        self.latestAttemptStatus = latestAttemptStatus; self.inactivePreview = inactivePreview
        self.effectiveStatus = effectiveStatus; self.stateStatus = stateStatus
        self.stateUncertainties = stateUncertainties; self.diagnostics = diagnostics
        self.latestAttempt = latestAttempt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "stale"
        archiveSchema = try c.decodeIfPresent(String.self, forKey: .archiveSchema) ?? "none"
        revisionId = try c.decodeIfPresent(String.self, forKey: .revisionId)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        facts = try c.decodeIfPresent([ChapterArchiveFact].self, forKey: .facts) ?? []
        stateDeltaCount = try c.decodeIfPresent(Int.self, forKey: .stateDeltaCount) ?? 0
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        canRetry = try c.decodeIfPresent(Bool.self, forKey: .canRetry) ?? false
        latestAttemptStatus = try c.decodeIfPresent(String.self, forKey: .latestAttemptStatus)
        inactivePreview = try c.decodeIfPresent(ChapterArchiveInactivePreview.self, forKey: .inactivePreview)
        effectiveStatus = try c.decodeIfPresent(String.self, forKey: .effectiveStatus) ?? (status == "complete" ? "full" : "none")
        stateStatus = try c.decodeIfPresent(String.self, forKey: .stateStatus) ?? (status == "complete" ? "complete" : "none")
        stateUncertainties = try c.decodeIfPresent([ChapterArchiveDiagnostic].self, forKey: .stateUncertainties) ?? []
        diagnostics = try c.decodeIfPresent([ChapterArchiveDiagnostic].self, forKey: .diagnostics) ?? []
        latestAttempt = try c.decodeIfPresent(ChapterArchiveLatestAttempt.self, forKey: .latestAttempt)
    }
}

/// Read-only readiness guard for actions that could use incomplete history.
/// The confirmation token is generated by the server and only authorizes the
/// exact current request; the client never reconstructs it or calls a model.
struct ProductionReadiness: Codable, Hashable, Sendable {
    struct Limitation: Codable, Hashable, Sendable, Identifiable {
        var chapterId: String
        var index: Int
        var title: String
        var reason: String
        var effectiveStatus: String
        var id: String { chapterId }
        enum CodingKeys: String, CodingKey {
            case index, title, reason, kind
            case chapterId = "chapter_id"
            case effectiveStatus = "effective_status"
            case chapterIndexLegacy = "chapter_index"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chapterId = try c.decode(String.self, forKey: .chapterId)
            index = try c.decodeIfPresent(Int.self, forKey: .index)
                ?? c.decodeIfPresent(Int.self, forKey: .chapterIndexLegacy)
                ?? 0
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? "第 \(index) 章"
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
                ?? c.decodeIfPresent(String.self, forKey: .kind)
                ?? "历史资料尚不完整"
            effectiveStatus = try c.decodeIfPresent(String.self, forKey: .effectiveStatus) ?? "none"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(chapterId, forKey: .chapterId)
            try c.encode(index, forKey: .index)
            try c.encode(title, forKey: .title)
            try c.encode(reason, forKey: .reason)
            try c.encode(effectiveStatus, forKey: .effectiveStatus)
        }
    }

    struct RecommendedRecovery: Codable, Hashable, Sendable, Identifiable {
        var chapterId: String
        var index: Int
        var title: String
        var reason: String
        var id: String { chapterId }
        enum CodingKeys: String, CodingKey {
            case index, title, reason
            case chapterId = "chapter_id"
        }
    }

    var contextToken: String
    var limitations: [Limitation]
    var recommendedRecovery: RecommendedRecovery?
    enum CodingKeys: String, CodingKey {
        case limitations
        case contextToken = "context_token"
        case recommendedRecovery = "recommended_recovery"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contextToken = try c.decodeIfPresent(String.self, forKey: .contextToken) ?? ""
        limitations = try c.decodeIfPresent([Limitation].self, forKey: .limitations) ?? []
        recommendedRecovery = try c.decodeIfPresent(RecommendedRecovery.self, forKey: .recommendedRecovery)
    }
}

/// A failed/stale archive revision is intentionally display-only.  It must
/// never be rendered as active memory or used by a later writing request.
struct ChapterArchiveInactivePreview: Codable, Hashable, Sendable {
    var revisionId: String
    var revision: Int
    var status: String
    var summary: String
    var factCount: Int
    var stateDeltaCount: Int

    enum CodingKeys: String, CodingKey {
        case revision, status, summary
        case revisionId = "revision_id"
        case factCount = "fact_count"
        case stateDeltaCount = "state_delta_count"
    }
}

extension ChapterArchive {
    var hasUsableMemory: Bool { effectiveStatus == "full" || effectiveStatus == "with_state_gaps" }

    private var latestAttemptNeedsModelConfiguration: Bool {
        guard let code = latestAttempt?.errorCode else { return false }
        return [
            "not_configured",
            "bad_url",
            "unauthorized",
            "llm_profile_not_configured",
            "llm_profile_missing",
            "api_key_undecryptable",
        ].contains(code) || code.hasSuffix("_thinking_not_disableable")
    }

    /// The server's bounded recovery instruction remains available after a
    /// reload, alongside all unresolved state entries.
    var recoverySuggestion: String {
        if latestAttemptNeedsModelConfiguration {
            return "请先修复 Extractor 的模型配置，再重新整理这一章的记忆。"
        }
        let recovery = (stateUncertainties + diagnostics)
            .map(\.recovery)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return recovery ?? "可重新整理这一章的记忆。"
    }

    /// Keep unknown state visibly unknown. This is deliberately a bounded
    /// summary for the author rather than a reconstructed state value.
    var attentionSummary: String? {
        var parts: [String] = []
        if !stateUncertainties.isEmpty {
            parts.append("摘要与事实仍可用；部分人物状态待整理。")
            let issue = stateUncertainties[0]
            if !issue.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("原因：\(issue.message)")
            }
        }
        if latestAttempt?.status == "failed" || latestAttemptStatus == "failed" {
            parts.append("旧记忆仍可用；最近一次整理没有完成。")
            if latestAttemptNeedsModelConfiguration {
                parts.append("Extractor 的模型配置需要先处理。")
            }
            if let message = latestAttempt?.errorMessage,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("原因：\(message)")
            }
            if let code = latestAttempt?.errorCode,
               !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("错误代码：\(code)")
            }
        }
        if parts.isEmpty, let diagnostic = diagnostics.first {
            parts.append(diagnostic.message)
        }
        if parts.isEmpty, let errorMessage,
           !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(errorMessage)
        }
        guard !parts.isEmpty else { return nil }
        parts.append("恢复：\(recoverySuggestion)")
        return parts.joined(separator: " ")
    }

    /// State gaps and diagnostics can overlap. Preserve the server order but
    /// avoid rendering an identical bounded item twice.
    var attentionDiagnostics: [ChapterArchiveDiagnostic] {
        var seen = Set<String>()
        return (stateUncertainties + diagnostics).filter { seen.insert($0.id).inserted }
    }
}

struct Chapter: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bookId: String
    let index: Int
    var title: String
    var userPrompt: String
    var targetWordCount: Int
    var authorNote: String
    var draftText: String
    var summary: String
    var headline: String
    var longSummary: String
    var stateChanges: [JSONValue]
    var unresolvedItems: [JSONValue]
    var atomicMemories: [JSONValue]
    var status: String
    var source: String
    var updatedAt: String
    var characterLinks: [ChapterLink]
    var exemptedCharacterNames: [String]
    var archive: ChapterArchive?
    var contentRevision: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, index, title, summary, status, source, headline, archive
        case longSummary = "long_summary"
        case stateChanges = "state_changes"
        case unresolvedItems = "unresolved_items"
        case atomicMemories = "atomic_memories"
        case bookId = "book_id"
        case userPrompt = "user_prompt"
        case targetWordCount = "target_word_count"
        case authorNote = "author_note"
        case legacyChapterStyle = "chapter_style"
        case draftText = "draft_text"
        case updatedAt = "updated_at"
        case characterLinks = "character_links"
        case exemptedCharacterNames = "exempted_character_names"
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bookId = try container.decode(String.self, forKey: .bookId)
        index = try container.decode(Int.self, forKey: .index)
        title = try container.decode(String.self, forKey: .title)
        userPrompt = try container.decode(String.self, forKey: .userPrompt)
        targetWordCount = try container.decodeIfPresent(Int.self, forKey: .targetWordCount) ?? 3000
        authorNote = try container.decodeIfPresent(String.self, forKey: .authorNote)
            ?? container.decodeIfPresent(String.self, forKey: .legacyChapterStyle)
            ?? ""
        draftText = try container.decode(String.self, forKey: .draftText)
        summary = try container.decode(String.self, forKey: .summary)
        headline = try container.decodeIfPresent(String.self, forKey: .headline) ?? ""
        let decodedLongSummary = try container.decodeIfPresent(String.self, forKey: .longSummary) ?? ""
        // v1.6.2 and older books may only have the legacy synopsis populated.
        // Present it immediately as the canonical summary even before the
        // backend data migration runs.
        longSummary = decodedLongSummary.isEmpty ? summary : decodedLongSummary
        stateChanges = try container.decodeIfPresent([JSONValue].self, forKey: .stateChanges) ?? []
        unresolvedItems = try container.decodeIfPresent([JSONValue].self, forKey: .unresolvedItems) ?? []
        atomicMemories = try container.decodeIfPresent([JSONValue].self, forKey: .atomicMemories) ?? []
        status = try container.decode(String.self, forKey: .status)
        source = try container.decode(String.self, forKey: .source)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        characterLinks = try container.decodeIfPresent([ChapterLink].self, forKey: .characterLinks) ?? []
        exemptedCharacterNames = try container.decodeIfPresent([String].self, forKey: .exemptedCharacterNames) ?? []
        archive = try container.decodeIfPresent(ChapterArchive.self, forKey: .archive)
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bookId, forKey: .bookId)
        try container.encode(index, forKey: .index)
        try container.encode(title, forKey: .title)
        try container.encode(userPrompt, forKey: .userPrompt)
        try container.encode(targetWordCount, forKey: .targetWordCount)
        try container.encode(authorNote, forKey: .authorNote)
        try container.encode(draftText, forKey: .draftText)
        try container.encode(summary, forKey: .summary)
        try container.encode(headline, forKey: .headline)
        try container.encode(longSummary, forKey: .longSummary)
        try container.encode(stateChanges, forKey: .stateChanges)
        try container.encode(unresolvedItems, forKey: .unresolvedItems)
        try container.encode(atomicMemories, forKey: .atomicMemories)
        try container.encode(status, forKey: .status)
        try container.encode(source, forKey: .source)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(characterLinks, forKey: .characterLinks)
        try container.encode(exemptedCharacterNames, forKey: .exemptedCharacterNames)
        try container.encodeIfPresent(archive, forKey: .archive)
        try container.encode(contentRevision, forKey: .contentRevision)
    }
}

struct ChapterSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bookId: String
    let index: Int
    var title: String
    var status: String
    var source: String
    var updatedAt: String
    var archiveStatus: String
    var archiveSchema: String
    var archiveCanRetry: Bool
    var archiveLatestAttemptStatus: String?
    var archiveEffectiveStatus: String = "none"
    var archiveStateStatus: String = "none"
    var archiveStateUncertaintyCount: Int = 0
    var contentRevision: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, index, title, status, source
        case bookId = "book_id"
        case updatedAt = "updated_at"
        case archiveStatus = "archive_status"
        case archiveSchema = "archive_schema"
        case archiveCanRetry = "archive_can_retry"
        case archiveLatestAttemptStatus = "archive_latest_attempt_status"
        case archiveEffectiveStatus = "archive_effective_status"
        case archiveStateStatus = "archive_state_status"
        case archiveStateUncertaintyCount = "archive_state_uncertainty_count"
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bookId = try container.decode(String.self, forKey: .bookId)
        index = try container.decode(Int.self, forKey: .index)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(String.self, forKey: .status)
        source = try container.decode(String.self, forKey: .source)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        archiveStatus = try container.decodeIfPresent(String.self, forKey: .archiveStatus) ?? "stale"
        archiveSchema = try container.decodeIfPresent(String.self, forKey: .archiveSchema) ?? "none"
        archiveCanRetry = try container.decodeIfPresent(Bool.self, forKey: .archiveCanRetry) ?? false
        archiveLatestAttemptStatus = try container.decodeIfPresent(String.self, forKey: .archiveLatestAttemptStatus)
        archiveEffectiveStatus = try container.decodeIfPresent(String.self, forKey: .archiveEffectiveStatus) ?? (archiveStatus == "complete" ? "full" : "none")
        archiveStateStatus = try container.decodeIfPresent(String.self, forKey: .archiveStateStatus) ?? (archiveStatus == "complete" ? "complete" : "none")
        archiveStateUncertaintyCount = try container.decodeIfPresent(Int.self, forKey: .archiveStateUncertaintyCount) ?? 0
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
    }

    init(
        id: String, bookId: String, index: Int, title: String, status: String,
        source: String, updatedAt: String, archiveStatus: String = "stale",
        archiveSchema: String = "none", archiveCanRetry: Bool = false,
        archiveLatestAttemptStatus: String? = nil, archiveEffectiveStatus: String = "none",
        archiveStateStatus: String = "none", archiveStateUncertaintyCount: Int = 0,
        contentRevision: Int = 0
    ) {
        self.id = id; self.bookId = bookId; self.index = index; self.title = title
        self.status = status; self.source = source; self.updatedAt = updatedAt
        self.archiveStatus = archiveStatus; self.archiveSchema = archiveSchema
        self.archiveCanRetry = archiveCanRetry; self.archiveLatestAttemptStatus = archiveLatestAttemptStatus
        self.archiveEffectiveStatus = archiveEffectiveStatus; self.archiveStateStatus = archiveStateStatus
        self.archiveStateUncertaintyCount = archiveStateUncertaintyCount
        self.contentRevision = contentRevision
    }
}

/// Read-only dry-run response for `GET /chapters/{id}/rewrite-preview`. Lists
/// exactly the chapters a rewrite's reopen cascade would actually invalidate
/// — never a client-side guess — so the confirmation dialog can name them.
struct RewriteImpactChapter: Codable, Hashable, Sendable {
    var id: String
    var index: Int
    var title: String

    enum CodingKeys: String, CodingKey {
        case id, index, title
    }
}

struct RewriteImpactPreview: Codable, Hashable, Sendable {
    var chapterId: String
    var index: Int
    var affectedChapters: [RewriteImpactChapter]

    enum CodingKeys: String, CodingKey {
        case index
        case chapterId = "chapter_id"
        case affectedChapters = "affected_chapters"
    }
}

/// Result of `ChapterEditorStore.rewrite()`. A rewrite on an accepted chapter
/// is two server calls, and the state between them is real and visible: once
/// the reopen lands the server has *already* voided this chapter's archive and
/// cascaded staleness onto every downstream chapter that depended on it. A
/// plain optional cannot express that — "nothing was attempted" and "the
/// archives are already gone but no new prose is coming" would both arrive as
/// `nil`, and the UI would tell the author nothing happened while the rail's
/// staleness markers silently went out of date.
enum ChapterRewriteOutcome: Equatable, Sendable {
    /// No archive was voided. Covers the guard rejecting the call, the reopen
    /// itself failing, and a never-accepted draft whose write job failed to
    /// start — in all of them the chapter stands exactly as the author left
    /// it. Any error was already published as a notice by the failing step.
    case notStarted

    /// The reopen landed; the write job did not start. The chapter is
    /// editable again, the previous prose is untouched (hard rule 35), and
    /// this chapter's archive plus its downstream cascade are already invalid
    /// on the server. The failure notice is published by `generate()`; the
    /// caller still owes the author a refreshed chapter list.
    case reopenedButGenerateFailed

    /// The write job is running. The payload is the server's chapter as of
    /// the moment the job was accepted; the prose in it is still the old one.
    case succeeded(Chapter)

    /// The chapter to feed back into the workspace, when there is one.
    var chapter: Chapter? {
        if case .succeeded(let chapter) = self { return chapter }
        return nil
    }

    /// Whether the on-screen chapter list is now out of date. True for both
    /// non-`notStarted` cases: a successful rewrite changed this chapter's own
    /// row, and a half-completed one changed the downstream staleness markers
    /// the confirmation dialog explicitly promised would appear.
    var requiresChapterListRefresh: Bool { self != .notStarted }
}

/// Finalized prose is immutable until the Backend has accepted an explicit
/// reopen. Keep this policy shared so UI affordances and Store mutations agree.
enum ChapterEditingPolicy {
    static func canEdit(_ chapter: Chapter?) -> Bool {
        guard let chapter else { return false }
        return chapter.status != "finalized"
    }
}

struct CharacterEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bookId: String
    let characterId: String
    let chapterId: String
    var eventType: String
    var eventText: String
    var chapterIndex: Int?
    var source: String?
    var editable: Bool?
    var contentRevision: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, source, editable
        case bookId = "book_id"
        case characterId = "character_id"
        case chapterId = "chapter_id"
        case eventType = "event_type"
        case eventText = "event_text"
        case chapterIndex = "chapter_index"
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bookId = try container.decode(String.self, forKey: .bookId)
        characterId = try container.decode(String.self, forKey: .characterId)
        chapterId = try container.decode(String.self, forKey: .chapterId)
        eventType = try container.decodeIfPresent(String.self, forKey: .eventType) ?? ""
        eventText = try container.decodeIfPresent(String.self, forKey: .eventText) ?? ""
        chapterIndex = try container.decodeIfPresent(Int.self, forKey: .chapterIndex)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        editable = try container.decodeIfPresent(Bool.self, forKey: .editable)
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
    }
}

struct Character: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let bookId: String
    var name: String
    var role: String
    var fixedProfile: String
    var dynamicFields: [String: JSONValue]
    var dynamicFieldsUpdatedChapterIndex: Int?
    var events: [CharacterEvent]
    var contentRevision: Int = 0

    enum CodingKeys: String, CodingKey {
        case id, name, role, events
        case bookId = "book_id"
        case fixedProfile = "fixed_profile"
        case dynamicFields = "dynamic_fields"
        case dynamicFieldsUpdatedChapterIndex = "dynamic_fields_updated_chapter_index"
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bookId = try container.decode(String.self, forKey: .bookId)
        name = try container.decode(String.self, forKey: .name)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        fixedProfile = try container.decodeIfPresent(String.self, forKey: .fixedProfile) ?? ""
        dynamicFields = try container.decodeIfPresent([String: JSONValue].self, forKey: .dynamicFields) ?? [:]
        dynamicFieldsUpdatedChapterIndex = try container.decodeIfPresent(Int.self, forKey: .dynamicFieldsUpdatedChapterIndex)
        events = try container.decodeIfPresent([CharacterEvent].self, forKey: .events) ?? []
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
    }
}

struct LLMProfile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var provider: String
    var baseURL: String
    var modelName: String
    var contentRevision: Int = 0
    var capabilities: ModelCapabilities?

    enum CodingKeys: String, CodingKey {
        case id, name, provider, capabilities
        case baseURL = "base_url"
        case modelName = "model_name"
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capabilities = try container.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "openai_compatible"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName) ?? ""
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
    }
}

struct AgentPersona: Codable, Identifiable, Hashable, Sendable {
    var id: String { agentRole }
    var agentRole: String
    var systemPrompt: String
    var editablePersona: String
    var defaultPersona: String
    var programProtocol: String
    var contentRevision: Int = 0

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case systemPrompt = "system_prompt"
        case editablePersona = "editable_persona"
        case defaultPersona = "default_persona"
        case programProtocol = "program_protocol"
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentRole = try container.decode(String.self, forKey: .agentRole)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        editablePersona = try container.decodeIfPresent(String.self, forKey: .editablePersona) ?? systemPrompt
        defaultPersona = try container.decodeIfPresent(String.self, forKey: .defaultPersona) ?? editablePersona
        programProtocol = try container.decodeIfPresent(String.self, forKey: .programProtocol) ?? ""
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
    }
}

/// The resolved book-level persona exposes the source so the UI never calls a
/// book override a "default" when it really follows a user-edited global one.
struct BookAgentPersona: Codable, Identifiable, Hashable, Sendable {
    var id: String { agentRole }
    var agentRole: String
    var source: String
    var bookPersona: String?
    var globalPersona: String
    var defaultPersona: String
    var effectivePersona: String
    var programProtocol: String
    var contentRevision: Int?

    enum CodingKeys: String, CodingKey {
        case source
        case agentRole = "agent_role"
        case bookPersona = "book_persona"
        case globalPersona = "global_persona"
        case defaultPersona = "default_persona"
        case effectivePersona = "effective_persona"
        case programProtocol = "program_protocol"
        case contentRevision = "content_revision"
    }
}

struct BookAgentPersonaPayload: Encodable, Sendable {
    let editable_persona: String
}

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText, markdown
    var id: String { rawValue }
    var fileExtension: String { self == .markdown ? "md" : "txt" }
    var label: String { self == .markdown ? "Markdown" : "纯文本" }
}

enum ExportScope: String, CaseIterable, Identifiable, Sendable {
    case accepted, all, current
    var id: String { rawValue }
    var label: String {
        switch self { case .accepted: "已接受章节"; case .all: "全部章节"; case .current: "本章" }
    }
}

/// Presentation-only scope policy. The composer still accepts every scope so
/// existing callers retain their export semantics; a book-level surface simply
/// must not offer a chapter that it cannot identify.
enum ExportPresentationPolicy {
    static func availableScopes(currentChapterID: String?) -> [ExportScope] {
        var scopes: [ExportScope] = [.accepted, .all]
        if currentChapterID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            scopes.append(.current)
        }
        return scopes
    }
}

struct ExportFile: Hashable, Sendable {
    var filename: String
    var text: String
}

/// Pure composer deliberately consumes only chapter prose and fixed book data;
/// Extractor memory remains exported through its separate legacy endpoint.
enum ExportComposer {
    static func chapters(for scope: ExportScope, chapters: [Chapter], currentID: String?) -> [Chapter] {
        switch scope {
        case .accepted: chapters.filter { $0.status == "finalized" }
        case .all: chapters
        case .current: chapters.filter { $0.id == currentID }
        }
    }

    static func compose(
        book: Book,
        chapters: [Chapter],
        characters: [Character],
        format: ExportFormat,
        includeWorld: Bool,
        includeCharacters: Bool,
        separateChapters: Bool
    ) -> [ExportFile] {
        let sorted = chapters.sorted { $0.index < $1.index }
        let base = safeFilename(book.title.isEmpty ? "LinoI书稿" : book.title)
        if separateChapters {
            var files: [ExportFile] = []
            if let settings = companionSettingsText(
                book: book, characters: characters, format: format,
                includeWorld: includeWorld, includeCharacters: includeCharacters
            ) {
                files.append(ExportFile(filename: "\(base)-设定.\(format.fileExtension)", text: settings))
            }
            files.append(contentsOf: sorted.map { chapter in
                ExportFile(filename: "\(base)-第\(chapter.index)章.\(format.fileExtension)", text: chapterText(chapter, format: format, includeHeading: true))
            })
            return files
        }
        var parts: [String] = []
        if format == .markdown { parts.append("# \(book.title.isEmpty ? "未命名书籍" : book.title)") }
        else { parts.append(book.title.isEmpty ? "未命名书籍" : book.title) }
        if includeWorld, !book.worldSetting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(format == .markdown ? "## 世界观\n\n\(book.worldSetting)" : "世界观\n\(book.worldSetting)")
        }
        if includeCharacters, !characters.isEmpty {
            let rows = characters.sorted { $0.name < $1.name }.map { character in
                format == .markdown
                    ? "- **\(character.name)**（身份：\(character.role.isEmpty ? "未填写" : character.role)）\n  \(character.fixedProfile)"
                    : "\(character.name)（身份：\(character.role.isEmpty ? "未填写" : character.role)）\n\(character.fixedProfile)"
            }
            parts.append((format == .markdown ? "## 人物设定\n\n" : "人物设定\n") + rows.joined(separator: "\n\n"))
        }
        parts.append(contentsOf: sorted.map { chapterText($0, format: format, includeHeading: true) })
        return [ExportFile(filename: "\(base).\(format.fileExtension)", text: parts.joined(separator: "\n\n"))]
    }

    private static func chapterText(_ chapter: Chapter, format: ExportFormat, includeHeading: Bool) -> String {
        let title = chapter.title.isEmpty ? "第 \(chapter.index) 章" : "第 \(chapter.index) 章 \(chapter.title)"
        guard includeHeading else { return chapter.draftText }
        return format == .markdown ? "## \(title)\n\n\(chapter.draftText)" : "\(title)\n\n\(chapter.draftText)"
    }

    /// In per-chapter mode fixed material is emitted once as a companion
    /// instead of being silently dropped or repeated in every chapter file.
    private static func companionSettingsText(
        book: Book, characters: [Character], format: ExportFormat,
        includeWorld: Bool, includeCharacters: Bool
    ) -> String? {
        var parts: [String] = []
        if includeWorld, !book.worldSetting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(format == .markdown ? "## 世界观\n\n\(book.worldSetting)" : "世界观\n\(book.worldSetting)")
        }
        if includeCharacters, !characters.isEmpty {
            let rows = characters.sorted { $0.name < $1.name }.map { character in
                format == .markdown
                    ? "- **\(character.name)**（身份：\(character.role.isEmpty ? "未填写" : character.role)）\n  \(character.fixedProfile)"
                    : "\(character.name)（身份：\(character.role.isEmpty ? "未填写" : character.role)）\n\(character.fixedProfile)"
            }
            parts.append((format == .markdown ? "## 人物设定\n\n" : "人物设定\n") + rows.joined(separator: "\n\n"))
        }
        guard !parts.isEmpty else { return nil }
        let title = book.title.isEmpty ? "未命名书籍" : book.title
        return (format == .markdown ? "# \(title)" : title) + "\n\n" + parts.joined(separator: "\n\n")
    }

    private static func safeFilename(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
    }
}

struct AgentBinding: Codable, Identifiable, Hashable, Sendable {
    var id: String { agentRole }
    var agentRole: String
    var llmProfileId: String?
    var thinkingEnabled: Bool?
    var reasoningEffort: String?
    var temperature: Double?
    var effectiveThinkingEnabled: Bool?
    var effectiveReasoningEffort: String?
    var effectiveTemperature: Double?
    var temperatureAdjustable: Bool
    var capabilities: ModelCapabilities
    var contentRevision: Int

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case llmProfileId = "llm_profile_id"
        case thinkingEnabled = "thinking_enabled"
        case reasoningEffort = "reasoning_effort"
        case temperature
        case effectiveThinkingEnabled = "effective_thinking_enabled"
        case effectiveReasoningEffort = "effective_reasoning_effort"
        case effectiveTemperature = "effective_temperature"
        case temperatureAdjustable = "temperature_adjustable"
        case capabilities
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentRole = try container.decode(String.self, forKey: .agentRole)
        llmProfileId = try container.decodeIfPresent(String.self, forKey: .llmProfileId)
        thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        effectiveThinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .effectiveThinkingEnabled)
        effectiveReasoningEffort = try container.decodeIfPresent(String.self, forKey: .effectiveReasoningEffort)
        effectiveTemperature = try container.decodeIfPresent(Double.self, forKey: .effectiveTemperature)
        temperatureAdjustable = try container.decodeIfPresent(Bool.self, forKey: .temperatureAdjustable) ?? false
        capabilities = try container.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities) ?? .unsupported
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision) ?? 0
    }
}

/// A complete model binding. Book overrides are all-or-nothing so the author
/// can always explain the effective result as either “follow global” or “this
/// book’s full override”, never a surprising mixture of two rows.
struct AgentModelBindingValues: Codable, Hashable, Sendable {
    var llmProfileId: String?
    var thinkingEnabled: Bool?
    var reasoningEffort: String?
    var temperature: Double?
    var effectiveThinkingEnabled: Bool?
    var effectiveReasoningEffort: String?
    var effectiveTemperature: Double?
    var contentRevision: Int?

    enum CodingKeys: String, CodingKey {
        case llmProfileId = "llm_profile_id"
        case thinkingEnabled = "thinking_enabled"
        case reasoningEffort = "reasoning_effort"
        case temperature
        case effectiveThinkingEnabled = "effective_thinking_enabled"
        case effectiveReasoningEffort = "effective_reasoning_effort"
        case effectiveTemperature = "effective_temperature"
        case contentRevision = "content_revision"
    }

    /// The response additionally contains effective values and a revision.
    /// A book override is a request body too, so never echo those read-only
    /// response fields back to the server.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(llmProfileId, forKey: .llmProfileId)
        try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
        try container.encode(reasoningEffort, forKey: .reasoningEffort)
        try container.encode(temperature, forKey: .temperature)
    }
}

struct BookAgentModelBinding: Codable, Identifiable, Hashable, Sendable {
    var id: String { agentRole }
    var agentRole: String
    var source: String
    var bookBinding: AgentModelBindingValues?
    var globalBinding: AgentModelBindingValues?
    var effectiveBinding: AgentModelBindingValues?
    var capabilities: ModelCapabilities
    var contentRevision: Int?

    enum CodingKeys: String, CodingKey {
        case source, capabilities
        case agentRole = "agent_role"
        case bookBinding = "book_binding"
        case globalBinding = "global_binding"
        case effectiveBinding = "effective_binding"
        case contentRevision = "content_revision"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentRole = try container.decode(String.self, forKey: .agentRole)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "global"
        bookBinding = try container.decodeIfPresent(AgentModelBindingValues.self, forKey: .bookBinding)
        globalBinding = try container.decodeIfPresent(AgentModelBindingValues.self, forKey: .globalBinding)
        effectiveBinding = try container.decodeIfPresent(AgentModelBindingValues.self, forKey: .effectiveBinding)
        capabilities = try container.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities) ?? .unsupported
        contentRevision = try container.decodeIfPresent(Int.self, forKey: .contentRevision)
    }
}

/// Shared by both book settings screens. Capability rules come from the
/// selected profile, never from the previously saved model after a switch.
struct BookModelSettingsDraft {
    var profileID = ""
    var thinking: Bool?
    var effort = ""
    var temperature: Double?
    private(set) var role: String
    private(set) var capabilities: ModelCapabilities?
    private(set) var profileExists = false

    init(role: String, row: BookAgentModelBinding? = nil, profiles: [LLMProfile] = []) {
        self.role = role
        let values = row?.bookBinding ?? row?.effectiveBinding
        profileID = values?.llmProfileId ?? ""
        thinking = values?.thinkingEnabled ?? values?.effectiveThinkingEnabled
        effort = values?.reasoningEffort ?? values?.effectiveReasoningEffort ?? ""
        temperature = values?.temperature
        refreshCapabilities(profiles: profiles, row: row)
    }

    var bounded: Bool { role == "extractor" || role == "inspiration_creator" }
    var thinkingEnabled: Bool {
        guard !bounded, let capabilities else { return false }
        return capabilities.thinkingRequired || (capabilities.thinkingToggleSupported && (thinking ?? true))
    }
    var thinkingAdjustable: Bool { !bounded && capabilities?.thinkingToggleSupported == true }
    var effortLevels: [String] { bounded ? [] : capabilities?.reasoningEffortLevels ?? [] }
    var effortAdjustable: Bool { thinkingEnabled && !effortLevels.isEmpty }
    var temperatureAdjustable: Bool {
        guard profileExists, let capabilities else { return false }
        return !thinkingEnabled || capabilities.temperatureEffectiveWhenThinking
    }
    var blockingReason: String? {
        if !profileExists { return "请选择一个可用模型。" }
        if capabilities == nil { return "模型能力资料未载入，请重新加载；若仍不可用，请先更新后端。" }
        if bounded && capabilities?.thinkingCanDisable != true { return "这个角色需要支持关闭深度思考的模型，请更换模型。" }
        return nil
    }
    var thinkingExplanation: String? {
        if bounded { return "这个角色的深度思考由服务端固定关闭。" }
        if capabilities?.thinkingRequired == true { return "这个模型始终开启深度思考，可调整支持的思考强度。" }
        if capabilities != nil && !thinkingAdjustable { return "这个模型未声明可调的深度思考选项。" }
        return nil
    }
    var temperatureExplanation: String? {
        guard capabilities != nil, !temperatureAdjustable else { return nil }
        return capabilities?.thinkingRequired == true
            ? "这个模型不支持调整温度。"
            : "开启深度思考时温度不生效；关闭后可调整。"
    }

    mutating func selectProfile(_ id: String, profiles: [LLMProfile], row: BookAgentModelBinding?) {
        guard profileID != id else { return }
        profileID = id
        thinking = nil
        effort = ""
        temperature = nil
        refreshCapabilities(profiles: profiles, row: row)
    }

    mutating func refreshCapabilities(profiles: [LLMProfile], row: BookAgentModelBinding?) {
        let profile = profiles.first { $0.id == profileID }
        profileExists = profile != nil
        capabilities = profile?.capabilities
        // Old servers can still describe an already-bound profile accurately.
        if capabilities == nil, !profileID.isEmpty, row?.effectiveBinding?.llmProfileId == profileID {
            capabilities = row?.capabilities
        }
    }

    var payload: AgentModelBindingValues? {
        guard blockingReason == nil, let capabilities else { return nil }
        return AgentModelBindingValues(
            llmProfileId: profileID,
            thinkingEnabled: bounded ? false : (capabilities.thinkingToggleSupported ? thinkingEnabled : nil),
            reasoningEffort: effortAdjustable && effortLevels.contains(effort) ? effort : nil,
            temperature: temperatureAdjustable ? temperature : nil,
            effectiveThinkingEnabled: nil, effectiveReasoningEffort: nil,
            effectiveTemperature: nil, contentRevision: nil
        )
    }
}

struct ModelCapabilities: Codable, Hashable, Sendable {
    var thinkingToggleSupported: Bool
    var thinkingCanDisable: Bool
    var thinkingRequired: Bool
    var reasoningEffortLevels: [String]
    var temperatureEffectiveWhenThinking: Bool

    static let unsupported = ModelCapabilities(
        thinkingToggleSupported: false,
        thinkingCanDisable: false,
        thinkingRequired: false,
        reasoningEffortLevels: [],
        temperatureEffectiveWhenThinking: true
    )

    enum CodingKeys: String, CodingKey {
        case thinkingToggleSupported = "thinking_toggle_supported"
        case thinkingCanDisable = "thinking_can_disable"
        case thinkingRequired = "thinking_required"
        case reasoningEffortLevels = "reasoning_effort_levels"
        case temperatureEffectiveWhenThinking = "temperature_effective_when_thinking"
    }

    init(
        thinkingToggleSupported: Bool,
        thinkingCanDisable: Bool,
        thinkingRequired: Bool,
        reasoningEffortLevels: [String],
        temperatureEffectiveWhenThinking: Bool
    ) {
        self.thinkingToggleSupported = thinkingToggleSupported
        self.thinkingCanDisable = thinkingCanDisable
        self.thinkingRequired = thinkingRequired
        self.reasoningEffortLevels = reasoningEffortLevels
        self.temperatureEffectiveWhenThinking = temperatureEffectiveWhenThinking
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thinkingToggleSupported = try container.decodeIfPresent(Bool.self, forKey: .thinkingToggleSupported) ?? false
        thinkingCanDisable = try container.decodeIfPresent(Bool.self, forKey: .thinkingCanDisable) ?? false
        thinkingRequired = try container.decodeIfPresent(Bool.self, forKey: .thinkingRequired) ?? false
        reasoningEffortLevels = try container.decodeIfPresent([String].self, forKey: .reasoningEffortLevels) ?? []
        temperatureEffectiveWhenThinking = try container.decodeIfPresent(Bool.self, forKey: .temperatureEffectiveWhenThinking) ?? true
    }
}

struct Violation: Codable, Hashable, Sendable {
    var code: String
    var message: String
    var names: [String]?
    var currentChars: Int?

    enum CodingKeys: String, CodingKey {
        case code, message, names
        case currentChars = "current_chars"
    }
}

/// Additive safe context attached to a terminal job. Failed jobs use the
/// upstream fields below; a completed Extractor may carry a conservative
/// state-salvage warning. Old clients ignore unknown keys safely.
struct JobErrorContext: Codable, Hashable, Sendable {
    var agentRole: String?
    var modelName: String?
    var upstreamReason: String?
    var finishReason: String?
    var blockReason: String?
    var httpStatus: Int?
    var completionWarning: String?
    var droppedStateComponents: Int?
    /// The safe server phase that was active when a service restart
    /// interrupted a job. It is optional for rolling compatibility with old
    /// servers, and intentionally takes precedence over the broad agent role
    /// when the UI tells the author where the interruption happened.
    var interruptedPhase: String? = nil

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case modelName = "model_name"
        case upstreamReason = "upstream_reason"
        case finishReason = "finish_reason"
        case blockReason = "block_reason"
        case httpStatus = "http_status"
        case completionWarning = "completion_warning"
        case droppedStateComponents = "dropped_state_components"
        case interruptedPhase = "interrupted_phase"
    }
}

/// Snapshot of a background write/extract job, returned by `POST /write`,
/// `POST /accept` and polled via `GET /chapters/{id}/job`. There is no more
/// SSE token stream — the client polls this endpoint until `phase` reaches a
/// terminal value (`done` / `failed` / `cancelled`).
struct WriteJobStatus: Decodable, Sendable {
    var chapterId: String
    var jobId: String?
    var outcomeCurrent: Bool?
    var kind: String
    var phase: String
    var attempt: Int?
    var errorCode: String?
    var errorMessage: String? = nil
    var errorContext: JobErrorContext? = nil
    var violations: [Violation]?
    var chapter: Chapter?
    var updatedCharacterIds: [String]?
    var addedEventIds: [String]?
    var memoryContext: MemoryContext? = nil
    var checkerResult: CheckerResult? = nil
    var visibleCheckerResult: CheckerResult? = nil
    /// The only public handle for a same-candidate retry. The candidate and
    /// its evidence remain server-only.
    var canRetryChecker: Bool = false
    var checkerSourceJobId: String? = nil

    enum CodingKeys: String, CodingKey {
        case chapterId = "chapter_id"
        case jobId = "job_id"
        case outcomeCurrent = "outcome_current"
        case kind, phase, attempt
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case errorContext = "error_context"
        case violations, chapter
        case updatedCharacterIds = "updated_character_ids"
        case addedEventIds = "added_event_ids"
        case memoryContext = "memory_context"
        case checkerResult = "checker_result"
        case visibleCheckerResult = "visible_checker_result"
        case canRetryChecker = "can_retry_checker"
        case checkerSourceJobId = "checker_source_job_id"
    }

    init(
        chapterId: String, jobId: String? = nil, outcomeCurrent: Bool? = nil,
        kind: String, phase: String, attempt: Int? = nil, errorCode: String? = nil,
        errorMessage: String? = nil, errorContext: JobErrorContext? = nil,
        violations: [Violation]? = nil, chapter: Chapter? = nil,
        updatedCharacterIds: [String]? = nil, addedEventIds: [String]? = nil,
        memoryContext: MemoryContext? = nil, checkerResult: CheckerResult? = nil,
        visibleCheckerResult: CheckerResult? = nil, canRetryChecker: Bool = false,
        checkerSourceJobId: String? = nil
    ) {
        self.chapterId = chapterId; self.jobId = jobId; self.outcomeCurrent = outcomeCurrent
        self.kind = kind; self.phase = phase; self.attempt = attempt; self.errorCode = errorCode
        self.errorMessage = errorMessage; self.errorContext = errorContext; self.violations = violations
        self.chapter = chapter; self.updatedCharacterIds = updatedCharacterIds; self.addedEventIds = addedEventIds
        self.memoryContext = memoryContext; self.checkerResult = checkerResult
        self.visibleCheckerResult = visibleCheckerResult; self.canRetryChecker = canRetryChecker
        self.checkerSourceJobId = checkerSourceJobId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterId = try c.decode(String.self, forKey: .chapterId)
        jobId = try c.decodeIfPresent(String.self, forKey: .jobId)
        outcomeCurrent = try c.decodeIfPresent(Bool.self, forKey: .outcomeCurrent)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "write"
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? "idle"
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        errorContext = try c.decodeIfPresent(JobErrorContext.self, forKey: .errorContext)
        violations = try c.decodeIfPresent([Violation].self, forKey: .violations)
        chapter = try c.decodeIfPresent(Chapter.self, forKey: .chapter)
        updatedCharacterIds = try c.decodeIfPresent([String].self, forKey: .updatedCharacterIds)
        addedEventIds = try c.decodeIfPresent([String].self, forKey: .addedEventIds)
        memoryContext = try c.decodeIfPresent(MemoryContext.self, forKey: .memoryContext)
        checkerResult = try c.decodeIfPresent(CheckerResult.self, forKey: .checkerResult)
        visibleCheckerResult = try c.decodeIfPresent(CheckerResult.self, forKey: .visibleCheckerResult)
        canRetryChecker = try c.decodeIfPresent(Bool.self, forKey: .canRetryChecker) ?? false
        checkerSourceJobId = try c.decodeIfPresent(String.self, forKey: .checkerSourceJobId)
    }

    /// Failure details for the backend-only candidate that Checker rejected.
    /// They must not be attached to the old text still visible in the editor.
    var failedCandidateCheckerResult: CheckerResult? {
        guard errorCode == "checker_rejected" else { return nil }
        return checkerResult
    }

    var completionWarning: String? {
        guard phase == "done", kind == "extract" else { return nil }
        let message = errorContext?.completionWarning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }

    /// Preserve concrete structured reasons for Checker rejection and the
    /// backend's safe deterministic Extractor rule after automatic correction
    /// is exhausted. Other failures continue through the localized table.
    var specificFailureReason: String? {
        if ["extract_failed", "archive_validation_failed", "archive_input_changed"].contains(errorCode) {
            let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !message.isEmpty else { return nil }
            return "正文已接受；\(message)。可直接重新归档，无需再次检查 Bible"
        }
        guard errorCode == "checker_rejected" else { return nil }
        let reasons = checkerResult?.issues?
            .map { $0.reason.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let uniqueReasons = reasons.reduce(into: [String]()) { result, reason in
            if !result.contains(reason) { result.append(reason) }
        }
        if !uniqueReasons.isEmpty {
            return "Checker 未通过：" + uniqueReasons.joined(separator: "；")
        }
        let message = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? nil : message
    }
}

struct MemoryContext: Decodable, Hashable, Sendable {
    struct Source: Decodable, Hashable, Sendable, Identifiable {
        var id: String
        var chapterIndex: Int?
        var kind: String?
        var excerpt: String?
        enum CodingKeys: String, CodingKey { case id, excerpt, kind; case chapterIndex = "chapter_index"; case memoryType = "memory_type"; case sourceExcerpt = "source_excerpt" }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            chapterIndex = try container.decodeIfPresent(Int.self, forKey: .chapterIndex)
            kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? container.decodeIfPresent(String.self, forKey: .memoryType)
            excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt) ?? container.decodeIfPresent(String.self, forKey: .sourceExcerpt)
        }
    }
    struct Conflict: Decodable, Hashable, Sendable, Identifiable {
        var id: String { (memoryEvidence ?? "") + "|" + (bibleEvidence ?? "") }
        var memoryEvidence: String?
        var bibleEvidence: String?
        var reason: String?
        enum CodingKeys: String, CodingKey { case reason, text; case memoryEvidence = "memory_evidence"; case bibleEvidence = "bible_evidence" }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let text = try container.decodeIfPresent(String.self, forKey: .text)
            memoryEvidence = try container.decodeIfPresent(String.self, forKey: .memoryEvidence) ?? text
            bibleEvidence = try container.decodeIfPresent(String.self, forKey: .bibleEvidence)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
        }
    }
    var brief: String
    var previousTail: String
    var sources: [Source]
    var conflicts: [Conflict]
    var characterCount: Int?
    enum CodingKeys: String, CodingKey { case brief, sources, conflicts, memoryBrief = "memory_brief"; case previousTail = "previous_tail"; case previousEnding = "previous_ending"; case characterCount = "character_count"; case memoryCount = "memory_non_whitespace_count" }
    init(from decoder: Decoder) throws {
        struct Brief: Decodable { let text: String }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let briefs = try container.decodeIfPresent([Brief].self, forKey: .memoryBrief) ?? []
        brief = try container.decodeIfPresent(String.self, forKey: .brief) ?? briefs.map(\.text).joined(separator: "\n")
        previousTail = try container.decodeIfPresent(String.self, forKey: .previousTail) ?? container.decodeIfPresent(String.self, forKey: .previousEnding) ?? ""
        sources = try container.decodeIfPresent([Source].self, forKey: .sources) ?? []
        conflicts = try container.decodeIfPresent([Conflict].self, forKey: .conflicts) ?? []
        characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount) ?? container.decodeIfPresent(Int.self, forKey: .memoryCount)
    }
}

struct CheckerIssue: Codable, Hashable, Sendable, Identifiable {
    var id: String { "\(kind)|\(reason)|\(draftEvidence)|\(bibleEvidence)" }
    var kind: String
    var draftEvidence: String
    var bibleEvidence: String
    var reason: String
    /// Source metadata is available only for the current visible manuscript.
    /// Candidate-job payloads continue to decode with these fields empty.
    var sourceKind: String = ""
    var sourceId: String = ""
    var sourceEvidence: String = ""
    enum CodingKeys: String, CodingKey {
        case kind, reason
        case draftEvidence = "draft_evidence"
        case bibleEvidence = "bible_evidence"
        case sourceKind = "source_kind"
        case sourceId = "source_id"
        case sourceEvidence = "source_evidence"
    }

    init(
        kind: String, draftEvidence: String, bibleEvidence: String, reason: String,
        sourceKind: String = "", sourceId: String = "", sourceEvidence: String = ""
    ) {
        self.kind = kind
        self.draftEvidence = draftEvidence
        self.bibleEvidence = bibleEvidence
        self.reason = reason
        self.sourceKind = sourceKind
        self.sourceId = sourceId
        self.sourceEvidence = sourceEvidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Job snapshots intentionally redact rejected candidate excerpts. The
        // public conclusion remains useful with only kind/reason, and a
        // missing excerpt must never make the whole job payload undecodable.
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        draftEvidence = try container.decodeIfPresent(String.self, forKey: .draftEvidence) ?? ""
        bibleEvidence = try container.decodeIfPresent(String.self, forKey: .bibleEvidence) ?? ""
        sourceKind = try container.decodeIfPresent(String.self, forKey: .sourceKind) ?? ""
        sourceId = try container.decodeIfPresent(String.self, forKey: .sourceId) ?? ""
        sourceEvidence = try container.decodeIfPresent(String.self, forKey: .sourceEvidence) ?? ""
    }
}

/// A deterministic identity choice returned only for the current visible
/// draft. The server deliberately withholds this from hidden candidates.
struct CheckerIdentityIssue: Codable, Hashable, Sendable, Identifiable {
    struct Candidate: Codable, Hashable, Sendable, Identifiable {
        var characterId: String
        var name: String
        var role: String
        var fixedProfile: String
        var id: String { characterId }
        enum CodingKeys: String, CodingKey {
            case name, role
            case characterId = "character_id"
            case fixedProfile = "fixed_profile"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            characterId = try c.decode(String.self, forKey: .characterId)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? "未命名人物"
            role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
            fixedProfile = try c.decodeIfPresent(String.self, forKey: .fixedProfile) ?? ""
        }
    }

    var kind: String
    var name: String
    var matchId: String
    var candidates: [Candidate]
    var id: String { matchId.isEmpty ? "\(kind)|\(name)" : matchId }
    enum CodingKeys: String, CodingKey {
        case kind, name, candidates
        case matchId = "match_id"
        case nameCandidates = "name_candidates"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "uncertain_character"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        matchId = try c.decodeIfPresent(String.self, forKey: .matchId) ?? ""
        // `name_candidates` is the current public contract. The old
        // `candidates` spelling is decoded only for cached v2.2 previews.
        candidates = try c.decodeIfPresent([Candidate].self, forKey: .nameCandidates)
            ?? c.decodeIfPresent([Candidate].self, forKey: .candidates)
            ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(matchId, forKey: .matchId)
        try c.encode(candidates, forKey: .nameCandidates)
    }
}

struct CheckerResult: Codable, Hashable, Sendable {
    var verdict: String?
    var status: String?
    var draftFingerprint: String?
    var issues: [CheckerIssue]?
    var errorCode: String?
    /// Safe, already-sanitised detail for a manual Checker response whose
    /// status is `unavailable`. This is not a Checker verdict and must never
    /// unlock acceptance.
    var errorMessage: String?
    var errorContext: JobErrorContext?
    var wasOverridden: Bool?
    var checkAttemptId: String?
    var inputFingerprint: String?
    var contextLimitations: [ProductionReadiness.Limitation] = []
    var identityIssues: [CheckerIdentityIssue] = []
    enum CodingKeys: String, CodingKey {
        case verdict, status, issues
        case draftFingerprint = "draft_fingerprint"
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case errorContext = "error_context"
        case wasOverridden = "override"
        case checkAttemptId = "check_attempt_id"
        case inputFingerprint = "input_fingerprint"
        case contextLimitations = "context_limitations"
        case identityIssues = "identity_issues"
    }

    init(
        verdict: String? = nil, status: String? = nil, draftFingerprint: String? = nil,
        issues: [CheckerIssue]? = nil, errorCode: String? = nil,
        errorMessage: String? = nil, errorContext: JobErrorContext? = nil,
        wasOverridden: Bool? = nil, checkAttemptId: String? = nil,
        inputFingerprint: String? = nil,
        contextLimitations: [ProductionReadiness.Limitation] = [],
        identityIssues: [CheckerIdentityIssue] = []
    ) {
        self.verdict = verdict; self.status = status; self.draftFingerprint = draftFingerprint
        self.issues = issues; self.errorCode = errorCode; self.errorMessage = errorMessage
        self.errorContext = errorContext; self.wasOverridden = wasOverridden
        self.checkAttemptId = checkAttemptId; self.inputFingerprint = inputFingerprint
        self.contextLimitations = contextLimitations
        self.identityIssues = identityIssues
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        draftFingerprint = try c.decodeIfPresent(String.self, forKey: .draftFingerprint)
        issues = try c.decodeIfPresent([CheckerIssue].self, forKey: .issues)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        errorContext = try c.decodeIfPresent(JobErrorContext.self, forKey: .errorContext)
        wasOverridden = try c.decodeIfPresent(Bool.self, forKey: .wasOverridden)
        checkAttemptId = try c.decodeIfPresent(String.self, forKey: .checkAttemptId)
        inputFingerprint = try c.decodeIfPresent(String.self, forKey: .inputFingerprint)
        contextLimitations = try c.decodeIfPresent([ProductionReadiness.Limitation].self, forKey: .contextLimitations) ?? []
        identityIssues = try c.decodeIfPresent([CheckerIdentityIssue].self, forKey: .identityIssues) ?? []
    }
    var displayVerdict: String { verdict ?? status ?? "unavailable" }
    var isPassed: Bool { displayVerdict == "passed" }
    /// Only these server verdicts are meaningful historical Checker evidence.
    /// Transport/unavailable/stale states must never be retained as a check.
    var hasConcreteVerdict: Bool {
        ["passed", "suspect", "violation"].contains(displayVerdict)
    }
    var isOverride: Bool { wasOverridden == true }
}

/// A Checker transport/status response is not itself evidence. This keeps a
/// historical concrete verdict visible as stale when the current response is
/// unavailable, while never allowing it to act as the current result.
enum CheckerSnapshotPresentationPolicy {
    static func shouldShowStaleSnapshot(
        hasConcreteSnapshot: Bool,
        checkerAppliesToVisibleDraft: Bool,
        currentCheckerResult: CheckerResult?
    ) -> Bool {
        guard hasConcreteSnapshot else { return false }
        return !(checkerAppliesToVisibleDraft && currentCheckerResult?.hasConcreteVerdict == true)
    }
}

/// Chapter rails receive health as independent fields. Schema describes an
/// active memory format, not whether an archive lifecycle needs attention.
enum ChapterArchiveRailState: Equatable, Sendable {
    case none
    case pending
    case attention

    static func resolve(
        status: String,
        canRetry: Bool,
        effectiveStatus: String = "none",
        latestAttemptStatus: String? = nil,
        stateUncertaintyCount: Int = 0
    ) -> Self {
        // A newer failed attempt or an explicit unknown slot needs a durable
        // rail marker even while an older active memory remains available.
        if effectiveStatus == "with_state_gaps"
            || latestAttemptStatus == "failed"
            || stateUncertaintyCount > 0 {
            return .attention
        }
        switch status {
        case "pending", "extracting": return .pending
        case "partial", "failed", "stale": return canRetry ? .attention : .none
        default: return .none
        }
    }

    var label: String? {
        switch self {
        case .none: nil
        case .pending: "归档中"
        case .attention: "归档待处理"
        }
    }
}

/// Async book-scoped configuration must never repaint a newer book after the
/// author switches books while a request is in flight.
enum BookPersonaResponsePolicy {
    static func accepts(responseBookID: String, activeBookID: String?, targetBookID: String?) -> Bool {
        responseBookID == activeBookID && responseBookID == targetBookID
    }
}

struct CheckerRunResult: Decodable, Sendable {
    var checkerResult: CheckerResult?
    var checkAttemptId: String?
    var inputFingerprint: String?
    var contextLimitations: [ProductionReadiness.Limitation] = []
    enum CodingKeys: String, CodingKey {
        case checkerResult = "checker_result"
        case checkAttemptId = "check_attempt_id"
        case inputFingerprint = "input_fingerprint"
        case contextLimitations = "context_limitations"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkerResult = try c.decodeIfPresent(CheckerResult.self, forKey: .checkerResult)
        checkAttemptId = try c.decodeIfPresent(String.self, forKey: .checkAttemptId)
        inputFingerprint = try c.decodeIfPresent(String.self, forKey: .inputFingerprint)
        contextLimitations = try c.decodeIfPresent([ProductionReadiness.Limitation].self, forKey: .contextLimitations) ?? []
    }
}

enum ChapterJobReconciliationDecision: Equatable, Sendable {
    case none
    case active
    case currentTerminal
    case obsoleteTerminal
    case unverifiedTerminal
}

/// Chooses whether a `/job` snapshot is safe to apply after loading the
/// authoritative Chapter. Old servers do not send `outcome_current`; their
/// failures remain local-cache-only rather than risking replay of stale state.
enum ChapterJobReconciler {
    static func decide(
        status: WriteJobStatus,
        chapter: Chapter,
        hasLocalInputDivergence: Bool
    ) -> ChapterJobReconciliationDecision {
        switch status.phase {
        case "selecting_memory", "writing", "validating", "checking", "extracting", "revising":
            return .active
        case "done":
            return hasLocalInputDivergence ? .obsoleteTerminal : .currentTerminal
        case "failed":
            if hasLocalInputDivergence {
                return .obsoleteTerminal
            }
            // Accepted prose remains immutable, but its current Extractor
            // failure is still actionable. A current manual Checker result
            // describes that same finalized text and is equally safe to
            // restore; Writer outcomes are never allowed to repaint it.
            if chapter.status == "finalized",
               !(["extract", "check"].contains(status.kind) && status.outcomeCurrent == true) {
                return .obsoleteTerminal
            }
            switch status.outcomeCurrent {
            case true: return .currentTerminal
            case false: return .obsoleteTerminal
            case nil: return .unverifiedTerminal
            }
        case "cancelled":
            if hasLocalInputDivergence
                || (chapter.status == "finalized" && !(status.kind == "check" && status.outcomeCurrent == true)) {
                return .obsoleteTerminal
            }
            switch status.outcomeCurrent {
            case true: return .currentTerminal
            case false: return .obsoleteTerminal
            case nil: return .unverifiedTerminal
            }
        case "idle":
            return .none
        default:
            return .none
        }
    }
}

/// Maps a terminal job's already-sanitised context to the exact step the
/// author needs to understand. Restart recovery deliberately favours the
/// server's `interrupted_phase`: an interrupted deterministic validation must
/// never be described as Writer work just because the originating agent was
/// Writer. Missing/unknown legacy phase stays unknown rather than guessed.
enum ChapterJobFailureStage {
    static func resolve(_ status: WriteJobStatus) -> ChapterGenerationStage? {
        switch status.errorContext?.interruptedPhase {
        case "selecting_memory": return .memorySelection
        case "writing": return .drafting
        case "validating": return .deterministicValidation
        case "checking": return .bibleChecking
        case "extracting": return .extraction
        case .some: return nil
        case .none: break
        }
        if status.errorCode == "interrupted" { return nil }
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
            case "checker_failed", "checker_rejected": return .bibleChecking
            default: return .drafting
            }
        }
    }
}

/// A monitor's notices are de-duplicated only for that one observation. A
/// later job for the same chapter, or a new manual refresh, must create a new
/// history entry instead of being hidden by an earlier network interruption.
enum ChapterTaskMonitoringNoticeKey {
    static func transient(chapterID: String, monitorID: UUID) -> String {
        "poll-transient:\(chapterID):\(monitorID.uuidString)"
    }

    static func stopped(chapterID: String, monitorID: UUID) -> String {
        "poll-stopped:\(chapterID):\(monitorID.uuidString)"
    }

    static func refresh(chapterID: String, requestID: UUID) -> String {
        "task-refresh:\(chapterID):\(requestID.uuidString)"
    }
}

/// Polling is an observer, never a background loop that may retry forever.
/// A successful read resets the transient budget; after the final bounded
/// delay the author receives an explicit read-only refresh path.
enum ChapterTaskPollingPolicy {
    static let normalDelayNanoseconds: UInt64 = 2_500_000_000

    static func retryDelayNanoseconds(afterConsecutiveFailures count: Int) -> UInt64? {
        switch count {
        case 1: return 500_000_000
        case 2: return 1_500_000_000
        case 3: return 3_000_000_000
        default: return nil
        }
    }
}

/// Only the deterministic violations that the server itself permits behind an
/// explicit accept override can offer that author choice. Empty text and
/// character attribution failures stay hard blockers.
enum ChapterPreflightOverridePolicy {
    private static let lengthOnlyCodes: Set<String> = ["minimum_length", "length_truncated"]

    static func permitsExplicitAcceptance(_ violations: [Violation]) -> Bool {
        let codes = Set(violations.map(\.code))
        return !codes.isEmpty && codes.isSubset(of: lengthOnlyCodes)
    }
}

/// Shared, platform-neutral lifecycle used by both chapter editors. It keeps
/// transport/job truth out of the SwiftUI views so iOS and macOS cannot infer
/// different meanings from the same backend snapshot.
enum ChapterGenerationStage: Int, CaseIterable, Equatable, Sendable {
    case memorySelection
    case drafting
    case deterministicValidation
    case bibleChecking
    case extraction
    case completed
    /// App-only request phase. Appended so every previously persisted raw
    /// value remains stable.
    case acceptance

    var label: String {
        switch self {
        case .memorySelection: return "整理记忆"
        case .drafting: return "整章写作"
        case .deterministicValidation: return "确定性校验"
        case .bibleChecking: return "Bible 检查"
        case .extraction: return "提取归档"
        case .completed: return "完成"
        case .acceptance: return "接受正文"
        }
    }

    /// `acceptance` is a request-state label rather than a writer pipeline
    /// step. Keep the established progress strip stable while still allowing
    /// a persisted failure to name this exact action.
    static var displayedCases: [Self] { allCases.filter { $0 != .acceptance } }
}

enum ChapterGenerationStepState: Equatable, Sendable {
    case pending
    case active
    case completed
    case failed
    case cancelled
}

struct ChapterGenerationStep: Identifiable, Equatable, Sendable {
    var id: ChapterGenerationStage { stage }
    var stage: ChapterGenerationStage
    var state: ChapterGenerationStepState
}

enum ChapterWritingPhase: Equatable, Sendable {
    case idle
    case selectingMemory
    case writing
    case writingAttempt(Int)
    case validating
    case checking
    case legacyRevising
    case extracting
    case accepting
    case failed(code: String?, message: String, stage: ChapterGenerationStage?)
    case cancelled(message: String, stage: ChapterGenerationStage?)

    var isActive: Bool {
        switch self {
        case .selectingMemory, .writing, .writingAttempt, .validating, .checking, .legacyRevising, .extracting, .accepting: return true
        case .idle, .failed, .cancelled: return false
        }
    }

    /// True only for write-side phases. Extraction has no cancel endpoint.
    var isGenerating: Bool {
        switch self {
        case .selectingMemory, .writing, .writingAttempt, .validating, .checking, .legacyRevising: return true
        default: return false
        }
    }

    var label: String? {
        switch self {
        case .selectingMemory: return "正在整理相关记忆"
        case .writing: return "正在整章写作（第 1/2 次）"
        case .writingAttempt(let attempt): return "正在整章写作（第 \(attempt)/2 次）"
        case .validating: return "正在进行确定性校验"
        case .checking: return "正在进行 Bible 检查"
        case .legacyRevising: return "旧版任务记录"
        case .extracting: return "Extractor 正在整理本章记忆"
        case .accepting: return "正在确认接受这章正文"
        case .failed(_, let message, _), .cancelled(let message, _): return message
        case .idle: return nil
        }
    }

    /// Short state text for compact headers. Terminal details belong in the
    /// always-visible generation panel, where they can wrap without pushing
    /// the title and character count out of place.
    var compactLabel: String? {
        switch self {
        case .failed: return "生成失败"
        case .cancelled: return "已停止"
        default: return label
        }
    }

    var pillStatus: String {
        switch self {
        case .extracting, .accepting: return "extracting"
        case .selectingMemory, .writing, .writingAttempt, .validating, .checking, .legacyRevising: return "writing"
        case .failed: return "failed"
        case .idle, .cancelled: return "idle"
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var currentStage: ChapterGenerationStage? {
        switch self {
        case .selectingMemory: return .memorySelection
        case .writing, .writingAttempt: return .drafting
        case .validating: return .deterministicValidation
        case .checking, .legacyRevising: return .bibleChecking
        case .extracting: return .extraction
        case .accepting: return .acceptance
        case .failed(_, _, let stage), .cancelled(_, let stage): return stage
        case .idle: return nil
        }
    }
}

enum ChapterRecoveryAction: Equatable, Sendable {
    case retryGeneration
    case retryExtraction

    var title: String {
        switch self {
        case .retryGeneration: return "重新生成"
        case .retryExtraction: return "重新提取"
        }
    }
}

/// Honest save states: "saved locally" is deliberately different from
/// "synced to the server". A failed remote save can therefore reassure the
/// user that the recoverable local copy still exists without claiming the
/// server accepted it.
enum ChapterSaveState: Equatable, Sendable {
    case synced
    case unsaved
    case savingLocally
    case localDraft
    case localSaveFailed(message: String)
    case restoredLocalDraft
    case savingRemotely
    case remoteSaveFailed(message: String, localDraftPreserved: Bool)

    var label: String {
        switch self {
        case .synced: return "已与服务器同步"
        case .unsaved: return "更改尚未保存"
        case .savingLocally: return "正在保存到本机"
        case .localDraft: return "已保存到本机，尚未同步"
        case .localSaveFailed: return "本机草稿保存失败"
        case .restoredLocalDraft: return "已恢复本机草稿，尚未同步"
        case .savingRemotely: return "正在保存到服务器"
        case .remoteSaveFailed(_, let localDraftPreserved):
            return localDraftPreserved
                ? "服务器保存失败，本机草稿仍在"
                : "服务器与本机草稿保存均失败"
        }
    }

    var failureMessage: String? {
        switch self {
        case .localSaveFailed(let message):
            return message
        case .remoteSaveFailed(let message, _):
            return message
        default:
            return nil
        }
    }

    var needsRetry: Bool {
        failureMessage != nil
    }
}

/// Text changes stay in memory so SwiftUI/IME composition never competes with
/// synchronous JSON encoding and atomic disk writes. Only transition points
/// flush an unsaved snapshot to the local recovery cache.
enum ChapterLocalDraftPersistencePolicy {
    static func needsPersistence(_ state: ChapterSaveState) -> Bool {
        switch state {
        case .unsaved, .localSaveFailed:
            return true
        case .remoteSaveFailed(_, let localDraftPreserved):
            return !localDraftPreserved
        case .synced, .savingLocally, .localDraft, .restoredLocalDraft, .savingRemotely:
            return false
        }
    }
}

/// The single presentation snapshot consumed by both frontends. It is a pure
/// derivation of server-backed chapter/job state plus the explicit local
/// cache/connection state, which makes contradictory UI states testable.
struct ChapterEditorPresentationState: Equatable, Sendable {
    var steps: [ChapterGenerationStep]
    var headline: String?
    var validationReason: String?
    var failureCode: String?
    var recoveryAction: ChapterRecoveryAction?
    var saveState: ChapterSaveState
    var connectionInterrupted: Bool

    static func make(
        phase: ChapterWritingPhase,
        chapterStatus: String?,
        checkerVerdict: String?,
        validationReason: String?,
        saveState: ChapterSaveState,
        connectionInterrupted: Bool
    ) -> ChapterEditorPresentationState {
        var states = Dictionary(
            uniqueKeysWithValues: ChapterGenerationStage.displayedCases.map { ($0, ChapterGenerationStepState.pending) }
        )

        func complete(before stage: ChapterGenerationStage) {
            for candidate in ChapterGenerationStage.displayedCases where candidate.rawValue < stage.rawValue {
                states[candidate] = .completed
            }
        }

        var failureCode: String?
        switch phase {
        case .selectingMemory:
            states[.memorySelection] = .active
        case .writing, .writingAttempt:
            complete(before: .drafting)
            states[.drafting] = .active
        case .validating:
            complete(before: .deterministicValidation)
            states[.deterministicValidation] = .active
        case .checking, .legacyRevising:
            complete(before: .bibleChecking)
            states[.bibleChecking] = .active
        case .extracting:
            complete(before: .extraction)
            states[.extraction] = .active
        case .accepting:
            complete(before: .acceptance)
            states[.acceptance] = .active
        case .failed(let code, _, let stage):
            if let stage {
                complete(before: stage)
                states[stage] = .failed
            }
            failureCode = code
        case .cancelled(_, let stage):
            if let stage {
                complete(before: stage)
                states[stage] = .cancelled
            }
        case .idle:
            switch chapterStatus {
            case "finalized":
                for stage in ChapterGenerationStage.displayedCases {
                    states[stage] = .completed
                }
            case "draft_ready":
                states[.memorySelection] = .completed
                states[.drafting] = .completed
                states[.deterministicValidation] = .completed
                switch checkerVerdict {
                case "passed":
                    states[.bibleChecking] = .completed
                case "suspect", "violation":
                    states[.bibleChecking] = .failed
                default:
                    states[.bibleChecking] = .pending
                }
            case "extracting":
                complete(before: .extraction)
                states[.extraction] = .active
            case "writing":
                complete(before: .drafting)
                states[.drafting] = .active
            default:
                break
            }
        }

        let recoveryAction: ChapterRecoveryAction?
        if case .failed(_, _, let stage) = phase {
            let requiresUserChange: Set<String> = [
                "unauthorized",
                "not_configured",
                "bad_url",
                "bible_empty",
                "chapter_finalized",
                "unselected_characters_in_bible",
                "ambiguous_character_name",
                "llm_content_blocked",
                "writer_minimum_failed",
            ]
            if stage == .acceptance || (failureCode.map(requiresUserChange.contains) ?? false) {
                recoveryAction = nil
            } else {
                recoveryAction = stage == .extraction ? .retryExtraction : .retryGeneration
            }
        } else {
            recoveryAction = nil
        }

        return ChapterEditorPresentationState(
            steps: ChapterGenerationStage.displayedCases.map {
                ChapterGenerationStep(stage: $0, state: states[$0] ?? .pending)
            },
            headline: phase.label,
            validationReason: validationReason,
            failureCode: failureCode,
            recoveryAction: recoveryAction,
            saveState: saveState,
            connectionInterrupted: connectionInterrupted
        )
    }
}

/// A server refresh may replace editor state only if no local input changed
/// while the request was in flight. This keeps a late failure reconciliation
/// from undoing a newly selected character or edited Bible/body.
enum ChapterRefreshReconciler {
    static func shouldReplaceLocal(
        startingRevision: UInt64,
        currentRevision: UInt64,
        hasLocalInputDivergence: Bool
    ) -> Bool {
        startingRevision == currentRevision && !hasLocalInputDivergence
    }
}

enum VisibleDraftActionPolicy {
    static func canAccept(
        hasDraft: Bool,
        phase: ChapterWritingPhase,
        checkerApplies: Bool,
        checkerPassed: Bool
    ) -> Bool {
        guard hasDraft, !phase.isActive else { return false }
        if phase.isFailed, phase.currentStage == .extraction {
            return true
        }
        return checkerApplies && checkerPassed
    }

    static func canCheck(hasDraft: Bool, phase: ChapterWritingPhase) -> Bool {
        hasDraft && !phase.isActive
    }
}

enum CheckerOverrideActionPolicy {
    static func shouldOffer(
        hasDraft: Bool,
        phase: ChapterWritingPhase,
        checkerAllowsAcceptance: Bool
    ) -> Bool {
        guard hasDraft, !phase.isActive, !checkerAllowsAcceptance else { return false }
        return !(phase.isFailed && phase.currentStage == .extraction)
    }
}

private struct CachedChapterTaskOutcome: Codable {
    enum Kind: String, Codable {
        case failed
        case cancelled
    }

    let formatVersion: Int?
    let kind: Kind
    let inputFingerprint: String?
    /// v1.5 review compatibility only. Records using the old body-only
    /// fingerprint are deliberately ignored because they can outlive edits to
    /// the Bible, target count, selected characters, or a cross-device success.
    let contentFingerprint: String?
    let message: String
    let code: String?
    let stageRawValue: Int?
    let validationReason: String?
    let pendingExemptionNames: [String]?
    let jobID: String?
}

struct ChapterTaskOutcome: Equatable, Sendable {
    let phase: ChapterWritingPhase
    let validationReason: String?
    let pendingExemptionNames: [String]
    let jobID: String?
}

/// Keeps an unsuccessful task explanation available after a client restart.
/// It is cleared as soon as the user changes inputs or starts a new task, and
/// is restored only while every chapter-side task input still matches the
/// failed attempt. No prompt/body content is stored, only a one-way fingerprint
/// plus already-safe presentation details.
enum ChapterTaskOutcomeStore {
    private static let keyPrefix = "linoi.chapter-task-outcome"
    private static let currentFormatVersion = 2

    static func load(
        chapter: Chapter,
        defaults: UserDefaults? = nil
    ) -> ChapterTaskOutcome? {
        let defaults = defaults ?? DebugRuntimeConfiguration.defaults ?? .standard
        guard let data = defaults.data(forKey: key(chapterID: chapter.id)),
              let record = try? JSONDecoder().decode(CachedChapterTaskOutcome.self, from: data) else {
            return nil
        }
        guard record.formatVersion == currentFormatVersion,
              record.inputFingerprint == taskInputFingerprint(chapter) else {
            clear(chapterID: chapter.id, defaults: defaults)
            return nil
        }
        let stage = record.stageRawValue.flatMap(ChapterGenerationStage.init(rawValue:))
        // A finalized chapter already carries the current archive attention
        // returned by the server. The local record has no authoritative job
        // identity to compare with a retry started on another device, so even
        // an Extractor failure could replace a newer server reason. Discard
        // every finalized cache record and present `chapter.archive` instead.
        if chapter.status == "finalized" {
            clear(chapterID: chapter.id, defaults: defaults)
            return nil
        }
        let phase: ChapterWritingPhase
        switch record.kind {
        case .failed:
            phase = .failed(code: record.code, message: record.message, stage: stage)
        case .cancelled:
            phase = .cancelled(message: record.message, stage: stage)
        }
        return ChapterTaskOutcome(
            phase: phase,
            validationReason: record.validationReason,
            pendingExemptionNames: record.pendingExemptionNames ?? [],
            jobID: record.jobID
        )
    }

    static func save(
        phase: ChapterWritingPhase,
        chapter: Chapter,
        validationReason: String? = nil,
        pendingExemptionNames: [String] = [],
        jobID: String? = nil,
        defaults: UserDefaults? = nil
    ) {
        let defaults = defaults ?? DebugRuntimeConfiguration.defaults ?? .standard
        let record: CachedChapterTaskOutcome
        switch phase {
        case .failed(let code, let message, let stage):
            record = CachedChapterTaskOutcome(
                formatVersion: currentFormatVersion,
                kind: .failed,
                inputFingerprint: taskInputFingerprint(chapter),
                contentFingerprint: nil,
                message: message,
                code: code,
                stageRawValue: stage?.rawValue,
                validationReason: validationReason,
                pendingExemptionNames: pendingExemptionNames,
                jobID: jobID
            )
        case .cancelled(let message, let stage):
            record = CachedChapterTaskOutcome(
                formatVersion: currentFormatVersion,
                kind: .cancelled,
                inputFingerprint: taskInputFingerprint(chapter),
                contentFingerprint: nil,
                message: message,
                code: nil,
                stageRawValue: stage?.rawValue,
                validationReason: validationReason,
                pendingExemptionNames: pendingExemptionNames,
                jobID: jobID
            )
        default:
            return
        }
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key(chapterID: chapter.id))
    }

    static func clear(
        chapterID: String,
        defaults: UserDefaults? = nil
    ) {
        let defaults = defaults ?? DebugRuntimeConfiguration.defaults ?? .standard
        defaults.removeObject(forKey: key(chapterID: chapterID))
    }

    static func taskInputFingerprint(_ chapter: Chapter) -> String {
        let scalarParts = [
            chapter.title,
            chapter.userPrompt,
            chapter.draftText,
            chapter.longSummary,
            chapter.headline,
            chapter.characterLinks.map(\.characterId).sorted().joined(separator: "\u{1F}"),
            chapter.exemptedCharacterNames.sorted().joined(separator: "\u{1F}"),
        ]
        let canonical = scalarParts
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "\u{1E}")
        return ReaderPositionStore.fingerprint(canonical)
    }

    private static func key(chapterID: String) -> String {
        "\(keyPrefix).\(chapterID)"
    }
}

private struct ReaderPositionRecord: Codable {
    let contentFingerprint: String
    let relativeOffset: Double
}

/// Persists a relative reading position only while the chapter body still
/// matches the saved content version. A revised body deliberately opens at
/// the top instead of guessing an obsolete character or array offset.
enum ReaderPositionStore {
    private static let keyPrefix = "linoi.reader-position"

    static func load(bookID: String, chapterID: String, text: String) -> Double? {
        guard
            let data = UserDefaults.standard.data(forKey: key(bookID: bookID, chapterID: chapterID)),
            let record = try? JSONDecoder().decode(ReaderPositionRecord.self, from: data),
            record.contentFingerprint == fingerprint(text),
            record.relativeOffset.isFinite
        else {
            return nil
        }
        return min(max(record.relativeOffset, 0), 1)
    }

    static func save(
        bookID: String,
        chapterID: String,
        text: String,
        relativeOffset: Double
    ) {
        guard relativeOffset.isFinite else { return }
        let record = ReaderPositionRecord(
            contentFingerprint: fingerprint(text),
            relativeOffset: min(max(relativeOffset, 0), 1)
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: key(bookID: bookID, chapterID: chapterID))
    }

    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func key(bookID: String, chapterID: String) -> String {
        "\(keyPrefix).\(bookID).\(chapterID)"
    }
}

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case chapters = "章节"
    case characters = "人物"
    case settings = "设定"
    case agents = "Agent"
    var id: String { rawValue }
}

extension String {
    var checkerLabel: String {
        switch self {
        case "passed": return "通过"
        case "suspect": return "存疑"
        case "violation": return "明确越界"
        case "stale": return "检查已失效"
        case "unavailable": return "检查不可用"
        default: return self
        }
    }

    var linoStatusLabel: String {
        switch self {
        case "draft": return "草稿"
        case "writing": return "写作中"
        case "draft_ready": return "待接受"
        case "finalized": return "已完成"
        case "failed": return "失败"
        case "extracting": return "提取中"
        default: return self
        }
    }

    var linoAgentName: String {
        switch self {
        case "memory_selector": return "Memory Selector"
        case "writer": return "Writer"
        case "checker": return "Checker"
        case "extractor": return "Extractor"
        case "inspiration_creator": return "灵感创造师"
        default: return capitalized
        }
    }

    /// 后端时间戳统一解析入口。SQLite 经 SQLAlchemy 存取后返回的是丢了时区
    /// 标记的裸时间字符串（如 `"2026-07-11T05:57:11.827494"`，无 `Z`/偏移），
    /// 标准 `ISO8601DateFormatter` 解析它稳定返回 nil。后端 `utc_now()` 写库
    /// 前就是 UTC，所以裸字符串按 UTC 解释；同时保留标准 ISO8601（含时区）
    /// 分支，未来后端序列化换成带时区字符串也能直接命中。
    var linoBackendDate: Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: self) { return date }
        if let date = ISO8601DateFormatter().date(from: self) { return date }
        // Some Foundation versions fail the ISO8601 fractional-seconds branch
        // for six-digit microseconds followed by `Z`, so keep an explicit UTC
        // fallback in addition to the timezone-less SQLite formats.
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: self) { return date }
        }
        return nil
    }

    var linoShortDate: String {
        guard let date = linoBackendDate else { return "最近更新" }
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: "zh_CN")
        rel.unitsStyle = .short
        return rel.localizedString(for: date, relativeTo: Date())
    }
}
