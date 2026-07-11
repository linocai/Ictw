import Foundation

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
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, title
        case worldSetting = "world_setting"
        case chapterCount = "chapter_count"
        case characterCount = "character_count"
        case updatedAt = "updated_at"
    }
}

struct ChapterLink: Codable, Hashable, Sendable {
    var characterId: String

    enum CodingKeys: String, CodingKey {
        case characterId = "character_id"
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
    var status: String
    var source: String
    var updatedAt: String
    var characterLinks: [ChapterLink]
    var exemptedCharacterNames: [String]

    enum CodingKeys: String, CodingKey {
        case id, index, title, summary, status, source, headline
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
        targetWordCount = try container.decode(Int.self, forKey: .targetWordCount)
        authorNote = try container.decodeIfPresent(String.self, forKey: .authorNote)
            ?? container.decodeIfPresent(String.self, forKey: .legacyChapterStyle)
            ?? ""
        draftText = try container.decode(String.self, forKey: .draftText)
        summary = try container.decode(String.self, forKey: .summary)
        headline = try container.decodeIfPresent(String.self, forKey: .headline) ?? ""
        status = try container.decode(String.self, forKey: .status)
        source = try container.decode(String.self, forKey: .source)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        characterLinks = try container.decodeIfPresent([ChapterLink].self, forKey: .characterLinks) ?? []
        exemptedCharacterNames = try container.decodeIfPresent([String].self, forKey: .exemptedCharacterNames) ?? []
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
        try container.encode(status, forKey: .status)
        try container.encode(source, forKey: .source)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(characterLinks, forKey: .characterLinks)
        try container.encode(exemptedCharacterNames, forKey: .exemptedCharacterNames)
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

    enum CodingKeys: String, CodingKey {
        case id, index, title, status, source
        case bookId = "book_id"
        case updatedAt = "updated_at"
    }
}

struct CharacterEvent: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let characterId: String
    let chapterId: String
    var eventType: String
    var eventText: String
    var chapterIndex: Int?

    enum CodingKeys: String, CodingKey {
        case id
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
    var events: [CharacterEvent]

    enum CodingKeys: String, CodingKey {
        case id, name, role, events
        case bookId = "book_id"
        case fixedProfile = "fixed_profile"
        case dynamicFields = "dynamic_fields"
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

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case systemPrompt = "system_prompt"
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

/// Additive per-failure context attached to a job's terminal `failed` phase
/// (backend `job_runs.error_context`, populated only for `LLMError`-sourced
/// failures). Old clients that never decode this key keep working off
/// `errorMessage` alone; `LinoErrorPresenter` uses it to name the failing
/// Agent/model and to surface the raw upstream/block reason verbatim.
struct JobErrorContext: Codable, Sendable {
    var agentRole: String?
    var modelName: String?
    var upstreamReason: String?
    var finishReason: String?
    var blockReason: String?
    var httpStatus: Int?

    enum CodingKeys: String, CodingKey {
        case agentRole = "agent_role"
        case modelName = "model_name"
        case upstreamReason = "upstream_reason"
        case finishReason = "finish_reason"
        case blockReason = "block_reason"
        case httpStatus = "http_status"
    }
}

/// Snapshot of a background write/extract job, returned by `POST /write`,
/// `POST /accept` and polled via `GET /chapters/{id}/job`. There is no more
/// SSE token stream — the client polls this endpoint until `phase` reaches a
/// terminal value (`done` / `failed` / `cancelled`).
struct WriteJobStatus: Codable, Sendable {
    var chapterId: String
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

    enum CodingKeys: String, CodingKey {
        case chapterId = "chapter_id"
        case kind, phase, attempt
        case errorCode = "error_code"
        case errorMessage = "error_message"
        case errorContext = "error_context"
        case violations, chapter
        case updatedCharacterIds = "updated_character_ids"
        case addedEventIds = "added_event_ids"
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
        case "reviser": return "Reviser"
        case "extractor": return "Extractor"
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
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
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
