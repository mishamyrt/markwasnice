import Foundation
import Testing
@testable import Markwasnice

@Suite
struct MarkdownCopyFormatTests {
    @Test
    func plainTextStripsInlineMarkup() {
        let converted = MarkdownCopyFormat.plainText.convert(
            "Some **bold**, *italic*, `code` and ~~gone~~."
        )

        #expect(converted == "Some bold, italic, code and gone.")
    }

    @Test
    func plainTextStripsHeadingAndHighlightMarkers() {
        let converted = MarkdownCopyFormat.plainText.convert(
            "# Title\n\nBody with ==mark==."
        )

        #expect(converted == "Title\n\nBody with mark.")
    }

    @Test
    func plainTextKeepsLinkDestination() {
        let converted = MarkdownCopyFormat.plainText.convert(
            "See [docs](https://example.com)."
        )

        #expect(converted == "See docs (https://example.com).")
    }

    @Test
    func plainTextRendersLists() {
        let converted = MarkdownCopyFormat.plainText.convert(
            "- one\n- two\n\n1. first\n2. second"
        )

        #expect(converted == "• one\n• two\n\n1. first\n2. second")
    }

    @Test
    func plainTextUnwrapsCodeBlock() {
        let converted = MarkdownCopyFormat.plainText.convert(
            "```swift\nlet a = 1\n```"
        )

        #expect(converted == "let a = 1")
    }

    @Test
    func telegramConvertsItalicAndKeepsBold() {
        let converted = MarkdownCopyFormat.telegram.convert(
            "Some **bold**, *italic*, `code` and ~~struck~~."
        )

        #expect(converted == "Some **bold**, __italic__, `code` and ~~struck~~.")
    }

    @Test
    func telegramTurnsHeadingIntoBold() {
        let converted = MarkdownCopyFormat.telegram.convert(
            "## Section\n\nText"
        )

        #expect(converted == "**Section**\n\nText")
    }

    @Test
    func telegramKeepsCodeBlockFence() {
        let converted = MarkdownCopyFormat.telegram.convert(
            "```swift\nlet a = 1\n```"
        )

        #expect(converted == "```swift\nlet a = 1\n```")
    }

    @Test
    func telegramDegradesLinkToLabelWithURL() {
        let converted = MarkdownCopyFormat.telegram.convert(
            "See [docs](https://example.com)."
        )

        #expect(converted == "See docs (https://example.com).")
    }

    @Test
    func blockQuoteContentIsKept() {
        let converted = MarkdownCopyFormat.plainText.convert(
            "> quoted **text**"
        )

        #expect(converted == "quoted text")
    }
}
