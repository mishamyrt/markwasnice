import Foundation
import Markdown

struct MarkdownStyleSpanCollector: MarkupWalker {
    private(set) var spans: [MarkdownStyleSpan] = []
    private var htmlRanges: [(range: SourceRange, lineCount: Int?)] = []

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        if let range = html.range {
            // cmark can report the end before the closing delimiter. The
            // literal's line count still describes the complete HTML block.
            let lineCount = html.rawHTML.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).count
                - (html.rawHTML.hasSuffix("\n") ? 1 : 0)
            htmlRanges.append((range, lineCount))
        }
    }

    mutating func visitInlineHTML(_ html: InlineHTML) {
        if let range = html.range {
            htmlRanges.append((range, nil))
        }
    }

    func resolvedSpans(
        in source: String,
        sourceMap: SourceMap,
        droppingZeroLength: Bool
    ) -> [ResolvedMarkdownStyleSpan] {
        var result = sourceMap.resolvedSpans(
            from: spans,
            droppingZeroLength: droppingZeroLength
        )
        let string = source as NSString
        let lines = htmlRanges.isEmpty ? [] : sourceMap.lineRanges()
        for (htmlRange, lineCount) in htmlRanges {
            guard var range = sourceMap.nsRange(for: htmlRange) else {
                continue
            }
            if let lineCount {
                let lastLine = min(
                    htmlRange.lowerBound.line + lineCount - 2,
                    lines.count - 1
                )
                range.length = NSMaxRange(lines[lastLine]) - range.location
            }
            result.append(contentsOf: MarkdownHTMLComment.ranges(
                in: string.substring(with: range)
            ).map {
                ResolvedMarkdownStyleSpan(
                    range: NSRange(
                        location: range.location + $0.location,
                        length: $0.length
                    ),
                    kind: .htmlComment
                )
            })
        }
        return result
    }

    mutating func visitHeading(_ heading: Heading) {
        add(.heading, for: heading)
        descendInto(heading)
    }

    mutating func visitStrong(_ strong: Strong) {
        add(.strong, for: strong)
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        add(.emphasis, for: emphasis)
        descendInto(emphasis)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        add(.strikethrough, for: strikethrough)
        descendInto(strikethrough)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        add(.inlineCode, for: inlineCode)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        add(.codeBlock, for: codeBlock)
    }

    mutating func visitLink(_ link: Link) {
        add(.link(destination: link.destination), for: link)
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) {
        add(.image(source: image.source), for: image)
        descendInto(image)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        add(.blockQuote, for: blockQuote)
        descendInto(blockQuote)
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        add(.orderedList, for: orderedList)
        descendInto(orderedList)
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        add(.unorderedList, for: unorderedList)
        descendInto(unorderedList)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        add(.thematicBreak, for: thematicBreak)
    }

    private mutating func add(_ kind: MarkdownStyleKind, for markup: Markup) {
        guard let range = markup.range else {
            return
        }

        spans.append(MarkdownStyleSpan(range: range, kind: kind))
    }
}
