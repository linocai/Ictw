import Foundation

struct LocalChapterDraft: Codable {
    var chapterId: String
    var title: String
    var userPrompt: String
    var targetWordCount: Int
    var authorNote: String
    var draftText: String
    var characterLinks: [ChapterLink]
    var dirty: Bool
    var updatedAt: Date
    var cleanBaselineAt: Date?

    var shouldRestore: Bool {
        guard dirty else { return false }
        guard let cleanBaselineAt else { return true }
        return updatedAt > cleanBaselineAt
    }

    func shouldRestore(over remote: Chapter) -> Bool {
        guard shouldRestore else { return false }
        guard let remoteUpdatedAt = Self.parseRemoteDate(remote.updatedAt) else { return true }
        return updatedAt > remoteUpdatedAt
    }

    init(chapter: Chapter, dirty: Bool, cleanBaselineAt: Date?) {
        self.chapterId = chapter.id
        self.title = chapter.title
        self.userPrompt = chapter.userPrompt
        self.targetWordCount = chapter.targetWordCount
        self.authorNote = chapter.authorNote
        self.draftText = chapter.draftText
        self.characterLinks = chapter.characterLinks
        self.dirty = dirty
        self.updatedAt = Date()
        self.cleanBaselineAt = cleanBaselineAt
    }

    func apply(to chapter: Chapter) -> Chapter {
        var copy = chapter
        copy.title = title
        copy.userPrompt = userPrompt
        copy.targetWordCount = targetWordCount
        copy.authorNote = authorNote
        copy.draftText = draftText
        copy.characterLinks = characterLinks
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case chapterId, title, userPrompt, targetWordCount, authorNote, draftText, characterLinks
        case legacyChapterStyle = "chapterStyle"
        case dirty, updatedAt, cleanBaselineAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chapterId = try container.decode(String.self, forKey: .chapterId)
        title = try container.decode(String.self, forKey: .title)
        userPrompt = try container.decode(String.self, forKey: .userPrompt)
        targetWordCount = try container.decode(Int.self, forKey: .targetWordCount)
        authorNote = try container.decodeIfPresent(String.self, forKey: .authorNote)
            ?? container.decodeIfPresent(String.self, forKey: .legacyChapterStyle)
            ?? ""
        draftText = try container.decode(String.self, forKey: .draftText)
        characterLinks = try container.decodeIfPresent([ChapterLink].self, forKey: .characterLinks) ?? []
        dirty = try container.decode(Bool.self, forKey: .dirty)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        cleanBaselineAt = try container.decodeIfPresent(Date.self, forKey: .cleanBaselineAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chapterId, forKey: .chapterId)
        try container.encode(title, forKey: .title)
        try container.encode(userPrompt, forKey: .userPrompt)
        try container.encode(targetWordCount, forKey: .targetWordCount)
        try container.encode(authorNote, forKey: .authorNote)
        try container.encode(draftText, forKey: .draftText)
        try container.encode(characterLinks, forKey: .characterLinks)
        try container.encode(dirty, forKey: .dirty)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(cleanBaselineAt, forKey: .cleanBaselineAt)
    }

    private static func parseRemoteDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw)
    }
}

final class ChapterDraftCache {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("LinoI/ChapterDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load(chapterId: String) -> LocalChapterDraft? {
        let url = fileURL(chapterId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LocalChapterDraft.self, from: data)
    }

    func saveClean(_ chapter: Chapter) {
        let draft = LocalChapterDraft(chapter: chapter, dirty: false, cleanBaselineAt: Date())
        save(draft)
    }

    func saveDirty(_ chapter: Chapter) {
        let existing = load(chapterId: chapter.id)
        let draft = LocalChapterDraft(
            chapter: chapter,
            dirty: true,
            cleanBaselineAt: existing?.cleanBaselineAt
        )
        save(draft)
    }

    func remove(chapterId: String) {
        try? FileManager.default.removeItem(at: fileURL(chapterId))
    }

    private func save(_ draft: LocalChapterDraft) {
        do {
            let data = try encoder.encode(draft)
            try data.write(to: fileURL(draft.chapterId), options: [.atomic])
        } catch {
            #if DEBUG
            print("ChapterDraftCache save failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func fileURL(_ chapterId: String) -> URL {
        let safe = chapterId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }
}
