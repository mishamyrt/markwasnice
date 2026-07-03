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
            let debounce = text.utf16.count > 200_000 ? 80 : 0
            if debounce > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(debounce))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else {
                return
            }

            let result = Self.parse(text: text, version: version, previous: previous)

            guard !Task.isCancelled else {
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

    /// Internal so the regression test harness can run the exact parse
    /// pipeline synchronously.
    nonisolated static func parse(
        text: String,
        version: Int,
        previous: MarkdownParseResult?
    ) -> MarkdownParseResult {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        var collector = MarkdownStyleSpanCollector()
        collector.visit(document)
        let sourceMap = SourceMap(text: text)
        let resolvedSpans: [ResolvedMarkdownStyleSpan] = collector.spans
            .compactMap { span in
                guard let range = sourceMap.nsRange(for: span.range) else {
                    return nil
                }

                return ResolvedMarkdownStyleSpan(range: range, kind: span.kind)
            }

        let spans = MarkdownLinkStyleResolver.resolve(spans: resolvedSpans, in: text)
        return MarkdownParseResult(
            textVersion: version,
            sourceLength: text.utf16.count,
            source: text,
            spans: spans,
            dirtyRanges: dirtyRanges(from: previous, to: spans, source: text)
        )
    }

    nonisolated private static func dirtyRanges(
        from previous: MarkdownParseResult?,
        to spans: [ResolvedMarkdownStyleSpan],
        source: String
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
            source: source
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
