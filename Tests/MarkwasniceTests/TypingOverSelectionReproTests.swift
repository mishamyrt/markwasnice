import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct TypingOverSelectionReproTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    @Test func typingLetterOverSelectionReplacesIt() {
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.setString("Hello **world** and more", clearsUndo: true)
        editor.textView.setSelectedRange(NSRange(location: 6, length: 9))
        editor.textView.insertText(
            "a",
            replacementRange: editor.textView.selectedRange()
        )

        #expect(editor.textView.string == "Hello a and more")
    }

    @Test func typingLetterOverSelectionAfterParseReplacesIt() {
        let source = """
        # Title

        Hello **world** and `code` here

        ```swift
        let a = 1
        ```
        """
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.setString(source, clearsUndo: true)
        guard let parse = MarkdownParseService.parse(
            text: source, version: 1, previous: nil
        ) else {
            Issue.record("parse returned nil outside a cancelled task")
            return
        }
        editor.applyParsedStyles(parse.spans, dirtyRanges: parse.dirtyRanges)

        let selection = (source as NSString).range(of: "**world** and")
        editor.textView.setSelectedRange(selection)
        editor.textView.insertText(
            "x",
            replacementRange: editor.textView.selectedRange()
        )

        #expect(editor.textView.string.contains("Hello x `code` here"))
    }

    @Test func keyDownTypingOverSelectionThroughInputContext() {
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        window.makeFirstResponder(editor.textView)

        editor.setString("Hello world selection test", clearsUndo: true)
        guard let parse = MarkdownParseService.parse(
            text: editor.string, version: 1, previous: nil
        ) else {
            Issue.record("parse returned nil outside a cancelled task")
            return
        }
        editor.applyParsedStyles(parse.spans, dirtyRanges: parse.dirtyRanges)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 5))

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "ф",
            charactersIgnoringModifiers: "ф",
            isARepeat: false,
            keyCode: 0
        ) else {
            Issue.record("failed to build key event")
            return
        }

        editor.textView.keyDown(with: event)

        #expect(editor.textView.string.hasPrefix("ф world"))
    }

    @Test func typingPairSymbolOverSelectionWrapsIt() {
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.setString("Hello world", clearsUndo: true)
        editor.textView.setSelectedRange(NSRange(location: 6, length: 5))
        editor.textView.insertText(
            "*",
            replacementRange: editor.textView.selectedRange()
        )

        #expect(editor.textView.string == "Hello *world*")
    }
}
