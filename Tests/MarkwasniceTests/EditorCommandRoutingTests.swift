import AppKit
import Carbon.HIToolbox
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
    private enum ArrowKey {
        case up
        case down

        var specialKey: NSEvent.SpecialKey {
            switch self {
            case .up:
                .upArrow
            case .down:
                .downArrow
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .up:
                UInt16(kVK_UpArrow)
            case .down:
                UInt16(kVK_DownArrow)
            }
        }
    }

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

    private func optionArrowEvent(_ key: ArrowKey) -> NSEvent? {
        let characters = String(key.specialKey.unicodeScalar)
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .numericPad],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: key.keyCode
        )
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

    @Test func optionUpMovesCurrentLine() {
        let source = "one\ntwo"
        let editor = makeEditor(source: source, caretAt: 5)
        guard let event = optionArrowEvent(.up) else {
            Issue.record("failed to build Option+Up event")
            return
        }

        editor.textView.keyDown(with: event)

        #expect(editor.textView.string == "two\none")
        #expect(editor.textView.selectedRange() == NSRange(location: 1, length: 0))
    }

    @Test func optionDownMovesCurrentLine() {
        let source = "one\ntwo"
        let editor = makeEditor(source: source, caretAt: 1)
        guard let event = optionArrowEvent(.down) else {
            Issue.record("failed to build Option+Down event")
            return
        }

        editor.textView.keyDown(with: event)

        #expect(editor.textView.string == "two\none")
        #expect(editor.textView.selectedRange() == NSRange(location: 5, length: 0))
    }

    @Test func optionDownMovesCaretBetweenIdenticalLines() {
        let source = "same\nsame"
        let editor = makeEditor(source: source, caretAt: 2)
        guard let event = optionArrowEvent(.down) else {
            Issue.record("failed to build Option+Down event")
            return
        }

        editor.textView.keyDown(with: event)

        #expect(editor.textView.string == source)
        #expect(editor.textView.selectedRange() == NSRange(location: 7, length: 0))
    }
}
