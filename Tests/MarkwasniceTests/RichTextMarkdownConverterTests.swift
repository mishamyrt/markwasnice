import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct RichTextMarkdownConverterTests {
    @Test func largePlainTextUsesImmediatePlan() throws {
        let pasteboard = makePasteboard()
        let plainText = String(repeating: "plain ", count: 10)
        pasteboard.setString(plainText, forType: .string)
        pasteboard.setData(Data("<b>rich</b>".utf8), forType: .html)

        let plan = RichTextMarkdownConverter.pastePlan(
            from: pasteboard,
            threshold: 8
        )
        guard case let .immediate(text) = try #require(plan) else {
            Issue.record("expected an immediate plain-text paste")
            return
        }

        #expect(text == plainText)
    }

    @Test func largeHTMLUsesPlainFallbackInsteadOfDeferredImporter() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("plain", forType: .string)
        pasteboard.setData(
            Data(String(repeating: "<b>x</b>", count: 10).utf8),
            forType: .html
        )

        let plan = RichTextMarkdownConverter.pastePlan(
            from: pasteboard,
            threshold: 5
        )
        guard case let .immediate(text) = try #require(plan) else {
            Issue.record("expected the HTML plain-text fallback")
            return
        }

        #expect(text == "plain")
    }

    @Test func largeRTFProducesDeferredSendablePayload() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("plain", forType: .string)
        pasteboard.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)

        let plan = RichTextMarkdownConverter.pastePlan(
            from: pasteboard,
            threshold: 5
        )
        guard case let .deferred(paste) = try #require(plan) else {
            Issue.record("expected deferred RTF conversion")
            return
        }

        #expect(paste.plainText == "plain")
        #expect(paste.representations.count == 1)
        #expect(paste.representations.first?.format == .rtf)
    }

    @Test func largeRTFPreservesRichConversionWithLargePlainFallback() throws {
        let pasteboard = makePasteboard()
        let plainText = String(repeating: "plain ", count: 10)
        pasteboard.setString(plainText, forType: .string)
        pasteboard.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)

        let plan = RichTextMarkdownConverter.pastePlan(
            from: pasteboard,
            threshold: 8
        )
        guard case let .deferred(paste) = try #require(plan) else {
            Issue.record("expected deferred RTF conversion")
            return
        }

        #expect(paste.plainText == plainText)
        #expect(paste.representations.first?.format == .rtf)
    }

    @Test func largeHTMLWithoutPlainTextIsNotDropped() throws {
        let pasteboard = makePasteboard()
        pasteboard.setData(Data("<b>rich</b>".utf8), forType: .html)

        let plan = RichTextMarkdownConverter.pastePlan(
            from: pasteboard,
            threshold: 1
        )
        guard case let .immediate(text) = try #require(plan) else {
            Issue.record("expected synchronous HTML fallback")
            return
        }

        #expect(text == "**rich**")
    }

    @Test func largeHTMLPrefersDeferredRTFOverPlainFallback() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("plain", forType: .string)
        pasteboard.setData(Data("<b>rich</b>".utf8), forType: .html)
        pasteboard.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)

        let plan = RichTextMarkdownConverter.pastePlan(
            from: pasteboard,
            threshold: 1
        )
        guard case let .deferred(paste) = try #require(plan) else {
            Issue.record("expected background-safe RTF conversion")
            return
        }

        #expect(paste.representations.first?.format == .rtf)
    }

    @Test func invalidHTMLFallsBackToRTF() throws {
        let pasteboard = makePasteboard()
        pasteboard.setString("plain", forType: .string)
        pasteboard.setData(Data(), forType: .html)
        let rich = NSMutableAttributedString(string: "rich")
        rich.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 0, length: rich.length)
        )
        let rtfData = try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.setData(rtfData, forType: .rtf)

        let plan = RichTextMarkdownConverter.pastePlan(
            from: pasteboard,
            threshold: rtfData.count + 1
        )
        guard case let .immediate(text) = try #require(plan) else {
            Issue.record("expected synchronous RTF fallback")
            return
        }

        #expect(text == "**rich**")
    }

    @Test func convertsDeferredRTFOffTheMainActor() async throws {
        let source = NSMutableAttributedString(string: "bold")
        source.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: 13),
            range: NSRange(location: 0, length: source.length)
        )
        let data = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let paste = RichTextMarkdownConverter.DeferredPaste(
            plainText: "bold",
            representations: [.init(data: data, format: .rtf)]
        )

        let converted = await Task.detached {
            RichTextMarkdownConverter.convertDeferredPaste(paste)
        }.value

        #expect(converted == "**bold**")
    }

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

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("RichTextMarkdownConverterTests-\(UUID())")
        )
        pasteboard.clearContents()
        return pasteboard
    }
}
