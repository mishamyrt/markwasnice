@preconcurrency import AppKit
import Markdown

/// Converts the semantic attributes supplied by rich-text pasteboards into
/// Markdown source. Both HTML and RTF are decoded by AppKit before reaching
/// this type, so the conversion path is shared by Pages, browsers, and other
/// native text editors.
enum RichTextMarkdownConverter {
    private static let markdownPasteboardType = NSPasteboard.PasteboardType(
        "net.daringfireball.markdown"
    )

    static func pasteText(from pasteboard: NSPasteboard) -> String? {
        let markdownText = pasteboard.string(forType: markdownPasteboardType)
            ?? pasteboard.data(forType: markdownPasteboardType)
                .flatMap { String(data: $0, encoding: .utf8) }
        if let markdownText {
            return preferredText(
                markdownText: markdownText,
                plainText: nil,
                richText: nil
            )
        }

        return preferredText(
            plainText: pasteboard.string(forType: .string),
            richText: attributedString(from: pasteboard)
        )
    }

    static func preferredText(
        markdownText: String? = nil,
        plainText: String?,
        richText: NSAttributedString?
    ) -> String? {
        if let markdownText {
            return normalizeLineSeparators(markdownText)
        }

        let plainText = plainText.map(normalizeLineSeparators)
        guard let richText else {
            return plainText
        }

        if let plainText, containsMarkdownSyntax(plainText) {
            return plainText
        }

        let converted = convert(richText)
        return converted.isEmpty ? plainText : converted
    }

    static func attributedString(from pasteboard: NSPasteboard) -> NSAttributedString? {
        let formats: [(NSPasteboard.PasteboardType, NSAttributedString.DocumentType)] = [
            (.html, .html),
            (.rtfd, .rtfd),
            (.rtf, .rtf),
        ]

        for (pasteboardType, documentType) in formats {
            guard let data = pasteboard.data(forType: pasteboardType) else {
                continue
            }

            if let attributedString = try? NSAttributedString(
                data: data,
                options: [.documentType: documentType],
                documentAttributes: nil
            ), attributedString.length > 0 {
                return attributedString
            }
        }

        return nil
    }

    static func convert(_ attributedString: NSAttributedString) -> String {
        guard attributedString.length > 0 else {
            return ""
        }

        let source = attributedString.string as NSString
        let paragraphs = paragraphs(in: attributedString, source: source)
        var blocks: [Block] = []
        var index = 0

        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            if let tableBlock = paragraph.tableBlock {
                var tableParagraphs = [paragraph]
                index += 1
                while index < paragraphs.count,
                      paragraphs[index].belongs(to: tableBlock.table)
                {
                    tableParagraphs.append(paragraphs[index])
                    index += 1
                }
                blocks.append(.table(renderTable(
                    tableParagraphs,
                    attributedString,
                    source: source
                )))
                continue
            }

            let contents = renderInline(
                paragraph.contentRange(in: source),
                in: attributedString,
                source: source
            )
            if let list = paragraph.list {
                blocks.append(.listItem(
                    String(repeating: "    ", count: max(0, list.depth - 1))
                        + (list.isOrdered ? "1. " : "- ")
                        + contents
                ))
            } else {
                blocks.append(.paragraph(contents))
            }
            index += 1
        }

        return normalizeLineSeparators(
            render(blocks).trimmingCharacters(in: .newlines)
        )
    }

    /// TextKit treats these Unicode separators as line boundaries, while the
    /// Markdown parser expects LF. Leaving one in the source makes the two
    /// systems disagree about every range that follows it.
    static func normalizeLineSeparators(_ string: String) -> String {
        guard string.unicodeScalars.contains(where: {
            $0 == "\u{2028}" || $0 == "\u{2029}"
        }) else {
            return string
        }

        var result = ""
        result.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\u{2028}", "\u{2029}":
                result.append("\n")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func containsMarkdownSyntax(_ string: String) -> Bool {
        let document = Document(parsing: string, options: [.disableSmartOpts])
        return document.children.contains(where: containsMarkdownSyntax)
    }

    private static func containsMarkdownSyntax(_ markup: Markup) -> Bool {
        switch markup {
        case is Markdown.Paragraph, is Text, is SoftBreak:
            return markup.children.contains(where: containsMarkdownSyntax)
        default:
            return true
        }
    }

    private struct Paragraph {
        let range: NSRange
        let paragraphStyle: NSParagraphStyle?

        var tableBlock: NSTextTableBlock? {
            paragraphStyle?.textBlocks.compactMap { $0 as? NSTextTableBlock }.last
        }

        var list: (depth: Int, isOrdered: Bool)? {
            guard let textLists = paragraphStyle?.textLists,
                  let innermost = textLists.last
            else {
                return nil
            }
            return (textLists.count, innermost.isOrdered)
        }

        func belongs(to table: NSTextTable) -> Bool {
            tableBlock?.table === table
        }

        /// AppKit's HTML/RTF import includes list markers in the backing
        /// string as `tab + marker + tab`, even though the same information
        /// is also present in `textLists`. Drop that presentation-only prefix
        /// before adding the Markdown marker.
        func contentRange(in source: NSString) -> NSRange {
            guard list != nil, range.length > 0 else {
                return range
            }

            let text = source.substring(with: range) as NSString
            guard text.hasPrefix("\t") else {
                return range
            }
            let markerEnd = text.range(
                of: "\t",
                options: [],
                range: NSRange(location: 1, length: text.length - 1)
            )
            guard markerEnd.location != NSNotFound else {
                return range
            }

            let offset = NSMaxRange(markerEnd)
            return NSRange(
                location: range.location + offset,
                length: range.length - offset
            )
        }
    }

    private enum Block {
        case paragraph(String)
        case listItem(String)
        case table(String)

        var text: String {
            switch self {
            case let .paragraph(text), let .listItem(text), let .table(text):
                text
            }
        }

        var isListItem: Bool {
            if case .listItem = self {
                return true
            }
            return false
        }
    }

    private struct InlineStyle: Equatable {
        let isBold: Bool
        let isItalic: Bool
        let isStruckThrough: Bool
        let link: String?
    }

    private struct TableCell: Hashable {
        let row: Int
        let column: Int
    }

    private static func paragraphs(
        in attributedString: NSAttributedString,
        source: NSString
    )
        -> [Paragraph]
    {
        var result: [Paragraph] = []
        var location = 0

        while location < source.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getParagraphStart(
                &start,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let attributeLocation = min(start, attributedString.length - 1)
            result.append(Paragraph(
                range: NSRange(location: start, length: contentsEnd - start),
                paragraphStyle: attributedString.attribute(
                    .paragraphStyle,
                    at: attributeLocation,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            ))
            location = max(end, location + 1)
        }

        return result
    }

    private static func render(_ blocks: [Block]) -> String {
        var result = ""
        var previous: Block?

        for block in blocks {
            if block.text.isEmpty {
                if !result.isEmpty, !result.hasSuffix("\n\n") {
                    result += "\n\n"
                }
                previous = block
                continue
            }

            if !result.isEmpty, !result.hasSuffix("\n\n") {
                result += previous?.isListItem == true && block.isListItem ? "\n" : "\n\n"
            }
            result += block.text
            previous = block
        }

        return result
    }

    private static func renderTable(
        _ paragraphs: [Paragraph],
        _ attributedString: NSAttributedString,
        source: NSString
    ) -> String {
        guard let firstBlock = paragraphs.first?.tableBlock else {
            return ""
        }

        var cells: [TableCell: [String]] = [:]
        var rowCount = 0
        var columnCount = firstBlock.table.numberOfColumns

        for paragraph in paragraphs {
            guard let block = paragraph.tableBlock else {
                continue
            }
            let cell = TableCell(row: block.startingRow, column: block.startingColumn)
            let contents = renderInline(
                paragraph.range,
                in: attributedString,
                source: source
            )
            if !contents.isEmpty {
                cells[cell, default: []].append(contents)
            }
            rowCount = max(rowCount, block.startingRow + block.rowSpan)
            columnCount = max(columnCount, block.startingColumn + block.columnSpan)
        }

        guard rowCount > 0, columnCount > 0 else {
            return ""
        }

        let rows = (0 ..< rowCount).map { row in
            (0 ..< columnCount).map { column in
                cells[TableCell(row: row, column: column)]?.joined(separator: " ") ?? ""
            }
        }
        let separator = Array(repeating: "---", count: columnCount)
        return ([rows[0], separator] + rows.dropFirst()).map(renderTableRow)
            .joined(separator: "\n")
    }

    private static func renderTableRow(_ cells: [String]) -> String {
        "| " + cells.joined(separator: " | ") + " |"
    }

    private static func renderInline(
        _ range: NSRange,
        in attributedString: NSAttributedString,
        source: NSString
    ) -> String {
        guard range.length > 0 else {
            return ""
        }

        var runs: [(InlineStyle, String)] = []
        attributedString.enumerateAttributes(in: range) { attributes, runRange, _ in
            let style = inlineStyle(from: attributes)
            let text = source.substring(with: runRange)
                .replacingOccurrences(of: "\u{fffc}", with: "")
                .replacingOccurrences(of: "\u{00a0}", with: " ")
            if runs.last?.0 == style {
                runs[runs.count - 1].1 += text
            } else {
                runs.append((style, text))
            }
        }

        return runs.map { render($0.1, style: $0.0) }.joined()
    }

    private static func inlineStyle(
        from attributes: [NSAttributedString.Key: Any]
    ) -> InlineStyle {
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        let strikeValue = (attributes[.strikethroughStyle] as? NSNumber)?.intValue
            ?? attributes[.strikethroughStyle] as? Int
            ?? 0
        let link: String? = switch attributes[.link] {
        case let url as URL:
            url.absoluteString
        case let string as String:
            string
        default:
            nil
        }

        return InlineStyle(
            isBold: traits.contains(.bold),
            isItalic: traits.contains(.italic),
            isStruckThrough: strikeValue != 0,
            link: link
        )
    }

    private static func render(_ text: String, style: InlineStyle) -> String {
        let leadingWhitespace = text.prefix(while: \Character.isWhitespace)
        let withoutLeading = text.dropFirst(leadingWhitespace.count)
        let trailingWhitespace = withoutLeading.reversed()
            .prefix(while: \Character.isWhitespace)
        let core = withoutLeading.dropLast(trailingWhitespace.count)
        guard !core.isEmpty else {
            return String(leadingWhitespace) + String(trailingWhitespace.reversed())
        }

        var result = escapeMarkdown(String(core))
        if style.isBold, style.isItalic {
            result = "***\(result)***"
        } else if style.isBold {
            result = "**\(result)**"
        } else if style.isItalic {
            result = "*\(result)*"
        }
        if style.isStruckThrough {
            result = "~~\(result)~~"
        }
        if let link = style.link, !link.isEmpty {
            result = "[\(result)](\(escapeLinkDestination(link)))"
        }

        return String(leadingWhitespace) + result + String(trailingWhitespace.reversed())
    }

    private static func escapeMarkdown(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\", "`", "*", "_", "[", "]", "~", "<", ">", "|", "#":
                result.append("\\")
            default:
                break
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static func escapeLinkDestination(_ string: String) -> String {
        guard string.unicodeScalars.contains(where: {
            $0 == " " || $0 == "(" || $0 == ")"
        }) else {
            return string
        }

        var result = ""
        result.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case " ":
                result += "%20"
            case "(":
                result += "%28"
            case ")":
                result += "%29"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
