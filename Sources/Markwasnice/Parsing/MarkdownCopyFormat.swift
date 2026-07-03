import Foundation
import Markdown

/// Conversion targets for the "Copy as" context-menu items.
enum MarkdownCopyFormat {
    /// Markdown syntax stripped, keeping readable structure.
    case plainText
    /// The inline markup Telegram's message box understands: **bold**,
    /// __italic__, ~~strikethrough~~, `code` and ``` blocks; everything it
    /// cannot render (headings, links) degrades to readable text.
    case telegram

    func convert(_ markdown: String) -> String {
        let renderer = Renderer(format: self)
        let converted = renderer.render(Document(parsing: markdown))
        // ==highlight== is not CommonMark, so it survives parsing as literal
        // text; neither target format knows it.
        return converted.replacingOccurrences(
            of: "==([^=\\n]+)==",
            with: "$1",
            options: .regularExpression
        )
    }

    private struct Renderer {
        let format: MarkdownCopyFormat

        func render(_ document: Document) -> String {
            renderBlocks(document.blockChildren)
        }

        private func renderBlocks(
            _ blocks: some Sequence<BlockMarkup>
        ) -> String {
            blocks.map(renderBlock).joined(separator: "\n\n")
        }

        private func renderBlock(_ block: BlockMarkup) -> String {
            switch block {
            case let heading as Heading:
                let text = renderInlines(heading.inlineChildren)
                return format == .telegram ? "**\(text)**" : text
            case let paragraph as Paragraph:
                return renderInlines(paragraph.inlineChildren)
            case let codeBlock as CodeBlock:
                let code = codeBlock.code.trimmingCharacters(
                    in: .newlines
                )
                guard format == .telegram else {
                    return code
                }

                return "```\(codeBlock.language ?? "")\n\(code)\n```"
            case let quote as BlockQuote:
                return renderBlocks(quote.blockChildren)
            case let list as UnorderedList:
                return list.listItems
                    .map { "• " + renderListItem($0) }
                    .joined(separator: "\n")
            case let list as OrderedList:
                return list.listItems.enumerated()
                    .map { "\($0 + 1). " + renderListItem($1) }
                    .joined(separator: "\n")
            case is ThematicBreak:
                return "—"
            case let html as HTMLBlock:
                return html.rawHTML.trimmingCharacters(in: .newlines)
            default:
                return block.format()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        private func renderListItem(_ item: ListItem) -> String {
            item.blockChildren.map(renderBlock).joined(separator: "\n")
        }

        private func renderInlines(
            _ inlines: some Sequence<InlineMarkup>
        ) -> String {
            inlines.map(renderInline).joined()
        }

        private func renderInline(_ inline: InlineMarkup) -> String {
            switch inline {
            case let text as Text:
                return text.string
            case let code as InlineCode:
                return format == .telegram ? "`\(code.code)`" : code.code
            case let strong as Strong:
                let inner = renderInlines(strong.inlineChildren)
                return format == .telegram ? "**\(inner)**" : inner
            case let emphasis as Emphasis:
                let inner = renderInlines(emphasis.inlineChildren)
                return format == .telegram ? "__\(inner)__" : inner
            case let strikethrough as Strikethrough:
                let inner = renderInlines(strikethrough.inlineChildren)
                return format == .telegram ? "~~\(inner)~~" : inner
            case let link as Link:
                let label = renderInlines(link.inlineChildren)
                guard let destination = link.destination,
                      !destination.isEmpty,
                      destination != label
                else {
                    return label
                }

                return "\(label) (\(destination))"
            case let image as Image:
                let label = renderInlines(image.inlineChildren)
                return label.isEmpty ? (image.source ?? "") : label
            case is SoftBreak, is LineBreak:
                return "\n"
            case let html as InlineHTML:
                return html.rawHTML
            default:
                return inline.format()
            }
        }
    }
}
