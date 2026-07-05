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
        guard let offsetInLine = line.utf16Offset(forUTF8Column: location.column) else {
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
            let character = text[index]
            if character.isNewline {
                let line = Line(
                    text: text[lineStartIndex ..< index],
                    utf16StartOffset: lineUTF16StartOffset
                )
                result.append(line)

                lineUTF16StartOffset += line.utf16Length + character.utf16.count
                lineStartIndex = text.index(after: index)
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
    let utf16Length: Int

    private let mapping: Mapping

    private enum Mapping {
        // An all-ASCII line maps one UTF-8 byte to one UTF-16 unit, so
        // offsets follow from the column with no per-character table.
        case ascii
        case table([Int: Int])
    }

    init(text: Substring, utf16StartOffset: Int) {
        self.utf16StartOffset = utf16StartOffset

        if text.allSatisfy(\.isASCII) {
            utf16Length = text.utf8.count
            mapping = .ascii
            return
        }

        var offsets = [1: 0]
        var utf8Column = 1
        var utf16Offset = 0

        for character in text {
            utf8Column += character.utf8.count
            utf16Offset += character.utf16.count
            offsets[utf8Column] = utf16Offset
        }

        utf16Length = utf16Offset
        mapping = .table(offsets)
    }

    func utf16Offset(forUTF8Column column: Int) -> Int? {
        switch mapping {
        case .ascii:
            guard column >= 1, column <= utf16Length + 1 else {
                return nil
            }

            return column - 1
        case let .table(offsets):
            return offsets[column]
        }
    }
}
