import AppKit
import Testing
@testable import Markwasnice

/// Pins the input-context command routing in
/// MarkdownEditorView.textView(_:doCommandBy:): Return continues markdown
/// prefixes (and falls back to AppKit by returning false when there is
/// nothing to continue), Tab/Backtab route to the indent commands. This is
/// the path IME-safe key handling goes through instead of raw keyDown
/// character dispatch.
@MainActor
struct EditorCommandRoutingTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeEditor(source: String, caretAt location: Int)
        -> MarkdownEditorView
    {
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.setString(source, clearsUndo: true)
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
        return editor
    }

    private func performCommand(
        _ selector: Selector,
        in editor: MarkdownEditorView
    ) -> Bool {
        editor.textView(editor.textView, doCommandBy: selector)
    }

    @Test func insertNewlineContinuesListPrefix() {
        let source = "- item"
        let editor = makeEditor(source: source, caretAt: (source as NSString).length)

        let handled = performCommand(
            #selector(NSResponder.insertNewline(_:)),
            in: editor
        )

        #expect(handled)
        #expect(editor.textView.string == "- item\n- ")
    }

    @Test func insertNewlineFallsBackToDefaultOnPlainText() {
        let source = "plain paragraph"
        let editor = makeEditor(source: source, caretAt: (source as NSString).length)

        let handled = performCommand(
            #selector(NSResponder.insertNewline(_:)),
            in: editor
        )

        // Unhandled: AppKit's default insertNewline must run instead, so the
        // text stays untouched here.
        #expect(!handled)
        #expect(editor.textView.string == source)
    }

    @Test func insertTabIndentsAtCaret() {
        let source = "text"
        let editor = makeEditor(source: source, caretAt: 0)

        let handled = performCommand(
            #selector(NSResponder.insertTab(_:)),
            in: editor
        )

        #expect(handled)
        #expect(editor.textView.string == "    text")
    }

    @Test func insertBacktabOutdentsIndentedLine() {
        let source = "    text"
        let editor = makeEditor(source: source, caretAt: 4)

        let handled = performCommand(
            #selector(NSResponder.insertBacktab(_:)),
            in: editor
        )

        #expect(handled)
        #expect(editor.textView.string == "text")
    }
}
