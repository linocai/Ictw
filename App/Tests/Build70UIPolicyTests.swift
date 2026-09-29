import Foundation

@main
struct Build70UIPolicyTests {
    static func main() throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            checks += 1
            guard condition else { throw Failure(message: message) }
        }
        let global = V2MacPersonaDraft.Context(role: "writer", scope: .global)
        let checker = V2MacPersonaDraft.Context(role: "checker", scope: .global)
        let book = V2MacPersonaDraft.Context(role: "writer", scope: .book("book-a"))
        var persona = V2MacPersonaDraft()
        persona.select(global); persona.load("original writer", for: global); persona.edit("my writer")
        persona.select(checker); persona.load("original checker", for: checker); persona.edit("my checker")
        persona.select(book); persona.load("book writer", for: book); persona.edit("my book writer")
        persona.select(global)
        try expect(persona.text == "my writer", "Writer draft must survive role and scope changes")
        persona.select(checker)
        try expect(persona.text == "my checker", "Checker draft must remain separate")
        persona.select(book)
        try expect(persona.text == "my book writer" && persona.hasUnsavedChanges, "Book persona must retain its own input")
        persona.load("a refreshed server value", for: book)
        try expect(persona.text == "my book writer", "A refresh must not replace an edited retained draft")
        let first = persona.beginSubmit(in: book)!
        persona.edit("blocked input"); persona.select(global)
        try expect(persona.text == first.text && persona.context == book, "In-flight persona must freeze input and scope")
        persona.complete(first, succeeded: false, currentContext: book, savedValue: nil)
        let retry = persona.beginSubmit(in: book)!
        persona.complete(first, succeeded: true, currentContext: book, savedValue: "late old confirmation")
        try expect(persona.isSaving && persona.text == retry.text, "An old same-scope response must not settle a retry")
        persona.complete(retry, succeeded: true, currentContext: book, savedValue: retry.text)
        try expect(!persona.isEdited && persona.hasUnsavedChanges, "Saving one scope must leave other scope drafts dirty")
        persona.select(global); persona.edit("original writer")
        try expect(!persona.isEdited, "Returning to the baseline must count as clean")

        let a = try character("a", book: "book-a", name: "Alice")
        let b = try character("b", book: "book-a", name: "Bob")
        let otherBookA = try character("a", book: "book-b", name: "Other Alice")
        let keyA = V2MacCharacterDrafts.Key(bookID: a.bookId, characterID: a.id)
        let keyB = V2MacCharacterDrafts.Key(bookID: b.bookId, characterID: b.id)
        let otherKey = V2MacCharacterDrafts.Key(bookID: otherBookA.bookId, characterID: otherBookA.id)
        var people = V2MacCharacterDrafts()
        people.load(a, for: keyA); people.edit(keyA, fallback: a, field: \.fixedProfile, value: "Alice author draft")
        people.load(b, for: keyB); people.edit(keyB, fallback: b, field: \.role, value: "Bob author role")
        people.load(a, for: keyA)
        try expect(people.value(for: keyA, fallback: a).fixedProfile == "Alice author draft", "Person A must survive A-B-A")
        try expect(people.value(for: keyB, fallback: b).role == "Bob author role", "Person B must retain separate input")
        people.load(otherBookA, for: otherKey)
        try expect(people.value(for: otherKey, fallback: otherBookA).name == "Other Alice", "Identical IDs in another book cannot inherit a draft")
        let sent = people.beginSubmit(keyA, fallback: a)!
        try expect(people.beginSubmit(keyB, fallback: b) == nil, "A sheet must submit only one person at a time")
        people.edit(keyA, fallback: a, field: \.name, value: "not allowed")
        try expect(people.value(for: keyA, fallback: a).name == a.name, "Input must be frozen while saving")
        people.complete(sent, succeeded: false)
        try expect(!people.isSaving && people.hasUnsavedChanges, "Failed save must keep all drafts for retry")
        let sentAgain = people.beginSubmit(keyA, fallback: a)!
        people.complete(sent, succeeded: true)
        try expect(people.isSaving, "Late previous completion must not settle a person retry")
        people.complete(sentAgain, succeeded: true)
        try expect(!people.isSaving && people.hasUnsavedChanges, "Saving A must not acknowledge B")
        people.remove(keyA)
        try expect(people.value(for: keyB, fallback: b).role == "Bob author role", "Deleting A must not remove B's draft")
        var changedB = b; changedB.name = "Server Bob"
        people.load(changedB, for: keyB)
        try expect(people.value(for: keyB, fallback: b).name == b.name, "A server refresh must not overwrite a dirty person's other fields")
        print("Build70 UI drafts: \(checks) checks passed")
    }

    static func character(_ id: String, book: String, name: String) throws -> Character {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "book_id": book, "name": name])
        return try JSONDecoder().decode(Character.self, from: data)
    }
    struct Failure: Error { let message: String }
}
