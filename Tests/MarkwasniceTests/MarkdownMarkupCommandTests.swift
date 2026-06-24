import Foundation
import Testing
@testable import Markwasnice

@Suite
struct MarkdownMarkupCommandTests {
    @Test
    func wrapsExplicitSelectionAndKeepsTextSelected() {
        let edit = MarkdownMarkupCommand.bold.edit(
            in: "hello", selectedRange: NSRange(location: 0, length: 5)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 5),
            replacementString: "**hello**",
            selectedRange: NSRange(location: 2, length: 5)
        ))
    }

    @Test
    func unwrapsExplicitSelectionInsideDelimiters() {
        let edit = MarkdownMarkupCommand.bold.edit(
            in: "**hello**", selectedRange: NSRange(location: 2, length: 5)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 9),
            replacementString: "hello",
            selectedRange: NSRange(location: 0, length: 5)
        ))
    }

    @Test
    func wrapsPreviousLetterWordWithoutPunctuation() {
        let edit = MarkdownMarkupCommand.italic.edit(
            in: "hello,", selectedRange: NSRange(location: 6, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 6, length: 0),
            replacementString: "**",
            selectedRange: NSRange(location: 7, length: 0)
        ))
    }

    @Test
    func wrapsPreviousLetterWordAtCursor() {
        let edit = MarkdownMarkupCommand.italic.edit(
            in: "hello", selectedRange: NSRange(location: 5, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 5),
            replacementString: "*hello*",
            selectedRange: NSRange(location: 6, length: 0)
        ))
    }

    @Test
    func insertsEmptyPairAfterWhitespace() {
        let edit = MarkdownMarkupCommand.highlight.edit(
            in: "hello ", selectedRange: NSRange(location: 6, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 6, length: 0),
            replacementString: "====",
            selectedRange: NSRange(location: 8, length: 0)
        ))
    }

    @Test
    func removesEmptyPairAtCursor() {
        let edit = MarkdownMarkupCommand.highlight.edit(
            in: "====",
            selectedRange: NSRange(location: 2, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 4),
            replacementString: "",
            selectedRange: NSRange(location: 0, length: 0)
        ))
    }

    @Test
    func linkWithSelectionMovesCursorToDestination() {
        let edit = MarkdownMarkupCommand.link.edit(
            in: "hello", selectedRange: NSRange(location: 0, length: 5)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 5),
            replacementString: "[hello]()",
            selectedRange: NSRange(location: 8, length: 0)
        ))
    }

    @Test
    func emptyLinkMovesCursorToText() {
        let edit = MarkdownMarkupCommand.link.edit(
            in: "", selectedRange: NSRange(location: 0, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "[]()",
            selectedRange: NSRange(location: 1, length: 0)
        ))
    }

    @Test
    func emptyImageLinkMovesCursorToAltText() {
        let edit = MarkdownMarkupCommand.imageLink.edit(
            in: "", selectedRange: NSRange(location: 0, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "![]()",
            selectedRange: NSRange(location: 2, length: 0)
        ))
    }

    @Test
    func removesEmptyLinkAtTextCursor() {
        let edit = MarkdownMarkupCommand.link.edit(
            in: "[]()", selectedRange: NSRange(location: 1, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 4),
            replacementString: "",
            selectedRange: NSRange(location: 0, length: 0)
        ))
    }

    @Test
    func unwrapsLinkWhenCursorIsInDestination() {
        let edit = MarkdownMarkupCommand.link.edit(
            in: "[hello](url)", selectedRange: NSRange(location: 11, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 12),
            replacementString: "hello",
            selectedRange: NSRange(location: 5, length: 0)
        ))
    }

    @Test
    func insertsEmptyCodeBlockWithCursorInside() {
        let edit = MarkdownMarkupCommand.codeBlock.edit(
            in: "", selectedRange: NSRange(location: 0, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "```\n\n```",
            selectedRange: NSRange(location: 4, length: 0)
        ))
    }
}
