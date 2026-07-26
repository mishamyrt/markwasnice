import Foundation

/// A "[ ]" / "[x]" opening a line that is not a list item. cmark folds the
/// checkbox of a real list item into `ListItem.checkbox` and leaves nothing in
/// the AST for this one — it is plain paragraph text — so both styling paths
/// find it by line prefix instead. List-item checkboxes are not scanned here:
/// they are already part of the list marker range (see listMarkerRegex).
enum MarkdownTaskCheckboxScanner {
    private static let bareCheckboxRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(\[[ xX]\])(?=[ \t]|$)"#,
        options: [.anchorsMatchLines]
    )

    /// The checkbox on the line covering `lineRange`, or nil when the line
    /// does not open with one. Matches within the parent string rather than
    /// materializing the line — this runs per keystroke, like
    /// MarkdownBlockPrefixAnalyzer.
    static func checkboxRange(for lineRange: NSRange, source: String) -> NSRange? {
        var start = 0
        var contentsEnd = 0
        (source as NSString).getLineStart(
            &start,
            end: nil,
            contentsEnd: &contentsEnd,
            for: lineRange
        )

        let content = NSRange(location: start, length: contentsEnd - start)
        guard let match = bareCheckboxRegex.firstMatch(
            in: source,
            options: [.anchored],
            range: content
        ),
            match.numberOfRanges > 1
        else {
            return nil
        }

        return match.range(at: 1)
    }

    /// Every bare checkbox in `source`, skipping the ones covered by
    /// `excludedRanges` (code blocks, where markdown tokens stay plain).
    static func spans(
        in source: String,
        excluding excludedRanges: [NSRange]
    ) -> [ResolvedMarkdownStyleSpan] {
        let excluded = excludedRanges.sorted { $0.location < $1.location }
        var excludedIndex = 0
        var spans: [ResolvedMarkdownStyleSpan] = []

        bareCheckboxRegex.enumerateMatches(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        ) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else {
                return
            }

            // Matches arrive in source order, so the exclusion cursor only
            // ever moves forward across the document.
            let range = match.range(at: 1)
            while excludedIndex < excluded.count,
                  NSMaxRange(excluded[excludedIndex]) <= range.location
            {
                excludedIndex += 1
            }
            guard excludedIndex == excluded.count
                || excluded[excludedIndex].location >= NSMaxRange(range)
            else {
                return
            }

            spans.append(ResolvedMarkdownStyleSpan(range: range, kind: .taskCheckbox))
        }

        return spans
    }
}
