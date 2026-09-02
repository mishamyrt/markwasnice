import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownStylingControllerTests {
    @Test
    func textChangeInvalidatesSameLengthParseBeforeDebounce() async throws {
        let editor = MarkdownEditorView(settings: EditorSettings(
            textSizeScale: 1,
            maxTextColumns: 64,
            tabInsertionMode: .spaces,
            tabWidth: 4
        ))
        let controller = MarkdownStylingController(editorView: editor)
        editor.setString("**aa**", clearsUndo: true)
        controller.scheduleParse(text: "**aa**")

        var attempts = 0
        while controller.freshStyleSpans == nil, attempts < 200 {
            try await Task.sleep(for: .milliseconds(5))
            attempts += 1
        }
        #expect(controller.freshStyleSpans != nil)

        editor.setString("__aa__", clearsUndo: false)
        controller.invalidateText()

        #expect(controller.freshStyleSpans == nil)
    }
}
