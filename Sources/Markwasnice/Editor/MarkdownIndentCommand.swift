import Foundation

/// Tab / Shift+Tab: shifts the leading indent of every line covered by the
/// selection, regardless of where inside the line the caret sits. The text
/// arrives as an NSString — the whole command is UTF-16 range math, and the
/// editor hands over the text storage's backing string, which bridging into a
/// Swift String would copy on every Tab.
enum MarkdownIndentCommand {
    case indent
    case outdent

    func edit(
        in nsString: NSString,
        selectedRange: NSRange,
        indentUnit: String,
        tabWidth: Int
    ) -> MarkdownMarkupEdit? {
        guard selectedRange.location != NSNotFound,
              selectedRange.location <= nsString.length,
              NSMaxRange(selectedRange) <= nsString.length
        else {
            return nil
        }

        let lineRange = nsString.lineRange(for: selectedRange)
        guard lineRange.length > 0 else {
            // Caret on the empty line after a trailing newline: there is no
            // line content to walk, but indenting should still start one.
            guard self == .indent else {
                return nil
            }

            return MarkdownMarkupEdit(
                replacementRange: lineRange,
                replacementString: indentUnit,
                selectedRange: NSRange(
                    location: selectedRange.location + indentUnit.utf16.count,
                    length: 0
                )
            )
        }

        let isSingleLine = NSMaxRange(nsString.lineRange(
            for: NSRange(location: lineRange.location, length: 0)
        )) >= NSMaxRange(lineRange)

        var replacement = ""
        var firstLineDelta = 0
        var totalDelta = 0
        var location = lineRange.location
        var isFirstLine = true
        while location < NSMaxRange(lineRange) {
            let currentLineRange = nsString.lineRange(
                for: NSRange(location: location, length: 0)
            )
            let (line, delta) = adjustedLine(
                nsString.substring(with: currentLineRange),
                indentUnit: indentUnit,
                tabWidth: tabWidth,
                indentsBlankLine: isSingleLine
            )
            replacement += line
            totalDelta += delta
            if isFirstLine {
                firstLineDelta = delta
                isFirstLine = false
            }
            location = NSMaxRange(currentLineRange)
        }

        guard totalDelta != 0 else {
            return nil
        }

        let newLocation: Int
        if selectedRange.length > 0, selectedRange.location == lineRange.location {
            // A selection anchored at the first line's start keeps covering
            // the indent inserted (or removed) in front of it.
            newLocation = lineRange.location
        } else {
            newLocation = max(
                lineRange.location,
                selectedRange.location + firstLineDelta
            )
        }
        let newEnd = max(newLocation, NSMaxRange(selectedRange) + totalDelta)
        return MarkdownMarkupEdit(
            replacementRange: lineRange,
            replacementString: replacement,
            selectedRange: NSRange(
                location: newLocation,
                length: selectedRange.length == 0 ? 0 : newEnd - newLocation
            )
        )
    }

    private func adjustedLine(
        _ line: String,
        indentUnit: String,
        tabWidth: Int,
        indentsBlankLine: Bool
    ) -> (line: String, delta: Int) {
        let nsLine = line as NSString
        var bodyLength = nsLine.length
        while bodyLength > 0, isNewline(nsLine.character(at: bodyLength - 1)) {
            bodyLength -= 1
        }

        switch self {
        case .indent:
            guard bodyLength > 0 || indentsBlankLine else {
                return (line, 0)
            }

            return (indentUnit + line, indentUnit.utf16.count)
        case .outdent:
            guard bodyLength > 0 else {
                return (line, 0)
            }

            if nsLine.character(at: 0) == 0x09 { // '\t'
                return (nsLine.substring(from: 1), -1)
            }

            var spaces = 0
            while spaces < min(bodyLength, tabWidth),
                  nsLine.character(at: spaces) == 0x20 // ' '
            {
                spaces += 1
            }
            guard spaces > 0 else {
                return (line, 0)
            }

            return (nsLine.substring(from: spaces), -spaces)
        }
    }

    private func isNewline(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D
    }
}
