import AppKit
import Foundation
import Rdktr
import Testing
@testable import Markwasnice

@Suite
struct ProofreadingSeverityTests {
    @Test
    func bucketsWeights() {
        #expect(ProofreadingSeverity(weight: 0) == .low)
        #expect(ProofreadingSeverity(weight: 49) == .low)
        #expect(ProofreadingSeverity(weight: 50) == .medium)
        #expect(ProofreadingSeverity(weight: 79) == .medium)
        #expect(ProofreadingSeverity(weight: 80) == .high)
        #expect(ProofreadingSeverity(weight: 99) == .high)
        #expect(ProofreadingSeverity(weight: 100) == .critical)
    }
}

@Suite
struct ProofreadingServiceTests {
    // Immutable after creation and safe for concurrent reads.
    nonisolated(unsafe) private static let checker = TextChecker(language: "ru")

    @Test
    func findsIssuesWithUTF16Ranges() throws {
        let checker = try #require(Self.checker)
        let text = "Наша команда профессионалов передаёт привет."
        let issues = ProofreadingService.issues(
            in: text,
            checker: checker,
            protectedRanges: []
        )
        #expect(!issues.isEmpty)
        let nsString = text as NSString
        for issue in issues {
            #expect(NSMaxRange(issue.range) <= nsString.length)
            #expect(issue.range.length > 0)
            #expect((0...100).contains(issue.weight))
            #expect(!issue.title.isEmpty)
        }
    }

    @Test
    func dropsIssuesInsideProtectedRanges() throws {
        let checker = try #require(Self.checker)
        let text = "Наша команда профессионалов передаёт привет."
        let unfiltered = ProofreadingService.issues(
            in: text,
            checker: checker,
            protectedRanges: []
        )
        let issues = ProofreadingService.issues(
            in: text,
            checker: checker,
            protectedRanges: [NSRange(location: 0, length: (text as NSString).length)]
        )
        #expect(!unfiltered.isEmpty)
        #expect(issues.isEmpty)
    }

    /// The protected ranges are searched, not scanned, so their overlaps have
    /// to be coalesced first: here the enclosing range starts earlier than the
    /// nested one, and a search over the raw array would stop at the nested
    /// range — which ends before the issue — and report no protection.
    @Test
    func dropsIssuesInsideAnEnclosingRangeThatStartsBeforeANestedOne() throws {
        let checker = try #require(Self.checker)
        let text = "Наша команда профессионалов передаёт привет."
        let issue = try #require(
            ProofreadingService.issues(
                in: text,
                checker: checker,
                protectedRanges: []
            ).first
        )
        let nested = NSRange(location: 0, length: issue.range.location - 1)

        let issues = ProofreadingService.issues(
            in: text,
            checker: checker,
            protectedRanges: [
                NSRange(location: 0, length: (text as NSString).length),
                nested,
            ]
        )

        #expect(NSMaxRange(nested) < issue.range.location)
        #expect(issues.isEmpty)
    }

    /// Touching is not overlapping, in either direction.
    @Test
    func keepsIssuesThatOnlyAbutAProtectedRange() throws {
        let checker = try #require(Self.checker)
        let text = "Наша команда профессионалов передаёт привет."
        let issue = try #require(
            ProofreadingService.issues(
                in: text,
                checker: checker,
                protectedRanges: []
            ).first
        )

        let issues = ProofreadingService.issues(
            in: text,
            checker: checker,
            protectedRanges: [
                NSRange(location: 0, length: issue.range.location),
                NSRange(
                    location: NSMaxRange(issue.range),
                    length: (text as NSString).length - NSMaxRange(issue.range)
                ),
            ]
        )

        #expect(issues.map(\.range) == [issue.range])
    }

    @Test
    func extractsProtectedRangesFromSpans() {
        let spans = [
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 0, length: 10),
                kind: .frontmatter
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 12, length: 5),
                kind: .strong
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 20, length: 8),
                kind: .inlineCode
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 30, length: 15),
                kind: .codeBlock
            ),
            ResolvedMarkdownStyleSpan(
                range: NSRange(location: 50, length: 20),
                kind: .linkDestination
            ),
        ]
        let protected = ProofreadingService.protectedRanges(from: spans)
        #expect(protected == [
            NSRange(location: 0, length: 10),
            NSRange(location: 20, length: 8),
            NSRange(location: 30, length: 15),
            NSRange(location: 50, length: 20),
        ])
    }
}

/// The decoration layout the presenter caches across crossfade frames: the
/// overlap clipping it holds, and its invalidation when the issue list moves
/// under it.
@MainActor
struct ProofreadingPresenterDecorationTests {
    /// Severity of every issue the presenter drew, in draw order. The
    /// severity closure is called once per issue per push, which makes it
    /// the only outside window onto the cached order.
    private final class DrawLog {
        var severities: [ProofreadingSeverity] = []
    }

    @Test
    func broaderUnderlinesAreClippedAroundMoreSpecificOnes() {
        // Draw order is most specific first, so the inner range claims its
        // span and the enclosing one keeps only the two flanks.
        let segments = ProofreadingPresenter.underlineSegments(
            forDrawOrderedRanges: [
                NSRange(location: 3, length: 4),
                NSRange(location: 0, length: 10),
                NSRange(location: 20, length: 5),
            ]
        )

        #expect(segments == [
            [NSRange(location: 3, length: 4)],
            [NSRange(location: 0, length: 3), NSRange(location: 7, length: 3)],
            [NSRange(location: 20, length: 5)],
        ])
    }

    @Test
    func sweepLayoutHandlesLargeDisjointIssueSets() {
        let ranges = (0 ..< 20000).map {
            NSRange(location: $0 * 2, length: 1)
        }

        let segments = ProofreadingPresenter.underlineSegments(
            forDrawOrderedRanges: ranges
        )

        #expect(segments == ranges.map { [$0] })
    }

    @Test
    func sweepLayoutRemovesInactiveRangesBuriedInHeap() {
        let segments = ProofreadingPresenter.underlineSegments(
            forDrawOrderedRanges: [
                NSRange(location: 0, length: 10),
                NSRange(location: 2, length: 2),
                NSRange(location: 5, length: 10),
            ]
        )

        #expect(segments == [
            [NSRange(location: 0, length: 10)],
            [],
            [NSRange(location: 10, length: 5)],
        ])
    }

    @Test
    func sweepLayoutKeepsRangesThatMeetAtBoundaries() {
        let ranges = [
            NSRange(location: 2, length: 2),
            NSRange(location: 0, length: 2),
            NSRange(location: 4, length: 2),
        ]

        let segments = ProofreadingPresenter.underlineSegments(
            forDrawOrderedRanges: ranges
        )

        #expect(segments == ranges.map { [$0] })
    }

    @Test
    func teardownInvalidatesRunLoopOwnedFadeTimer() throws {
        var fixture: (ProofreadingPresenter, DrawLog)? = makePresenter()
        let timer = try #require(fixture?.0.startFadeTimerForTesting())

        fixture = nil

        #expect(!timer.isValid)
    }

    @Test
    func drawOrderIsMostSpecificFirstAndRepeatsIdenticallyOnRefresh() {
        let (presenter, log) = makePresenter()
        presenter.setIssues(Self.overlappingIssues)

        #expect(log.severities == [.medium, .high, .low])

        // A push that only recolors must reuse the cached layout unchanged.
        log.severities = []
        presenter.refreshColors()
        #expect(log.severities == [.medium, .high, .low])
    }

    @Test
    func editingIssueTextDropsItAndRebuildsTheLayout() {
        let (presenter, log) = makePresenter()
        presenter.setIssues(Self.overlappingIssues)
        log.severities = []

        // Two characters typed inside the medium issue: it and the low issue
        // enclosing it lose their text, while the far high one just shifts.
        presenter.handleTextEdit(
            editedRange: NSRange(location: 4, length: 2),
            changeInLength: 2,
            sourceLength: 202
        )

        #expect(presenter.issues.map(\.ruleID) == [3])
        #expect(presenter.issues.map(\.range) == [NSRange(location: 22, length: 5)])
        // A stale layout would still index the three-issue order here.
        #expect(log.severities == [.high])
    }

    @Test
    func clearingIssuesStopsDrawing() {
        let (presenter, log) = makePresenter()
        presenter.setIssues(Self.overlappingIssues)
        log.severities = []

        presenter.clearIssues()

        #expect(presenter.issues.isEmpty)
        #expect(log.severities.isEmpty)
    }

    // MARK: - Fixtures

    /// Weights are picked so each issue lands in a different severity bucket
    /// and the draw log identifies which issue was drawn when.
    private static let overlappingIssues = [
        issue(location: 0, length: 10, ruleID: 1, weight: 0),
        issue(location: 3, length: 4, ruleID: 2, weight: 50),
        issue(location: 20, length: 5, ruleID: 3, weight: 80),
    ]

    private static func issue(
        location: Int,
        length: Int,
        ruleID: Int,
        weight: Int
    ) -> ProofreadingIssue {
        ProofreadingIssue(
            range: NSRange(location: location, length: length),
            ruleID: ruleID,
            title: "rule \(ruleID)",
            hint: "hint \(ruleID)",
            weight: weight
        )
    }

    private func makePresenter() -> (ProofreadingPresenter, DrawLog) {
        let storage = NSTextStorage(string: String(repeating: "a", count: 200))
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(
                width: 400,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        layoutManager.addTextContainer(container)
        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        let log = DrawLog()
        let presenter = ProofreadingPresenter(textView: textView) { severity in
            log.severities.append(severity)
            return .systemOrange
        }
        presenter.setEnabled(true)
        return (presenter, log)
    }
}
