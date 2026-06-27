import Foundation
import Markdown

enum MarkdownInlineStyleScanner {
    static func inlineSpans(
        in lineRange: NSRange,
        source: String
    ) -> [ResolvedMarkdownStyleSpan] {
        let string = source as NSString
        guard lineRange.location >= 0,
              lineRange.length >= 0,
              NSMaxRange(lineRange) <= string.length
        else {
            return []
        }

        let line = string.substring(with: lineRange)
        let trimmedLine = line.trimmingCharacters(in: .newlines)
        guard !trimmedLine.isEmpty else {
            return []
        }

        let document = Document(parsing: trimmedLine, options: [.disableSmartOpts])
        var collector = MarkdownStyleSpanCollector()
        collector.visit(document)

        let sourceMap = SourceMap(text: trimmedLine)
        let lineStartOffset = lineRange.location

        return collector.spans.compactMap { span in
            guard !span.kind.isBlockStyle else {
                return nil
            }

            guard let substringRange = sourceMap.nsRange(for: span.range),
                  substringRange.length > 0
            else {
                return nil
            }

            let fullRange = NSRange(
                location: lineStartOffset + substringRange.location,
                length: substringRange.length
            )

            guard NSMaxRange(fullRange) <= NSMaxRange(lineRange) else {
                return nil
            }

            return ResolvedMarkdownStyleSpan(range: fullRange, kind: span.kind)
        }
    }
}
