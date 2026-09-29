import Foundation

@main
struct Build69UIPolicyTests {
    static func main() throws {
        if CommandLine.arguments.contains("--deletion-only") {
            try deletionNavigationChecks()
            return
        }
        let global = V2MacPersonaDraft.Context(role: "writer", scope: .global)
        let bookA = V2MacPersonaDraft.Context(role: "writer", scope: .book("synthetic-a"))
        let bookB = V2MacPersonaDraft.Context(role: "writer", scope: .book("synthetic-b"))
        let checker = V2MacPersonaDraft.Context(role: "checker", scope: .global)
        var checks = 0
        func expect(_ value: Bool, _ message: String) throws {
            checks += 1
            guard value else { throw TestFailure(message: message) }
        }

        var draft = V2MacPersonaDraft()
        draft.select(global)
        draft.edit("author input before load")
        try expect(draft.beginSubmit(in: global) == nil, "Unloaded input must not be saved")
        draft.load("server value", for: global)
        try expect(draft.text == "author input before load" && draft.isLoaded, "Initial load must preserve early author input")
        draft.load("other role", for: checker)
        try expect(draft.text == "author input before load", "Wrong-role load must not replace the draft")

        let failed = draft.beginSubmit(in: global)!
        try expect(draft.beginSubmit(in: global) == nil, "Duplicate submit must be blocked")
        draft.select(bookA)
        draft.edit("edited while saving")
        try expect(draft.context == global && draft.text == failed.text, "Scope and input must remain frozen while saving")
        draft.complete(failed, succeeded: false, currentContext: global, savedValue: "server value")
        try expect(draft.text == failed.text && draft.isEdited && !draft.isSaving, "Save failure must keep input ready for retry")
        let retried = draft.beginSubmit(in: global)!
        draft.complete(retried, succeeded: true, currentContext: global, savedValue: retried.text)
        try expect(draft.text == retried.text && !draft.isEdited, "Confirmed retry must acknowledge the submitted input")

        draft.select(bookA)
        draft.load("book source", for: bookA)
        draft.edit("book author input")
        try expect(draft.beginSubmit(in: nil) == nil && draft.beginSubmit(in: bookB) == nil, "Lost or changed book must not fall back to another scope")
        let late = draft.beginSubmit(in: bookA)!
        draft.complete(late, succeeded: true, currentContext: bookB, savedValue: "other book")
        try expect(draft.text == "book author input" && draft.isEdited && !draft.isSaving, "Late success after book change must preserve the old draft")
        draft.select(global)
        draft.load("new global source", for: global)
        draft.edit("new global input")
        let current = draft.beginSubmit(in: global)!
        draft.complete(late, succeeded: true, currentContext: global, savedValue: "late old book")
        try expect(draft.text == "new global input" && draft.isSaving, "Old-scope completion must not settle a new submission")
        draft.complete(current, succeeded: false, currentContext: global, savedValue: nil)

        draft.select(checker)
        draft.load("", for: checker)
        try expect(draft.beginSubmit(in: checker) == nil, "A loaded but empty default must not be saved")
        draft.edit("  \n ")
        try expect(draft.beginSubmit(in: checker) == nil, "Whitespace-only persona must not be saved")
        let reset = draft.beginSubmit(in: checker, requiresText: false)!
        draft.complete(reset, succeeded: false, currentContext: checker, savedValue: "reset source")
        try expect(draft.text == "  \n " && draft.isEdited, "Restore failure must keep author input")
        let resetRetry = draft.beginSubmit(in: checker, requiresText: false)!
        draft.complete(resetRetry, succeeded: true, currentContext: checker, savedValue: "confirmed reset")
        try expect(draft.text == "confirmed reset" && !draft.isEdited, "Only successful restore may replace the draft")
        print("Build69 UI policy: \(checks) checks passed")
        try deletionNavigationChecks()
    }

    static func deletionNavigationChecks() throws {
        let bookContext = UUID()
        let navigation = UUID()
        let receipt = V2ChapterDeletionNavigation(
            bookID: "synthetic-book", bookContextID: bookContext,
            chapterID: "last-chapter", navigationID: navigation
        )
        var checks = 0
        func expect(_ value: Bool, _ message: String) throws {
            checks += 1
            guard value else { throw TestFailure(message: message) }
        }
        func canBegin(book: String? = "synthetic-book", context: UUID? = nil, nav: UUID? = nil,
                      selected: String? = "last-chapter", editor: String? = "last-chapter") -> Bool {
            receipt.canBeginDeletion(
                currentBookID: book, currentBookContextID: context ?? bookContext,
                currentNavigationID: nav ?? navigation,
                selectedChapterID: selected, editorChapterID: editor
            )
        }
        func canNavigate(book: String? = "synthetic-book", context: UUID? = nil, nav: UUID? = nil,
                         selected: String? = "last-chapter", editor: String? = nil) -> Bool {
            receipt.canNavigateAfterDeletion(
                currentBookID: book, currentBookContextID: context ?? bookContext,
                currentNavigationID: nav ?? navigation,
                selectedChapterID: selected, editorChapterID: editor
            )
        }

        try expect(canBegin(), "Stable selection must start the requested DELETE")
        try expect(!canBegin(editor: "earlier-chapter"), "Delayed Task must not delete a newly loaded chapter")
        try expect(!canBegin(selected: "earlier-chapter"), "Pending navigation must not start an old DELETE")
        let abaNavigation = UUID()
        try expect(!canBegin(nav: abaNavigation), "A-B-A before Task start must invalidate the DELETE")
        try expect(!canBegin(context: UUID()), "Closed and reopened book must not reuse the old request")
        try expect(canNavigate(), "Normal successful DELETE with a cleared editor must navigate")
        try expect(!canNavigate(editor: "last-chapter"), "Same-chapter later edits kept by Store must remain visible")
        try expect(!canNavigate(selected: "earlier-chapter", editor: "earlier-chapter"), "Deleting a different chapter must not leave the author's current chapter")
        try expect(!canNavigate(nav: abaNavigation), "A-B-A while DELETE or refresh waits must invalidate navigation even with nil editor")
        try expect(!canNavigate(selected: nil), "An independently closed path must not be replaced")
        try expect(!canNavigate(book: "other-book"), "Cross-book completion must not navigate")
        try expect(!canNavigate(context: UUID()), "Book epoch change while refresh waits must not navigate")
        try expect(receipt.ownsBook(currentBookID: "synthetic-book", currentBookContextID: bookContext), "Same-book cleanup may proceed even when chapter navigation changed")
        try expect(!receipt.ownsBook(currentBookID: "other-book", currentBookContextID: bookContext), "Old DELETE must not remove a row/cache from the new book")
        try expect(!receipt.ownsBook(currentBookID: "synthetic-book", currentBookContextID: UUID()), "Late cleanup must not bind itself to a reopened session")
        print("Build69 deletion navigation: \(checks) checks passed")
    }

    struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
