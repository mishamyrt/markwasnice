import Foundation
import Markdown

@MainActor
final class MarkdownParseService {
    var onParse: ((MarkdownParseResult) -> Void)?

    private var nextVersion = 0
    private var latestScheduledVersion = 0
    private var parseTask: Task<Void, Never>?
    private var previousResult: MarkdownParseResult?

    deinit {
        parseTask?.cancel()
    }

    func scheduleParse(text: String) {
        nextVersion += 1
        let version = nextVersion
        latestScheduledVersion = version

        let previous = previousResult
        parseTask?.cancel()
        parseTask = Task.detached(priority: .utility) { [text, version, previous] in
            let debounce = Self.debounceMilliseconds(forTextLength: text.utf16.count)
            if debounce > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(debounce))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled,
                  let result = Self.parse(
                      text: text,
                      version: version,
                      previous: previous
                  )
            else {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, version == latestScheduledVersion else {
                    return
                }

                previousResult = result
                onParse?(result)
            }
        }
    }

    /// How long a keystroke burst gets to supersede a parse before it starts.
    /// Small documents parse fast enough that result latency matters more
    /// than the wasted work; larger ones would otherwise run a full pipeline
    /// per keystroke only to discard the result.
    nonisolated private static func debounceMilliseconds(
        forTextLength length: Int
    ) -> Int {
        switch length {
        case ..<20000:
            0
        case ..<200_000:
            20
        default:
            80
        }
    }

    /// Internal so the regression test harness can run the exact parse
    /// pipeline synchronously. Returns nil only when the surrounding task
    /// was cancelled between pipeline phases.
    nonisolated static func parse(
        text: String,
        version: Int,
        previous: MarkdownParseResult?
    ) -> MarkdownParseResult? {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        guard !Task.isCancelled else {
            return nil
        }

        var collector = MarkdownStyleSpanCollector()
        collector.visit(document)
        let sourceMap = SourceMap(text: text)
        guard !Task.isCancelled else {
            return nil
        }

        let resolvedSpans: [ResolvedMarkdownStyleSpan] = collector.spans
            .compactMap { span in
                guard let range = sourceMap.nsRange(for: span.range) else {
                    return nil
                }

                return ResolvedMarkdownStyleSpan(range: range, kind: span.kind)
            }

        // Before link resolution so links inside re-parsed shifted text get
        // their punctuation/destination sub-spans like everywhere else.
        let dedentedSpans = MarkdownShiftedContentReparser.spans(
            replacing: resolvedSpans,
            in: text,
            document: document,
            sourceMap: sourceMap
        )
        var spans = MarkdownLinkStyleResolver.resolve(spans: dedentedSpans, in: text)
        if let frontmatterRange = MarkdownFrontmatter.range(in: text) {
            // cmark reads the block as thematic breaks, setext headings and
            // paragraphs; every such span lies inside the block, so whole
            // spans are dropped rather than clipped. Editing inside the block
            // dirties all of its lines each parse (the span differ drops the
            // block span when an edit overlaps it) — same shape as
            // .codeBlock, and frontmatter blocks are small.
            spans.removeAll {
                NSIntersectionRange($0.range, frontmatterRange).length > 0
            }
            spans.insert(
                ResolvedMarkdownStyleSpan(
                    range: frontmatterRange,
                    kind: .frontmatter
                ),
                at: 0
            )
        }
        guard !Task.isCancelled else {
            return nil
        }

        return MarkdownParseResult(
            textVersion: version,
            sourceLength: text.utf16.count,
            source: text,
            spans: spans,
            dirtyRanges: dirtyRanges(
                from: previous,
                to: spans,
                source: text,
                sourceMap: sourceMap
            )
        )
    }

    nonisolated private static func dirtyRanges(
        from previous: MarkdownParseResult?,
        to spans: [ResolvedMarkdownStyleSpan],
        source: String,
        sourceMap: SourceMap
    ) -> [NSRange]? {
        guard let previous else {
            return nil
        }

        let change = MarkdownStyleRangeDiffer.sourceChange(
            from: previous.source,
            to: source
        )
        let translatedSpans = MarkdownStyleRangeDiffer.translatedSpansAfterSourceChange(
            previous.spans,
            editRange: change.currentRange,
            lengthDelta: change.lengthDelta,
            sourceLength: (source as NSString).length
        )
        var ranges = MarkdownStyleRangeDiffer.dirtyRanges(
            from: translatedSpans,
            to: spans,
            source: source,
            lineRanges: sourceMap.lineRanges()
        )

        // The heuristic local styling applied while typing can diverge from
        // the parser on the edited lines without changing span signatures, so
        // include the edited lines to let the parser re-style them
        // authoritatively. Skip when the edit region is huge (distant edits
        // between two parses); the signature diff already covers real changes.
        if change.currentRange.length <= 2048,
           change.hasSourceEdits || change.lengthDelta != 0
        {
            let string = source as NSString
            let location = min(change.currentRange.location, string.length)
            let length = min(change.currentRange.length, string.length - location)
            ranges.append(string.lineRange(
                for: NSRange(location: location, length: length)
            ))
        }

        return ranges
    }
}
