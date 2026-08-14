import Foundation

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

    enum CodingKeys: String, CodingKey {
        case id, title
        case worldSetting = "world_setting"
        case chapterCount = "chapter_count"
        case characterCount = "character_count"
        case archivePendingCount = "archive_pending_count"
        case archiveAttentionCount = "archive_attention_count"
        case updatedAt = "updated_at"
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
    }
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

    enum CodingKeys: String, CodingKey {
        case id, index, title, status, source
        case bookId = "book_id"
        case updatedAt = "updated_at"
        case archiveStatus = "archive_status"
        case archiveSchema = "archive_schema"
        case archiveCanRetry = "archive_can_retry"
        case archiveLatestAttemptStatus = "archive_latest_attempt_status"
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
    }

    init(
        id: String, bookId: String, index: Int, title: String, status: String,
        source: String, updatedAt: String, archiveStatus: String = "stale",
        archiveSchema: String = "none", archiveCanRetry: Bool = false,
        archiveLatestAttemptStatus: String? = nil
    ) {
        self.id = id; self.bookId = bookId; self.index = index; self.title = title
        self.status = status; self.source = source; self.updatedAt = updatedAt
        self.archiveStatus = archiveStatus; self.archiveSchema = archiveSchema
        self.archiveCanRetry = archiveCanRetry; self.archiveLatestAttemptStatus = archiveLatestAttemptStatus
    }
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
    let characterId: String
    let chapterId: String
    var eventType: String
    var eventText: String
    var chapterIndex: Int?
    var source: String?
    var editable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, source, editable
        case characterId = "character_id"
        case chapterId = "chapter_id"
        case eventType = "event_type"
        case eventText = "event_text"
        case chapterIndex = "chapter_index"
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

    enum CodingKeys: String, CodingKey {
        case id, name, role, events
        case bookId = "book_id"
        case fixedProfile = "fixed_profile"
        case dynamicFields = "dynamic_fields"
        case dynamicFieldsUpdatedChapterIndex = "dynamic_fields_updated_chapter_index"
    }
}

struct LLMProfile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var provider: String
    var baseURL: String
    var modelName: String

    enum CodingKeys: String, CodingKey {
        case id, name, provider
        case baseURL = "base_url"
        case modelName = "model_name"
    }
}

struct AgentPersona: Codable, Identifiable, Hashable, Sendable {
    var id: String { agentRole }
    var agentRole: String
    var systemPrompt: String
    var editablePersona: String
    var defaultPersona: String
    var programProtocol: String

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case systemPrompt = "system_prompt"
        case editablePersona = "editable_persona"
        case defaultPersona = "default_persona"
        case programProtocol = "program_protocol"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentRole = try container.decode(String.self, forKey: .agentRole)
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        editablePersona = try container.decodeIfPresent(String.self, forKey: .editablePersona) ?? systemPrompt
        defaultPersona = try container.decodeIfPresent(String.self, forKey: .defaultPersona) ?? editablePersona
        programProtocol = try container.decodeIfPresent(String.self, forKey: .programProtocol) ?? ""
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

    enum CodingKeys: String, CodingKey {
        case source
        case agentRole = "agent_role"
        case bookPersona = "book_persona"
        case globalPersona = "global_persona"
        case defaultPersona = "default_persona"
        case effectivePersona = "effective_persona"
        case programProtocol = "program_protocol"
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
struct JobErrorContext: Codable, Sendable {
    var agentRole: String?
    var modelName: String?
    var upstreamReason: String?
    var finishReason: String?
    var blockReason: String?
    var httpStatus: Int?
    var completionWarning: String?
    var droppedStateComponents: Int?

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case modelName = "model_name"
        case upstreamReason = "upstream_reason"
        case finishReason = "finish_reason"
        case blockReason = "block_reason"
        case httpStatus = "http_status"
        case completionWarning = "completion_warning"
        case droppedStateComponents = "dropped_state_components"
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
    var errorMessage: String?
    var errorContext: JobErrorContext?
    var violations: [Violation]?
    var chapter: Chapter?
    var updatedCharacterIds: [String]?
    var addedEventIds: [String]?
    var memoryContext: MemoryContext? = nil
    var checkerResult: CheckerResult? = nil
    var visibleCheckerResult: CheckerResult? = nil

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
    var id: String { "\(kind)|\(draftEvidence)|\(bibleEvidence)" }
    var kind: String
    var draftEvidence: String
    var bibleEvidence: String
    var reason: String
    enum CodingKeys: String, CodingKey { case kind, reason; case draftEvidence = "draft_evidence"; case bibleEvidence = "bible_evidence" }
}

struct CheckerResult: Codable, Hashable, Sendable {
    var verdict: String?
    var status: String?
    var draftFingerprint: String?
    var issues: [CheckerIssue]?
    var errorCode: String?
    var wasOverridden: Bool?
    enum CodingKeys: String, CodingKey {
        case verdict, status, issues
        case draftFingerprint = "draft_fingerprint"
        case errorCode = "error_code"
        case wasOverridden = "override"
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

    static func resolve(status: String, canRetry: Bool) -> Self {
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
    enum CodingKeys: String, CodingKey { case checkerResult = "checker_result" }
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
        case "failed", "cancelled":
            if hasLocalInputDivergence || chapter.status == "finalized" {
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

    var label: String {
        switch self {
        case .memorySelection: return "整理记忆"
        case .drafting: return "整章写作"
        case .deterministicValidation: return "确定性校验"
        case .bibleChecking: return "Bible 检查"
        case .extraction: return "提取归档"
        case .completed: return "完成"
        }
    }
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
    case failed(code: String?, message: String, stage: ChapterGenerationStage?)
    case cancelled(message: String, stage: ChapterGenerationStage?)

    var isActive: Bool {
        switch self {
        case .selectingMemory, .writing, .writingAttempt, .validating, .checking, .legacyRevising, .extracting: return true
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
        case .extracting: return "extracting"
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
            uniqueKeysWithValues: ChapterGenerationStage.allCases.map { ($0, ChapterGenerationStepState.pending) }
        )

        func complete(before stage: ChapterGenerationStage) {
            for candidate in ChapterGenerationStage.allCases where candidate.rawValue < stage.rawValue {
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
        case .failed(let code, _, let stage):
            let failedStage = stage ?? .drafting
            complete(before: failedStage)
            states[failedStage] = .failed
            failureCode = code
        case .cancelled(_, let stage):
            let cancelledStage = stage ?? .drafting
            complete(before: cancelledStage)
            states[cancelledStage] = .cancelled
        case .idle:
            switch chapterStatus {
            case "finalized":
                for stage in ChapterGenerationStage.allCases {
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
            if let failureCode, requiresUserChange.contains(failureCode) {
                recoveryAction = nil
            } else {
                recoveryAction = stage == .extraction ? .retryExtraction : .retryGeneration
            }
        } else {
            recoveryAction = nil
        }

        return ChapterEditorPresentationState(
            steps: ChapterGenerationStage.allCases.map {
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
        defaults: UserDefaults = .standard
    ) -> ChapterTaskOutcome? {
        guard chapter.status != "finalized" else {
            clear(chapterID: chapter.id, defaults: defaults)
            return nil
        }
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
        defaults: UserDefaults = .standard
    ) {
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
        defaults: UserDefaults = .standard
    ) {
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
