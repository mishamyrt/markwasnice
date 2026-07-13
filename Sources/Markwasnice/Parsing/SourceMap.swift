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

    /// UTF-16 line ranges including the trailing newline, matching
    /// NSString.lineRange(for:) semantics — the lines are already computed,
    /// so callers avoid another full-document walk.
    func lineRanges() -> [NSRange] {
        var result: [NSRange] = []
        result.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let nextLineStart = index + 1 < lines.count
                ? lines[index + 1].utf16StartOffset
                : textLength
            result.append(NSRange(
                location: line.utf16StartOffset,
                length: nextLineStart - line.utf16StartOffset
            ))
        }

        return result
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
        var builder = Line.Builder()
        var lineUTF16StartOffset = 0

        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            index = scalars.index(after: index)

            guard isNewline(scalar) else {
                builder.append(scalar)
                continue
            }

            var newlineUTF16Length = 1
            if scalar == "\r", index < scalars.endIndex, scalars[index] == "\n" {
                index = scalars.index(after: index)
                newlineUTF16Length += 1
            }

            let line = builder.finish(utf16StartOffset: lineUTF16StartOffset)
            result.append(line)

            lineUTF16StartOffset += line.utf16Length + newlineUTF16Length
            builder = Line.Builder()
        }

        result.append(builder.finish(utf16StartOffset: lineUTF16StartOffset))
        return result
    }

    /// The newlines cmark recognizes are the scalars Character.isNewline
    /// matches; CR LF is handled as a pair at the call site.
    private static func isNewline(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A ... 0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }
}

private struct Line {
    let utf16StartOffset: Int
    let utf16Length: Int

    /// UTF-8 length of the leading run where one byte maps to one UTF-16
    /// unit; for an all-ASCII line this is the whole line and the boundary
    /// arrays stay empty.
    private let asciiPrefixUTF8Length: Int

    /// Scalar boundaries past the ASCII prefix as parallel sorted arrays:
    /// `utf8Boundaries[i]` is a UTF-8 offset from the line start and
    /// `utf16Boundaries[i]` the matching UTF-16 offset.
    private let utf8Boundaries: [Int]
    private let utf16Boundaries: [Int]

    func utf16Offset(forUTF8Column column: Int) -> Int? {
        let utf8Offset = column - 1
        guard utf8Offset >= 0 else {
            return nil
        }

        if utf8Offset <= asciiPrefixUTF8Length {
            return utf8Offset
        }

        var low = 0
        var high = utf8Boundaries.count
        while low < high {
            let middle = (low + high) / 2
            if utf8Boundaries[middle] < utf8Offset {
                low = middle + 1
            } else {
                high = middle
            }
        }

        guard low < utf8Boundaries.count, utf8Boundaries[low] == utf8Offset else {
            return nil
        }

        return utf16Boundaries[low]
    }

    struct Builder {
        private var utf8Length = 0
        private var utf16Length = 0
        private var isAllASCII = true
        private var asciiPrefixUTF8Length = 0
        private var utf8Boundaries: [Int] = []
        private var utf16Boundaries: [Int] = []

        mutating func append(_ scalar: Unicode.Scalar) {
            if isAllASCII {
                if scalar.isASCII {
                    utf8Length += 1
                    utf16Length += 1
                    return
                }

                isAllASCII = false
                asciiPrefixUTF8Length = utf8Length
            }

            utf8Length += Self.utf8Width(scalar)
            utf16Length += scalar.value < 0x10000 ? 1 : 2
            utf8Boundaries.append(utf8Length)
            utf16Boundaries.append(utf16Length)
        }

        func finish(utf16StartOffset: Int) -> Line {
            Line(
                utf16StartOffset: utf16StartOffset,
                utf16Length: utf16Length,
                asciiPrefixUTF8Length: isAllASCII ? utf8Length : asciiPrefixUTF8Length,
                utf8Boundaries: utf8Boundaries,
                utf16Boundaries: utf16Boundaries
            )
        }

        private static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
            switch scalar.value {
            case ..<0x80: 1
            case ..<0x800: 2
            case ..<0x10000: 3
            default: 4
            }
        }
    }
}
