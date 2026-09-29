import Foundation

// The runner inserts the actual View methods at the markers below. This tests
// their async lifetime against a held transport without duplicating the save
// implementation. Native controls are verified separately in the Mac App.
@MainActor
final class FormSession {
    struct Book { var id = "book-a"; var title = "Book"; var worldSetting = "server world" }
    var currentBook: Book? = Book()
    var bookContextID = UUID()
}

@MainActor
final class HeldFormTransport {
    var worldRequests: [(String, String)] = []
    var createRequests: [(String, String, String)] = []
    var updateRequests: [Character] = []
    private var continuation: CheckedContinuation<Bool, Never>?
    private func wait() async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
    func saveBook(title: String, world: String) async -> Bool {
        worldRequests.append((title, world)); return await wait()
    }
    func create(name: String, role: String, fixedProfile: String) async -> Character? {
        createRequests.append((name, role, fixedProfile))
        return await wait() ? try! testCharacter(name: name) : nil
    }
    func update(_ character: Character) async -> Bool {
        updateRequests.append(character); return await wait()
    }
    func complete(_ succeeded: Bool) { let current = continuation; continuation = nil; current?.resume(returning: succeeded) }
}

@MainActor
final class FormShelf { func upsert(_ book: FormSession.Book) {} }

@MainActor
class WorldForm {
    let session = FormSession()
    let workspace = HeldFormTransport()
    let bookshelf = FormShelf()
    var title = "Book", world = "author world", text = "author world", initialText = "server world"
    var originalTitle = "Book", originalWorld = "server world"
    var loaded = true, saving = false, dismissed = 0
    var loadedID: String? = "book-a", loadedBookID: String? = "book-a"
    var loadedContextID: UUID?
    var submissionID: UUID?
    init() { loadedContextID = session.bookContextID }
    func dismiss() { dismissed += 1 }
}
@MainActor final class MacWorldForm: WorldForm {
    private var isDirty: Bool { title != originalTitle || world != originalWorld }
    private var ownsBook: Bool { session.currentBook?.id == loadedID && session.bookContextID == loadedContextID }
    // BUILD70:MAC_WORLD_SAVE
}
@MainActor final class IOSWorldForm: WorldForm {
    private var isDirty: Bool { loaded && text != initialText }
    // BUILD70:IOS_WORLD_SAVE
}

@MainActor
class NewPersonForm {
    let session = FormSession()
    let characters = HeldFormTransport()
    var name = "Author person", role = "Author role", traits = "Author profile", profile = "Author profile"
    var creating = false, saving = false, dismissed = 0
    var submissionID: UUID?
    func dismiss() { dismissed += 1 }
}
@MainActor final class MacNewPersonForm: NewPersonForm {
    // BUILD70:MAC_PERSON_CREATE
}
@MainActor final class IOSNewPersonForm: NewPersonForm {
    // BUILD70:IOS_PERSON_CREATE
}
@MainActor final class IOSPersonForm {
    let session = FormSession()
    let characters = HeldFormTransport()
    var original = try! testCharacter(name: "Server name")
    var edited = try! testCharacter(name: "Author name")
    var saving = false, dismissed = 0
    var submissionID: UUID?
    private var isDirty: Bool { edited != original }
    func dismiss() { dismissed += 1 }
    // BUILD70:IOS_PERSON_SAVE
}

func testCharacter(name: String) throws -> Character {
    let value: [String: Any] = ["id": "person-a", "book_id": "book-a", "name": name]
    return try JSONDecoder().decode(Character.self, from: JSONSerialization.data(withJSONObject: value))
}
extension String { var v2IOSTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

@main
struct Build70FormLifecycleTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) throws {
            checks += 1; guard condition else { throw Failure(message: message) }
        }
        func settle() async { for _ in 0..<20 { await Task.yield() } }

        let mac = MacWorldForm()
        mac.save(); mac.save()
        try expect(mac.saving, "Mac world save must lock synchronously before spawning a Task")
        await settle()
        try expect(mac.workspace.worldRequests.count == 1, "Two world submits must produce one request")
        mac.world = "later input"
        mac.workspace.complete(true); await settle()
        try expect(mac.originalWorld == "author world" && mac.world == "later input" && mac.dismissed == 0, "Mac success may confirm only its submitted snapshot")
        mac.save(); await settle(); mac.workspace.complete(false); await settle()
        try expect(!mac.saving && mac.world == "later input" && mac.dismissed == 0, "Mac failure must unlock and retain input")
        mac.save(); await settle(); mac.workspace.complete(true); await settle()
        try expect(mac.dismissed == 1, "A normal retry should save and close once")

        let ios = IOSWorldForm()
        ios.saveAndDismiss(); await settle()
        ios.text = "later iOS input"
        ios.workspace.complete(true); await settle()
        try expect(ios.initialText == "author world" && ios.text == "later iOS input" && ios.dismissed == 0, "iOS world must retain input beyond the submitted snapshot")
        ios.saveAndDismiss(); await settle(); ios.workspace.complete(false); await settle()
        try expect(!ios.saving && ios.text == "later iOS input", "iOS world failure must leave retryable input")

        let macContext = MacWorldForm()
        macContext.save(); await settle(); macContext.session.bookContextID = UUID()
        macContext.workspace.complete(true); await settle()
        try expect(macContext.dismissed == 0 && macContext.originalWorld == "server world", "Late Mac success cannot settle a reopened book context")
        let iosContext = IOSWorldForm()
        iosContext.saveAndDismiss(); await settle(); iosContext.session.currentBook?.id = "book-b"
        iosContext.workspace.complete(true); await settle()
        try expect(iosContext.dismissed == 0 && iosContext.initialText == "server world", "Late iOS success cannot acknowledge another book")
        let switchedBeforeStart = MacWorldForm()
        switchedBeforeStart.save(); switchedBeforeStart.session.bookContextID = UUID(); await settle()
        try expect(switchedBeforeStart.workspace.worldRequests.isEmpty && !switchedBeforeStart.saving, "A changed context before Task execution must not send the old input to the new book")

        let newMac = MacNewPersonForm()
        newMac.create(); newMac.create()
        try expect(newMac.creating, "Mac create must lock before any await")
        await settle()
        try expect(newMac.characters.createRequests.count == 1, "Repeated Mac create must send one POST")
        let sent = newMac.characters.createRequests[0]
        try expect(sent.0 == newMac.name && sent.1 == newMac.role && sent.2 == newMac.traits, "One POST must carry all three author fields")
        newMac.characters.complete(false); await settle()
        try expect(!newMac.creating && newMac.dismissed == 0 && newMac.name == "Author person", "Failed create must keep input and unlock")
        newMac.create(); await settle(); newMac.characters.complete(true); await settle()
        try expect(newMac.characters.createRequests.count == 2 && newMac.dismissed == 1, "Explicit retry must send one new POST and close on success")

        let newIOS = IOSNewPersonForm()
        newIOS.create(); newIOS.create(); await settle()
        try expect(newIOS.characters.createRequests.count == 1, "iOS create must remain single-flight")
        newIOS.profile = "newer profile"; newIOS.characters.complete(true); await settle()
        try expect(newIOS.dismissed == 0 && newIOS.profile == "newer profile", "iOS create success must not discard a different current input")
        let changedMac = MacNewPersonForm()
        changedMac.create(); await settle(); changedMac.session.currentBook?.id = "book-b"
        changedMac.characters.complete(true); await settle()
        try expect(changedMac.dismissed == 0, "Old-book create success cannot dismiss the current form")
        let inactive = MacNewPersonForm()
        inactive.create(); await settle(); inactive.submissionID = nil
        inactive.characters.complete(true); await settle()
        try expect(inactive.dismissed == 0, "Disappeared form must ignore its response")

        let person = IOSPersonForm()
        person.saveAndDismiss(); person.saveAndDismiss(); await settle()
        try expect(person.characters.updateRequests.count == 1, "Person save must be single-flight")
        person.edited.role = "new author role"
        person.characters.complete(true); await settle()
        try expect(person.original.name == "Author name" && person.original.role.isEmpty && person.edited.role == "new author role" && person.dismissed == 0, "Saved person baseline must reflect the submitted fields, not newer input")
        person.saveAndDismiss(); await settle(); person.characters.complete(false); await settle()
        try expect(!person.saving && person.edited.role == "new author role", "Person failure must preserve input for retry")
        person.saveAndDismiss(); await settle(); person.characters.complete(true); await settle()
        try expect(person.dismissed == 1 && person.original == person.edited, "Successful person retry should settle and close normally")
        print("Build70 actual View form lifecycle: \(checks) checks passed")
    }
    struct Failure: Error { let message: String }
}
