import Foundation
import Testing
@testable import Markwasnice

@MainActor
struct EditorSearchPresentationTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeSession(text: String) -> EditorDocumentSession {
        EditorDocumentSession(
            text: text,
            fileURL: nil,
            isEdited: false,
            settings: Self.settings
        ) {}
    }

    @Test func selectedTextBecomesTheSearchQuery() {
        let text = "alpha beta alpha"
        let session = makeSession(text: text)
        session.shellState.setSearchQuery("alpha")
        session.editorView.textView.setSelectedRange(
            (text as NSString).range(of: "beta")
        )

        session.showSearch()

        #expect(session.shellState.isSearchPresented)
        #expect(session.shellState.searchQuery == "beta")
        #expect(session.shellState.searchMatchCount == 1)
    }

    @Test func searchQueryIsPreservedWithoutASelection() {
        let text = "alpha beta alpha"
        let session = makeSession(text: text)
        session.shellState.setSearchQuery("alpha")
        session.editorView.textView.setSelectedRange(
            NSRange(location: 6, length: 0)
        )

        session.showSearch()

        #expect(session.shellState.searchQuery == "alpha")
        #expect(session.shellState.searchMatchCount == 2)
    }
}
