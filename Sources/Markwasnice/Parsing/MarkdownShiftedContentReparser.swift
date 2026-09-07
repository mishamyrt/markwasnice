import Foundation
import Markdown

/// Indentation is a visual shift in this editor, not syntax: Tab/Shift+Tab
/// shift whole lines, and the block prefix analyzer reads indented headings
/// and lists as their markdown kind. Two cmark behaviors fight that:
///
/// 1. A 4-space or tab indent parses as an indented code block, silently
///    turning shifted text into code and dropping its inline styles.
/// 2. Inline source positions on indented paragraph continuation lines are
///    reported relative to the line with its leading whitespace stripped, so
///    every span on such a line lands short of the real text (and, measured
///    in UTF-8 bytes, can split a multi-byte character and vanish entirely).
///
/// Both are fixed the same way: re-parse the affected block's lines with the
/// leading whitespace removed and map the resulting spans back through the
/// per-line strip counts. Code blocks stay reachable through fences only; a
/// block whose first characters are ``` or ~~~ keeps its code block span, so
/// a shifted fence still reads as a fence.
enum MarkdownShiftedContentReparser {
    /// Levels of "dedent and parse again" nesting. Every level strips at
    /// least one leading character per re-parsed line, so this only bounds
    /// pathological hand-crafted input.
    private static let maxDepth = 5

    /// The same shifted regions as the styling pass, kept as blocks for
    /// preview/export. Replacing inside each container preserves nested lists.
    static func document(parsing source: String) -> Document {
        document(parsing: source, depth: 0)
    }

    private static func document(parsing source: String, depth: Int) -> Document {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        guard depth < maxDepth else {
            return document
        }
        let sourceMap = SourceMap(text: source)
        let string = source as NSString
        var scanner = RegionScanner(source: string, sourceMap: sourceMap)
        scanner.visit(document)
        guard !scanner.regions.isEmpty || source.contains("[") else {
            return document
        }
        let regions = Dictionary(uniqueKeysWithValues: scanner.regions.map {
            ($0.originalRange, $0)
        })
        // Scan once per source, not once per inline text node: bridging a
        // large UTF-8 string to NSString for every node is quadratic work.
        let checkboxes = Dictionary(uniqueKeysWithValues:
            MarkdownTaskCheckboxScanner.spans(in: source, excluding: []).map {
                let checked = string.substring(with: $0.range).lowercased() == "[x]"
                return ($0.range.location, checked ? "☑" : "☐")
            }
        )

        func rewrite(_ block: BlockMarkup) -> [BlockMarkup] {
            if let range = block.range.flatMap(sourceMap.nsRange(for:)),
               let region = regions[range]
            {
                return Array(Self.document(
                    parsing: dedentedSource(for: region, in: string),
                    depth: depth + 1
                ).blockChildren)
            }
            guard block.childCount > 0 else {
                return [block]
            }
            let children: [Markup] = block.children.flatMap { child -> [Markup] in
                if block is Paragraph, let text = child as? Text,
                   let range = text.range.flatMap(sourceMap.nsRange(for:)),
                   let symbol = checkboxes[range.location],
                   text.string.hasPrefix("[")
                {
                    return [Text(symbol + text.string.dropFirst(3))]
                }
                guard let child = child as? BlockMarkup else {
                    return [child]
                }
                return rewrite(child).map { $0 as Markup }
            }
            // Replacing an attached node also copies its ancestors. The new
            // document only needs this subtree, so avoid copying the root for
            // every paragraph in a large document.
            return [block.detachedFromParent
                .withUncheckedChildren(children) as! BlockMarkup]
        }

        return Document(document.blockChildren.flatMap(rewrite))
    }

    static func spans(
        replacing spans: [ResolvedMarkdownStyleSpan],
        in source: String,
        document: Document,
        sourceMap: SourceMap
    ) -> [ResolvedMarkdownStyleSpan] {
        replacementSpans(
            for: spans,
            in: source as NSString,
            document: document,
            sourceMap: sourceMap,
            depth: 0
        )
    }

    /// One line of a re-parsed region: the slice of the source that joins the
    /// dedented sub-document, minus its first `stripped` characters.
    private struct Segment {
        let range: NSRange
        let stripped: Int
    }

    private struct Region {
        let originalRange: NSRange
        /// Spans lying entirely inside this range are replaced.
        let dropRange: NSRange
        let segments: [Segment]
    }

    private static func replacementSpans(
        for spans: [ResolvedMarkdownStyleSpan],
        in source: NSString,
        document: Document,
        sourceMap: SourceMap,
        depth: Int
    ) -> [ResolvedMarkdownStyleSpan] {
        guard depth < maxDepth else {
            return spans
        }

        var scanner = RegionScanner(source: source, sourceMap: sourceMap)
        scanner.visit(document)
        guard !scanner.regions.isEmpty else {
            return spans
        }

        // Replacements go after the surviving spans: styling applies spans in
        // array order on top of reset base attributes, so container spans
        // (lists, quotes) that enclose a region keep running first.
        //
        // The walker visits blocks in document order and the region-producing
        // blocks (indented code blocks, paragraphs) never contain each other,
        // so dropRanges are ascending and non-overlapping; only the last
        // region starting at or before a span can absorb it.
        let regions = scanner.regions
        var result = spans.filter { span in
            // NSIntersectionRange yields {0,0} against any region when the
            // span is {0,0}, so the old exhaustive scan always dropped that
            // span once a region existed; keep doing so.
            guard span.range.location > 0 || span.range.length > 0 else {
                return false
            }

            guard let region = lastRegion(
                startingAtOrBefore: span.range.location,
                in: regions
            ) else {
                return true
            }

            return NSIntersectionRange(span.range, region.dropRange) != span.range
        }
        for region in scanner.regions {
            result.append(contentsOf: reparsedSpans(
                for: region,
                in: source,
                depth: depth
            ))
        }

        return result
    }

    /// The region with the greatest dropRange.location at or before the
    /// given location; regions are sorted ascending by dropRange.location.
    private static func lastRegion(
        startingAtOrBefore location: Int,
        in regions: [Region]
    ) -> Region? {
        var low = 0
        var high = regions.count
        while low < high {
            let middle = (low + high) / 2
            if regions[middle].dropRange.location <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }

        guard low > 0 else {
            return nil
        }

        return regions[low - 1]
    }

    /// The region's dedented lines parsed as their own document, with the
    /// resulting spans mapped back to `source` coordinates.
    private static func reparsedSpans(
        for region: Region,
        in source: NSString,
        depth: Int
    ) -> [ResolvedMarkdownStyleSpan] {
        let subSource = dedentedSource(for: region, in: source)
        var segmentStarts: [Int] = []
        var subLength = 0
        for segment in region.segments {
            segmentStarts.append(subLength)
            subLength += segment.range.length - segment.stripped
        }

        let document = Document(parsing: subSource, options: [.disableSmartOpts])
        var collector = MarkdownStyleSpanCollector()
        collector.visit(document)
        let sourceMap = SourceMap(text: subSource)
        // Zero-length spans survive resolution (the mapping below drops
        // them), matching the top-level parse pipeline.
        let subSpans = sourceMap.resolvedSpans(
            from: collector.spans,
            droppingZeroLength: false
        )

        // Dedenting can leave deeper lines indented far enough to form an
        // indented code block again, and a dedented paragraph can still carry
        // shifted continuation lines; recurse until the sub-document is flat.
        return replacementSpans(
            for: subSpans,
            in: subSource as NSString,
            document: document,
            sourceMap: sourceMap,
            depth: depth + 1
        ).compactMap { span in
            guard span.range.length > 0,
                  let lower = originalOffset(
                      for: span.range.location,
                      segments: region.segments,
                      segmentStarts: segmentStarts
                  ),
                  let upper = originalOffset(
                      for: NSMaxRange(span.range) - 1,
                      segments: region.segments,
                      segmentStarts: segmentStarts
                  )
            else {
                return nil
            }

            return ResolvedMarkdownStyleSpan(
                range: NSRange(location: lower, length: upper + 1 - lower),
                kind: span.kind
            )
        }
    }

    private static func originalOffset(
        for subOffset: Int,
        segments: [Segment],
        segmentStarts: [Int]
    ) -> Int? {
        var low = 0
        var high = segmentStarts.count - 1
        guard high >= 0, subOffset >= 0 else {
            return nil
        }

        while low < high {
            let middle = (low + high + 1) / 2
            if segmentStarts[middle] <= subOffset {
                low = middle
            } else {
                high = middle - 1
            }
        }

        let segment = segments[low]
        let offsetInSegment = subOffset - segmentStarts[low]
        guard offsetInSegment < segment.range.length - segment.stripped else {
            return nil
        }

        return segment.range.location + segment.stripped + offsetInSegment
    }

    private static func dedentedSource(
        for region: Region,
        in source: NSString
    ) -> String {
        region.segments.map { segment in
            source.substring(with: NSRange(
                location: segment.range.location + segment.stripped,
                length: segment.range.length - segment.stripped
            ))
        }.joined()
    }

    private struct RegionScanner: MarkupWalker {
        let source: NSString
        let sourceMap: SourceMap
        var regions: [Region] = []

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            guard let sourceRange = codeBlock.range,
                  let nsRange = sourceMap.nsRange(for: sourceRange),
                  nsRange.length > 0,
                  let region = indentedBlockRegion(for: nsRange)
            else {
                return
            }

            regions.append(region)
        }

        mutating func visitParagraph(_ paragraph: Paragraph) {
            // Deliberately no descendInto: paragraphs hold only inline
            // children, which cannot contribute regions.
            guard let sourceRange = paragraph.range,
                  let nsRange = sourceMap.nsRange(for: sourceRange),
                  nsRange.length > 0,
                  let region = shiftedParagraphRegion(for: nsRange)
            else {
                return
            }

            regions.append(region)
        }

        /// Returns nil when there is no indent to strip (an indented code
        /// block inside a block quote or after a list marker starts
        /// mid-line): the caller keeps the code block span, matching what the
        /// text looks like.
        private func indentedBlockRegion(for range: NSRange) -> Region? {
            let blockLineRange = source.lineRange(for: range)
            var lineRanges: [NSRange] = []
            var leadingCounts: [Int] = []
            var dedent = Int.max
            var location = blockLineRange.location
            while location < NSMaxRange(blockLineRange) {
                let lineRange = source.lineRange(
                    for: NSRange(location: location, length: 0)
                )
                let leading = leadingWhitespaceLength(of: lineRange)
                let isBlank = leading >= lineRange.length
                    || isNewline(source.character(at: lineRange.location + leading))
                if !isBlank {
                    dedent = min(dedent, leading)
                }

                lineRanges.append(lineRange)
                leadingCounts.append(leading)
                location = max(NSMaxRange(lineRange), location + 1)
            }

            guard dedent != .max, dedent > 0 else {
                return nil
            }

            return Region(
                originalRange: range,
                dropRange: blockLineRange,
                segments: zip(lineRanges, leadingCounts).map { lineRange, leading in
                    Segment(range: lineRange, stripped: min(dedent, leading))
                }
            )
        }

        /// A paragraph whose continuation lines carry leading whitespace.
        /// cmark strips that whitespace before parsing inlines and reports
        /// their positions against the stripped lines, so the paragraph is
        /// re-parsed dedented instead of trusting those positions. The first
        /// line starts at the paragraph's own start (past any list marker)
        /// and is never stripped.
        private func shiftedParagraphRegion(for range: NSRange) -> Region? {
            let firstLineRange = source.lineRange(
                for: NSRange(location: range.location, length: 0)
            )
            var segments = [Segment(
                range: NSRange(
                    location: range.location,
                    length: NSMaxRange(firstLineRange) - range.location
                ),
                stripped: 0
            )]
            var hasShiftedContinuation = false
            var location = NSMaxRange(firstLineRange)
            while location < NSMaxRange(range) {
                let lineRange = source.lineRange(
                    for: NSRange(location: location, length: 0)
                )
                let leading = leadingWhitespaceLength(of: lineRange)
                if leading > 0 {
                    hasShiftedContinuation = true
                }

                segments.append(Segment(range: lineRange, stripped: leading))
                location = max(NSMaxRange(lineRange), location + 1)
            }

            guard hasShiftedContinuation else {
                return nil
            }

            return Region(originalRange: range, dropRange: range, segments: segments)
        }

        private func leadingWhitespaceLength(of lineRange: NSRange) -> Int {
            var leading = 0
            while leading < lineRange.length,
                  isHorizontalWhitespace(
                      source.character(at: lineRange.location + leading)
                  )
            {
                leading += 1
            }

            return leading
        }
    }
}

private func isHorizontalWhitespace(_ character: unichar) -> Bool {
    character == 0x20 || character == 0x09
}

private func isNewline(_ character: unichar) -> Bool {
    character == 0x0A || character == 0x0D
}
