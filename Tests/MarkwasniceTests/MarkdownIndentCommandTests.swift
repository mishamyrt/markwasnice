import Foundation
import Testing
@testable import Markwasnice

@Suite
struct MarkdownIndentCommandTests {
    private let unit = "    "

    @Test
    func indentsLineRegardlessOfCaretPosition() {
        let edit = MarkdownIndentCommand.indent.edit(
            in: "hello" as NSString,
            selectedRange: NSRange(location: 3, length: 0),
            indentUnit: unit,
            tabWidth: 4
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 5),
            replacementString: "    hello",
            selectedRange: NSRange(location: 7, length: 0)
        ))
    }

    @Test
    func outdentsLineRegardlessOfCaretPosition() {
        let edit = MarkdownIndentCommand.outdent.edit(
            in: "    hello" as NSString,
            selectedRange: NSRange(location: 7, length: 0),
            indentUnit: unit,
            tabWidth: 4
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 9),
            replacementString: "hello",
            selectedRange: NSRange(location: 3, length: 0)
        ))
    }

    @Test
    func outdentRemovesOnlyAvailableSpacesAndClampsCaretToLineStart() {
        let edit = MarkdownIndentCommand.outdent.edit(
            in: "  hello" as NSString,
            selectedRange: NSRange(location: 1, length: 0),
            indentUnit: unit,
            tabWidth: 4
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 7),
            replacementString: "hello",
            selectedRange: NSRange(location: 0, length: 0)
        ))
    }

    @Test
    func outdentRemovesLeadingTab() {
        let edit = MarkdownIndentCommand.outdent.edit(
            in: "\thello" as NSString,
            selectedRange: NSRange(location: 4, length: 0),
            indentUnit: "\t",
            tabWidth: 4
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 6),
            replacementString: "hello",
            selectedRange: NSRange(location: 3, length: 0)
        ))
    }

    @Test
    func outdentWithoutIndentDoesNothing() {
        let edit = MarkdownIndentCommand.outdent.edit(
            in: "hello" as NSString,
            selectedRange: NSRange(location: 2, length: 0),
            indentUnit: unit,
            tabWidth: 4
        )

        #expect(edit == nil)
    }

    @Test
    func indentsEverySelectedLineAndKeepsSelectionCoveringThem() {
        let edit = MarkdownIndentCommand.indent.edit(
            in: "a\nb" as NSString,
            selectedRange: NSRange(location: 0, length: 3),
            indentUnit: unit,
            tabWidth: 4
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 3),
            replacementString: "    a\n    b",
            selectedRange: NSRange(location: 0, length: 11)
        ))
    }

    @Test
    func indentSkipsBlankLinesInMultilineSelection() {
        let edit = MarkdownIndentCommand.indent.edit(
            in: "a\n\nb" as NSString,
            selectedRange: NSRange(location: 0, length: 4),
            indentUnit: unit,
            tabWidth: 4
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 4),
            replacementString: "    a\n\n    b",
            selectedRange: NSRange(location: 0, length: 12)
        ))
    }

    @Test
    func indentsEmptyTrailingLine() {
        let edit = MarkdownIndentCommand.indent.edit(
            in: "a\n" as NSString,
            selectedRange: NSRange(location: 2, length: 0),
            indentUnit: unit,
            tabWidth: 4
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 2, length: 0),
            replacementString: "    ",
            selectedRange: NSRange(location: 6, length: 0)
        ))
    }
}
