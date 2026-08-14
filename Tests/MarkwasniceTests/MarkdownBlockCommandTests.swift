import Foundation
import Testing
@testable import Markwasnice

struct MarkdownBlockCommandTests {
    @Test func addsAndRemovesBlockquote() {
        let added = MarkdownBlockCommand.blockquote.edit(
            in: "text" as NSString,
            selectedRange: NSRange(location: 2, length: 0)
        )
        #expect(added == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 4),
            replacementString: "> text",
            selectedRange: NSRange(location: 4, length: 0)
        ))

        let removed = MarkdownBlockCommand.blockquote.edit(
            in: "> text" as NSString,
            selectedRange: NSRange(location: 4, length: 0)
        )
        #expect(removed == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 6),
            replacementString: "text",
            selectedRange: NSRange(location: 2, length: 0)
        ))
    }

    @Test func blockquoteAppliesToSelectedNonblankLines() {
        let edit = MarkdownBlockCommand.blockquote.edit(
            in: "one\n\ntwo" as NSString,
            selectedRange: NSRange(location: 0, length: 8)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 8),
            replacementString: "> one\n\n> two",
            selectedRange: NSRange(location: 0, length: 12)
        ))
    }

    @Test func blockquoteDoesNotNestAlreadyQuotedLinesInMixedSelection() {
        let edit = MarkdownBlockCommand.blockquote.edit(
            in: "> one\ntwo" as NSString,
            selectedRange: NSRange(location: 0, length: 9)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 9),
            replacementString: "> one\n> two",
            selectedRange: NSRange(location: 0, length: 11)
        ))
    }

    @Test func listAddsAndRemovesBulletPrefix() {
        let added = MarkdownBlockCommand.list.edit(
            in: "item" as NSString,
            selectedRange: NSRange(location: 1, length: 0)
        )
        #expect(added == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 4),
            replacementString: "- item",
            selectedRange: NSRange(location: 3, length: 0)
        ))

        let removed = MarkdownBlockCommand.list.edit(
            in: "- item" as NSString,
            selectedRange: NSRange(location: 3, length: 0)
        )
        #expect(removed == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 6),
            replacementString: "item",
            selectedRange: NSRange(location: 1, length: 0)
        ))
    }

    @Test func orderedListNumbersSelectedLines() {
        let edit = MarkdownBlockCommand.orderedList.edit(
            in: "one\ntwo\nthree" as NSString,
            selectedRange: NSRange(location: 0, length: 13)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 13),
            replacementString: "1. one\n2. two\n3. three",
            selectedRange: NSRange(location: 0, length: 22)
        ))
    }

    @Test func listCommandReplacesExistingListKind() {
        let edit = MarkdownBlockCommand.taskList.edit(
            in: "1. first\n2. second" as NSString,
            selectedRange: NSRange(location: 0, length: 18)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 18),
            replacementString: "- [ ] first\n- [ ] second",
            selectedRange: NSRange(location: 0, length: 24)
        ))
    }

    @Test func taskConversionPreservesCompletedState() {
        let edit = MarkdownBlockCommand.orderedTaskList.edit(
            in: "- [x] done" as NSString,
            selectedRange: NSRange(location: 5, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 10),
            replacementString: "1. [x] done",
            selectedRange: NSRange(location: 7, length: 0)
        ))
    }

    @Test func listFormattingKeepsBlockquoteContainer() {
        let edit = MarkdownBlockCommand.list.edit(
            in: "> quoted" as NSString,
            selectedRange: NSRange(location: 4, length: 0)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 8),
            replacementString: "> - quoted",
            selectedRange: NSRange(location: 6, length: 0)
        ))
    }

    @Test func marksUncheckedTasksCompletedWithoutChangingCompletedTasks() {
        let edit = MarkdownBlockCommand.markTaskCompleted.edit(
            in: "- [ ] todo\n- [x] done" as NSString,
            selectedRange: NSRange(location: 0, length: 21)
        )

        #expect(edit == MarkdownMarkupEdit(
            replacementRange: NSRange(location: 0, length: 21),
            replacementString: "- [x] todo\n- [x] done",
            selectedRange: NSRange(location: 0, length: 21)
        ))
    }

    @Test func completedTaskCommandDoesNothingOutsideUncheckedTask() {
        let edit = MarkdownBlockCommand.markTaskCompleted.edit(
            in: "plain\n- [x] done" as NSString,
            selectedRange: NSRange(location: 0, length: 17)
        )

        #expect(edit == nil)
    }
}
