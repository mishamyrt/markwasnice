import Foundation
import Markdown
import Testing
@testable import Markwasnice

@Suite
struct MarkdownStyleRangeDifferTests {
    @Test
    func sourceChangeDetectsInsertion() {
        let change = MarkdownStyleRangeDiffer.sourceChange(
            from: "abc",
            to: "axbc"
        )

        #expect(change.previousRange == NSRange(location: 1, length: 0))
        #expect(change.currentRange == NSRange(location: 1, length: 1))
        #expect(change.lengthDelta == 1)
    }

    @Test
    func sourceChangeDetectsDeletion() {
        let change = MarkdownStyleRangeDiffer.sourceChange(
            from: "abc",
            to: "ac"
        )

        #expect(change.previousRange == NSRange(location: 1, length: 1))
        #expect(change.currentRange == NSRange(location: 1, length: 0))
        #expect(change.lengthDelta == -1)
    }

    @Test
    func sourceChangeDetectsEditAfterMultiChunkPrefix() {
        let base = String(repeating: "a", count: 10_000)
        let change = MarkdownStyleRangeDiffer.sourceChange(
            from: base + "tail",
            to: base + "xtail"
        )

        #expect(change.previousRange == NSRange(location: 10_000, length: 0))
        #expect(change.currentRange == NSRange(location: 10_000, length: 1))
        #expect(change.lengthDelta == 1)
    }

    @Test
    func sourceChangeDetectsEditBeforeMultiChunkSuffix() {
        let base = String(repeating: "a", count: 10_000)
        let change = MarkdownStyleRangeDiffer.sourceChange(
            from: "x" + base,
            to: "y" + base
        )

        #expect(change.previousRange == NSRange(location: 0, length: 1))
        #expect(change.currentRange == NSRange(location: 0, length: 1))
        #expect(change.lengthDelta == 0)
    }

    @Test
    func sourceChangeOfIdenticalMultiChunkTextHasNoEdits() {
        let text = String(repeating: "ab", count: 5000)
        let change = MarkdownStyleRangeDiffer.sourceChange(
            from: text,
            to: text
        )

        #expect(!change.hasSourceEdits)
        #expect(change.lengthDelta == 0)
    }

    @Test
    func translatedSpansKeepSpansBeforeEdit() {
        let spans = [
            span(in: "hello world", matching: "hello", kind: .strong),
        ]
        let change = sourceChange(from: "hello world", to: "hellox world")

        let translated = MarkdownStyleRangeDiffer.translatedSpansAfterSourceChange(
            spans,
            editRange: change.currentRange,
            lengthDelta: change.lengthDelta,
            sourceLength: "hellox world".utf16.count
        )

        #expect(translated == spans)
    }

    @Test
    func translatedSpansShiftSpansAfterEdit() {
        let spans = [
            span(in: "hello world", matching: "world", kind: .strong),
        ]
        let change = sourceChange(from: "hello world", to: "hellox world")

        let translated = MarkdownStyleRangeDiffer.translatedSpansAfterSourceChange(
            spans,
            editRange: change.currentRange,
            lengthDelta: change.lengthDelta,
            sourceLength: "hellox world".utf16.count
        )

        #expect(translated == [
            span(in: "hellox world", matching: "world", kind: .strong),
        ])
    }

    @Test
    func translatedSpansDropSpansOverlappingEdit() {
        let spans = [
            span(in: "hello world", matching: "hello", kind: .strong),
        ]
        let change = sourceChange(from: "hello world", to: "hey world")

        let translated = MarkdownStyleRangeDiffer.translatedSpansAfterSourceChange(
            spans,
            editRange: change.currentRange,
            lengthDelta: change.lengthDelta,
            sourceLength: "hey world".utf16.count
        )

        #expect(translated.isEmpty)
    }

    @Test
    func identicalSpansHaveNoDirtyRanges() {
        let source = "Intro\n\n# Heading\n"
        let spans = [
            span(in: source, matching: "# Heading", kind: .heading),
        ]

        let dirtyRanges = MarkdownStyleRangeDiffer.dirtyRanges(
            from: spans,
            to: spans,
            source: source,
            lineRanges: SourceMap(text: source).lineRanges()
        )

        #expect(dirtyRanges.isEmpty)
    }

    @Test
    func changedInlineSpanDirtiesOnlyItsLine() {
        let source = "First paragraph\n\n**word** here\n\n**Later** text\n"
        let previousSpans = [
            span(in: source, matching: "**Later**", kind: .strong),
        ]
        let currentSpans = [
            span(in: source, matching: "**word**", kind: .strong),
            span(in: source, matching: "**Later**", kind: .strong),
        ]

        let dirtyRanges = MarkdownStyleRangeDiffer.dirtyRanges(
            from: previousSpans,
            to: currentSpans,
            source: source,
            lineRanges: SourceMap(text: source).lineRanges()
        )

        #expect(dirtyRanges == [lineRange(in: source, matching: "**word** here")])
    }

    @Test
    func blockSpanCoveringMultipleLinesIsEquivalentToPerLineSpans() {
        let source = "- one\n- two\n- three\n"
        let previousSpans = [
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 0, length: source.utf16.count - 1),
                kind: .unorderedList
            ),
        ]
        let currentSpans = [
            span(in: source, matching: "- one", kind: .unorderedList),
            span(in: source, matching: "- two", kind: .unorderedList),
            span(in: source, matching: "- three", kind: .unorderedList),
        ]

        let dirtyRanges = MarkdownStyleRangeDiffer.dirtyRanges(
            from: previousSpans,
            to: currentSpans,
            source: source,
            lineRanges: SourceMap(text: source).lineRanges()
        )

        #expect(dirtyRanges.isEmpty)
    }

    @Test
    func reorderedEqualSpansHaveNoDirtyRanges() {
        let source = "**a** and *b*\n"
        let strong = span(in: source, matching: "**a**", kind: .strong)
        let emphasis = span(in: source, matching: "*b*", kind: .emphasis)

        let dirtyRanges = MarkdownStyleRangeDiffer.dirtyRanges(
            from: [strong, emphasis],
            to: [emphasis, strong],
            source: source,
            lineRanges: SourceMap(text: source).lineRanges()
        )

        #expect(dirtyRanges.isEmpty)
    }

    @Test
    func duplicatedSpanIsEquivalentToSingleSpan() {
        let source = "**a** text\n"
        let strong = span(in: source, matching: "**a**", kind: .strong)

        let dirtyRanges = MarkdownStyleRangeDiffer.dirtyRanges(
            from: [strong, strong],
            to: [strong],
            source: source,
            lineRanges: SourceMap(text: source).lineRanges()
        )

        #expect(dirtyRanges.isEmpty)
    }

    @Test
    func changingBlockKindDirtiesAffectedLine() {
        let source = "# Heading\n\nParagraph\n"
        let previousSpans = [
            span(in: source, matching: "# Heading", kind: .heading),
        ]
        let currentSpans: [ResolvedMarkdownStyleSpan] = []

        let dirtyRanges = MarkdownStyleRangeDiffer.dirtyRanges(
            from: previousSpans,
            to: currentSpans,
            source: source,
            lineRanges: SourceMap(text: source).lineRanges()
        )

        #expect(dirtyRanges == [lineRange(in: source, matching: "# Heading")])
    }

    @Test
    func inlineScannerFindsCodeStrongAndEmphasis() {
        let source = "Text with `code`, **bold**, and *italic*."
        let lineRange = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))

        let spans = MarkdownInlineStyleScanner.inlineSpans(in: lineRange, source: source)

        #expect(spans.contains(span(in: source, matching: "`code`", kind: .inlineCode)))
        #expect(spans.contains(span(in: source, matching: "**bold**", kind: .strong)))
        #expect(spans.contains(span(in: source, matching: "*italic*", kind: .emphasis)))
    }

    @Test
    func inlineScannerFindsLinkAndImage() {
        let source = "A [link](https://example.com) and ![alt](image.png)."
        let lineRange = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))

        let spans = MarkdownInlineStyleScanner.inlineSpans(in: lineRange, source: source)

        #expect(spans.contains { $0.kind == .link(destination: "https://example.com") })
        #expect(spans.contains { $0.kind == .image(source: "image.png") })
    }

    @Test
    func blockAnalyzerDetectsHeading() {
        let source = "# Title"
        let lineRange = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))

        let span = MarkdownBlockPrefixAnalyzer.prefixBlockSpan(for: lineRange, source: source)

        #expect(span?.kind == .heading)
    }

    @Test
    func blockAnalyzerDetectsUnorderedList() {
        let source = "- item"
        let lineRange = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))

        let span = MarkdownBlockPrefixAnalyzer.prefixBlockSpan(for: lineRange, source: source)

        #expect(span?.kind == .unorderedList)
    }

    @Test
    func blockAnalyzerDetectsOrderedList() {
        let source = "1. item"
        let lineRange = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))

        let span = MarkdownBlockPrefixAnalyzer.prefixBlockSpan(for: lineRange, source: source)

        #expect(span?.kind == .orderedList)
    }

    @Test
    func blockAnalyzerDetectsBlockQuote() {
        let source = "> quote"
        let lineRange = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))

        let span = MarkdownBlockPrefixAnalyzer.prefixBlockSpan(for: lineRange, source: source)

        #expect(span?.kind == .blockQuote)
    }

    @Test
    func blockAnalyzerDetectsThematicBreak() {
        let source = "---"
        let lineRange = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))

        let span = MarkdownBlockPrefixAnalyzer.prefixBlockSpan(for: lineRange, source: source)

        #expect(span?.kind == .thematicBreak)
    }

    @Test
    func addingListItemBetweenListAndHeadingDirtiesOnlyNewItem() {
        let current = "- first\n- new\n# Heading\n"
        let previousSpans = [
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 0, length: 7),
                kind: .unorderedList
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 14, length: 9),
                kind: .heading
            ),
        ]
        let currentSpans = parsedSpans(in: current)

        let dirtyRanges = MarkdownStyleRangeDiffer.dirtyRanges(
            from: previousSpans,
            to: currentSpans,
            source: current,
            lineRanges: SourceMap(text: current).lineRanges()
        )

        #expect(dirtyRanges == [lineRange(in: current, matching: "- new")])
    }

    @Test
    func deletingListMarkerSpacePreservesInlineCodeLocally() {
        let source = "- first\n-`second`"
        let lineRange = (source as NSString).lineRange(for: (source as NSString).range(of: "-`second`"))

        let spans = MarkdownInlineStyleScanner.inlineSpans(in: lineRange, source: source)

        #expect(spans.contains(span(in: source, matching: "`second`", kind: .inlineCode)))
    }

    private func span(
        in source: String,
        matching substring: String,
        kind: MarkdownStyleKind
    ) -> ResolvedMarkdownStyleSpan {
        let range = (source as NSString).range(of: substring)
        return ResolvedMarkdownStyleSpan(range: range, kind: kind)
    }

    private func lineRange(in source: String, matching substring: String) -> NSRange {
        let string = source as NSString
        let range = string.range(of: substring)
        guard range.location != NSNotFound else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return string.lineRange(for: range)
    }

    private func sourceChange(from previous: String, to current: String) -> SourceChange {
        MarkdownStyleRangeDiffer.sourceChange(from: previous, to: current)
    }

    private func parsedSpans(in source: String) -> [ResolvedMarkdownStyleSpan] {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var collector = MarkdownStyleSpanCollector()
        collector.visit(document)
        let sourceMap = SourceMap(text: source)
        return collector.spans.compactMap { span in
            sourceMap.nsRange(for: span.range).map {
                ResolvedMarkdownStyleSpan(range: $0, kind: span.kind)
            }
        }
    }
}
