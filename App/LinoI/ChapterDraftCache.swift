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
    static let currentVersion = 2
    var version: Int
    var chapterId: String
    var bookID: String?
    var bookTitle: String?
    var chapterIndex: Int?
    var title: String
    var userPrompt: String
    var targetWordCount: Int
    var authorNote: String
    var draftText: String
    var characterLinks: [ChapterLink]
    var exemptedCharacterNames: [String]
    var dirty: Bool
    /// Server-issued baseline for this edit. Device time is deliberately not
    /// used for cross-device ordering: clocks cannot prove which content won.
    var baseRevision: Int?
    var updatedAt: Date

    var shouldRestore: Bool {
        dirty
    }

    func shouldRestore(over remote: Chapter) -> Bool {
        guard shouldRestore else { return false }
        // Legacy drafts with no baseline remain usable only against the old
        // Backend response that also lacks a revision. Once a v2.1 server has
        // supplied a revision we refuse an automatic restore rather than risk
        // turning an unknown old local copy into a blind overwrite.
        guard let baseRevision else { return remote.contentRevision == 0 }
        return remote.contentRevision == 0 || baseRevision == remote.contentRevision
    }

    init(chapter: Chapter, dirty: Bool, bookTitle: String? = nil) {
        version = Self.currentVersion
        self.chapterId = chapter.id
        self.bookID = chapter.bookId
        self.bookTitle = bookTitle
        self.chapterIndex = chapter.index
        self.title = chapter.title
        self.userPrompt = chapter.userPrompt
        self.targetWordCount = chapter.targetWordCount
        self.authorNote = chapter.authorNote
        self.draftText = chapter.draftText
        self.characterLinks = chapter.characterLinks
        self.exemptedCharacterNames = chapter.exemptedCharacterNames
        self.dirty = dirty
        baseRevision = chapter.contentRevision > 0 ? chapter.contentRevision : nil
        self.updatedAt = Date()
    }

    func apply(to chapter: Chapter) -> Chapter {
        var copy = chapter
        copy.title = title
        copy.userPrompt = userPrompt
        copy.targetWordCount = targetWordCount
        copy.authorNote = authorNote
        copy.draftText = draftText
        copy.characterLinks = characterLinks
        copy.exemptedCharacterNames = exemptedCharacterNames
        return copy
    }

    enum CodingKeys: String, CodingKey {
        case version, chapterId, bookID, bookTitle, chapterIndex, title, userPrompt, targetWordCount, authorNote, draftText, characterLinks, exemptedCharacterNames
        case legacyChapterStyle = "chapterStyle"
        case dirty, baseRevision, updatedAt, cleanBaselineAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        chapterId = try container.decode(String.self, forKey: .chapterId)
        bookID = try container.decodeIfPresent(String.self, forKey: .bookID)
        bookTitle = try container.decodeIfPresent(String.self, forKey: .bookTitle)
        chapterIndex = try container.decodeIfPresent(Int.self, forKey: .chapterIndex)
        title = try container.decode(String.self, forKey: .title)
        userPrompt = try container.decode(String.self, forKey: .userPrompt)
        targetWordCount = try container.decodeIfPresent(Int.self, forKey: .targetWordCount) ?? 3000
        authorNote = try container.decodeIfPresent(String.self, forKey: .authorNote)
            ?? container.decodeIfPresent(String.self, forKey: .legacyChapterStyle)
            ?? ""
        draftText = try container.decode(String.self, forKey: .draftText)
        characterLinks = try container.decodeIfPresent([ChapterLink].self, forKey: .characterLinks) ?? []
        exemptedCharacterNames = try container.decodeIfPresent([String].self, forKey: .exemptedCharacterNames) ?? []
        dirty = try container.decode(Bool.self, forKey: .dirty)
        baseRevision = try container.decodeIfPresent(Int.self, forKey: .baseRevision)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(chapterId, forKey: .chapterId)
        try container.encodeIfPresent(bookID, forKey: .bookID)
        try container.encodeIfPresent(bookTitle, forKey: .bookTitle)
        try container.encodeIfPresent(chapterIndex, forKey: .chapterIndex)
        try container.encode(title, forKey: .title)
        try container.encode(userPrompt, forKey: .userPrompt)
        try container.encode(targetWordCount, forKey: .targetWordCount)
        try container.encode(authorNote, forKey: .authorNote)
        try container.encode(draftText, forKey: .draftText)
        try container.encode(characterLinks, forKey: .characterLinks)
        try container.encode(exemptedCharacterNames, forKey: .exemptedCharacterNames)
        try container.encode(dirty, forKey: .dirty)
        try container.encodeIfPresent(baseRevision, forKey: .baseRevision)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// This is an in-memory removal receipt, never another on-disk draft format.
/// Atomic cache writes replace the file identity even for identical contents.
struct LocalDraftFileSnapshot: Sendable {
    let chapterID: String
    let fileIdentity: String
    let data: Data
}

struct RetainedDraftError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ChapterDraftCache {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let root = DebugRuntimeConfiguration.dataRoot {
            self.directory = root.appendingPathComponent("ChapterDrafts", isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("LinoI/ChapterDrafts", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func load(chapterId: String) -> LocalChapterDraft? {
        let url = fileURL(chapterId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LocalChapterDraft.self, from: data)
    }

    /// Export scans cold drafts too. A malformed file is a visible preflight
    /// failure, never evidence that there was no local author content.
    func allDrafts() throws -> [LocalChapterDraft] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".checked-v") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try decoder.decode(LocalChapterDraft.self, from: Data(contentsOf: $0)) }
    }

    /// Only confirmed-deleted IDs are candidates. An unrelated malformed
    /// draft must not hide the recovery path for a deleted chapter.
    func retainedDraftFiles(chapterIDs: Set<String>) throws -> [(LocalChapterDraft, LocalDraftFileSnapshot)] {
        guard !chapterIDs.isEmpty else { return [] }
        let names: Set<String>
        do {
            names = Set(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .map(\.lastPathComponent))
        } catch {
            throw RetainedDraftError(message: "未能读取本机保留稿目录；请保留副本并检查本机存储后刷新。")
        }
        var result: [(LocalChapterDraft, LocalDraftFileSnapshot)] = []
        for chapterID in chapterIDs.sorted() {
            let url = fileURL(chapterID)
            guard names.contains(url.lastPathComponent) else { continue }
            let snapshot = try fileSnapshot(chapterID: chapterID)
            let draft: LocalChapterDraft
            do { draft = try decoder.decode(LocalChapterDraft.self, from: snapshot.data) }
            catch { throw RetainedDraftError(message: "有一份本机保留稿无法读取；副本仍保留，请重试刷新并检查本机存储。") }
            guard draft.chapterId == chapterID else {
                throw RetainedDraftError(message: "本机保留稿的文件身份不符；副本仍保留，请重试刷新。")
            }
            if draft.dirty { result.append((draft, snapshot)) }
        }
        return result
    }

    /// The caller is the main-actor Store, so ordinary app cache writes cannot
    /// interleave this synchronous compare and deletion. Never use remove(),
    /// which also clears a different checked-snapshot file.
    func removeRetained(_ snapshot: LocalDraftFileSnapshot) throws {
        let current = try fileSnapshot(chapterID: snapshot.chapterID)
        guard current.fileIdentity == snapshot.fileIdentity, current.data == snapshot.data,
              let draft = try? decoder.decode(LocalChapterDraft.self, from: current.data),
              draft.chapterId == snapshot.chapterID, draft.dirty else {
            throw RetainedDraftError(message: "这份本机保留稿已变化，未移除任何内容。请刷新并核对最新稿件，确认另存后再试。")
        }
        do { try FileManager.default.removeItem(at: fileURL(snapshot.chapterID)) }
        catch { throw RetainedDraftError(message: "未能移除这份本机保留稿；副本仍保留，请检查本机存储后重试。") }
    }

    /// Retains author input and its save time while freezing available source
    /// labels before the original server chapter disappears.
    @discardableResult
    func retainSource(chapterID: String, bookID: String, bookTitle: String?, chapterIndex: Int) -> Bool {
        guard var draft = load(chapterId: chapterID), draft.dirty else { return false }
        draft.bookID = bookID
        draft.bookTitle = bookTitle ?? draft.bookTitle
        draft.chapterIndex = chapterIndex
        return save(draft)
    }

    @discardableResult
    func saveClean(_ chapter: Chapter) -> Bool {
        let draft = LocalChapterDraft(chapter: chapter, dirty: false)
        return save(draft)
    }

    @discardableResult
    func saveDirty(_ chapter: Chapter, bookTitle: String? = nil) -> Bool {
        let draft = LocalChapterDraft(chapter: chapter, dirty: true,
            bookTitle: bookTitle ?? load(chapterId: chapter.id)?.bookTitle)
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

    private func fileSnapshot(chapterID: String) throws -> LocalDraftFileSnapshot {
        let url = fileURL(chapterID)
        do {
            let before = try fileIdentity(at: url)
            let data = try Data(contentsOf: url)
            guard try fileIdentity(at: url) == before else {
                throw RetainedDraftError(message: "本机保留稿正在变化，请刷新后再核对。未移除任何内容。")
            }
            return LocalDraftFileSnapshot(chapterID: chapterID, fileIdentity: before, data: data)
        } catch let error as RetainedDraftError { throw error }
        catch { throw RetainedDraftError(message: "未能读取这份本机保留稿；请保留副本并重试刷新。") }
    }

    private func fileIdentity(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let volume = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber else {
            throw RetainedDraftError(message: "本机保留稿的文件身份无法确认；未移除任何内容。")
        }
        return "\(volume.uint64Value):\(file.uint64Value)"
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
