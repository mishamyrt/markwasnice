import Foundation

enum MarkdownLinkStyleResolver {
    static func resolve(
        spans: [ResolvedMarkdownStyleSpan],
        in text: String
    ) -> [ResolvedMarkdownStyleSpan] {
        spans.flatMap { span in
            switch span.kind {
            case .link:
                return expandedLinkSyntaxSpans(for: span, in: text, isImage: false)
            case .image:
                return expandedLinkSyntaxSpans(for: span, in: text, isImage: true)
            default:
                return [span]
            }
        }
    }

    static func expandedLinkSyntaxSpans(
        for span: ResolvedMarkdownStyleSpan, in text: String, isImage: Bool
    ) -> [ResolvedMarkdownStyleSpan] {
        let string = text as NSString
        guard span.range.location >= 0,
              span.range.length >= 0,
              span.range.location + span.range.length <= string.length
        else {
            return []
        }

        let syntax = string.substring(with: span.range) as NSString
        let labelStart = isImage ? 1 : 0
        guard syntax.length >= (isImage ? 5 : 4),
              !isImage || syntax.character(at: 0) == Self.exclamationMark,
              syntax.character(at: labelStart) == Self.openBracket,
              let labelEnd = matchingCloseBracket(in: syntax, after: labelStart),
              labelEnd + 1 < syntax.length,
              syntax.character(at: labelEnd + 1) == Self.openParen,
              let destinationEnd = closingParen(in: syntax, after: labelEnd + 1)
        else {
            return []
        }

        let openParenIndex = labelEnd + 1
        var result: [ResolvedMarkdownStyleSpan] = []

        if isImage {
            result.append(style(
                .linkSyntaxPunctuation,
                location: span.range.location,
                length: 1
            ))
        }

        result.append(style(
            .linkSyntaxPunctuation,
            location: span.range.location + labelStart,
            length: 1
        ))
        result.append(style(
            .linkSyntaxPunctuation,
            location: span.range.location + labelEnd,
            length: 1
        ))
        result.append(style(
            .linkSyntaxPunctuation,
            location: span.range.location + openParenIndex,
            length: 1
        ))

        let destinationLength = destinationEnd - openParenIndex - 1
        if destinationLength > 0 {
            result.append(
                style(
                    .linkDestination,
                    location: span.range.location + openParenIndex + 1,
                    length: destinationLength
                )
            )
        }

        result.append(style(
            .linkSyntaxPunctuation,
            location: span.range.location + destinationEnd,
            length: 1
        ))
        return result
    }

    /// Parameters are named `…Index` and every literal is spelled `Self.x`
    /// on purpose: an index parameter named after a character constant
    /// shadows it, and heterogeneous `BinaryInteger ==` then silently
    /// compares the character against the index instead of the literal.
    private static func matchingCloseBracket(
        in string: NSString,
        after openIndex: Int
    ) -> Int? {
        var depth = 1
        var index = openIndex + 1

        while index < string.length {
            let character = string.character(at: index)
            if character == Self.backslash {
                index += 2
                continue
            }

            if character == Self.openBracket {
                depth += 1
            } else if character == Self.closeBracket {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }

            index += 1
        }

        return nil
    }

    private static func closingParen(in string: NSString, after openIndex: Int) -> Int? {
        var index = string.length - 1
        while index > openIndex {
            let character = string.character(at: index)
            if character == Self.closeParen, !isEscapedCharacter(at: index, in: string) {
                return index
            }

            index -= 1
        }

        return nil
    }

    private static func isEscapedCharacter(at index: Int, in string: NSString) -> Bool {
        var backslashCount = 0
        var current = index - 1

        while current >= 0, string.character(at: current) == Self.backslash {
            backslashCount += 1
            current -= 1
        }

        return !backslashCount.isMultiple(of: 2)
    }

    private static func style(
        _ kind: MarkdownStyleKind,
        location: Int,
        length: Int
    ) -> ResolvedMarkdownStyleSpan {
        ResolvedMarkdownStyleSpan(
            range: NSRange(location: location, length: length),
            kind: kind
        )
    }

    private static let exclamationMark: unichar = 33
    private static let openParen: unichar = 40
    private static let closeParen: unichar = 41
    private static let openBracket: unichar = 91
    private static let backslash: unichar = 92
    private static let closeBracket: unichar = 93
}
