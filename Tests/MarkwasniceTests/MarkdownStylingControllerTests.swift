import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownStylingControllerTests {
    @Test(arguments: [false, true])
    func appearanceChangesKeepTranslatedSpans(resizesWindow: Bool) async throws {
        let settings = EditorSettings(
            textSizeScale: 1,
            maxTextColumns: 64,
            tabInsertionMode: .spaces,
            tabWidth: 4
        )
        let editor = MarkdownEditorView(settings: settings)
        let controller = MarkdownStylingController(editorView: editor)
        editor.setString("Intro\n\n[link](https://example.com)\n", clearsUndo: true)
        controller.scheduleParse(text: editor.string)
        try await waitForParse(controller)

        editor.textView.insertText(
            "xxxx",
            replacementRange: NSRange(location: 0, length: 0)
        )
        controller.invalidateText()
        let destination = (editor.string as NSString).range(of: "https://example.com")
        let storage = try #require(editor.textView.textStorage)
        let location = NSMaxRange(destination) - 1
        #expect(storage.attribute(
            .underlineStyle,
            at: location,
            effectiveRange: nil
        ) as? Int == 1)

        if resizesWindow {
            controller.updateWindowWidthFontScale(for: 420)
        } else {
            controller.applySettings(settings)
        }
        #expect(storage.attribute(
            .underlineStyle,
            at: location,
            effectiveRange: nil
        ) as? Int == 1)

        controller.scheduleParse(text: editor.string)
        try await waitForParse(controller)
        #expect(storage.attribute(
            .underlineStyle,
            at: location,
            effectiveRange: nil
        ) as? Int == 1)
    }

    private func waitForParse(_ controller: MarkdownStylingController) async throws {
        for _ in 0 ..< 200 where controller.freshStyleSpans == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(controller.freshStyleSpans != nil)
    }

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
