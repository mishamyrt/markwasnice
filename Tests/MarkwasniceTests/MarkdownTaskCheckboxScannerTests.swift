import Foundation
import Testing
@testable import Markwasnice

struct MarkdownTaskCheckboxScannerTests {
    private func parsedCheckboxRanges(in text: String) -> [NSRange] {
        MarkdownParseService.parse(text: text, version: 1, previous: nil)!
            .spans
            .filter { $0.kind == .taskCheckbox }
            .map(\.range)
    }

    /// What the per-keystroke path produces, line by line — it has to agree
    /// with the parse, otherwise the checkbox repaints when the parse lands.
    private func localCheckboxRanges(in text: String) -> [NSRange] {
        let string = text as NSString
        var ranges: [NSRange] = []
        var lineStart = 0
        while lineStart < string.length {
            let lineRange = string.lineRange(
                for: NSRange(location: lineStart, length: 0)
            )
            if let range = MarkdownTaskCheckboxScanner.checkboxRange(
                for: lineRange,
                source: text
            ) {
                ranges.append(range)
            }
            lineStart = max(NSMaxRange(lineRange), lineStart + 1)
        }

        return ranges
    }

    @Test func stylesCheckboxWithoutListMarker() {
        let ranges = parsedCheckboxRanges(in: "[x] standalone")

        #expect(ranges == [NSRange(location: 0, length: 3)])
    }

    @Test func stylesEveryLineOfACheckboxParagraph() {
        // cmark folds these three lines into one paragraph with soft breaks
        // and misreports the source columns of the continuation lines, so the
        // scan is line-anchored rather than AST-driven.
        let text = "[ ] one\n[x] two\n  [ ] three"
        let ranges = parsedCheckboxRanges(in: text)

        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3),
            NSRange(location: 18, length: 3),
        ])
        #expect(localCheckboxRanges(in: text) == ranges)
    }

    @Test func stylesCheckboxWithNoTextAfterIt() {
        // The state right after Enter continues a checkbox list.
        #expect(parsedCheckboxRanges(in: "[ ] one\n[ ] ") == [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3),
        ])
    }

    @Test func leavesListItemCheckboxToTheListMarker() {
        #expect(parsedCheckboxRanges(in: "- [ ] item").isEmpty)
        #expect(parsedCheckboxRanges(in: "1. [x] item").isEmpty)
        #expect(localCheckboxRanges(in: "- [ ] item").isEmpty)
    }

    @Test func ignoresCheckboxInsideFencedCode() {
        let text = "```\n[ ] not a task\n```"

        #expect(parsedCheckboxRanges(in: text).isEmpty)
    }

    @Test func ignoresCheckboxInsideFrontmatter() {
        let text = "---\ntitle: [x]\n---\n[ ] task"
        let ranges = parsedCheckboxRanges(in: text)

        // Only the one below the frontmatter block survives.
        #expect(ranges == [NSRange(location: 19, length: 3)])
    }

    @Test func ignoresBracketsThatAreNotACheckbox() {
        #expect(parsedCheckboxRanges(in: "[x]: https://example.com").isEmpty)
        #expect(parsedCheckboxRanges(in: "[ok] text").isEmpty)
        #expect(parsedCheckboxRanges(in: "text [ ] mid-line").isEmpty)
        #expect(parsedCheckboxRanges(in: "> [ ] quoted").isEmpty)
    }

    @Test func indentedCheckboxIsStyledRatherThanReadAsCode() {
        // Indentation is a visual shift in this editor, so the four-space line
        // is not an indented code block (see MarkdownShiftedContentReparser).
        #expect(parsedCheckboxRanges(in: "    [ ] shifted") == [
            NSRange(location: 4, length: 3),
        ])
    }
}
