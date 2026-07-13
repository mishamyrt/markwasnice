import Foundation

enum MarkdownBlockPrefixAnalyzer {
    private static let headingPrefixRegex =
        try! NSRegularExpression(pattern: #"^[ \t]*#{1,6}[ \t]+"#)
    private static let unorderedListPrefixRegex =
        try! NSRegularExpression(pattern: #"^[ \t]*[-+*][ \t]+"#)
    private static let orderedListPrefixRegex =
        try! NSRegularExpression(pattern: #"^[ \t]*\d+[.)][ \t]+"#)
    private static let blockQuotePrefixRegex =
        try! NSRegularExpression(pattern: #"^[ \t]*>"#)
    private static let thematicBreakRegex =
        try! NSRegularExpression(pattern: #"^[ \t]*([-+*][ \t]*){3,}$"#)

    /// Line-prefix block detection only — deliberately no fenced-code-block
    /// containment scan, which would have to walk the document from the start
    /// and is too slow to run per keystroke. Callers get code block ranges
    /// from the last parse's spans instead.
    static func prefixBlockSpan(
        for lineRange: NSRange,
        source: String
    ) -> ResolvedMarkdownStyleSpan? {
        let line = (source as NSString).substring(with: lineRange)

        if lineMatches(headingPrefixRegex, line) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .heading)
        }

        if lineMatches(unorderedListPrefixRegex, line) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .unorderedList)
        }

        if lineMatches(orderedListPrefixRegex, line) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .orderedList)
        }

        if lineMatches(blockQuotePrefixRegex, line) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .blockQuote)
        }

        if lineMatches(thematicBreakRegex, line) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .thematicBreak)
        }

        return nil
    }

    private static func lineMatches(
        _ regex: NSRegularExpression,
        _ line: String
    ) -> Bool {
        regex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) != nil
    }
}
