import Foundation
import Testing
@testable import Markwasnice

struct MarkdownLineMoveCommandTests {
    @Test
    func movesCurrentLineUpAndKeepsCaretColumn() {
        let edit = MarkdownLineMoveCommand.up.edit(
            in: "one\ntwo\nthree" as NSString,
            selectedRange: NSRange(location: 6, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 8),
            replacementString: "two\none\n",
            selectedRange: NSRange(location: 2, length: 0)
        ))
    }

    @Test
    func movesCurrentLineDownAndKeepsCaretColumn() {
        let edit = MarkdownLineMoveCommand.down.edit(
            in: "one\ntwo\nthree" as NSString,
            selectedRange: NSRange(location: 5, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 4, length: 9),
            replacementString: "three\ntwo",
            selectedRange: NSRange(location: 11, length: 0)
        ))
    }

    @Test
    func movesLastLineUpWithoutLosingItsSeparator() {
        let edit = MarkdownLineMoveCommand.up.edit(
            in: "one\ntwo" as NSString,
            selectedRange: NSRange(location: 5, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 7),
            replacementString: "two\none",
            selectedRange: NSRange(location: 1, length: 0)
        ))
    }

    @Test
    func movesSelectedLinesTogether() {
        let edit = MarkdownLineMoveCommand.up.edit(
            in: "a\nb\nc\nd" as NSString,
            selectedRange: NSRange(location: 2, length: 4)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 6),
            replacementString: "b\nc\na\n",
            selectedRange: NSRange(location: 0, length: 4)
        ))
    }

    @Test
    func movesLineIntoTrailingEmptyLine() {
        let edit = MarkdownLineMoveCommand.down.edit(
            in: "a\nb\n" as NSString,
            selectedRange: NSRange(location: 2, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 2, length: 2),
            replacementString: "\nb",
            selectedRange: NSRange(location: 3, length: 0)
        ))
    }

    @Test
    func movesCaretBetweenIdenticalLinesWithoutChangingText() {
        let edit = MarkdownLineMoveCommand.down.edit(
            in: "same\nsame" as NSString,
            selectedRange: NSRange(location: 2, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 9),
            replacementString: "same\nsame",
            selectedRange: NSRange(location: 7, length: 0)
        ))
    }

    @Test
    func movesCaretBetweenAdjacentEmptyLines() {
        let edit = MarkdownLineMoveCommand.down.edit(
            in: "a\n\n\nb" as NSString,
            selectedRange: NSRange(location: 2, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 2, length: 2),
            replacementString: "\n\n",
            selectedRange: NSRange(location: 3, length: 0)
        ))
    }

    @Test
    func preservesCRLFLineEndings() {
        let edit = MarkdownLineMoveCommand.up.edit(
            in: "one\r\ntwo\r\nthree" as NSString,
            selectedRange: NSRange(location: 6, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 10),
            replacementString: "two\r\none\r\n",
            selectedRange: NSRange(location: 1, length: 0)
        ))
    }

    @Test
    func preservesMixedLineEndingsByPosition() {
        let edit = MarkdownLineMoveCommand.down.edit(
            in: "a\r\nb\nc" as NSString,
            selectedRange: NSRange(location: 3, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 3, length: 3),
            replacementString: "c\nb",
            selectedRange: NSRange(location: 5, length: 0)
        ))
    }

    @Test
    func keepsUTF16SelectionWithEmojiLine() {
        let edit = MarkdownLineMoveCommand.down.edit(
            in: "a\n😀x\nz" as NSString,
            selectedRange: NSRange(location: 2, length: 2)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 2, length: 5),
            replacementString: "z\n😀x",
            selectedRange: NSRange(location: 4, length: 2)
        ))
    }

    @Test
    func doesNothingAtDocumentBoundaries() {
        #expect(MarkdownLineMoveCommand.up.edit(
            in: "one\ntwo" as NSString,
            selectedRange: NSRange(location: 0, length: 0)
        ) == nil)
        #expect(MarkdownLineMoveCommand.down.edit(
            in: "one\ntwo" as NSString,
            selectedRange: NSRange(location: 4, length: 0)
        ) == nil)
    }
}
