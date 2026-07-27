import Foundation
import Rdktr

@MainActor
final class ProofreadingService {
    var onCheck: ((_ issues: [ProofreadingIssue], _ source: String) -> Void)?

    private var nextVersion = 0
    private var latestScheduledVersion = 0
    private var checkTask: Task<Void, Never>?

    /// Immutable after creation and safe for concurrent reads; created lazily
    /// off-main on first check. nil means the embedded rules failed to load
    /// and the service stays a no-op.
    nonisolated(unsafe) private static let checker = TextChecker()

    deinit {
        checkTask?.cancel()
    }

    func scheduleCheck(
        text: String,
        protectedRanges: [NSRange],
        debounceMilliseconds: Int = 300
    ) {
        nextVersion += 1
        let version = nextVersion
        latestScheduledVersion = version

        checkTask?.cancel()
        checkTask = Task.detached(priority: .utility) { [
            text,
            protectedRanges,
            version
        ] in
            if debounceMilliseconds > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(debounceMilliseconds))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled, let checker = Self.checker else {
                return
            }

            let issues = Self.issues(
                in: text,
                checker: checker,
                protectedRanges: protectedRanges
            )
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, version == latestScheduledVersion else {
                    return
                }

                onCheck?(issues, text)
            }
        }
    }

    func cancel() {
        // Bump the version so any in-flight task's result no longer matches.
        nextVersion += 1
        latestScheduledVersion = nextVersion
        checkTask?.cancel()
        checkTask = nil
    }

    nonisolated static func issues(
        in text: String,
        checker: TextChecker,
        protectedRanges: [NSRange]
    ) -> [ProofreadingIssue] {
        // Both sides grow with the document, so the linear scan per issue was
        // the dominant cost of a check on a code-heavy file. Normalized once,
        // each issue then costs a binary search.
        let protected = normalized(protectedRanges)
        return checker.check(text).compactMap { issue in
            // String.Index is bound to this exact snapshot; the conversion
            // must never touch the live editor string.
            let range = NSRange(issue.range, in: text)
            guard range.length > 0,
                  !intersects(range, protected)
            else {
                return nil
            }

            return ProofreadingIssue(
                range: range,
                ruleID: issue.rule.id,
                title: issue.rule.title,
                hint: issue.rule.hint,
                weight: issue.rule.weight
            )
        }
    }

    /// Sorted and coalesced, which is what makes the binary search below
    /// valid: with overlapping ranges (a link destination inside a code span,
    /// say) a lower-starting range can outlive the one the search lands on.
    /// Empty ranges are dropped — they can never intersect anything.
    nonisolated private static func normalized(_ ranges: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        merged.reserveCapacity(ranges.count)
        for range in ranges.filter({ $0.length > 0 })
            .sorted(by: { $0.location < $1.location })
        {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `ranges` must come from `normalized(_:)`.
    nonisolated private static func intersects(
        _ range: NSRange,
        _ ranges: [NSRange]
    ) -> Bool {
        // The first range that has not already ended before `range` starts is
        // the only candidate: everything after it starts even later.
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(ranges[middle]) <= range.location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ranges.count && ranges[low].location < NSMaxRange(range)
    }

    nonisolated static func protectedRanges(
        from spans: [ResolvedMarkdownStyleSpan]
    ) -> [NSRange] {
        spans.compactMap { span in
            switch span.kind {
            case .codeBlock, .inlineCode, .frontmatter, .linkDestination:
                span.range
            default:
                nil
            }
        }
    }
}
