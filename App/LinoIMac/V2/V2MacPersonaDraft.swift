import Foundation

/// The settings sheet owns this memory-only draft. A delayed initial load or
/// save can confirm only the scope and role that supplied its input.
struct V2MacPersonaDraft {
    enum Scope: Hashable {
        case global
        case book(String)
    }

    struct Context: Hashable {
        let role: String
        let scope: Scope
    }

    struct Submission {
        let id: UUID
        let context: Context
        let text: String
    }

    private(set) var context: Context?
    private struct Entry {
        var text = ""
        var baseline: String?
        var wasEdited = false
        var submissionID: UUID?
        var isEdited: Bool { baseline.map { text != $0 } ?? wasEdited }
    }
    private var entries: [Context: Entry] = [:]
    private var current: Entry { context.flatMap { entries[$0] } ?? Entry() }
    var text: String { current.text }
    var isLoaded: Bool { current.baseline != nil }
    var isEdited: Bool { current.isEdited }
    var isSaving: Bool { entries.values.contains { $0.submissionID != nil } }
    var hasUnsavedChanges: Bool { entries.values.contains { $0.isEdited } }

    mutating func select(_ context: Context) {
        guard !isSaving, self.context != context else { return }
        self.context = context
        if entries[context] == nil { entries[context] = Entry() }
    }

    mutating func load(_ value: String?, for context: Context) {
        guard self.context == context, let value else { return }
        var entry = entries[context] ?? Entry()
        let keepInput = entry.isEdited || entry.submissionID != nil
        entry.baseline = value
        if !keepInput { entry.text = value; entry.wasEdited = false }
        entries[context] = entry
    }

    mutating func edit(_ value: String) {
        guard !isSaving, let context else { return }
        var entry = entries[context] ?? Entry()
        entry.text = value
        entry.wasEdited = true
        entries[context] = entry
    }

    func canSubmit(in currentContext: Context?, requiresText: Bool = true) -> Bool {
        context != nil && context == currentContext && isLoaded && !isSaving
            && (!requiresText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    mutating func beginSubmit(in currentContext: Context?, requiresText: Bool = true) -> Submission? {
        guard canSubmit(in: currentContext, requiresText: requiresText), let context else { return nil }
        let id = UUID()
        entries[context]?.submissionID = id
        return Submission(id: id, context: context, text: text)
    }

    mutating func complete(
        _ submission: Submission, succeeded: Bool,
        currentContext: Context?, savedValue: String?
    ) {
        guard var entry = entries[submission.context], entry.submissionID == submission.id else { return }
        entry.submissionID = nil
        if succeeded, currentContext == submission.context {
            entry.text = savedValue ?? submission.text
            entry.baseline = entry.text
            entry.wasEdited = false
        }
        entries[submission.context] = entry
    }
}
