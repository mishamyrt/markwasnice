import AppKit
import Testing
@testable import Markwasnice

/// Deterministic fuzz: replace random selections with a typed character on
/// documents that exercise every style path. An out-of-bounds range anywhere
/// in the restyle pipeline raises NSRangeException and kills the process.
@MainActor
struct TypingOverSelectionFuzzTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private static let documents = [
        """
        ###### asd asdasd

        asdddasd

        asdddasd

        sd
        """,
        """
        # Title

        Body with **bold** and *italic* and `code` and [link](https://a.b).

        - one
        - two

        > quote

        ```swift
        let a = 1
        ```
        """,
        """
        Проверка русского текста и заголовков

        ## Заголовок

        Абзац с ==выделением== и ~~зачёркиванием~~ и nbsp\u{00A0}тут.
        """,
    ]

    @Test func replacingRandomSelectionsNeverBreaksRestyle() {
        var seed: UInt64 = 0x1234_5678
        func random(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return bound > 0 ? Int(seed >> 33) % bound : 0
        }

        for document in Self.documents {
            for iteration in 0 ..< 120 {
                let editor = MarkdownEditorView(
                    settings: Self.settings,
                    frame: NSRect(x: 0, y: 0, width: 800, height: 600)
                )
                editor.setString(document, clearsUndo: true)
                guard let parse = MarkdownParseService.parse(
                    text: editor.string, version: 1, previous: nil
                ) else {
                    Issue.record("parse returned nil outside a cancelled task")
                    return
                }
                editor.applyParsedStyles(
                    parse.spans, dirtyRanges: parse.dirtyRanges
                )
                if iteration % 2 == 0 {
                    editor.setFocusModeEnabled(true)
                }

                let length = (editor.string as NSString).length
                let location = random(length)
                let selectionLength = 1 + random(min(24, length - location))
                editor.textView.setSelectedRange(
                    NSRange(location: location, length: selectionLength)
                )
                editor.textView.insertText(
                    "ф",
                    replacementRange: editor.textView.selectedRange()
                )

                // A second keystroke after the replacement: the first edit
                // translates the spans, the second styles with them.
                editor.textView.insertText(
                    "ы",
                    replacementRange: editor.textView.selectedRange()
                )
            }
        }
    }
}
