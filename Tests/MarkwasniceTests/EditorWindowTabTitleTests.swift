import Testing
@testable import Markwasnice

@Suite
struct EditorWindowTabTitleTests {
    @Test
    func marksUnsavedDocuments() {
        #expect(
            EditorWindowTabTitle.make(title: "Notes", isEdited: true) == "Notes •"
        )
    }

    @Test
    func leavesSavedDocumentsUntouched() {
        #expect(
            EditorWindowTabTitle.make(title: "Notes", isEdited: false) == "Notes"
        )
    }
}
