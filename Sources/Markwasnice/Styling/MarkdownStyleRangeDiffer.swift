import Foundation

enum MarkdownStyleRangeDiffer {
    static func translatedSpansAfterSourceChange(
        _ spans: [ResolvedMarkdownStyleSpan],
        editRange: NSRange,
        lengthDelta: Int,
        sourceLength: Int
    ) -> [ResolvedMarkdownStyleSpan] {
        let previousEditLength = max(0, editRange.length - lengthDelta)
        let previousEditRange = NSRange(
            location: editRange.location,
            length: previousEditLength
        )
        let previousEditUpperBound = NSMaxRange(previousEditRange)

        return spans.compactMap { span in
            let spanUpperBound = NSMaxRange(span.range)

            if spanUpperBound <= previousEditRange.location {
                return span
            }

            if span.range.location >= previousEditUpperBound {
                let shiftedLocation = span.range.location + lengthDelta
                let shiftedRange = NSRange(
                    location: shiftedLocation,
                    length: span.range.length
                )
                guard NSMaxRange(shiftedRange) <= sourceLength else {
                    return nil
                }
                return ResolvedMarkdownStyleSpan(range: shiftedRange, kind: span.kind)
            }

            return nil
        }
    }

    /// `lineRanges` are the newline-inclusive UTF-16 line ranges of `source`,
    /// as `SourceMap.lineRanges()` returns them — the parse pipeline already
    /// has them, so the differ doesn't rescan the document.
    static func dirtyRanges(
        from previousSpans: [ResolvedMarkdownStyleSpan],
        to currentSpans: [ResolvedMarkdownStyleSpan],
        source: String,
        lineRanges: [NSRange]
    ) -> [NSRange] {
        let string = source as NSString
        guard string.length > 0, !lineRanges.isEmpty else {
            return []
        }

        let previousSignatures = signaturesByLine(
            previousSpans,
            lineRanges: lineRanges,
            source: source
        )
        let currentSignatures = signaturesByLine(
            currentSpans,
            lineRanges: lineRanges,
            source: source
        )
        let interestingLines = Set(previousSignatures.keys)
            .union(currentSignatures.keys)

        var dirtyRanges: [NSRange] = []
        for lineIndex in interestingLines {
            let previous = previousSignatures[lineIndex, default: []]
            let current = currentSignatures[lineIndex, default: []]
            // Both sides emit signatures in span-array order, so unchanged
            // lines compare equal as plain arrays; only reordered lines pay
            // for the order- and duplicate-insensitive Set comparison that
            // decides equality.
            if previous != current, Set(previous) != Set(current) {
                dirtyRanges.append(lineRanges[lineIndex])
            }
        }

        return mergedRanges(dirtyRanges)
    }

    static func sourceChange(
        from previousSource: String,
        to currentSource: String
    ) -> SourceChange {
        let previous = previousSource as NSString
        let current = currentSource as NSString
        let sharedLength = min(previous.length, current.length)

        let prefixLength = commonPrefixLength(
            previous,
            current,
            limit: sharedLength
        )
        let suffixLength = commonSuffixLength(
            previous,
            current,
            limit: sharedLength - prefixLength
        )
        let previousSuffixLocation = previous.length - suffixLength
        let currentSuffixLocation = current.length - suffixLength

        return SourceChange(
            previousRange: NSRange(
                location: prefixLength,
                length: previousSuffixLocation - prefixLength
            ),
            currentRange: NSRange(
                location: prefixLength,
                length: currentSuffixLocation - prefixLength
            ),
            lengthDelta: current.length - previous.length,
            insertedText: current.substring(with: NSRange(
                location: prefixLength,
                length: currentSuffixLocation - prefixLength
            ))
        )
    }

    /// Comparing through getCharacters copies each chunk once and scans it
    /// natively; per-unit character(at:) would pay a bridged call per unit
    /// over what is nearly the whole document for an edit near its end.
    private static let comparisonChunkLength = 4096

    private static func commonPrefixLength(
        _ previous: NSString,
        _ current: NSString,
        limit: Int
    ) -> Int {
        var previousChunk = [unichar](repeating: 0, count: comparisonChunkLength)
        var currentChunk = [unichar](repeating: 0, count: comparisonChunkLength)

        var offset = 0
        while offset < limit {
            let chunkLength = min(comparisonChunkLength, limit - offset)
            previous.getCharacters(
                &previousChunk,
                range: NSRange(location: offset, length: chunkLength)
            )
            current.getCharacters(
                &currentChunk,
                range: NSRange(location: offset, length: chunkLength)
            )

            for index in 0 ..< chunkLength
                where previousChunk[index] != currentChunk[index]
            {
                return offset + index
            }

            offset += chunkLength
        }

        return limit
    }

    private static func commonSuffixLength(
        _ previous: NSString,
        _ current: NSString,
        limit: Int
    ) -> Int {
        var previousChunk = [unichar](repeating: 0, count: comparisonChunkLength)
        var currentChunk = [unichar](repeating: 0, count: comparisonChunkLength)

        var suffixLength = 0
        while suffixLength < limit {
            let chunkLength = min(comparisonChunkLength, limit - suffixLength)
            previous.getCharacters(
                &previousChunk,
                range: NSRange(
                    location: previous.length - suffixLength - chunkLength,
                    length: chunkLength
                )
            )
            current.getCharacters(
                &currentChunk,
                range: NSRange(
                    location: current.length - suffixLength - chunkLength,
                    length: chunkLength
                )
            )

            var index = chunkLength - 1
            while index >= 0 {
                if previousChunk[index] != currentChunk[index] {
                    return suffixLength + (chunkLength - 1 - index)
                }
                index -= 1
            }

            suffixLength += chunkLength
        }

        return limit
    }

    private static func signaturesByLine(
        _ spans: [ResolvedMarkdownStyleSpan],
        lineRanges: [NSRange],
        source: String
    ) -> [Int: [SpanSignature]] {
        let string = source as NSString
        var result: [Int: [SpanSignature]] = [:]

        for span in spans {
            guard span.range.length > 0 else {
                continue
            }

            let spanUpperBound = NSMaxRange(span.range)
            let firstLineIndex = lineIndex(
                containing: span.range.location,
                in: lineRanges
            )

            for lineIndex in firstLineIndex ..< lineRanges.count {
                let lineRange = lineRanges[lineIndex]
                if lineRange.location >= spanUpperBound {
                    break
                }

                let intersection = NSIntersectionRange(span.range, lineRange)
                guard intersection.length > 0 else {
                    continue
                }

                let normalizedLength = lengthTrimmingTrailingNewline(
                    intersection,
                    lineRange: lineRange,
                    source: string
                )
                guard normalizedLength > 0 else {
                    continue
                }

                result[lineIndex, default: []].append(SpanSignature(
                    kind: span.kind,
                    relativeRange: NSRange(
                        location: intersection.location - lineRange.location,
                        length: normalizedLength
                    )
                ))
            }
        }

        return result
    }

    /// Index of the first line whose end lies beyond the given location —
    /// the line containing it, since line ranges are sorted and contiguous.
    private static func lineIndex(
        containing location: Int,
        in lineRanges: [NSRange]
    ) -> Int {
        var low = 0
        var high = lineRanges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(lineRanges[mid]) <= location {
                low = mid + 1
            } else {
                high = mid
            }
        }

        return low
    }

    private static func lengthTrimmingTrailingNewline(
        _ intersection: NSRange,
        lineRange: NSRange,
        source: NSString
    ) -> Int {
        let lineUpperBound = NSMaxRange(lineRange)
        let intersectionUpperBound = NSMaxRange(intersection)
        guard intersectionUpperBound == lineUpperBound,
              lineUpperBound > lineRange.location,
              Character(UnicodeScalar(source.character(at: lineUpperBound - 1))!)
              .isNewline
        else {
            return intersection.length
        }

        return max(0, intersection.length - 1)
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sortedRanges = ranges
            .filter { $0.length > 0 }
            .sorted { lhs, rhs in
                if lhs.location == rhs.location {
                    return lhs.length < rhs.length
                }

                return lhs.location < rhs.location
            }
        guard var currentRange = sortedRanges.first else {
            return []
        }

        var result: [NSRange] = []
        for range in sortedRanges.dropFirst() {
            let currentUpperBound = currentRange.location + currentRange.length
            let rangeUpperBound = range.location + range.length
            if range.location <= currentUpperBound {
                currentRange.length = max(currentUpperBound, rangeUpperBound)
                    - currentRange.location
            } else {
                result.append(currentRange)
                currentRange = range
            }
        }

        result.append(currentRange)
        return result
    }
}

struct SourceChange {
    let previousRange: NSRange
    let currentRange: NSRange
    let lengthDelta: Int
    let insertedText: String

    var hasSourceEdits: Bool {
        previousRange.length > 0 || currentRange.length > 0
    }

    var isInsertion: Bool {
        previousRange.length == 0 && currentRange.length > 0
    }

    var isSmallLocalEdit: Bool {
        max(previousRange.length, currentRange.length) <= 512
    }

    var insertedTextContainsNewline: Bool {
        insertedText.contains("\n") || insertedText.contains("\r")
    }
}

private struct SpanSignature: Hashable {
    let kind: MarkdownStyleKind
    let relativeRange: NSRange
}
