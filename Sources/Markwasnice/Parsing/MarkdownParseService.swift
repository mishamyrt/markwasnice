import Foundation
import Markdown

@MainActor
final class MarkdownParseService {
    var onParse: ((MarkdownParseResult) -> Void)?

    private var nextVersion = 0
    private var latestScheduledVersion = 0
    private var parseTask: Task<Void, Never>?

    deinit {
        parseTask?.cancel()
    }

    func scheduleParse(text: String) {
        nextVersion += 1
        let version = nextVersion
        latestScheduledVersion = version

        parseTask?.cancel()
        parseTask = Task.detached(priority: .utility) { [text, version] in
            let debounce = text.utf16.count > 200_000 ? 80 : 0
            if debounce > 0 {
                do {
                    try await Task.sleep(for: .milliseconds(debounce))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else {
                return
            }

            let result = Self.parse(text: text, version: version)

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run { [weak self] in
                guard let self, version == latestScheduledVersion else {
                    return
                }

                onParse?(result)
            }
        }
    }

    nonisolated private static func parse(
        text: String,
        version: Int
    ) -> MarkdownParseResult {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        var collector = MarkdownStyleSpanCollector()
        collector.visit(document)

        return MarkdownParseResult(
            textVersion: version,
            sourceLength: text.utf16.count,
            spans: collector.spans
        )
    }
}
