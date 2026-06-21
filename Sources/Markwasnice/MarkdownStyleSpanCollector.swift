import Markdown

struct MarkdownStyleSpanCollector: MarkupWalker {
    private(set) var spans: [MarkdownStyleSpan] = []

    mutating func visitHeading(_ heading: Heading) {
        add(.heading(level: heading.level), for: heading)
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
