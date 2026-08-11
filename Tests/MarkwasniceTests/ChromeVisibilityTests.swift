import Testing

@testable import Markwasnice

@MainActor
struct ChromeVisibilityTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeSession() -> EditorDocumentSession {
        EditorDocumentSession(
            text: "",
            fileURL: nil,
            isEdited: false,
            settings: Self.settings,
        ) {}
    }

    @Test func hoverRevealsEachBarWithoutHidingTheOther() {
        let session = makeSession()
        let state = session.shellState

        session.markdownEditorViewDidScroll(session.editorView)
        #expect(!state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)

        state.onToolbarHoverChanged?(true)
        #expect(state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)

        state.onStatusBarHoverChanged?(true)
        #expect(state.isToolbarVisible)
        #expect(state.isStatusBarVisible)

        session.markdownEditorViewDidScroll(session.editorView)
        state.onStatusBarHoverChanged?(true)
        #expect(!state.isToolbarVisible)
        #expect(state.isStatusBarVisible)

        state.onToolbarHoverChanged?(true)
        #expect(state.isToolbarVisible)
        #expect(state.isStatusBarVisible)
    }

    @Test func typingAndScrollingHideBothBars() {
        let session = makeSession()
        let state = session.shellState

        session.markdownEditorViewDidScroll(session.editorView)
        #expect(!state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)

        state.onToolbarHoverChanged?(true)
        state.onStatusBarHoverChanged?(true)
        session.editorView.setString("a", clearsUndo: false)
        session.markdownEditorViewDidChangeText(session.editorView)
        #expect(!state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)
    }

    @Test func selectionDoesNotChangeStatusBarVisibility() {
        let session = makeSession()
        let state = session.shellState

        session.markdownEditorViewDidScroll(session.editorView)
        session.markdownEditorView(
            session.editorView,
            didChangeSelectionText: "Two selected sentences. Really!"
        )

        #expect(!state.isStatusBarVisible)
        #expect(state.characterCountText == "31 characters")
        #expect(state.wordCountText == "4 words")
        #expect(state.sentenceCountText == "2 sentences")

        state.onStatusBarHoverChanged?(true)
        #expect(state.isStatusBarVisible)

        session.markdownEditorViewDidScroll(session.editorView)
        #expect(!state.isStatusBarVisible)
    }
}
