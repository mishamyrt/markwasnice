import Foundation
import Markdown

struct MarkdownParseResult: Sendable {
    let textVersion: Int
    let sourceLength: Int
    let spans: [MarkdownStyleSpan]
}

struct MarkdownStyleSpan: Sendable {
    let range: SourceRange
    let kind: MarkdownStyleKind
}

struct ResolvedMarkdownStyleSpan: Sendable {
    let range: NSRange
    let kind: MarkdownStyleKind

    func affectsTyping(at location: Int) -> Bool {
        let lowerBound = range.location
        let upperBound = range.location + range.length

        if location > lowerBound && location < upperBound {
            return true
        }

        return location == upperBound && kind.isBlockStyle
    }
}

enum MarkdownStyleKind: Sendable {
    case heading(level: Int)
    case strong
    case emphasis
    case inlineCode
    case codeBlock
    case link(destination: String?)
    case image(source: String?)
    case blockQuote
    case orderedList
    case unorderedList
    case thematicBreak
}

extension MarkdownStyleKind {
    var isBlockStyle: Bool {
        switch self {
        case .heading, .codeBlock, .blockQuote, .orderedList, .unorderedList:
            return true
        case .strong, .emphasis, .inlineCode, .link, .image, .thematicBreak:
            return false
        }
    }
}
