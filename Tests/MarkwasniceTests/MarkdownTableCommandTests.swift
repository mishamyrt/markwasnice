import Foundation
import Testing
@testable import Markwasnice

@Suite
struct MarkdownTableCommandTests {
    @Test
    func generatesHeaderDelimiterAndBodyRows() {
        let edit = MarkdownTableCommand.edit(
            in: "" as NSString, selectedRange: NSRange(location: 0, length: 0),
            rows: 2, columns: 2
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "|   |   |\n|---|---|\n|   |   |\n|   |   |\n",
            selectedRange: NSRange(location: 2, length: 0)
        ))
    }

    @Test
    func placesCaretInFirstHeaderCellAfterPrefix() {
        let edit = MarkdownTableCommand.edit(
            in: "abc" as NSString, selectedRange: NSRange(location: 3, length: 0),
            rows: 1, columns: 1
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 3, length: 0),
            replacementString: "\n\n|   |\n|---|\n|   |\n",
            selectedRange: NSRange(location: 7, length: 0)
        ))
    }

    @Test
    func addsSingleNewlineAfterLineEnd() {
        let edit = MarkdownTableCommand.edit(
            in: "abc\n" as NSString, selectedRange: NSRange(location: 4, length: 0),
            rows: 1, columns: 1
        )

        #expect(edit?.replacementString == "\n|   |\n|---|\n|   |\n")
    }

    @Test
    func addsNoPrefixAfterBlankLine() {
        let edit = MarkdownTableCommand.edit(
            in: "abc\n\n" as NSString, selectedRange: NSRange(location: 5, length: 0),
            rows: 1, columns: 1
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 5, length: 0),
            replacementString: "|   |\n|---|\n|   |\n",
            selectedRange: NSRange(location: 7, length: 0)
        ))
    }

    @Test
    func addsNoPrefixWhenOnlyNewlinesPrecede() {
        let edit = MarkdownTableCommand.edit(
            in: "\n" as NSString, selectedRange: NSRange(location: 1, length: 0),
            rows: 1, columns: 1
        )

        #expect(edit?.replacementString == "|   |\n|---|\n|   |\n")
    }

    @Test
    func addsBlankLineBeforeFollowingText() {
        let edit = MarkdownTableCommand.edit(
            in: "tail" as NSString, selectedRange: NSRange(location: 0, length: 0),
            rows: 1, columns: 1
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 0),
            replacementString: "|   |\n|---|\n|   |\n\n",
            selectedRange: NSRange(location: 2, length: 0)
        ))
    }

    @Test
    func addsSingleNewlineBeforeFollowingNewline() {
        let edit = MarkdownTableCommand.edit(
            in: "\ntail" as NSString, selectedRange: NSRange(location: 0, length: 0),
            rows: 1, columns: 1
        )

        #expect(edit?.replacementString == "|   |\n|---|\n|   |\n")
    }

    @Test
    func terminatesLastRowWithoutTrailingBlankLine() {
        let edit = MarkdownTableCommand.edit(
            in: "abc\n\n" as NSString, selectedRange: NSRange(location: 5, length: 0),
            rows: 1, columns: 1
        )

        #expect(edit?.replacementString.hasSuffix("|   |\n") == true)
        #expect(edit?.replacementString.hasSuffix("|   |\n\n") == false)
    }

    @Test
    func replacesSelection() {
        let edit = MarkdownTableCommand.edit(
            in: "before\n\nsel\n\nafter" as NSString,
            selectedRange: NSRange(location: 8, length: 3),
            rows: 1, columns: 1
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 8, length: 3),
            replacementString: "|   |\n|---|\n|   |",
            selectedRange: NSRange(location: 10, length: 0)
        ))
    }

    @Test
    func rejectsInvalidSizes() {
        let range = NSRange(location: 0, length: 0)
        #expect(MarkdownTableCommand.edit(
            in: "" as NSString, selectedRange: range, rows: 0, columns: 1
        ) == nil)
        #expect(MarkdownTableCommand.edit(
            in: "" as NSString, selectedRange: range, rows: 1, columns: 0
        ) == nil)
        #expect(MarkdownTableCommand.edit(
            in: "" as NSString, selectedRange: range, rows: 1, columns: 100
        ) == nil)
    }

    @Test
    func rejectsOutOfBoundsRange() {
        #expect(MarkdownTableCommand.edit(
            in: "abc" as NSString, selectedRange: NSRange(location: 2, length: 5),
            rows: 1, columns: 1
        ) == nil)
        #expect(MarkdownTableCommand.edit(
            in: "abc" as NSString, selectedRange: NSRange(
                location: NSNotFound,
                length: 0
            ),
            rows: 1, columns: 1
        ) == nil)
    }
}
