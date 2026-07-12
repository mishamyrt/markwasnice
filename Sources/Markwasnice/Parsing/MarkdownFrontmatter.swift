import Foundation

/// Detects a YAML frontmatter block at the start of a document: an opening
/// "---" line closed by a "---" or "..." line. Recognition only — the YAML
/// inside is never parsed here. This is the single source of truth for
/// whether a block exists; the parse pipeline, local styling, preview, and
/// typography all consult it so they can never disagree.
enum MarkdownFrontmatter {
    /// Upper bound (UTF-16 units) scanned for the closing delimiter. The
    /// scanner runs per keystroke in the local styling path; a document that
    /// opens with a thematic-break "---" and never closes it must not cost
    /// an O(document) walk per key press. Real frontmatter is far smaller.
    static let maximumScanLength = 16384

    static func range(in source: String) -> NSRange? {
        range(in: source as NSString)
    }

    /// The whole block including both delimiter lines and the closing line's
    /// trailing newline, or nil when the document has no closed frontmatter
    /// block (a lone leading "---" stays a thematic break).
    static func range(in string: NSString) -> NSRange? {
        guard string.length >= 3,
              string.character(at: 0) == dash,
              string.character(at: 1) == dash,
              string.character(at: 2) == dash
        else {
            return nil
        }

        let openingLine = string.lineRange(for: NSRange(location: 0, length: 0))
        guard isDelimiterLine(openingRegex, line: openingLine, in: string) else {
            return nil
        }

        var lineStart = NSMaxRange(openingLine)
        let scanUpperBound = min(string.length, maximumScanLength)
        while lineStart < scanUpperBound {
            let line = string.lineRange(for: NSRange(
                location: lineStart,
                length: 0
            ))
            if isDelimiterLine(closingRegex, line: line, in: string) {
                return NSRange(location: 0, length: NSMaxRange(line))
            }
            lineStart = NSMaxRange(line)
        }
        return nil
    }

    private static let dash = unichar(UInt8(ascii: "-"))

    /// Exactly three dashes at column 0; trailing spaces/tabs tolerated.
    /// "----" is a thematic break, not a frontmatter delimiter.
    private static let openingRegex = try! NSRegularExpression(
        pattern: #"^---[ \t]*$"#
    )
    /// YAML also ends a document with "...".
    private static let closingRegex = try! NSRegularExpression(
        pattern: #"^(?:---|\.\.\.)[ \t]*$"#
    )

    private static func isDelimiterLine(
        _ regex: NSRegularExpression,
        line: NSRange,
        in string: NSString
    ) -> Bool {
        var start = 0
        var end = 0
        var contentsEnd = 0
        string.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: line)
        let content = NSRange(location: start, length: contentsEnd - start)
        return regex.firstMatch(
            in: string as String,
            options: [.anchored],
            range: content
        ) != nil
    }
}
