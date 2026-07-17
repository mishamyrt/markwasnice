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
    func wrapsExplicitSelectionInsideSurroundingSpaces() {
        let edit = MarkdownMarkupCommand.bold.edit(
            in: " hello ", selectedRange: NSRange(location: 0, length: 7)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 7),
            replacementString: " **hello** ",
            selectedRange: NSRange(location: 3, length: 5)
        ))
    }

    @Test
    func unwrapsExplicitSelectionInsideSurroundingSpaces() {
        let edit = MarkdownMarkupCommand.bold.edit(
            in: " **hello** ", selectedRange: NSRange(location: 0, length: 11)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 11),
            replacementString: " hello ",
            selectedRange: NSRange(location: 1, length: 5)
        ))
    }

    @Test
    func wrapsEachSelectedLineSeparately() {
        let edit = MarkdownMarkupCommand.bold.edit(
            in: " one\ntwo ", selectedRange: NSRange(location: 0, length: 9)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 9),
            replacementString: " **one**\n**two** ",
            selectedRange: NSRange(location: 0, length: 17)
        ))
    }

    @Test
    func unwrapsEachSelectedLineSeparately() {
        let edit = MarkdownMarkupCommand.bold.edit(
            in: " **one**\n**two** ", selectedRange: NSRange(location: 0, length: 17)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 17),
            replacementString: " one\ntwo ",
            selectedRange: NSRange(location: 0, length: 9)
        ))
    }

    @Test
    func multilineWrapLeavesBlankLinesUnchanged() {
        let edit = MarkdownMarkupCommand.highlight.edit(
            in: "one\n   \ntwo", selectedRange: NSRange(location: 0, length: 11)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 11),
            replacementString: "==one==\n   \n==two==",
            selectedRange: NSRange(location: 0, length: 19)
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
    func wrapsWholeWordWithCursorInside() {
        let edit = MarkdownMarkupCommand.italic.edit(
            in: "say hello now", selectedRange: NSRange(location: 6, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 4, length: 5),
            replacementString: "*hello*",
            selectedRange: NSRange(location: 7, length: 0)
        ))
    }

    @Test
    func unwrapsWholeWordWithCursorInside() {
        let edit = MarkdownMarkupCommand.italic.edit(
            in: "say *hello* now", selectedRange: NSRange(location: 7, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 4, length: 7),
            replacementString: "hello",
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
    func linkWithSelectionKeepsSurroundingSpacesOutsideLabel() {
        let edit = MarkdownMarkupCommand.link.edit(
            in: " hello ", selectedRange: NSRange(location: 0, length: 7)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 7),
            replacementString: " [hello]() ",
            selectedRange: NSRange(location: 9, length: 0)
        ))
    }

    @Test
    func imageLinkWithSelectionKeepsSurroundingSpacesOutsideAltText() {
        let edit = MarkdownMarkupCommand.imageLink.edit(
            in: " alt ", selectedRange: NSRange(location: 0, length: 5)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 5),
            replacementString: " ![alt]() ",
            selectedRange: NSRange(location: 8, length: 0)
        ))
    }

    @Test
    func multilineLinkWrapsEachLineSeparately() {
        let edit = MarkdownMarkupCommand.link.edit(
            in: " one\ntwo ", selectedRange: NSRange(location: 0, length: 9)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 9),
            replacementString: " [one]()\n[two]() ",
            selectedRange: NSRange(location: 7, length: 0)
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

    @Test
    func codeBlockWrapsMultilineSelectionAsSingleBlock() {
        let edit = MarkdownMarkupCommand.codeBlock.edit(
            in: "one\ntwo", selectedRange: NSRange(location: 0, length: 7)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 7),
            replacementString: "```\none\ntwo\n```",
            selectedRange: NSRange(location: 4, length: 7)
        ))
    }
}

@Suite
struct MarkdownHeadingCommandTests {
    @Test
    func addsHeadingMarkerAtCaret() {
        let edit = MarkdownMarkupCommand.heading2.edit(
            in: "title", selectedRange: NSRange(location: 2, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 5),
            replacementString: "## title",
            selectedRange: NSRange(location: 5, length: 0)
        ))
    }

    @Test
    func replacesExistingHeadingLevel() {
        let edit = MarkdownMarkupCommand.heading3.edit(
            in: "# title", selectedRange: NSRange(location: 4, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 7),
            replacementString: "### title",
            selectedRange: NSRange(location: 6, length: 0)
        ))
    }

    @Test
    func togglesOffSameHeadingLevel() {
        let edit = MarkdownMarkupCommand.heading2.edit(
            in: "## title", selectedRange: NSRange(location: 4, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 8),
            replacementString: "title",
            selectedRange: NSRange(location: 1, length: 0)
        ))
    }

    @Test
    func caretInsideMarkerLandsAfterNewPrefix() {
        let edit = MarkdownMarkupCommand.heading2.edit(
            in: "## title", selectedRange: NSRange(location: 1, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 8),
            replacementString: "title",
            selectedRange: NSRange(location: 0, length: 0)
        ))
    }

    @Test
    func appliesHeadingToEverySelectedLine() {
        let edit = MarkdownMarkupCommand.heading1.edit(
            in: "a\nb\n", selectedRange: NSRange(location: 0, length: 4)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 4),
            replacementString: "# a\n# b\n",
            selectedRange: NSRange(location: 0, length: 8)
        ))
    }

    @Test
    func headingAffectsWholeLineFromAnyCaretColumn() {
        let edit = MarkdownMarkupCommand.heading1.edit(
            in: "first\nsecond", selectedRange: NSRange(location: 9, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 6, length: 6),
            replacementString: "# second",
            selectedRange: NSRange(location: 11, length: 0)
        ))
    }

    @Test
    func headingOnBlankCaretLineInsertsMarker() {
        let edit = MarkdownMarkupCommand.heading4.edit(
            in: "", selectedRange: NSRange(location: 0, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "#### ",
            selectedRange: NSRange(location: 5, length: 0)
        ))
    }
}
