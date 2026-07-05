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

    static func dirtyRanges(
        from previousSpans: [ResolvedMarkdownStyleSpan],
        to currentSpans: [ResolvedMarkdownStyleSpan],
        source: String
    ) -> [NSRange] {
        let string = source as NSString
        guard string.length > 0 else {
            return []
        }

        let lineRanges = Self.lineRanges(in: source)
        guard !lineRanges.isEmpty else {
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
            if previous != current {
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
        var prefixLength = 0

        while prefixLength < sharedLength,
              previous.character(at: prefixLength) == current.character(at: prefixLength)
        {
            prefixLength += 1
        }

        var previousSuffixLocation = previous.length
        var currentSuffixLocation = current.length
        while previousSuffixLocation > prefixLength,
              currentSuffixLocation > prefixLength,
              previous.character(at: previousSuffixLocation - 1)
              == current.character(at: currentSuffixLocation - 1)
        {
            previousSuffixLocation -= 1
            currentSuffixLocation -= 1
        }

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

    private static func signaturesByLine(
        _ spans: [ResolvedMarkdownStyleSpan],
        lineRanges: [NSRange],
        source: String
    ) -> [Int: Set<SpanSignature>] {
        let string = source as NSString
        var result: [Int: Set<SpanSignature>] = [:]

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

                result[lineIndex, default: []].insert(SpanSignature(
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

    private static func lineRanges(in source: String) -> [NSRange] {
        let string = source as NSString
        var ranges: [NSRange] = []
        var location = 0

        while location <= string.length {
            let range = string.lineRange(for: NSRange(location: location, length: 0))
            ranges.append(range)

            let nextLocation = NSMaxRange(range)
            guard nextLocation > location else {
                break
            }
            location = nextLocation
        }

        return ranges
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
