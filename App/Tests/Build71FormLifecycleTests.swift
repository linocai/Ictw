import Foundation
import Combine

// Actual production handlers are inserted by the runner; only transport and
// presentation boundaries are held so failure/leave races can be reproduced.
// BUILD71:COORDINATOR
@MainActor final class Bus { var showNewBook = false, showSettings = false }
@MainActor final class Shortcut {
    enum Sheet: Equatable { case newBook, settings, dirtyForm }
    let commandBus = Bus()
    var sheet: Sheet?
    // BUILD71:SHORTCUTS
}
struct Draft: Equatable {
    var profileID = "profile", thinking = false, effort = "", temperature: Double? = 1
    var payload: String? { profileID }
}
@MainActor final class Transport {
    var continuation: CheckedContinuation<Bool, Never>?
    func saveBookModelBinding(bookID: String, role: String, binding: String) async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
    func load() async {}
    func loadBookModelBindings(bookID: String) async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ success: Bool) { continuation?.resume(returning: success); continuation = nil }
}
@MainActor final class Notices { func publish(_ value: String) {} }
@MainActor final class Session { let notices = Notices(); var currentBook: Book? }
struct Book { var id = "book" }
@MainActor final class ModelForm {
    let agents = Transport(), session = Session()
    let sheetLeaveCoordinator = V2IOSCharacterSheetLeaveCoordinator()
    let bookID = "book", role = "writer"
    var draft = Draft(), savedDraft = Draft(), row: String? = "row"
    var saving = false, showingLeaveConfirmation = false, dismissed = 0
    var loading = true, loadFailed = false
    func dismiss() { dismissed += 1 }
    func loadDraft() { savedDraft = draft }
    // BUILD71:MODEL_METHODS
}
@MainActor final class Shelf {
    var request: (String, String)?
    var continuation: CheckedContinuation<Book?, Never>?
    func createBook(title: String, world: String) async -> Book? {
        request = (title, world)
        return await withCheckedContinuation { continuation = $0 }
    }
}
@MainActor final class Editor { func persistLocalDraftIfNeeded() -> Bool { true } }
@MainActor enum V2IOSBookNavigation {
    static func prepare(editor: Editor, workspace: Int, characters: Int, inspiration: Int) -> Bool { true }
}
@MainActor final class NewBookForm {
    let editor = Editor(), bookshelf = Shelf(), session = Session()
    let workspace = 0, characters = 0, inspiration = 0
    var title = "书名", world = "世界观", creating = false, dismissed = 0
    func dismiss() { dismissed += 1 }
    // BUILD71:NEW_BOOK
}
extension String { var v2IOSTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }
@main struct Build71Forms {
    @MainActor static func main() async {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
        let shortcuts = Shortcut()
        for invoke in [shortcuts.newBookShelf, shortcuts.settingsShelf, shortcuts.newBookDesk, shortcuts.settingsDesk] {
            shortcuts.sheet = .dirtyForm; invoke(true)
            expect(shortcuts.sheet == .dirtyForm, "shortcut replaced dirty sheet")
            shortcuts.sheet = nil; invoke(true)
            expect(shortcuts.sheet != nil, "shortcut stopped opening an available sheet")
        }
        let form = ModelForm()
        form.draft.temperature = 0.8; form.syncSheetLeaveCoordinator()
        expect(form.isDirty && form.sheetLeaveCoordinator.blocksDismissal, "edited model must block sheet dismissal")
        form.sheetLeaveCoordinator.requestLeave()
        expect(form.showingLeaveConfirmation && form.dismissed == 0, "outer sheet must request confirmation")
        form.showingLeaveConfirmation = false; form.save()
        form.requestDismiss()
        expect(form.saving && !form.showingLeaveConfirmation && form.dismissed == 0, "saving cannot close")
        while form.agents.continuation == nil { await Task.yield() }
        form.agents.finish(false)
        while form.saving { await Task.yield() }
        form.requestDismiss()
        expect(form.isDirty && form.draft.temperature == 0.8 && form.showingLeaveConfirmation, "failed save must preserve input and leave guard")
        form.save()
        while form.agents.continuation == nil { await Task.yield() }
        form.agents.finish(true)
        while form.saving { await Task.yield() }
        form.requestDismiss()
        expect(!form.isDirty && form.dismissed == 1, "successful save permits dismissal")
        let loadingForm = ModelForm(); loadingForm.row = nil
        let loadTask = Task { await loadingForm.load() }
        while loadingForm.agents.continuation == nil { await Task.yield() }
        loadingForm.agents.finish(false); await loadTask.value
        expect(loadingForm.loadFailed, "no row must show recoverable failure")
        loadingForm.row = "late successful parent row"; loadingForm.recoverLoadedDraft()
        expect(!loadingForm.loadFailed, "parent success must recover superseded child read")
        loadingForm.draft.temperature = 0.6; loadingForm.loadFailed = true
        loadingForm.recoverLoadedDraft()
        expect(loadingForm.draft.temperature == 0.6 && loadingForm.isDirty, "late recovery must not overwrite author input")
        let book = NewBookForm(); book.create()
        expect(book.creating, "create must freeze synchronously")
        book.title = "late input"; book.world = "late world"
        while book.bookshelf.continuation == nil { await Task.yield() }
        expect(book.bookshelf.request?.0 == "书名" && book.bookshelf.request?.1 == "世界观", "request must use submitted snapshot")
        book.bookshelf.continuation?.resume(returning: nil)
        while book.creating { await Task.yield() }
        expect(book.dismissed == 0 && book.title == "late input", "failure must keep input")
        print("Build71 actual UI handlers: \(checks) passed")
    }
}
