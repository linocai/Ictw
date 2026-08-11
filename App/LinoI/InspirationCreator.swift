import Foundation

struct InspirationCard: Codable, Identifiable, Hashable, Sendable {
    var id: String { title + "\u{1f}" + body }
    let title: String
    let body: String
    let historyBasis: String?
    let note: String?
    let historyChapterIndexes: [Int]

    enum CodingKeys: String, CodingKey {
        case title, body, note
        case historyBasis = "history_basis"
        case historyChapterIndexes = "history_chapter_indexes"
    }
}

struct InspirationResponse: Codable, Hashable, Sendable {
    let cards: [InspirationCard]
}

struct InspirationRequestPayload: Encodable, Sendable {
    let title: String
    let bible: String
    let selectedCharacterIds: [String]
    let pacingBoundary: String

    enum CodingKeys: String, CodingKey {
        case title, bible
        case selectedCharacterIds = "selected_character_ids"
        case pacingBoundary = "pacing_boundary"
    }
}

struct InspirationSnapshot: Equatable, Sendable {
    let chapterID: String
    let title: String
    let bible: String
    let selectedCharacterIDs: [String]
    let pacingBoundary: String

    init(
        chapterID: String,
        title: String,
        bible: String,
        selectedCharacterIDs: [String],
        pacingBoundary: String = ""
    ) {
        self.chapterID = chapterID
        self.title = title
        self.bible = bible
        self.selectedCharacterIDs = Array(Set(selectedCharacterIDs)).sorted()
        self.pacingBoundary = InspirationDraftPolicy.normalizedPacingBoundary(pacingBoundary)
    }

    init(_ chapter: Chapter, pacingBoundary: String = "") {
        self.init(
            chapterID: chapter.id,
            title: chapter.title,
            bible: chapter.userPrompt,
            selectedCharacterIDs: chapter.characterLinks.map(\.characterId),
            pacingBoundary: pacingBoundary
        )
    }
}

struct InspirationUndo: Equatable, Sendable {
    let chapterID: String
    let before: String
    let after: String

    func canApply(chapterID: String, currentBible: String) -> Bool {
        self.chapterID == chapterID && currentBible == after
    }
}

enum InspirationDraftPolicy {
    static let maxPacingBoundaryCharacters = 500

    static func normalizedPacingBoundary(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxPacingBoundaryCharacters))
    }

    static func isStale(
        snapshot: InspirationSnapshot?,
        current: Chapter?,
        pacingBoundary: String = ""
    ) -> Bool {
        guard let snapshot, let current else { return false }
        return snapshot != InspirationSnapshot(current, pacingBoundary: pacingBoundary)
    }

    static func appending(body: String, to bible: String) -> String {
        bible.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? body
            : bible + "\n\n" + body
    }
}

enum InspirationErrorCopy {
    static func message(for error: Error) -> String {
        guard let apiError = error as? APIError else {
            return "这次灵感生成没有完成，请稍后重试。"
        }
        switch apiError {
        case .notConfigured:
            return "请先在设置中完成后端连接。"
        case .badURL:
            return "后端地址无效，请在设置中检查。"
        case .transport:
            return "暂时无法连接服务，请检查网络后重试。"
        case .http(let statusCode, let body):
            if statusCode == 404, body == "Not Found" {
                return "当前后端版本还不支持灵感创造师，请先更新后端。"
            }
            return body.isEmpty ? "灵感服务暂时不可用，请稍后重试。" : body
        case .validation(let code, let backendMessage, _):
            switch code {
            case "llm_profile_not_configured":
                return "灵感创造师还没有可用模型。请先到“设置 → Agent”为它绑定一个 Profile。"
            case "inspiration_invalid_response", "llm_invalid_response", "llm_output_truncated":
                return "这批结果没有整理出至少 3 条可用灵感，请再试一次。"
            case "inspiration_character_invalid":
                return "当前人物选择已发生变化，请刷新章节后重试。"
            case "llm_timeout":
                return "灵感生成超时，请稍后重试。"
            case "llm_content_blocked":
                return "上游模型拒绝了这次请求，可以调整 Bible 表达后再试。"
            case "llm_rate_limited", "llm_upstream_unavailable":
                return "模型服务暂时繁忙，请稍后重试。"
            default:
                return backendMessage.isEmpty ? "这次灵感生成没有完成，请稍后重试。" : backendMessage
            }
        }
    }
}
