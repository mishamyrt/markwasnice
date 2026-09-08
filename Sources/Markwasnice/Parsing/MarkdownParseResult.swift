import Foundation
import Markdown

struct MarkdownParseResult {
    let textVersion: Int
    let sourceLength: Int
    let source: String
    let spans: [ResolvedMarkdownStyleSpan]
    /// Line ranges (in `source` coordinates) whose styling differs from the
    /// previous parse. `nil` means "unknown" (first parse) and requires a full
    /// restyle. Empty means nothing changed.
    let dirtyRanges: [NSRange]?
}

struct MarkdownStyleSpan {
    let range: SourceRange
    let kind: MarkdownStyleKind
}

struct ResolvedMarkdownStyleSpan: Equatable {
    let range: NSRange
    let kind: MarkdownStyleKind

    func affectsTyping(at location: Int) -> Bool {
        let lowerBound = range.location
        let upperBound = range.location + range.length

        if location > lowerBound, location < upperBound {
            return true
        }

        return location == upperBound && kind.isBlockStyle
    }
}

enum MarkdownStyleKind: Equatable, Hashable {
    case frontmatter
    case heading
    case strong
    case emphasis
    case htmlComment
    case strikethrough
    case inlineCode
    case codeBlock
    case link(destination: String?)
    case image(source: String?)
    case linkSyntaxPunctuation
    case linkDestination
    case blockQuote
    case orderedList
    case unorderedList
    /// A checkbox standing on its own line, without a list marker in front.
    case taskCheckbox
    case thematicBreak
}

extension MarkdownStyleKind {
    var isBlockStyle: Bool {
        switch self {
        case .frontmatter, .heading, .codeBlock, .blockQuote, .orderedList,
             .unorderedList:
            return true
        case .strong, .emphasis, .htmlComment, .strikethrough, .inlineCode, .link, .image,
             .linkSyntaxPunctuation, .linkDestination, .taskCheckbox,
             .thematicBreak:
            return false
        }
    }
}
