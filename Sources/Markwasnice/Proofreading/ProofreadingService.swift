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
        checker.check(text).compactMap { issue in
            // String.Index is bound to this exact snapshot; the conversion
            // must never touch the live editor string.
            let range = NSRange(issue.range, in: text)
            guard range.length > 0,
                  !protectedRanges.contains(where: {
                      NSIntersectionRange(range, $0).length > 0
                  })
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

    nonisolated static func protectedRanges(
        from spans: [ResolvedMarkdownStyleSpan]
    ) -> [NSRange] {
        spans.compactMap { span in
            switch span.kind {
            case .codeBlock, .inlineCode, .frontmatter:
                span.range
            default:
                nil
            }
        }
    }
}
