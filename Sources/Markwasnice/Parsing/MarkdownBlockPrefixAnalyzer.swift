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
    private static let anyFenceRegex =
        try! NSRegularExpression(pattern: #"^[ \t]*(`{3,}|~{3,}).*$"#)
    private static let closingFenceRegex =
        try! NSRegularExpression(pattern: #"^[ \t]*(`{3,}|~{3,})[ \t]*$"#)

    static func blockSpan(
        for lineRange: NSRange,
        source: String
    ) -> ResolvedMarkdownStyleSpan? {
        if let codeBlockRange = codeBlockRange(containing: lineRange, in: source) {
            return ResolvedMarkdownStyleSpan(range: codeBlockRange, kind: .codeBlock)
        }

        return prefixBlockSpan(for: lineRange, source: source)
    }

    /// Line-prefix block detection only — no fenced-code-block containment
    /// scan. The fence scan walks the document from the start and is too slow
    /// to run per keystroke; callers that already know the code block ranges
    /// (e.g. from the last parse) should use this variant.
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

    private static func codeBlockRange(
        containing lineRange: NSRange,
        in source: String
    ) -> NSRange? {
        let string = source as NSString
        guard let openingFence = openingFenceLine(before: lineRange.location, in: source)
        else {
            return nil
        }

        let openingLineRange = string.lineRange(for: NSRange(
            location: openingFence.location,
            length: 0
        ))
        var lineStart = NSMaxRange(openingLineRange)

        while lineStart < string.length {
            let currentLineRange = string.lineRange(for: NSRange(
                location: lineStart,
                length: 0
            ))

            if let marker = fenceMarker(
                for: currentLineRange, in: source, matching: closingFenceRegex
            ),
                marker.character == openingFence.marker.character,
                marker.length >= openingFence.marker.length
            {
                return NSRange(
                    location: openingFence.location,
                    length: NSMaxRange(currentLineRange) - openingFence.location
                )
            }

            lineStart = NSMaxRange(currentLineRange)
        }

        return NSRange(
            location: openingFence.location,
            length: string.length - openingFence.location
        )
    }

    private static func openingFenceLine(
        before location: Int,
        in source: String
    ) -> (location: Int, marker: FenceMarker)? {
        let string = source as NSString
        var lineStart = 0
        var activeFence: (location: Int, marker: FenceMarker)?

        while lineStart < string.length {
            let lineRange = string.lineRange(for: NSRange(location: lineStart, length: 0))
            defer { lineStart = NSMaxRange(lineRange) }

            if lineRange.location > location {
                break
            }

            guard let marker = fenceMarker(
                for: lineRange, in: source, matching: anyFenceRegex
            ) else {
                continue
            }

            if let active = activeFence {
                if marker.character == active.marker.character,
                   marker.length >= active.marker.length
                {
                    activeFence = nil
                }
            } else {
                activeFence = (lineRange.location, marker)
            }
        }

        return activeFence
    }

    private static func fenceMarker(
        for lineRange: NSRange,
        in source: String,
        matching regex: NSRegularExpression
    ) -> FenceMarker? {
        let line = (source as NSString).substring(with: lineRange)
        guard let match = regex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ),
            match.numberOfRanges >= 2
        else {
            return nil
        }

        let markerRange = match.range(at: 1)
        let marker = (line as NSString).substring(with: markerRange)
        return FenceMarker(
            character: marker.hasPrefix("`") ? .backtick : .tilde,
            length: marker.utf16.count
        )
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

private struct FenceMarker {
    let character: FenceCharacter
    let length: Int
}

private enum FenceCharacter {
    case backtick
    case tilde
}
