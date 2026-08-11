import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct RichTextMarkdownConverterTests {
    @Test func prefersDeclaredMarkdownPasteboardContent() {
        #expect(RichTextMarkdownConverter.preferredText(
            markdownText: "# Markdown\u{2028}body",
            plainText: "rich text",
            richText: NSAttributedString(string: "rich text")
        ) == "# Markdown\nbody")
    }

    @Test func prefersPlainSourceWhenItContainsMarkdownSyntax() {
        let richText = NSMutableAttributedString(string: "**bold**")
        richText.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 0, length: richText.length)
        )

        #expect(RichTextMarkdownConverter.preferredText(
            plainText: "**bold**",
            richText: richText
        ) == "**bold**")
    }

    @Test func detectsBlockAndInlineMarkdownSyntax() {
        let samples = [
            "# Heading",
            "A **bold** word",
            "- list item",
            "> quote",
            "`inline code`",
            "[link](https://example.com)",
            "~~removed~~",
            "```swift\nlet value = 1\n```",
            "| Name | Value |\n| --- | --- |\n| A | 1 |",
        ]
        let richText = NSAttributedString(string: "converted")

        for sample in samples {
            #expect(RichTextMarkdownConverter.preferredText(
                plainText: sample,
                richText: richText
            ) == sample)
        }
    }

    @Test func keepsRichConversionForOrdinaryPlainText() {
        let samples = [
            "Meeting notes #42",
            "Temperature is -5 degrees",
            "Multiply 2 * 3",
            "https://example.com",
        ]
        let richText = NSMutableAttributedString(string: "bold")
        richText.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 0, length: richText.length)
        )

        for sample in samples {
            #expect(RichTextMarkdownConverter.preferredText(
                plainText: sample,
                richText: richText
            ) == "**bold**")
        }
    }

    @Test func convertsBoldItalicStrikethroughAndLinks() throws {
        let source =
            NSMutableAttributedString(string: "plain bold italic both strike link")
        let link = try #require(URL(string: "https://example.com/a_(b)"))
        source.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: range(of: "bold", in: source.string)
        )
        source.addAttribute(
            .font,
            value: NSFontManager.shared.convert(
                NSFont.systemFont(ofSize: 13),
                toHaveTrait: .italicFontMask
            ),
            range: range(of: "italic", in: source.string)
        )
        source.addAttribute(
            .font,
            value: NSFontManager.shared.convert(
                NSFont.boldSystemFont(ofSize: 13),
                toHaveTrait: .italicFontMask
            ),
            range: range(of: "both", in: source.string)
        )
        source.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: range(of: "strike", in: source.string)
        )
        source.addAttribute(
            .link,
            value: link,
            range: range(of: "link", in: source.string)
        )

        #expect(RichTextMarkdownConverter.convert(source)
            ==
            "plain **bold** *italic* ***both*** ~~strike~~ [link](https://example.com/a_%28b%29)")
    }

    @Test func keepsWhitespaceOutsideEmphasisAndEscapesMarkdown() {
        let source = NSMutableAttributedString(string: "before *bold* after")
        source.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 6, length: 8)
        )

        #expect(RichTextMarkdownConverter.convert(source)
            == "before **\\*bold\\*** after")
    }

    @Test func preservesUnicodeWhileEscapingMarkdown() {
        let source = NSAttributedString(string: "Привет 👋 *тест*")

        #expect(RichTextMarkdownConverter.convert(source)
            == "Привет 👋 \\*тест\\*")
    }

    @Test func normalizesUnicodeSeparatorBeforeFormattedText() {
        let source = NSMutableAttributedString(string: "before\u{2028}bold")
        source.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 7, length: 4)
        )

        #expect(RichTextMarkdownConverter.convert(source) == "before\n**bold**")
    }

    @Test func normalizesSeparatorsInPlainText() {
        #expect(RichTextMarkdownConverter.normalizeLineSeparators(
            "one\u{2028}two\u{2029}three"
        ) == "one\ntwo\nthree")
    }

    @Test func convertsNestedLists() {
        // This is the marker shape produced by AppKit's HTML importer.
        let source = NSMutableAttributedString(string: "\t•\tone\n\t1.\ttwo")
        let outer = NSTextList(markerFormat: .disc, options: 0)
        let inner = NSTextList(markerFormat: .decimal, options: 0)
        let firstStyle = NSMutableParagraphStyle()
        firstStyle.textLists = [outer]
        let secondStyle = NSMutableParagraphStyle()
        secondStyle.textLists = [outer, inner]
        source.addAttribute(
            .paragraphStyle,
            value: firstStyle,
            range: NSRange(location: 0, length: 7)
        )
        source.addAttribute(
            .paragraphStyle,
            value: secondStyle,
            range: NSRange(location: 7, length: 7)
        )

        #expect(RichTextMarkdownConverter.convert(source) == "- one\n    1. two")
    }

    @Test func convertsTextTableUsingFirstRowAsMarkdownHeader() {
        let table = NSTextTable()
        table.numberOfColumns = 2
        let source = NSMutableAttributedString()
        appendCell("Name", row: 0, column: 0, table: table, to: source)
        appendCell("Value", row: 0, column: 1, table: table, to: source)
        appendCell("A | B", row: 1, column: 0, table: table, to: source)
        appendCell("42", row: 1, column: 1, table: table, to: source)

        #expect(RichTextMarkdownConverter.convert(source) == #"""
        | Name | Value |
        | --- | --- |
        | A \| B | 42 |
        """#)
    }

    private func appendCell(
        _ text: String,
        row: Int,
        column: Int,
        table: NSTextTable,
        to source: NSMutableAttributedString
    ) {
        let style = NSMutableParagraphStyle()
        style.textBlocks = [NSTextTableBlock(
            table: table,
            startingRow: row,
            rowSpan: 1,
            startingColumn: column,
            columnSpan: 1
        )]
        source.append(NSAttributedString(
            string: text + "\n",
            attributes: [.paragraphStyle: style]
        ))
    }

    private func range(of substring: String, in string: String) -> NSRange {
        (string as NSString).range(of: substring)
    }
}
