import Foundation
import Testing
@testable import Markwasnice

struct MarkdownContinuationCommandTests {
    @Test func continuesUnorderedList() throws {
        let text = "- first"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementRange == NSRange(location: 7, length: 0))
        #expect(edit.replacementString == "\n- ")
        #expect(edit.selectedRange == NSRange(location: 10, length: 0))
    }

    @Test func continuesOrderedListIncrementingMarker() throws {
        let text = "1. first\n2. second"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n3. ")
    }

    @Test func continuesParenthesizedOrderedMarker() throws {
        let text = "3) item"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n4) ")
    }

    @Test func preservesIndentation() throws {
        let text = "  - nested"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n  - ")
    }

    @Test func continuesListCheckboxAsUnchecked() throws {
        let text = "- [x] done"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n- [ ] ")
    }

    @Test func continuesOrderedListCheckbox() throws {
        let text = "  1. [ ] first"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n  2. [ ] ")
    }

    @Test func continuesCheckboxWithoutListMarker() throws {
        let text = "  [X] standalone task"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n  [ ] ")
    }

    @Test func bracketsWithoutACheckboxStateStayPlainText() throws {
        // "[ok]" is not a checkbox, so the line continues as a plain list item.
        let text = "- [ok] link-ish"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n- ")
    }

    @Test func exitsEmptyCheckboxItem() throws {
        let text = "- [ ] first\n- [ ] "
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementRange == NSRange(location: 12, length: 6))
        #expect(edit.replacementString == "\n")
        #expect(edit.selectedRange == NSRange(location: 13, length: 0))
    }

    @Test func exitsEmptyCheckboxWithoutListMarker() throws {
        let text = "[ ] first\n[ ] "
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n")
        #expect(edit.selectedRange == NSRange(location: 11, length: 0))
    }

    @Test func continuesBlockQuote() throws {
        let text = "> quoted line"
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n> ")
    }

    @Test func exitsEmptyListItem() throws {
        let text = "- first\n- "
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        // The empty "- " prefix is replaced with a plain newline.
        #expect(edit.replacementRange == NSRange(location: 8, length: 2))
        #expect(edit.replacementString == "\n")
        #expect(edit.selectedRange == NSRange(location: 9, length: 0))
    }

    @Test func exitsEmptyQuoteLine() throws {
        let text = "> quote\n> "
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        ))

        #expect(edit.replacementString == "\n")
    }

    @Test func exitReplacesWholeLineWhenCaretIsMidLine() throws {
        let text = "- \nafter"
        // Caret inside the empty list line, before its newline.
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: 2, length: 0)
        ))

        #expect(edit.replacementRange == NSRange(location: 0, length: 3))
        #expect(edit.replacementString == "\n")
        #expect(edit.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test func caretRightAfterNewlineResolvesToPreviousLine() throws {
        let text = "- item\nplain"
        // Caret at the start of "plain" — right after the newline. The
        // location - 1 anchor resolves to the "- item" line, so Enter there
        // continues the list.
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: 7, length: 0)
        ))

        #expect(edit.replacementString == "\n- ")
    }

    @Test func plainTextProducesNoEdit() {
        let text = "just a paragraph"
        let edit = MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        )

        #expect(edit == nil)
    }

    @Test func nonEmptySelectionProducesNoEdit() {
        let text = "- first"
        let edit = MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: 0, length: 3)
        )

        #expect(edit == nil)
    }

    @Test func listMarkerWithoutContentProducesExitNotContinuation() throws {
        // "- " alone must exit, never continue with another "- ".
        let text = "- "
        let edit = try #require(MarkdownContinuationCommand.edit(
            in: text as NSString,
            selectedRange: NSRange(location: 2, length: 0)
        ))

        #expect(edit.replacementString == "\n")
    }

    @Test func outOfBoundsSelectionProducesNoEdit() {
        let edit = MarkdownContinuationCommand.edit(
            in: "- item" as NSString,
            selectedRange: NSRange(location: 100, length: 0)
        )

        #expect(edit == nil)
    }
}
