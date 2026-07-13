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
        // Match within the parent string rather than materializing the line
        // as a substring — this runs per keystroke. Same pattern as
        // MarkdownFrontmatter.isDelimiterLine.
        var start = 0
        var contentsEnd = 0
        (source as NSString).getLineStart(
            &start,
            end: nil,
            contentsEnd: &contentsEnd,
            for: lineRange
        )
        let content = NSRange(location: start, length: contentsEnd - start)

        if matches(headingPrefixRegex, in: source, range: content) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .heading)
        }

        if matches(unorderedListPrefixRegex, in: source, range: content) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .unorderedList)
        }

        if matches(orderedListPrefixRegex, in: source, range: content) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .orderedList)
        }

        if matches(blockQuotePrefixRegex, in: source, range: content) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .blockQuote)
        }

        if matches(thematicBreakRegex, in: source, range: content) {
            return ResolvedMarkdownStyleSpan(range: lineRange, kind: .thematicBreak)
        }

        return nil
    }

    private static func matches(
        _ regex: NSRegularExpression,
        in source: String,
        range: NSRange
    ) -> Bool {
        regex.firstMatch(in: source, options: [.anchored], range: range) != nil
    }
}
