import Foundation
import Testing
@testable import Markwasnice

@Suite
struct MarkdownLinkStyleResolverTests {
    @Test
    func inlineLinkStylesPunctuationAndDestinationOnly() {
        let text = "See [text](https://example.com)."
        let spans = MarkdownLinkStyleResolver.resolve(
            spans: [span(location: 4, length: 27, kind: .link(destination: "https://example.com"))],
            in: text
        )

        #expect(simplify(spans) == [
            SimpleSpan(4, 1, "punctuation"),
            SimpleSpan(9, 1, "punctuation"),
            SimpleSpan(10, 1, "punctuation"),
            SimpleSpan(11, 19, "destination"),
            SimpleSpan(30, 1, "punctuation"),
        ])
    }

    @Test
    func inlineImageUsesSamePunctuationAndDestinationStyles() {
        let text = "![alt](image.png)"
        let spans = MarkdownLinkStyleResolver.resolve(
            spans: [span(location: 0, length: 17, kind: .image(source: "image.png"))],
            in: text
        )

        #expect(simplify(spans) == [
            SimpleSpan(0, 1, "punctuation"),
            SimpleSpan(1, 1, "punctuation"),
            SimpleSpan(5, 1, "punctuation"),
            SimpleSpan(6, 1, "punctuation"),
            SimpleSpan(7, 9, "destination"),
            SimpleSpan(16, 1, "punctuation"),
        ])
    }

    @Test
    func escapedLabelBracketDoesNotEndLabelEarly() {
        let text = #"[a \]](u)"#
        let spans = MarkdownLinkStyleResolver.resolve(
            spans: [span(location: 0, length: (text as NSString).length, kind: .link(destination: "u"))],
            in: text
        )

        #expect(simplify(spans) == [
            SimpleSpan(0, 1, "punctuation"),
            SimpleSpan(5, 1, "punctuation"),
            SimpleSpan(6, 1, "punctuation"),
            SimpleSpan(7, 1, "destination"),
            SimpleSpan(8, 1, "punctuation"),
        ])
    }

    @Test
    func nonInlineLinkSyntaxIsNotExpanded() {
        let text = "[text][reference]"
        let spans = MarkdownLinkStyleResolver.resolve(
            spans: [span(location: 0, length: (text as NSString).length, kind: .link(destination: "https://example.com"))],
            in: text
        )

        #expect(spans.isEmpty)
    }

    private func span(location: Int, length: Int, kind: MarkdownStyleKind) -> ResolvedMarkdownStyleSpan {
        ResolvedMarkdownStyleSpan(range: NSRange(location: location, length: length), kind: kind)
    }

    private func simplify(_ spans: [ResolvedMarkdownStyleSpan]) -> [SimpleSpan] {
        spans.map { span in
            SimpleSpan(span.range.location, span.range.length, name(for: span.kind))
        }
    }

    private func name(for kind: MarkdownStyleKind) -> String {
        switch kind {
        case .linkSyntaxPunctuation:
            "punctuation"
        case .linkDestination:
            "destination"
        default:
            "other"
        }
    }
}

private struct SimpleSpan: Equatable {
    let location: Int
    let length: Int
    let kind: String

    init(_ location: Int, _ length: Int, _ kind: String) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}
