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
}
