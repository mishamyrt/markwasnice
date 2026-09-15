import Foundation
import Testing
@testable import Markwasnice

@Suite
struct MarkdownStylingEngineTests {
    // MARK: - editAdjustedRange

    @Test
    func rangeBeforeEditStaysPut() {
        let adjusted = MarkdownStylingEngine.editAdjustedRange(
            NSRange(location: 0, length: 3),
            editLocation: 5,
            changeInLength: 2,
            editedLength: 2,
            sourceLength: 20
        )

        #expect(adjusted == NSRange(location: 0, length: 3))
    }

    @Test
    func rangeAfterEditShiftsByDelta() {
        let adjusted = MarkdownStylingEngine.editAdjustedRange(
            NSRange(location: 10, length: 3),
            editLocation: 5,
            changeInLength: 2,
            editedLength: 2,
            sourceLength: 20
        )

        #expect(adjusted == NSRange(location: 12, length: 3))
    }

    @Test
    func typingAtRangeEndGrowsIt() {
        let adjusted = MarkdownStylingEngine.editAdjustedRange(
            NSRange(location: 5, length: 3),
            editLocation: 8,
            changeInLength: 2,
            editedLength: 2,
            sourceLength: 20
        )

        #expect(adjusted == NSRange(location: 5, length: 5))
    }

    @Test
    func rangeInsideDeletionCollapsesToNil() {
        let adjusted = MarkdownStylingEngine.editAdjustedRange(
            NSRange(location: 5, length: 3),
            editLocation: 4,
            changeInLength: -6,
            editedLength: 0,
            sourceLength: 10
        )

        #expect(adjusted == nil)
    }

    @Test
    func adjustedRangeIsClampedToSource() {
        let adjusted = MarkdownStylingEngine.editAdjustedRange(
            NSRange(location: 4, length: 6),
            editLocation: 0,
            changeInLength: 3,
            editedLength: 3,
            sourceLength: 8
        )

        #expect(adjusted == NSRange(location: 7, length: 1))
    }

    // MARK: - editDirtyRange

    @Test
    func editDirtyRangeIncludesFollowingLine() {
        let string = "first\nsecond\nthird\n" as NSString

        let range = MarkdownStylingEngine.editDirtyRange(
            editedRange: NSRange(location: 1, length: 2),
            in: string
        )

        #expect(range == NSRange(location: 0, length: 13))
    }

    @Test
    func editDirtyRangeOnLastLineStaysOnIt() {
        let string = "first\nsecond" as NSString

        let range = MarkdownStylingEngine.editDirtyRange(
            editedRange: NSRange(location: 7, length: 1),
            in: string
        )

        #expect(range == NSRange(location: 6, length: 6))
    }

    @Test
    func editDirtyRangeClampsOutOfBoundsEdit() {
        let string = "abc" as NSString

        let range = MarkdownStylingEngine.editDirtyRange(
            editedRange: NSRange(location: 10, length: 5),
            in: string
        )

        #expect(range == NSRange(location: 0, length: 3))
    }

    // MARK: - mergeRanges

    @Test
    func mergesUnsortedNestedTouchingAndDuplicateRanges() {
        let ranges = [
            NSRange(location: 12, length: 2),
            NSRange(location: 3, length: 1),
            NSRange(location: 6, length: 2),
            NSRange(location: 2, length: 2),
            NSRange(location: 2, length: 4),
            NSRange(location: 2, length: 4),
            NSRange(location: 10, length: 0),
        ]

        #expect(MarkdownStylingEngine.mergeRanges(ranges) == [
            NSRange(location: 2, length: 6),
            NSRange(location: 12, length: 2),
        ])
        #expect(MarkdownStylingEngine.mergeRanges([]).isEmpty)
        #expect(MarkdownStylingEngine.mergeRanges([
            NSRange(location: 2, length: 0),
        ]).isEmpty)
    }

    // MARK: - mergedLineRanges

    @Test
    func rangesOnTouchingLinesMerge() {
        let string = "first\nsecond\nthird\n" as NSString

        let merged = MarkdownStylingEngine.mergedLineRanges(
            [
                NSRange(location: 1, length: 1),
                NSRange(location: 7, length: 1),
            ],
            in: string
        )

        #expect(merged == [NSRange(location: 0, length: 13)])
    }

    @Test
    func disjointLineRangesStaySeparate() {
        let string = "first\nsecond\nthird\n" as NSString

        let merged = MarkdownStylingEngine.mergedLineRanges(
            [
                NSRange(location: 1, length: 1),
                NSRange(location: 14, length: 1),
            ],
            in: string
        )

        #expect(merged == [
            NSRange(location: 0, length: 6),
            NSRange(location: 13, length: 6),
        ])
    }

    @Test
    func outOfBoundsRangesAreDropped() {
        let string = "abc" as NSString

        let merged = MarkdownStylingEngine.mergedLineRanges(
            [NSRange(location: 10, length: 2)],
            in: string
        )

        #expect(merged.isEmpty)
    }

    // MARK: - lineNormalized

    @Test
    func lineNormalizedExpandsToWholeLines() {
        let string = "first\nsecond\n" as NSString

        let normalized = MarkdownStylingEngine.lineNormalized(
            NSRange(location: 7, length: 1),
            in: string
        )

        #expect(normalized == NSRange(location: 6, length: 7))
    }

    @Test
    func lineNormalizedCollapsesOutOfBoundsInput() {
        let string = "abc" as NSString

        let normalized = MarkdownStylingEngine.lineNormalized(
            NSRange(location: 10, length: 1),
            in: string
        )

        #expect(normalized == NSRange(location: 0, length: 0))
    }

    // MARK: - chunkedStyleRanges

    @Test
    func chunksAlignToLineBoundariesAndCoverTheDocument() {
        let line = String(repeating: "a", count: 3000) + "\n"
        let string = String(repeating: line, count: 3) as NSString

        let chunks = MarkdownStylingEngine.chunkedStyleRanges(
            in: string,
            excluding: nil
        )

        #expect(chunks == [
            NSRange(location: 0, length: 6002),
            NSRange(location: 6002, length: 3001),
        ])
    }

    @Test
    func visibleRangeIsCarvedOutOfChunks() {
        let line = String(repeating: "a", count: 3000) + "\n"
        let string = String(repeating: line, count: 3) as NSString

        let chunks = MarkdownStylingEngine.chunkedStyleRanges(
            in: string,
            excluding: NSRange(location: 0, length: 6002)
        )

        #expect(chunks == [NSRange(location: 6002, length: 3001)])
    }

    @Test
    func emptyDocumentHasNoChunks() {
        #expect(MarkdownStylingEngine.chunkedStyleRanges(
            in: "" as NSString,
            excluding: nil
        ).isEmpty)
    }

    // MARK: - subtract

    @Test
    func subtractWithoutIntersectionReturnsRange() {
        let result = MarkdownStylingEngine.subtract(
            NSRange(location: 10, length: 5),
            from: NSRange(location: 0, length: 5)
        )

        #expect(result == [NSRange(location: 0, length: 5)])
    }

    @Test
    func subtractInMiddleSplitsRange() {
        let result = MarkdownStylingEngine.subtract(
            NSRange(location: 3, length: 4),
            from: NSRange(location: 0, length: 10)
        )

        #expect(result == [
            NSRange(location: 0, length: 3),
            NSRange(location: 7, length: 3),
        ])
    }

    @Test
    func subtractCoveringRangeReturnsNothing() {
        let result = MarkdownStylingEngine.subtract(
            NSRange(location: 0, length: 10),
            from: NSRange(location: 2, length: 5)
        )

        #expect(result.isEmpty)
    }

    // MARK: - isLargeEdit

    @Test
    func largeEditThresholdIsExclusive() {
        #expect(!MarkdownStylingEngine.isLargeEdit(
            editedRange: NSRange(location: 0, length: 8000),
            changeInLength: 0
        ))
        #expect(MarkdownStylingEngine.isLargeEdit(
            editedRange: NSRange(location: 0, length: 8001),
            changeInLength: 0
        ))
        #expect(MarkdownStylingEngine.isLargeEdit(
            editedRange: NSRange(location: 0, length: 0),
            changeInLength: -8001
        ))
    }

    // MARK: - spansForRange

    @Test
    func spansForRangeKeepsOnlyIntersectingSpans() {
        let spans = [
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 0, length: 5),
                kind: .heading
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 10, length: 5),
                kind: .strong
            ),
        ]

        let filtered = MarkdownStylingEngine.spansForRange(
            NSRange(location: 4, length: 2),
            from: spans
        )

        #expect(filtered == [spans[0]])
    }

    /// The scan stops at the range end, so a span starting exactly there is
    /// already out — it shares no characters with the range.
    @Test
    func spansForRangeExcludesSpanStartingAtRangeEnd() {
        let spans = [
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 0, length: 5),
                kind: .heading
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 5, length: 5),
                kind: .strong
            ),
        ]

        let filtered = MarkdownStylingEngine.spansForRange(
            NSRange(location: 0, length: 5),
            from: spans
        )

        #expect(filtered == [spans[0]])
    }

    /// Container spans start well before their contents, so the early exit
    /// must key off where a span starts, never off where the previous one
    /// ended — an enclosing code block would otherwise be dropped.
    @Test
    func spansForRangeKeepsEnclosingContainerSpan() {
        let spans = [
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 0, length: 500),
                kind: .codeBlock
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 2, length: 3),
                kind: .strong
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 600, length: 4),
                kind: .emphasis
            ),
        ]

        let filtered = MarkdownStylingEngine.spansForRange(
            NSRange(location: 400, length: 10),
            from: spans
        )

        #expect(filtered == [spans[0]])
    }

    @Test
    func spansForRangeOnEmptySpansReturnsNothing() {
        #expect(MarkdownStylingEngine.spansForRange(
            NSRange(location: 0, length: 10),
            from: []
        ).isEmpty)
    }

    // MARK: - documentOrdered

    @Test
    func documentOrderedSortsSpansByStart() {
        let checkbox = ResolvedMarkdownStyleSpan(
            range: NSRange(location: 2, length: 3),
            kind: .taskCheckbox
        )
        let list = ResolvedMarkdownStyleSpan(
            range: NSRange(location: 0, length: 20),
            kind: .unorderedList
        )
        let emphasis = ResolvedMarkdownStyleSpan(
            range: NSRange(location: 10, length: 4),
            kind: .emphasis
        )

        let ordered = MarkdownStylingEngine.documentOrdered([
            list, emphasis, checkbox,
        ])

        #expect(ordered == [list, checkbox, emphasis])
    }

    /// Spans starting together keep their incoming order: attribute
    /// application lets the later one win, so reordering them would change
    /// which style is visible.
    @Test
    func documentOrderedKeepsOrderOfSpansStartingTogether() {
        let first = ResolvedMarkdownStyleSpan(
            range: NSRange(location: 4, length: 6),
            kind: .strong
        )
        let second = ResolvedMarkdownStyleSpan(
            range: NSRange(location: 4, length: 2),
            kind: .inlineCode
        )
        let earlier = ResolvedMarkdownStyleSpan(
            range: NSRange(location: 0, length: 2),
            kind: .heading
        )

        let ordered = MarkdownStylingEngine.documentOrdered([
            first, second, earlier,
        ])

        #expect(ordered == [earlier, first, second])
    }
}
