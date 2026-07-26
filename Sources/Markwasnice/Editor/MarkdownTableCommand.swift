import Foundation

/// Builds an empty pipe table (header row, delimiter row, body rows) that
/// replaces the selection or is inserted at the caret. Pads the table with
/// newlines so it is separated from the surrounding text by a blank line,
/// and places the caret inside the first header cell. Pure computation over
/// (text, selection), mirroring MarkdownContinuationCommand — the text
/// arrives as an NSString so the editor can hand over the text storage's
/// backing string instead of bridging the whole document.
enum MarkdownTableCommand {
    static let sizeRange = 1 ... 99
    static let defaultRows = 3
    static let defaultColumns = 3

    private static let newline = unichar(0x0A)

    static func edit(
        in nsString: NSString,
        selectedRange: NSRange,
        rows: Int,
        columns: Int
    ) -> MarkdownMarkupEdit? {
        guard selectedRange.location != NSNotFound,
              selectedRange.location <= nsString.length,
              NSMaxRange(selectedRange) <= nsString.length,
              sizeRange.contains(rows),
              sizeRange.contains(columns)
        else {
            return nil
        }

        let cellRow = "|" + String(repeating: "   |", count: columns)
        let delimiterRow = "|" + String(repeating: "---|", count: columns)
        let table = ([cellRow, delimiterRow]
            + Array(repeating: cellRow, count: rows))
            .joined(separator: "\n")

        let prefix = leadingNewlines(in: nsString, before: selectedRange.location)
        let suffix = trailingNewlines(in: nsString, after: NSMaxRange(selectedRange))
        return MarkdownMarkupEdit(
            replacementRange: selectedRange,
            replacementString: prefix + table + suffix,
            selectedRange: NSRange(
                location: selectedRange.location + (prefix as NSString).length + 2,
                length: 0
            )
        )
    }

    /// Newlines needed before the table so a blank line separates it from
    /// the preceding text; none when only newlines (or nothing) precede it.
    private static func leadingNewlines(
        in nsString: NSString,
        before location: Int
    ) -> String {
        var count = 0
        var index = location
        while index > 0, count < 2, nsString.character(at: index - 1) == newline {
            count += 1
            index -= 1
        }
        guard index > 0 else {
            return ""
        }

        return String(repeating: "\n", count: 2 - count)
    }

    /// Newlines needed after the table: one to terminate the last row plus
    /// one blank line before the following text; just the terminator when
    /// only newlines (or nothing) follow.
    private static func trailingNewlines(
        in nsString: NSString,
        after location: Int
    ) -> String {
        var count = 0
        var index = location
        while index < nsString.length, count < 2,
              nsString.character(at: index) == newline
        {
            count += 1
            index += 1
        }
        guard index < nsString.length else {
            return count == 0 ? "\n" : ""
        }

        return String(repeating: "\n", count: 2 - count)
    }
}
