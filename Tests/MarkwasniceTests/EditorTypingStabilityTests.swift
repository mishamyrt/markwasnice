import AppKit
import Testing
@testable import Markwasnice

/// Regression harness for typing-time visual stability.
///
/// Flicker means: the state right after a keystroke (local heuristic styling)
/// differs from the state right after the parse result lands. These tests
/// drive the real input path (`insertText` → `didProcessEditing` → local
/// styling), then apply the real parse pipeline, and assert the two states
/// are identical — both text attributes and drawn code-background ranges.
@MainActor
struct EditorTypingStabilityTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    // MARK: - Scenarios

    @Test(arguments: ["", "\n\nAfter"])
    func typingOnCommentClosingLineKeepsWrappedIndent(suffix: String) throws {
        let source = """
        <!-- Схлопывание
        1. Если 2 скважины — метка слева и справа
        2. Если 3, 1 слева, вторая и третья справа
        3. Меньше или равно 3 метр, в рисуем на расстоянии в 1_метр -->
        """ + suffix
        let harness = EditorHarness(source: source, settings: Self.settings)
        harness.type("klkdasdfg", at: (source as NSString).range(of: "Ме").upperBound)
        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func restylingWhileTypingInsideCommentKeepsItsStyle() throws {
        let source = "<!-- first\n3. a long commented list item with a wrapped continuation -->\n\nAfter"
        let harness = EditorHarness(source: source, settings: Self.settings)
        harness.type("x", at: (source as NSString).range(of: "commented").upperBound)
        harness.editor.applySettings(Self.settings)
        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingInsideMultilineCommentKeepsStylingAligned() throws {
        let source = "<!-- first\n\n# heading\n[x] task\n`code`\n-->\n\nAfter"
        let harness = EditorHarness(source: source, settings: Self.settings)
        harness.type("!", at: (source as NSString).range(of: "heading").upperBound)
        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingAfterCommentDoesNotExtendItsStyle() throws {
        let source = "<!-- comment -->"
        let harness = EditorHarness(source: source, settings: Self.settings)
        harness.type("\nplain", at: source.utf16.count)
        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingInsideNestedImageLinkLabelKeepsStylingAligned() throws {
        let source = """
        Intro line

        [![IMAGE Aasda](https://upload.wikimedia.org/img.png)](https://www.youtube.com/watch?v=ciawICBvQoE)

        Tail line
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        let insertLocation = (source as NSString).range(of: "Aasda").upperBound
        harness.type("sdd", at: insertLocation)

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingNearDocumentEndKeepsLocalSpanOffsets() throws {
        let prefix = String(repeating: "plain paragraph\n", count: 2_000)
        let source = prefix + "Tail with **bold text** and [link](https://example.com)"
        let harness = EditorHarness(source: source, settings: Self.settings)
        let location = (source as NSString).range(of: "bold text").upperBound

        harness.type("!", at: location)

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingOnLineAboveLinkKeepsLinkStylingAligned() throws {
        let source = """
        Intro line

        [![IMAGE Aasda](https://upload.wikimedia.org/img.png)](https://www.youtube.com/watch?v=ciawICBvQoE)
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type("abc", at: (source as NSString).range(of: "Intro line").upperBound)

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingInParagraphBeforeCodeBlockKeepsBlockRangesStable() throws {
        let source = """
        Paragraph before

        ```swift
        let a = 1
        let b = 2
        ```

        Paragraph after
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type(
            "x",
            at: (source as NSString).range(of: "Paragraph before").upperBound
        )

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingInsideCodeBlockKeepsNeighborBlocksStable() throws {
        let source = """
        # Doc

        ```swift
        let first = 1
        ```

        Middle paragraph

        ```swift
        let second = 2
        ```

        ```swift
        let third = 3
        ```
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type(
            "23",
            at: (source as NSString).range(of: "let second = 2").upperBound
        )

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingMarkdownTokensInsideCodeBlockStaysPlain() throws {
        let source = """
        ```swift
        let bold = "**not markdown**"
        ```
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type(
            "*x*",
            at: (source as NSString).range(of: "markdown**").upperBound
        )

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func typingInBlockQuoteWithEmojiKeepsStylingStable() throws {
        let source = "> ☝️ Всегда снимайте дамп перед прошивкой."
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type(" Важно", at: (source as NSString).length)

        try harness.assertLocalStateMatchesParsedState()
    }

    /// Reproduces the real per-keystroke sequence of the app: after every
    /// text change `EditorDocumentSession.markdownEditorViewDidChangeText`
    /// calls `refreshSearchMatches` → `clearSearchMatches` →
    /// `editorView.setSearchMatches([], selectedIndex: nil)`, which triggers
    /// a full restyle BEFORE the parse result arrives.
    @Test func sessionSearchClearBetweenKeystrokeAndParseDoesNotShiftStyling() throws {
        let source = """
        Intro line

        [![IMAGE Aasda](https://upload.wikimedia.org/img.png)](https://www.youtube.com/watch?v=ciawICBvQoE)

        ```swift
        let a = 1
        ```
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type("sdd", at: (source as NSString).range(of: "Aasda").upperBound)
        // The session-level per-keystroke call that lands between the edit
        // and the parse result.
        harness.editor.setSearchMatches([], selectedIndex: nil)

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func sessionSearchClearWhileTypingBeforeCodeBlockKeepsBlockStable() throws {
        let source = """
        Paragraph before

        ```swift
        let a = 1
        let b = 2
        ```
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type(
            "xy",
            at: (source as NSString).range(of: "Paragraph before").upperBound
        )
        harness.editor.setSearchMatches([], selectedIndex: nil)

        try harness.assertLocalStateMatchesParsedState()
    }

    /// When a restyle genuinely runs between a keystroke and the parse
    /// result (e.g. live search recomputing matches while typing), it must
    /// use span positions translated across the edit — not the stale ones.
    @Test func activeSearchRestyleWhileTypingUsesTranslatedSpans() throws {
        let source = """
        Paragraph findme here

        ```swift
        let a = 1
        ```
        """
        let harness = EditorHarness(source: source, settings: Self.settings)
        let match = (source as NSString).range(of: "findme")
        harness.editor.setSearchMatches([match], selectedIndex: 0)

        harness.type("xy", at: (source as NSString).range(of: "Paragraph").upperBound)
        // Session recomputes matches on the changed text and pushes the
        // shifted range — this triggers a full restyle before the parse.
        let shiftedMatch = NSRange(location: match.location + 2, length: match.length)
        harness.editor.setSearchMatches([shiftedMatch], selectedIndex: 0)

        try harness.assertLocalStateMatchesParsedState()
    }

    /// Pressing Enter after a heading must leave the new empty line with the
    /// base paragraph style: the heading's outdented first-line indent would
    /// otherwise park the caret in the hash gutter.
    @Test func enterAfterHeadingLeavesCaretLineWithBaseIndent() throws {
        let source = "## Heading\n\nBody"
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type("\n", at: ("## Heading" as NSString).length)

        guard let storage = harness.editor.textView.textStorage else {
            Issue.record("missing text storage")
            return
        }

        // The newline terminating the new empty caret line (index 11).
        let caretLineNewlineIndex = ("## Heading\n" as NSString).length
        let style = storage.attribute(
            .paragraphStyle,
            at: caretLineNewlineIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(style != nil)
        #expect(
            style?.firstLineHeadIndent == style?.headIndent,
            "empty line after heading must not inherit the heading outdent"
        )

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func enterAfterHeadingAtEndOfDocumentStaysConsistent() throws {
        // Note: the trailing newline itself keeps the heading paragraph style
        // (TextKit conforms paragraph styles to whole paragraphs); the caret
        // in the extra line fragment is positioned from typingAttributes,
        // which are base. Here we only assert local/parse consistency.
        let source = "## Heading"
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.type("\n", at: (source as NSString).length)

        try harness.assertLocalStateMatchesParsedState()
    }

    /// Focus dimming is updated with a paragraph-delta restyle instead of a
    /// whole-document one; moving the caret must dim the paragraph that lost
    /// it and undim the one that gained it, leaving the rest untouched.
    @Test func focusModeCaretMovesKeepDimmingConsistent() throws {
        let source = """
        First paragraph line

        Second paragraph line

        Third paragraph line
        """
        let harness = EditorHarness(source: source, settings: Self.settings)
        harness.editor.setFocusModeEnabled(true)

        let string = source as NSString
        let first = string.range(of: "First").location
        let second = string.range(of: "Second").location
        let third = string.range(of: "Third").location

        harness.moveCaret(to: second)
        #expect(harness.isDimmed(at: first))
        #expect(!harness.isDimmed(at: second))
        #expect(harness.isDimmed(at: third))

        harness.moveCaret(to: third)
        #expect(harness.isDimmed(at: first))
        #expect(
            harness.isDimmed(at: second),
            "the paragraph that lost the caret must be re-dimmed"
        )
        #expect(!harness.isDimmed(at: third))

        try harness.assertLocalStateMatchesParsedState()
    }

    /// Enter at the end of the focused paragraph moves the focus to the new
    /// line; the paragraph left behind must be dimmed even though the edit
    /// shifted the stored active range.
    @Test func focusModeEnterDimsParagraphLeftBehind() throws {
        let source = """
        First paragraph line

        Second paragraph line
        """
        let harness = EditorHarness(source: source, settings: Self.settings)
        harness.editor.setFocusModeEnabled(true)

        let string = source as NSString
        let first = string.range(of: "First").location
        let secondRange = string.range(of: "Second paragraph line")
        harness.moveCaret(to: NSMaxRange(secondRange))
        #expect(!harness.isDimmed(at: secondRange.location))

        harness.pressEnter(at: NSMaxRange(secondRange))

        #expect(harness.isDimmed(at: first))
        #expect(
            harness.isDimmed(at: secondRange.location),
            "the paragraph left behind by Enter must be dimmed"
        )

        try harness.assertLocalStateMatchesParsedState()
    }

    /// Pressing Enter right after the closing backtick of an inline code
    /// list item must not stretch the drawn code balloon over the new line:
    /// the geometric edit translation cannot know a boundary insertion falls
    /// outside the span, so the local re-derivation has to win within the
    /// same editing pass.
    @Test func enterAfterInlineCodeListItemKeepsBalloonOnItsLine() throws {
        let source = """
        1. `routers`
        2. `services`
        3. `repositories`
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.pressEnter(
            at: (source as NSString).range(of: "`services`").upperBound
        )

        try harness.assertLocalStateMatchesParsedState()
    }

    @Test func deletingInParagraphBeforeCodeBlockKeepsBlockRangesStable() throws {
        let source = """
        Paragraph before

        ```swift
        let a = 1
        ```
        """
        let harness = EditorHarness(source: source, settings: Self.settings)

        harness.deleteBackward(
            count: 3,
            at: (source as NSString).range(of: "Paragraph before").upperBound
        )

        try harness.assertLocalStateMatchesParsedState()
    }
}

// MARK: - Harness

@MainActor
private final class EditorHarness {
    let editor: MarkdownEditorView
    private var previousParse: MarkdownParseResult?
    private var version = 0

    init(source: String, settings: EditorSettings) {
        editor = MarkdownEditorView(
            settings: settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.setString(source, clearsUndo: true)
        applyFreshParse()
    }

    func type(_ text: String, at location: Int) {
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
        for character in text {
            editor.textView.insertText(
                String(character),
                replacementRange: editor.textView.selectedRange()
            )
        }
    }

    func moveCaret(to location: Int) {
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    func isDimmed(at location: Int) -> Bool {
        guard let storage = editor.textView.textStorage,
              location < storage.length,
              let color = storage.attribute(
                  .foregroundColor,
                  at: location,
                  effectiveRange: nil
              ) as? NSColor
        else {
            return false
        }

        return color.alphaComponent < 0.9
    }

    /// Drives the real Enter path: list/quote continuation first (as
    /// MarkdownTextView.keyDown does), plain newline insertion otherwise.
    func pressEnter(at location: Int) {
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
        if !editor.markdownTextViewContinueMarkdownPrefix(editor.textView) {
            editor.textView.insertText(
                "\n",
                replacementRange: editor.textView.selectedRange()
            )
        }
    }

    func deleteBackward(count: Int, at location: Int) {
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
        for _ in 0..<count {
            editor.textView.deleteBackward(nil)
        }
    }

    /// Captures the post-keystroke (local styling) state, applies the real
    /// parse result, captures the post-parse state, and asserts equality.
    func assertLocalStateMatchesParsedState(
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let localAttributes = attributeSnapshot()
        let localInlineRanges = editor.textView.inlineCodeRanges
        let localBlockRanges = editor.textView.codeBlockRanges

        applyFreshParse()

        let parsedAttributes = attributeSnapshot()
        let parsedInlineRanges = editor.textView.inlineCodeRanges
        let parsedBlockRanges = editor.textView.codeBlockRanges

        #expect(
            localBlockRanges == parsedBlockRanges,
            "code block draw ranges flicker: local \(localBlockRanges) vs parsed \(parsedBlockRanges)",
            sourceLocation: sourceLocation
        )
        #expect(
            localInlineRanges == parsedInlineRanges,
            "inline code draw ranges flicker: local \(localInlineRanges) vs parsed \(parsedInlineRanges)",
            sourceLocation: sourceLocation
        )

        let differences = Self.diff(local: localAttributes, parsed: parsedAttributes)
        #expect(
            differences.isEmpty,
            "attribute flicker at:\n\(differences.joined(separator: "\n"))",
            sourceLocation: sourceLocation
        )
    }

    private func applyFreshParse() {
        version += 1
        guard let result = MarkdownParseService.parse(
            text: editor.string,
            version: version,
            previous: previousParse
        ) else {
            Issue.record("parse returned nil outside a cancelled task")
            return
        }

        previousParse = result
        editor.applyParsedStyles(result.spans, dirtyRanges: result.dirtyRanges)
    }

    // MARK: Attribute snapshots

    private struct CharacterStyle: Equatable {
        var foreground: String
        var underline: Int
        var fontName: String
        var fontTraits: UInt
        var firstLineHeadIndent: CGFloat
        var headIndent: CGFloat
    }

    private func attributeSnapshot() -> [CharacterStyle] {
        guard let storage = editor.textView.textStorage else {
            return []
        }

        var styles: [CharacterStyle] = []
        styles.reserveCapacity(storage.length)
        storage.enumerateAttributes(
            in: NSRange(location: 0, length: storage.length)
        ) { attributes, range, _ in
            let foreground = (attributes[.foregroundColor] as? NSColor)?
                .description ?? "nil"
            let underline = attributes[.underlineStyle] as? Int ?? 0
            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0).rawValue } ?? 0
            let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
            let style = CharacterStyle(
                foreground: foreground,
                underline: underline,
                fontName: font?.fontName ?? "nil",
                fontTraits: traits,
                firstLineHeadIndent: paragraphStyle?.firstLineHeadIndent ?? 0,
                headIndent: paragraphStyle?.headIndent ?? 0
            )
            for _ in 0..<range.length {
                styles.append(style)
            }
        }
        return styles
    }

    private static func diff(
        local: [CharacterStyle],
        parsed: [CharacterStyle]
    ) -> [String] {
        guard local.count == parsed.count else {
            return ["length mismatch: local \(local.count) vs parsed \(parsed.count)"]
        }

        var differences: [String] = []
        for index in 0..<local.count where local[index] != parsed[index] {
            differences.append(
                "index \(index): local \(local[index]) vs parsed \(parsed[index])"
            )
            if differences.count >= 12 {
                differences.append("…")
                break
            }
        }
        return differences
    }
}
