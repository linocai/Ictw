import Foundation

/// A successful chapter DELETE may clear its editor while the author is already
/// elsewhere. List cleanup belongs to the book; navigation also belongs to
/// the exact selection that started the operation.
struct V2ChapterDeletionNavigation {
    let bookID: String
    let bookContextID: UUID
    let chapterID: String
    let navigationID: UUID

    func ownsBook(currentBookID: String?, currentBookContextID: UUID) -> Bool {
        currentBookID == bookID && currentBookContextID == bookContextID
    }

    func canBeginDeletion(
        currentBookID: String?, currentBookContextID: UUID,
        currentNavigationID: UUID, selectedChapterID: String?, editorChapterID: String?
    ) -> Bool {
        ownsBook(currentBookID: currentBookID, currentBookContextID: currentBookContextID)
            && currentNavigationID == navigationID
            && selectedChapterID == chapterID && editorChapterID == chapterID
    }

    func canNavigateAfterDeletion(
        currentBookID: String?, currentBookContextID: UUID,
        currentNavigationID: UUID, selectedChapterID: String?, editorChapterID: String?
    ) -> Bool {
        ownsBook(currentBookID: currentBookID, currentBookContextID: currentBookContextID)
            && currentNavigationID == navigationID && selectedChapterID == chapterID
            // The Store clears the editor only when its chapter and edit
            // revision still own the DELETE. Same-chapter later edits keep a
            // nonnil editor and therefore must not be navigated away from.
            && editorChapterID == nil
    }
}
