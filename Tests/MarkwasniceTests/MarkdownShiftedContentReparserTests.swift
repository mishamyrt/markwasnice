import Foundation
import Testing
@testable import Markwasnice

@Suite
struct MarkdownShiftedContentReparserTests {
    private func parsedSpans(for text: String) -> [ResolvedMarkdownStyleSpan] {
        MarkdownParseService.parse(text: text, version: 1, previous: nil)!.spans
    }

    private func spanTexts(
        of kind: MarkdownStyleKind,
        in text: String
    ) -> [String] {
        let nsText = text as NSString
        return parsedSpans(for: text)
            .filter { $0.kind == kind }
            .compactMap { span in
                NSMaxRange(span.range) <= nsText.length
                    ? nsText.substring(with: span.range)
                    : nil
            }
    }

    // MARK: Indented code blocks re-read as shifted text

    @Test
    func spaceShiftedLineKeepsStrongStyle() {
        let spans = parsedSpans(for: "    **bold** text")

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 4, length: 8),
            kind: .strong
        )))
        #expect(!spans.contains { $0.kind == .codeBlock })
    }

    @Test
    func tabShiftedLineKeepsEmphasisStyle() {
        let spans = parsedSpans(for: "\t*em* text")

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 1, length: 4),
            kind: .emphasis
        )))
        #expect(!spans.contains { $0.kind == .codeBlock })
    }

    @Test
    func shiftedHeadingKeepsHeadingStyle() {
        let spans = parsedSpans(for: "    # Title")

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 4, length: 7),
            kind: .heading
        )))
        #expect(!spans.contains { $0.kind == .codeBlock })
    }

    @Test
    func shiftedListKeepsListStyle() {
        let spans = parsedSpans(for: "    - item\n        - nested")

        #expect(spans.contains { $0.kind == .unorderedList })
        #expect(!spans.contains { $0.kind == .codeBlock })
    }

    @Test
    func indentedBlockInsideListItemKeepsInlineStyles() {
        let spans = parsedSpans(for: "- item\n\n        deep *em*")

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 21, length: 4),
            kind: .emphasis
        )))
        #expect(!spans.contains { $0.kind == .codeBlock })
    }

    @Test
    func blankLineInsideShiftedTextKeepsBothParts() {
        let spans = parsedSpans(for: "    **a**\n\n    *b*")

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 4, length: 5),
            kind: .strong
        )))
        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 15, length: 3),
            kind: .emphasis
        )))
        #expect(!spans.contains { $0.kind == .codeBlock })
    }

    @Test
    func deeperShiftAfterBlankLineReparsesRecursively() {
        let spans = parsedSpans(for: "    a\n\n        **b**")

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 15, length: 5),
            kind: .strong
        )))
        #expect(!spans.contains { $0.kind == .codeBlock })
    }

    @Test
    func fencedBlockStaysCode() {
        let spans = parsedSpans(for: "```\n**not bold**\n```")

        #expect(spans.contains { $0.kind == .codeBlock })
        #expect(!spans.contains { $0.kind == .strong })
    }

    @Test
    func shiftedFenceStaysCode() {
        let spans = parsedSpans(for: "    ```\n    **not bold**\n    ```")

        #expect(spans.contains { $0.kind == .codeBlock })
        #expect(!spans.contains { $0.kind == .strong })
    }

    @Test
    func indentedCodeInsideBlockQuoteStaysCode() {
        let spans = parsedSpans(for: ">     code")

        #expect(spans.contains { $0.kind == .blockQuote })
    }

    @Test
    func shiftedLinkGetsResolvedSubSpans() {
        let spans = parsedSpans(for: "    [label](https://example.com)")

        #expect(spans.contains { $0.kind == .linkDestination })
        #expect(!spans.contains { $0.kind == .codeBlock })
    }

    // MARK: Shifted paragraph continuation lines

    @Test
    func shiftedContinuationLinesKeepStrongSpansOnMarkers() {
        let text = "Я не понял планов развития:\n"
            + "    Зд и так в **плане**\n"
            + "    **REDIS** и так в **планах**"

        #expect(spanTexts(of: .strong, in: text) == [
            "**плане**", "**REDIS**", "**планах**",
        ])
    }

    @Test
    func slightlyShiftedContinuationLineKeepsEmphasisSpan() {
        #expect(spanTexts(of: .emphasis, in: "a\n  *b*") == ["*b*"])
    }

    @Test
    func listItemContinuationLineKeepsStrongSpan() {
        #expect(spanTexts(of: .strong, in: "- item\n    cont **b**") == ["**b**"])
    }

    @Test
    func strongAcrossShiftedContinuationLineCoversBothLines() {
        #expect(
            spanTexts(of: .strong, in: "para **a\n    b** c") == ["**a\n    b**"]
        )
    }

    @Test
    func unshiftedMultilineParagraphIsUntouched() {
        #expect(spanTexts(of: .strong, in: "para **a**\nnext **b**") == [
            "**a**", "**b**",
        ])
    }
}
