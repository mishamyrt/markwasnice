import Foundation

/// Line-based extraction of YAML scalar-value content inside a frontmatter
/// block for the typography command. Not a YAML parser: it understands
/// single-line plain and quoted scalars, sequence items, and literal/folded
/// block scalars. Multi-line quoted scalars, flow collections ([..], {..})
/// and anchors/aliases are left untouched.
enum FrontmatterValueScanner {
    /// Ranges (in source coordinates) of string-value content that typography
    /// may rewrite. Keys, indentation, "-" sequence markers, quote delimiters
    /// of quoted scalars, and comments are excluded, so the YAML structure
    /// survives any rewrite of the returned ranges. Ranges are ascending and
    /// disjoint.
    static func valueRanges(
        in frontmatterRange: NSRange,
        source: NSString
    ) -> [NSRange] {
        guard frontmatterRange.length > 0,
              NSMaxRange(frontmatterRange) <= source.length
        else {
            return []
        }

        let openingLine = source.lineRange(
            for: NSRange(location: frontmatterRange.location, length: 0)
        )
        let closingLine = source.lineRange(
            for: NSRange(location: NSMaxRange(frontmatterRange) - 1, length: 0)
        )

        var ranges: [NSRange] = []
        // Indent of the key line that opened a literal/folded block scalar;
        // while set, deeper-indented lines are string content as a whole.
        var blockScalarParentIndent: Int?
        var lineStart = NSMaxRange(openingLine)
        while lineStart < closingLine.location {
            let line = source.lineRange(for: NSRange(location: lineStart, length: 0))
            defer { lineStart = NSMaxRange(line) }

            var contentStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &contentStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: line
            )
            let content = source.substring(with: NSRange(
                location: contentStart,
                length: contentsEnd - contentStart
            )) as NSString
            let indent = leadingWhitespaceLength(of: content)
            let isBlank = indent == content.length

            if let parentIndent = blockScalarParentIndent {
                if isBlank {
                    continue
                }
                if indent > parentIndent {
                    ranges.append(NSRange(
                        location: contentStart + indent,
                        length: content.length - indent
                    ))
                    continue
                }
                blockScalarParentIndent = nil
            }

            if isBlank || content.character(at: indent) == hash {
                continue
            }

            guard let value = valueRange(in: content) else {
                continue
            }
            appendValueContent(
                value,
                in: content,
                lineIndent: indent,
                lineContentStart: contentStart,
                to: &ranges,
                blockScalarParentIndent: &blockScalarParentIndent
            )
        }
        return ranges
    }

    // MARK: Line classification

    /// "key: value" (with optional "- " sequence prefixes) or a plain
    /// sequence item "- value". Anything else — nested-structure lines,
    /// plain-scalar continuations — is skipped.
    private static let keyLineRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:-[ \t]+)*[^:#][^:]*:(?:[ \t]+(.*))?$"#
    )
    private static let sequenceItemRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*-[ \t]+(.*)$"#
    )

    /// The value part of the line, relative to `content`, or nil when the
    /// line carries no scalar value ("key:" opening a nested structure
    /// included).
    private static func valueRange(in content: NSString) -> NSRange? {
        let full = NSRange(location: 0, length: content.length)
        for regex in [keyLineRegex, sequenceItemRegex] {
            if let match = regex.firstMatch(in: content as String, range: full) {
                let value = match.range(at: 1)
                return value.location == NSNotFound || value.length == 0
                    ? nil
                    : value
            }
        }
        return nil
    }

    // MARK: Value classification

    private static let blockScalarHeaderRegex = try! NSRegularExpression(
        pattern: #"^[|>][0-9+-]*[ \t]*(?:#.*)?$"#
    )
    /// Whole-line quoted scalar first, then quoted scalar followed by an
    /// inline comment. Greedy inner group keeps unescaped same-type quotes
    /// inside the delimiters; backtracking in the comment variant still
    /// stops at the delimiter that precedes " #".
    private static let doubleQuotedRegexes = [
        try! NSRegularExpression(pattern: #"^"(.*)"[ \t]*$"#),
        try! NSRegularExpression(pattern: #"^"(.*)"[ \t]+#.*$"#),
    ]
    private static let singleQuotedRegexes = [
        try! NSRegularExpression(pattern: #"^'(.*)'[ \t]*$"#),
        try! NSRegularExpression(pattern: #"^'(.*)'[ \t]+#.*$"#),
    ]
    private static let inlineCommentRegex = try! NSRegularExpression(
        pattern: #"[ \t]#"#
    )

    private static func appendValueContent(
        _ value: NSRange,
        in content: NSString,
        lineIndent: Int,
        lineContentStart: Int,
        to ranges: inout [NSRange],
        blockScalarParentIndent: inout Int?
    ) {
        let valueText = content.substring(with: value) as NSString
        let full = NSRange(location: 0, length: valueText.length)
        let first = valueText.character(at: 0)

        if first == hash {
            // "key: # comment" — no value at all.
            return
        }
        if blockScalarHeaderRegex.firstMatch(
            in: valueText as String,
            range: full
        ) != nil {
            blockScalarParentIndent = lineIndent
            return
        }
        if first == doubleQuote || first == singleQuote {
            let regexes = first == doubleQuote
                ? doubleQuotedRegexes
                : singleQuotedRegexes
            for regex in regexes {
                if let match = regex.firstMatch(
                    in: valueText as String,
                    range: full
                ) {
                    let inner = match.range(at: 1)
                    if inner.length > 0 {
                        ranges.append(NSRange(
                            location: lineContentStart + value.location
                                + inner.location,
                            length: inner.length
                        ))
                    }
                    return
                }
            }
            // Unterminated on this line (multi-line quoted scalar) — skip.
            return
        }
        if flowAndAliasStarters.contains(first) {
            return
        }

        // Plain scalar: ends at an inline comment, trailing whitespace is
        // not content.
        var length = value.length
        if let comment = inlineCommentRegex.firstMatch(
            in: valueText as String,
            range: full
        ) {
            length = comment.range.location
        }
        while length > 0, isSpaceOrTab(valueText.character(at: length - 1)) {
            length -= 1
        }
        if length > 0 {
            ranges.append(NSRange(
                location: lineContentStart + value.location,
                length: length
            ))
        }
    }

    // MARK: Character helpers

    private static let hash = unichar(UInt8(ascii: "#"))
    private static let doubleQuote = unichar(UInt8(ascii: "\""))
    private static let singleQuote = unichar(UInt8(ascii: "'"))
    private static let space = unichar(UInt8(ascii: " "))
    private static let tab = unichar(UInt8(ascii: "\t"))
    private static let flowAndAliasStarters: Set<unichar> = [
        unichar(UInt8(ascii: "[")),
        unichar(UInt8(ascii: "{")),
        unichar(UInt8(ascii: "&")),
        unichar(UInt8(ascii: "*")),
    ]

    private static func isSpaceOrTab(_ character: unichar) -> Bool {
        character == space || character == tab
    }

    private static func leadingWhitespaceLength(of content: NSString) -> Int {
        var index = 0
        while index < content.length, isSpaceOrTab(content.character(at: index)) {
            index += 1
        }
        return index
    }
}
