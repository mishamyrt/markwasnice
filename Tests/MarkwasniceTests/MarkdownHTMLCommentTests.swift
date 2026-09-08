import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownHTMLCommentTests {
    private let settings = EditorSettings(
        textSizeScale: 1, maxTextColumns: 64, tabInsertionMode: .spaces, tabWidth: 4
    )
    @Test(arguments: [
        (
            "first\n  Привет 🙂 мир  \nlast",
            "Привет 🙂 мир",
            NSRange(location: 12, length: 0)
        ),
        ("before Привет 🙂 after", "Привет 🙂", NSRange(location: 7, length: 9)),
        ("one\n\ntwo", "one\n\ntwo", NSRange(location: 0, length: 8)),
        ("one\r\ntwo", "one", NSRange(location: 1, length: 0)),
        ("", "", NSRange(location: 0, length: 0)),
        ("one\n", "", NSRange(location: 4, length: 0)),
    ])
    func shortcutWrapsAndUnwraps(
        source: String,
        content: String,
        selection: NSRange
    ) throws {
        let string = source as NSString
        let edit = try #require(MarkdownMarkupCommand.comment.edit(
            in: string, selectedRange: selection
        ))
        #expect(edit.replacementString == "<!-- " + content + " -->")
        let commented = string.replacingCharacters(
            in: edit.replacementRange, with: edit.replacementString
        ) as NSString
        let reverse = try #require(MarkdownMarkupCommand.comment.edit(
            in: commented, selectedRange: edit.selectedRange
        ))
        #expect(commented.replacingCharacters(
            in: reverse.replacementRange, with: reverse.replacementString
        ) == source)
        #expect(reverse.selectedRange == selection)
    }

    @Test(arguments: [
        ("<!--word-->", NSRange(location: 0, length: 11), "word"),
        ("  <!-- word -->\nnext", NSRange(location: 0, length: 16), "  word\nnext"),
        ("<!-- one\n\ntwo -->", NSRange(location: 10, length: 0), "one\n\ntwo"),
        (
            "before <!-- word --> after",
            NSRange(location: 14, length: 2),
            "before word after"
        ),
    ])
    func unwrapsExistingComment(
        source: String,
        selection: NSRange,
        expected: String
    ) throws {
        let edit = try #require(MarkdownMarkupCommand.comment.edit(
            in: source as NSString, selectedRange: selection
        ))
        #expect((source as NSString).replacingCharacters(
            in: edit.replacementRange, with: edit.replacementString
        ) == expected)
    }

    @Test(arguments: [
        ("<!-- **hidden** -->", ["<!-- **hidden** -->"]),
        ("До <!-- Привет 🙂 --> после", ["<!-- Привет 🙂 -->"]),
        ("<!-- first\n\n[x] second\n-->\nvisible", ["<!-- first\n\n[x] second\n-->"]),
        (
            "<!-- hidden --> visible <!-- second -->",
            ["<!-- hidden -->", "<!-- second -->"]
        ),
        ("    <!-- shifted -->", ["<!-- shifted -->"]),
        ("> <!-- first\n> second -->", ["<!-- first\n> second -->"]),
        ("<!-- first\r\nsecond\r\n-->", ["<!-- first\r\nsecond\r\n-->"]),
        ("<div>\n<!-- hidden -->\n</div>", ["<!-- hidden -->"]),
        ("<!-- unfinished\nnext line", ["<!-- unfinished\nnext line"]),
        ("`<!-- code -->`", []),
        ("```html\n<!-- code -->\n```", []),
        ("---\nnote: <!-- value -->\n---", []),
        (#"\<!-- escaped -->"#, []),
    ])
    func parserFindsOnlyCommentRanges(source: String, comments: [String]) throws {
        let parsed = try #require(MarkdownParseService.parse(
            text: source, version: 1, previous: nil
        ))
        let ranges = parsed.spans.filter { $0.kind == .htmlComment }.map(\.range)
        #expect(ranges.map { (source as NSString).substring(with: $0) } == comments)
        for span in parsed.spans
            where span.kind == .taskCheckbox || span.kind == .strong
        {
            #expect(!ranges.contains { NSIntersectionRange($0, span.range).length > 0 })
        }
    }

    @Test
    func localScannerMatchesInlineCommentWithUnicode() {
        let source = "До <!-- Привет 🙂 --> после"
        let spans = MarkdownInlineStyleScanner.inlineSpans(
            in: NSRange(location: 0, length: source.utf16.count), source: source
        )
        #expect(spans == [ResolvedMarkdownStyleSpan(
            range: (source as NSString).range(of: "<!-- Привет 🙂 -->"), kind: .htmlComment
        )])
    }

    @Test
    func commentUsesPunctuationColorAndItalicAcrossItsEntireRange() throws {
        let source = "before <!-- **hidden** --> after"
        let editor = MarkdownEditorView(settings: settings)
        editor.setString(source, clearsUndo: true)
        let parse = try #require(MarkdownParseService.parse(
            text: source, version: 1, previous: nil
        ))
        editor.applyParsedStyles(parse.spans, dirtyRanges: nil)
        let storage = try #require(editor.textView.textStorage)
        let comment = (source as NSString).range(of: "<!-- **hidden** -->")
        let colors = EditorThemeColors.default.variant(for: editor.effectiveAppearance)
        for location in comment.location ..< NSMaxRange(comment) {
            let color = storage.attribute(
                .foregroundColor,
                at: location,
                effectiveRange: nil
            ) as? NSColor
            let font = try #require(storage.attribute(
                .font,
                at: location,
                effectiveRange: nil
            ) as? NSFont)
            #expect(color == colors.punctuation)
            #expect(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
            #expect(!NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        }
        #expect(storage.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
            == colors.foreground)
    }

    @Test(arguments: [
        ("<!-- hidden -->\n\nvisible", "visible"),
        ("before<!-- hidden --> after", "before after"),
        ("<!-- hidden --> visible", "visible"),
        ("```\n<!-- literal -->\n```", "<!-- literal -->"),
    ])
    func previewAndCopyOmitComments(source: String, expected: String) {
        let renderer = MarkdownPreviewRenderer(theme: .init(
            baseFontSize: 20, colors: EditorThemeColors.default.light
        ))
        #expect(renderer.render(source).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == expected)
        #expect(MarkdownCopyFormat.plainText.convert(source)
            .trimmingCharacters(in: .whitespacesAndNewlines) == expected)
    }

    @Test
    func editorCommandCanBeUndone() throws {
        let editor = MarkdownEditorView(settings: settings)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = editor
        editor.setString("first\nsecond", clearsUndo: true)
        let selection = NSRange(location: 8, length: 0)
        editor.textView.setSelectedRange(selection)
        let undo = try #require(editor.textView.undoManager)
        undo.beginUndoGrouping()
        editor.applyMarkup(.comment)
        undo.endUndoGrouping()
        #expect(editor.string == "first\n<!-- second -->")
        undo.undo()
        #expect(editor.string == "first\nsecond")
        undo.redo()
        #expect(editor.string == "first\n<!-- second -->")
    }
}
