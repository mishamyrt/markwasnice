import Foundation

/// The pure range math of the incremental styling pipeline, extracted from
/// the editor view so it can be unit tested without a live AppKit text
/// stack. Every function takes the document string (or plain ranges) as
/// input and computes what to restyle; the view keeps attribute application,
/// the deferred-task lifecycle, and everything that reads the live view
/// (visible rect, marked text, reentrancy guards around NSTextStorage).
enum MarkdownStylingEngine {
    /// Edits larger than this reset the span cache and fall back to
    /// visible-first local styling instead of a synchronous restyle.
    static let largeEditThreshold = 8000
    /// A merged dirty area larger than this goes through the chunked
    /// deferred pass instead of one synchronous sweep.
    static let styleChunkLength = 16000
    /// Size of one background styling chunk.
    static let backgroundChunkLength = 4000

    static func isLargeEdit(editedRange: NSRange, changeInLength: Int) -> Bool {
        editedRange.length > largeEditThreshold
            || abs(changeInLength) > largeEditThreshold
    }

    /// Shift/grow a range across an edit: content before the edit stays put,
    /// content after shifts by the delta, and a range whose boundary touches
    /// the edit absorbs it (typing at the edge of code or of the focused
    /// paragraph extends them).
    static func editAdjustedRange(
        _ range: NSRange,
        editLocation: Int,
        changeInLength: Int,
        editedLength: Int,
        sourceLength: Int
    ) -> NSRange? {
        let removedLength = max(0, editedLength - changeInLength)
        let editOldEnd = editLocation + removedLength
        var lower = range.location
        var upper = NSMaxRange(range)

        if lower >= editOldEnd {
            lower += changeInLength
        } else if lower > editLocation {
            lower = editLocation
        }

        if upper >= editOldEnd {
            upper += changeInLength
        } else if upper > editLocation {
            upper = editLocation
        }

        lower = max(0, min(lower, sourceLength))
        upper = max(lower, min(upper, sourceLength))
        let length = upper - lower
        return length > 0 ? NSRange(location: lower, length: length) : nil
    }

    /// The lines to restyle locally after an edit. Includes the following
    /// line: pressing Enter splits a line and pushes its old terminator onto
    /// the next (possibly empty) line, carrying the old paragraph style with
    /// it. TextKit conforms paragraph styles to paragraph boundaries, so a
    /// heading's outdented indent would otherwise park the caret in the hash
    /// gutter until the next parse.
    static func editDirtyRange(
        editedRange: NSRange,
        in string: NSString
    ) -> NSRange {
        let location = min(editedRange.location, string.length)
        let length = max(0, min(editedRange.length, string.length - location))
        var dirtyRange = string.lineRange(
            for: NSRange(location: location, length: length)
        )
        if NSMaxRange(dirtyRange) < string.length {
            let followingLine = string.lineRange(
                for: NSRange(location: NSMaxRange(dirtyRange), length: 0)
            )
            dirtyRange = NSUnionRange(dirtyRange, followingLine)
        }

        return dirtyRange
    }

    /// Dirty ranges normalized to whole lines and merged where they touch;
    /// ranges outside the document are dropped.
    static func mergedLineRanges(
        _ ranges: [NSRange],
        in string: NSString
    ) -> [NSRange] {
        let lineRanges: [NSRange] = ranges.compactMap { range in
            guard range.length >= 0,
                  range.location >= 0,
                  range.location <= string.length
            else {
                return nil
            }

            let length = min(range.length, string.length - range.location)
            return string.lineRange(for: NSRange(
                location: range.location,
                length: length
            ))
        }

        let sorted = lineRanges
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }
        guard var current = sorted.first else {
            return []
        }

        var result: [NSRange] = []
        for range in sorted.dropFirst() {
            if range.location <= NSMaxRange(current) {
                current.length = max(NSMaxRange(current), NSMaxRange(range))
                    - current.location
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }

    /// The range expanded to whole lines; out-of-bounds input collapses to
    /// an empty range at the document start.
    static func lineNormalized(_ range: NSRange, in string: NSString) -> NSRange {
        guard range.location >= 0, range.location <= string.length else {
            return NSRange(location: 0, length: 0)
        }

        let length = min(range.length, string.length - range.location)
        return string.lineRange(for: NSRange(
            location: range.location,
            length: max(0, length)
        ))
    }

    /// The whole document split into line-aligned background styling chunks,
    /// with the (already styled) visible range carved out.
    static func chunkedStyleRanges(
        in string: NSString,
        excluding visibleRange: NSRange?
    ) -> [NSRange] {
        guard string.length > 0 else {
            return []
        }

        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let upperBound = min(location + backgroundChunkLength, string.length)
            let range = string.lineRange(for: NSRange(
                location: location,
                length: upperBound - location
            ))
            for styleRange in visibleRange.map({ subtract($0, from: range) }) ?? [range] {
                if let styleRange = bounded(styleRange, length: string.length),
                   styleRange.length > 0
                {
                    ranges.append(styleRange)
                }
            }
            location = max(NSMaxRange(range), location + 1)
        }

        return ranges
    }

    /// Spans ordered by where they start, keeping the original relative order
    /// of spans that start together. The parse pipeline emits them in AST
    /// order, which is only nearly sorted: a link's punctuation sub-spans are
    /// expanded ahead of the inline children of its label, and bare checkboxes
    /// are appended after the whole walk. The tie-break on the original index
    /// matters because attribute application lets a later span win over an
    /// earlier one on the same characters.
    static func documentOrdered(
        _ spans: [ResolvedMarkdownStyleSpan]
    ) -> [ResolvedMarkdownStyleSpan] {
        spans.enumerated()
            .sorted {
                ($0.element.range.location, $0.offset)
                    < ($1.element.range.location, $1.offset)
            }
            .map(\.element)
    }

    /// The spans intersecting `range`. Expects `spans` in document order (see
    /// documentOrdered(_:)) so the scan can stop at the first span starting at
    /// or after the range end instead of walking the whole document's spans on
    /// every restyled chunk. The other end cannot be skipped the same way:
    /// container spans (code blocks, quotes, lists, frontmatter) start well
    /// before their contents, so span ends are not monotonic and a search over
    /// them would drop an enclosing span.
    static func spansForRange(
        _ range: NSRange,
        from spans: [ResolvedMarkdownStyleSpan]
    ) -> [ResolvedMarkdownStyleSpan] {
        let upperBound = NSMaxRange(range)
        var result: [ResolvedMarkdownStyleSpan] = []
        for span in spans {
            guard span.range.location < upperBound else {
                break
            }

            if NSIntersectionRange(span.range, range).length > 0 {
                result.append(span)
            }
        }

        return result
    }

    static func subtract(_ excludedRange: NSRange, from range: NSRange) -> [NSRange] {
        let intersection = NSIntersectionRange(range, excludedRange)
        guard intersection.length > 0 else {
            return [range]
        }

        var result: [NSRange] = []
        if intersection.location > range.location {
            result.append(NSRange(
                location: range.location,
                length: intersection.location - range.location
            ))
        }

        let excludedUpperBound = NSMaxRange(intersection)
        let rangeUpperBound = NSMaxRange(range)
        if excludedUpperBound < rangeUpperBound {
            result.append(NSRange(
                location: excludedUpperBound,
                length: rangeUpperBound - excludedUpperBound
            ))
        }

        return result
    }

    /// The range unchanged when it fits inside a document of `length`, nil
    /// otherwise — the one bounds check the editor view and the style applier
    /// both gate their text-storage ranges through.
    static func bounded(_ range: NSRange, length: Int) -> NSRange? {
        guard range.location >= 0,
              range.length >= 0,
              range.location <= length,
              NSMaxRange(range) <= length
        else {
            return nil
        }

        return range
    }
}
