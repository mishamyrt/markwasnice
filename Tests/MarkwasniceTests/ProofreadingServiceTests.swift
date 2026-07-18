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
        ]
        let protected = ProofreadingService.protectedRanges(from: spans)
        #expect(protected == [
            NSRange(location: 0, length: 10),
            NSRange(location: 20, length: 8),
            NSRange(location: 30, length: 15),
        ])
    }
}
