import Foundation

/// Enter inside a list or quote: continues the prefix on the new line
/// (incrementing ordered markers, restarting task checkboxes as unchecked),
/// while Shift+Enter indents a new line within the same list item.
/// Enter on a line holding only an empty prefix exits the list/quote by
/// clearing it. Pure computation over (text, selection), mirroring
/// MarkdownIndentCommand; returns nil when a plain newline should be
/// inserted instead. The text arrives as an NSString — everything here is
/// UTF-16 range math, and the editor hands over the text storage's backing
/// string, which bridging into a Swift String would copy on every Return.
enum MarkdownContinuationCommand {
    private static let checkboxPattern = MarkdownLineGrammar.checkbox
    private static let markerPattern = MarkdownLineGrammar.listMarker
    private static let emptyCheckbox = "[ ] "
    private static let listContinuationRegex = try! NSRegularExpression(
        pattern: "^([ \\t]*)(?:(\(markerPattern))[ \\t]+)?"
            + "(\(checkboxPattern)[ \\t]+)?(.*)$"
    )
    private static let emptyListPrefixRegex =
        try! NSRegularExpression(pattern: "^[ \\t]*\(markerPattern)\\s*$")
    private static let emptyCheckboxPrefixRegex = try! NSRegularExpression(
        pattern: "^[ \\t]*(?:\(markerPattern)\\s+)?\(checkboxPattern)\\s*$"
    )
    private static let emptyQuotePrefixRegex =
        try! NSRegularExpression(pattern: "^[ \\t]*>\\s*$")
    private static let quoteContinuationRegex =
        try! NSRegularExpression(pattern: "^([ \\t]*)>")
    private static let orderedMarkerRegex = try! NSRegularExpression(
        pattern: "^(\\d+)([\(MarkdownLineGrammar.orderedMarkerSeparators)])$"
    )

    /// The caret's line and the text from the line start up to the caret.
    /// Anchored at `location - 1` so a caret sitting right after a newline
    /// resolves to the line it just finished, not the empty next one.
    private struct CaretLineContext {
        let lineRange: NSRange
        let caretLocation: Int
        let prefix: String
    }

    static func edit(
        in nsString: NSString,
        selectedRange: NSRange,
        continuingItem: Bool = false
    ) -> MarkdownMarkupEdit? {
        guard selectedRange.length == 0,
              selectedRange.location != NSNotFound,
              selectedRange.location <= nsString.length
        else {
            return nil
        }

        let context = caretLineContext(
            in: nsString,
            caretLocation: selectedRange.location
        )
        if !continuingItem {
            if let exitEdit = exitEmptyPrefixEdit(in: nsString, context: context) {
                return exitEdit
            }
        }

        guard let continuation = listContinuation(
            in: nsString,
            context: context,
            continuingItem: continuingItem
        ) ?? (continuingItem ? nil : quoteContinuation(for: context))
        else {
            return nil
        }

        return MarkdownMarkupEdit(
            replacementRange: NSRange(location: context.caretLocation, length: 0),
            replacementString: continuation,
            selectedRange: NSRange(
                location: context.caretLocation + (continuation as NSString).length,
                length: 0
            )
        )
    }

    private static func caretLineContext(
        in nsString: NSString,
        caretLocation location: Int
    ) -> CaretLineContext {
        let lineLocation = location > 0 ? location - 1 : 0
        let lineRange = nsString.lineRange(for: NSRange(
            location: lineLocation,
            length: 0
        ))
        let prefixRange = NSRange(
            location: lineRange.location,
            length: max(0, location - lineRange.location)
        )
        return CaretLineContext(
            lineRange: lineRange,
            caretLocation: location,
            prefix: nsString.substring(with: prefixRange)
        )
    }

    private static func exitEmptyPrefixEdit(
        in nsString: NSString,
        context: CaretLineContext
    ) -> MarkdownMarkupEdit? {
        let lineText = nsString.substring(with: context.lineRange)
            .trimmingCharacters(in: .newlines)
        guard lineMatchesEmptyPrefix(lineText) else {
            return nil
        }

        let lineRange = context.lineRange
        let replacementRange = NSRange(
            location: lineRange.location,
            length: NSMaxRange(lineRange) > context.caretLocation
                ? lineRange.length
                : (context.prefix as NSString).length
        )
        return MarkdownMarkupEdit(
            replacementRange: replacementRange,
            replacementString: "\n",
            selectedRange: NSRange(
                location: replacementRange.location + 1,
                length: 0
            )
        )
    }

    private static func lineMatchesEmptyPrefix(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        let expressions = [
            emptyListPrefixRegex,
            emptyCheckboxPrefixRegex,
            emptyQuotePrefixRegex,
        ]
        return expressions.contains { expression in
            expression.firstMatch(in: line, range: range) != nil
        }
    }

    private static func listContinuation(
        in nsString: NSString,
        context: CaretLineContext,
        continuingItem: Bool
    ) -> String? {
        let indentation = String(context.prefix.prefix { $0 == " " || $0 == "\t" })
        var line = context
        while true {
            let prefix = line.prefix as NSString
            if let match = listContinuationRegex.firstMatch(
                in: line.prefix,
                range: NSRange(location: 0, length: prefix.length)
            ), match.range(at: 2).location != NSNotFound
                || match.range(at: 3).location != NSNotFound
            {
                // Preserve tabs so the continuation has the same visual columns.
                let contentIndent = String(prefix
                    .substring(to: match.range(at: 4).location)
                    .map { $0 == "\t" ? "\t" : " " })
                if line.lineRange.location == context.lineRange.location
                    || context.prefix.hasPrefix(contentIndent)
                {
                    if !continuingItem,
                       line.lineRange.location == context.lineRange.location,
                       match.range(at: 4).length == 0
                    {
                        return nil
                    }
                    if continuingItem {
                        return "\n\(contentIndent)"
                    }
                    let markerRange = match.range(at: 2)
                    let marker = markerRange.location == NSNotFound
                        ? ""
                        : nextListMarker(after: prefix.substring(with: markerRange)) + " "
                    let checkbox = match.range(at: 3).location != NSNotFound
                        ? emptyCheckbox
                        : ""
                    return "\n\(prefix.substring(with: match.range(at: 1)))\(marker)\(checkbox)"
                }
            }

            // Only walk adjacent indented lines; an unindented line ends the item.
            guard !indentation.isEmpty,
                  line.lineRange.location > 0,
                  line.prefix.hasPrefix(indentation)
            else {
                return nil
            }
            line = caretLineContext(
                in: nsString,
                caretLocation: line.lineRange.location
            )
        }
    }

    private static func quoteContinuation(for context: CaretLineContext) -> String? {
        let prefix = context.prefix as NSString
        guard let match = quoteContinuationRegex.firstMatch(
            in: context.prefix,
            range: NSRange(location: 0, length: prefix.length)
        ),
            match.numberOfRanges == 2
        else {
            return nil
        }

        let indentation = prefix.substring(with: match.range(at: 1))
        return "\n\(indentation)> "
    }

    private static func nextListMarker(after marker: String) -> String {
        guard let match = orderedMarkerRegex.firstMatch(
            in: marker,
            range: NSRange(location: 0, length: (marker as NSString).length)
        ),
            match.numberOfRanges == 3,
            let number = Int((marker as NSString).substring(with: match.range(at: 1)))
        else {
            return marker
        }

        let suffix = (marker as NSString).substring(with: match.range(at: 2))
        let (nextNumber, didOverflow) = number.addingReportingOverflow(1)
        guard !didOverflow else {
            return marker
        }
        return "\(nextNumber)\(suffix)"
    }
}
