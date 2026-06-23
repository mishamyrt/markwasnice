import Foundation
import Markdown

struct SourceMap {
    private let textLength: Int
    private let lines: [Line]

    init(text: String) {
        textLength = text.utf16.count
        lines = Self.makeLines(for: text)
    }

    func nsRange(for sourceRange: SourceRange) -> NSRange? {
        guard let lower = utf16Offset(for: sourceRange.lowerBound),
              let upper = utf16Offset(for: sourceRange.upperBound),
              lower <= upper,
              upper <= textLength
        else {
            return nil
        }

        return NSRange(location: lower, length: upper - lower)
    }

    private func utf16Offset(for location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= lines.count else {
            return nil
        }

        let line = lines[location.line - 1]
        guard let offsetInLine = line.utf16OffsetByUTF8Column[location.column] else {
            return nil
        }

        return line.utf16StartOffset + offsetInLine
    }

    private static func makeLines(for text: String) -> [Line] {
        var result: [Line] = []
        var lineStartIndex = text.startIndex
        var lineUTF16StartOffset = 0

        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isNewline {
                let lineText = text[lineStartIndex ..< index]
                result.append(Line(
                    text: lineText,
                    utf16StartOffset: lineUTF16StartOffset
                ))

                let nextIndex = text.index(after: index)
                lineUTF16StartOffset += text[lineStartIndex ..< nextIndex].utf16.count
                lineStartIndex = nextIndex
            }

            index = text.index(after: index)
        }

        result.append(Line(
            text: text[lineStartIndex ..< text.endIndex],
            utf16StartOffset: lineUTF16StartOffset
        ))
        return result
    }
}

private struct Line {
    let utf16StartOffset: Int
    let utf16OffsetByUTF8Column: [Int: Int]

    init(text: Substring, utf16StartOffset: Int) {
        self.utf16StartOffset = utf16StartOffset

        var offsets = [1: 0]
        var utf8Column = 1
        var utf16Offset = 0

        for character in text {
            utf8Column += String(character).utf8.count
            utf16Offset += String(character).utf16.count
            offsets[utf8Column] = utf16Offset
        }

        utf16OffsetByUTF8Column = offsets
    }
}
