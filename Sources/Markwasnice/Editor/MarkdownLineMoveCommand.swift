import Foundation

/// Option+Up / Option+Down: moves the current line, or the lines touched by
/// a selection, one place while keeping the selection with them.
enum MarkdownLineMoveCommand {
    case up
    case down

    /// The text storage is an NSString, so line and selection positions stay
    /// in AppKit's native UTF-16 coordinates without copying the document.
    func edit(
        in nsString: NSString,
        selectedRange: NSRange
    ) -> MarkdownMarkupEdit? {
        guard selectedRange.location != NSNotFound,
              selectedRange.location <= nsString.length,
              NSMaxRange(selectedRange) <= nsString.length
        else {
            return nil
        }

        let movingRange = Self.lineRange(
            containing: selectedRange,
            in: nsString
        )
        let movingLines = Self.lines(in: nsString, range: movingRange)
        let sourceLines: [Line]
        let reorderedContents: [String]
        let movingStartIndex: Int

        switch self {
        case .up:
            guard movingRange.location > 0 else {
                return nil
            }

            let previousLine = Self.line(
                in: nsString,
                at: movingRange.location - 1
            )
            guard NSMaxRange(previousLine.range) == movingRange.location else {
                return nil
            }

            sourceLines = [previousLine] + movingLines
            reorderedContents = movingLines.map(\.content) + [previousLine.content]
            movingStartIndex = 0
        case .down:
            let movingEnd = NSMaxRange(movingRange)
            let nextLine = Self.line(in: nsString, at: movingEnd)
            guard nextLine.range.location == movingEnd else {
                return nil
            }

            sourceLines = movingLines + [nextLine]
            reorderedContents = [nextLine.content] + movingLines.map(\.content)
            movingStartIndex = 1
        }

        let replacementRange = NSRange(
            location: sourceLines[0].range.location,
            length: NSMaxRange(sourceLines[sourceLines.count - 1].range)
                - sourceLines[0].range.location
        )
        let replacementString = zip(reorderedContents, sourceLines)
            .map { $0.0 + $0.1.ending }
            .joined()

        let outputLineLengths = zip(reorderedContents, sourceLines).map {
            ($0.0 as NSString).length + ($0.1.ending as NSString).length
        }
        let newMovingOffset = outputLineLengths
            .prefix(movingStartIndex)
            .reduce(0, +)
        let newMovingLength = outputLineLengths
            .dropFirst(movingStartIndex)
            .prefix(movingLines.count)
            .reduce(0, +)
        let oldSelectionOffset = selectedRange.location - movingRange.location
        let newSelectionOffset = min(oldSelectionOffset, newMovingLength)
        let newSelectionLength = min(
            selectedRange.length,
            newMovingLength - newSelectionOffset
        )

        return MarkdownMarkupEdit(
            replacementRange: replacementRange,
            replacementString: replacementString,
            selectedRange: NSRange(
                location: replacementRange.location + newMovingOffset
                    + newSelectionOffset,
                length: newSelectionLength
            )
        )
    }

    private static func lineRange(
        containing selectedRange: NSRange,
        in nsString: NSString
    ) -> NSRange {
        let firstLine = line(in: nsString, at: selectedRange.location)
        guard selectedRange.length > 0 else {
            return firstLine.range
        }

        let lastLine = line(
            in: nsString,
            at: NSMaxRange(selectedRange) - 1
        )
        return NSRange(
            location: firstLine.range.location,
            length: NSMaxRange(lastLine.range) - firstLine.range.location
        )
    }

    private static func lines(in nsString: NSString, range: NSRange) -> [Line] {
        var lines: [Line] = []
        var location = range.location
        repeat {
            let line = line(in: nsString, at: location)
            lines.append(line)

            let nextLocation = NSMaxRange(line.range)
            guard nextLocation > location,
                  nextLocation < NSMaxRange(range)
            else {
                break
            }
            location = nextLocation
        } while true

        return lines
    }

    private static func line(in nsString: NSString, at location: Int) -> Line {
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        nsString.getLineStart(
            &lineStart,
            end: &lineEnd,
            contentsEnd: &contentsEnd,
            for: NSRange(location: location, length: 0)
        )

        return Line(
            range: NSRange(location: lineStart, length: lineEnd - lineStart),
            content: nsString.substring(with: NSRange(
                location: lineStart,
                length: contentsEnd - lineStart
            )),
            ending: nsString.substring(with: NSRange(
                location: contentsEnd,
                length: lineEnd - contentsEnd
            ))
        )
    }

    private struct Line {
        let range: NSRange
        let content: String
        let ending: String
    }
}
