import Foundation
import Testing
@testable import Markwasnice

@Suite
struct MarkdownInlineStyleScannerTests {
    @Test
    func strikethroughSpanCoversMarkers() {
        let source = "Some ~~gone~~ text"
        let spans = MarkdownInlineStyleScanner.inlineSpans(
            in: NSRange(location: 0, length: (source as NSString).length),
            source: source
        )

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 5, length: 8),
            kind: .strikethrough
        )))
    }

    @Test
    func shiftedLineKeepsInlineSpans() {
        let source = "    **bold** text"
        let spans = MarkdownInlineStyleScanner.inlineSpans(
            in: NSRange(location: 0, length: (source as NSString).length),
            source: source
        )

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 4, length: 8),
            kind: .strong
        )))
    }

    @Test
    func tabShiftedLineKeepsInlineSpans() {
        let source = "\t~~gone~~ text"
        let spans = MarkdownInlineStyleScanner.inlineSpans(
            in: NSRange(location: 0, length: (source as NSString).length),
            source: source
        )

        #expect(spans.contains(ResolvedMarkdownStyleSpan(
            range: NSRange(location: 1, length: 8),
            kind: .strikethrough
        )))
    }

    @Test
    func strikethroughInsideInlineCodeStaysPlain() {
        let source = "Code `~~kept~~` here"
        let spans = MarkdownInlineStyleScanner.inlineSpans(
            in: NSRange(location: 0, length: (source as NSString).length),
            source: source
        )

        #expect(!spans.contains { $0.kind == .strikethrough })
    }
}
