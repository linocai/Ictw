import Foundation

/// A people sheet retains each person's input until it is saved or the author
/// explicitly discards the sheet. Book identity prevents drafts crossing books.
struct V2MacCharacterDrafts {
    struct Key: Hashable {
        let bookID: String
        let characterID: String
    }
    struct Submission {
        let id: UUID
        let key: Key
        let character: Character
    }
    private struct Entry {
        var original: Character
        var edited: Character
        var submissionID: UUID?
        var isDirty: Bool {
            original.name != edited.name || original.role != edited.role
                || original.fixedProfile != edited.fixedProfile
        }
    }
    private var entries: [Key: Entry] = [:]
    var isSaving: Bool { entries.values.contains { $0.submissionID != nil } }
    var hasUnsavedChanges: Bool { entries.values.contains { $0.isDirty } }

    func value(for key: Key, fallback: Character) -> Character {
        entries[key]?.edited ?? fallback
    }

    mutating func load(_ character: Character, for key: Key) {
        guard let existing = entries[key] else {
            entries[key] = Entry(original: character, edited: character)
            return
        }
        guard !existing.isDirty, existing.submissionID == nil else { return }
        entries[key] = Entry(original: character, edited: character)
    }

    mutating func edit(_ key: Key, fallback: Character, field: WritableKeyPath<Character, String>, value: String) {
        guard !isSaving else { return }
        if entries[key] == nil { load(fallback, for: key) }
        entries[key]?.edited[keyPath: field] = value
    }

    mutating func beginSubmit(_ key: Key, fallback: Character) -> Submission? {
        guard !isSaving else { return nil }
        if entries[key] == nil { load(fallback, for: key) }
        guard let entry = entries[key], !entry.edited.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let id = UUID()
        entries[key]?.submissionID = id
        return Submission(id: id, key: key, character: entry.edited)
    }

    mutating func complete(_ submission: Submission, succeeded: Bool) {
        guard var entry = entries[submission.key], entry.submissionID == submission.id else { return }
        entry.submissionID = nil
        if succeeded {
            entry.original = submission.character
            entry.edited = submission.character
        }
        entries[submission.key] = entry
    }

    mutating func remove(_ key: Key) { entries.removeValue(forKey: key) }
}
