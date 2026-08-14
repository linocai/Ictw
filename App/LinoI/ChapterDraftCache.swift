import Foundation

/// A local-only, versioned record of the latest Checker result that is known
/// to apply to a complete visible draft. It is never uploaded and never used
/// to authorize acceptance; it only makes stale UI evidence honest.
struct CheckedDraftSnapshot: Codable, Hashable, Sendable {
    static let currentVersion = 1
    let version: Int
    let chapterID: String
    let draftText: String
    let inputFingerprint: String
    let checkerResult: CheckerResult
    let savedAt: Date

    init(chapter: Chapter, checkerResult: CheckerResult) {
        version = Self.currentVersion
        chapterID = chapter.id
        draftText = chapter.draftText
        inputFingerprint = Self.fingerprint(for: chapter)
        self.checkerResult = checkerResult
        savedAt = Date()
    }

    func applies(to chapter: Chapter) -> Bool {
        version == Self.currentVersion
            && chapterID == chapter.id
            && draftText == chapter.draftText
            && inputFingerprint == Self.fingerprint(for: chapter)
    }

    static func fingerprint(for chapter: Chapter) -> String {
        // Length-prefixing makes the serialized input unambiguous without
        // introducing another platform-specific crypto dependency.
        let links = chapter.characterLinks.map(\.characterId).sorted().joined(separator: "\u{1F}")
        let values = [chapter.title, chapter.userPrompt, chapter.authorNote, links, chapter.draftText]
        return values.map { "\($0.utf8.count):\($0)" }.joined(separator: "\u{1E}")
    }
}

enum CheckedDraftSentenceDiff {
    /// Sentence-level diff only runs when a real snapshot exists. The range
    /// list is intentionally deterministic and does not claim a semantic
    /// rewrite explanation for a missing local baseline.
    static func changedRanges(previous: String, current: String) -> [Range<String.Index>] {
        guard previous != current else { return [] }
        let old = sentences(previous)
        let new = sentences(current)
        var oldCounts: [String: Int] = [:]
        old.forEach { oldCounts[$0.text, default: 0] += 1 }
        return new.compactMap { sentence in
            guard (oldCounts[sentence.text] ?? 0) > 0 else { return sentence.range }
            oldCounts[sentence.text, default: 0] -= 1
            return nil
        }
    }

    private static func sentences(_ text: String) -> [(text: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start = text.startIndex
        for index in text.indices {
            guard "。！？!?\n".contains(text[index]) else { continue }
            let end = text.index(after: index)
            let range = start..<end
            let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append((value, range)) }
            start = end
        }
        if start < text.endIndex {
            let range = start..<text.endIndex
            let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append((value, range)) }
        }
        return result
    }
}

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
        targetWordCount = try container.decodeIfPresent(Int.self, forKey: .targetWordCount) ?? 3000
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
        // v1.6 local drafts deliberately stop persisting retired writing inputs.
        // The decoder above still reads old cache files for a safe restore.
        try container.encode(draftText, forKey: .draftText)
        try container.encode(characterLinks, forKey: .characterLinks)
        try container.encode(dirty, forKey: .dirty)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(cleanBaselineAt, forKey: .cleanBaselineAt)
    }

    private static func parseRemoteDate(_ raw: String) -> Date? {
        raw.linoBackendDate
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

    @discardableResult
    func saveClean(_ chapter: Chapter) -> Bool {
        let draft = LocalChapterDraft(chapter: chapter, dirty: false, cleanBaselineAt: Date())
        return save(draft)
    }

    @discardableResult
    func saveDirty(_ chapter: Chapter) -> Bool {
        let existing = load(chapterId: chapter.id)
        let draft = LocalChapterDraft(
            chapter: chapter,
            dirty: true,
            cleanBaselineAt: existing?.cleanBaselineAt
        )
        return save(draft)
    }

    func remove(chapterId: String) {
        try? FileManager.default.removeItem(at: fileURL(chapterId))
        try? FileManager.default.removeItem(at: checkedSnapshotURL(chapterId))
    }

    func loadCheckedSnapshot(chapterId: String) -> CheckedDraftSnapshot? {
        guard let data = try? Data(contentsOf: checkedSnapshotURL(chapterId)) else { return nil }
        guard let snapshot = try? decoder.decode(CheckedDraftSnapshot.self, from: data),
              snapshot.version == CheckedDraftSnapshot.currentVersion,
              snapshot.checkerResult.hasConcreteVerdict else { return nil }
        return snapshot
    }

    @discardableResult
    func saveCheckedSnapshot(_ snapshot: CheckedDraftSnapshot) -> Bool {
        guard snapshot.checkerResult.hasConcreteVerdict else { return false }
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: checkedSnapshotURL(snapshot.chapterID), options: [.atomic])
            return true
        } catch { return false }
    }

    private func save(_ draft: LocalChapterDraft) -> Bool {
        do {
            let data = try encoder.encode(draft)
            try data.write(to: fileURL(draft.chapterId), options: [.atomic])
            return true
        } catch {
            #if DEBUG
            print("ChapterDraftCache save failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    private func fileURL(_ chapterId: String) -> URL {
        let safe = chapterId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    private func checkedSnapshotURL(_ chapterId: String) -> URL {
        let safe = chapterId.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).checked-v\(CheckedDraftSnapshot.currentVersion).json")
    }
}
