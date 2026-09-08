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

        // Scan the line dedented: indentation is a visual shift in this
        // editor (see MarkdownShiftedContentReparser), while cmark would read
        // a 4-space or tab shift as an indented code block and drop every
        // inline span on the line.
        var leadingLength = 0
        while leadingLength < lineRange.length {
            let character = string.character(at: lineRange.location + leadingLength)
            guard character == 0x20 || character == 0x09 else { // ' ' or '\t'
                break
            }

            leadingLength += 1
        }

        let line = string.substring(with: NSRange(
            location: lineRange.location + leadingLength,
            length: lineRange.length - leadingLength
        ))
        let trimmedLine = line.trimmingCharacters(in: .newlines)
        guard !trimmedLine.isEmpty else {
            return []
        }

        let document = Document(parsing: trimmedLine, options: [.disableSmartOpts])
        var collector = MarkdownStyleSpanCollector()
        collector.visit(document)

        let sourceMap = SourceMap(text: trimmedLine)
        let lineStartOffset = lineRange.location + leadingLength

        // Unlike the parse pipeline, zero-length spans are dropped right at
        // resolution: the scanner only feeds local restyling, which has no
        // later mapping step to drop them.
        let resolvedSpans = collector.resolvedSpans(
            in: trimmedLine,
            sourceMap: sourceMap,
            droppingZeroLength: true
        ).filter { !$0.kind.isBlockStyle }

        return resolvedSpans.compactMap { span in
            let fullRange = NSRange(
                location: lineStartOffset + span.range.location,
                length: span.range.length
            )

            guard NSMaxRange(fullRange) <= NSMaxRange(lineRange) else {
                return nil
            }

            return ResolvedMarkdownStyleSpan(range: fullRange, kind: span.kind)
        }
    }
}
