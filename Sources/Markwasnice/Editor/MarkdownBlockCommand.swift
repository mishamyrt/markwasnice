import Foundation

/// Line-oriented block formatting commands used by the Format menu.
enum MarkdownBlockCommand {
    case blockquote
    case list
    case taskList
    case orderedList
    case orderedTaskList
    case markTaskCompleted

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

        let lineRange = nsString.lineRange(for: selectedRange)
        let lines = blockCommandLines(
            in: nsString.substring(with: lineRange) as NSString
        )
        let transformations: [BlockLineTransformation]
        switch self {
        case .blockquote:
            transformations = blockquoteTransformations(for: lines)
        case .list, .taskList, .orderedList, .orderedTaskList:
            transformations = listTransformations(for: lines)
        case .markTaskCompleted:
            transformations = taskCompletionTransformations(for: lines)
        }

        let replacement = transformations.map(\.replacement).joined()
        guard replacement != nsString.substring(with: lineRange) else {
            return nil
        }

        let newSelection: NSRange
        if selectedRange.length > 0 {
            newSelection = NSRange(
                location: lineRange.location,
                length: (replacement as NSString).length
            )
        } else {
            let first = transformations[0]
            let offsetInLine = selectedRange.location - lineRange.location
            let newOffset = offsetInLine <= first.oldPrefixLength
                ? first.newPrefixLength
                : offsetInLine - first.oldPrefixLength + first.newPrefixLength
            newSelection = NSRange(
                location: lineRange.location + newOffset,
                length: 0
            )
        }

        return MarkdownMarkupEdit(
            replacementRange: lineRange,
            replacementString: replacement,
            selectedRange: newSelection
        )
    }

    private func blockquoteTransformations(
        for lines: [BlockCommandLine]
    ) -> [BlockLineTransformation] {
        let contentLines = lines.filter { !$0.bodyIsBlank }
        let removesPrefix = !contentLines.isEmpty
            && contentLines.allSatisfy { $0.body.hasPrefix(">") }
        let formatsBlankLine = lines.count == 1

        return lines.map { line in
            guard !line.bodyIsBlank || formatsBlankLine else {
                return line.unchangedTransformation
            }

            if removesPrefix {
                let removedLength = quoteMarkerLength(in: line.body)
                let body = (line.body as NSString).substring(from: removedLength)
                return line.transformation(
                    body: body,
                    oldPrefixLength: line.leadingLength + removedLength,
                    newPrefixLength: line.leadingLength
                )
            }

            if line.body.hasPrefix(">") {
                return line.unchangedTransformation
            }

            return line.transformation(
                body: "> " + line.body,
                oldPrefixLength: line.leadingLength,
                newPrefixLength: line.leadingLength + 2
            )
        }
    }

    private func listTransformations(
        for lines: [BlockCommandLine]
    ) -> [BlockLineTransformation] {
        let contentLines = lines.filter { !$0.bodyIsBlank }
        let removesPrefix = !contentLines.isEmpty
            && contentLines.allSatisfy { listPrefix(in: $0.body).matches(self) }
        let formatsBlankLine = lines.count == 1
        var orderedIndex = 1

        return lines.map { line in
            guard !line.bodyIsBlank || formatsBlankLine else {
                return line.unchangedTransformation
            }

            let existing = listPrefix(in: line.body)
            let oldPrefixLength = line.leadingLength + existing.contentOffset
            if removesPrefix {
                return line.transformation(
                    body: existing.container + existing.content,
                    oldPrefixLength: oldPrefixLength,
                    newPrefixLength: line.leadingLength
                        + (existing.container as NSString).length
                )
            }

            let marker: String
            switch self {
            case .list, .taskList:
                marker = "- "
            case .orderedList, .orderedTaskList:
                marker = "\(orderedIndex). "
                orderedIndex += 1
            case .blockquote, .markTaskCompleted:
                preconditionFailure("Not a list command")
            }

            let checkbox: String
            switch self {
            case .taskList, .orderedTaskList:
                checkbox = "[\(existing.checkboxState ?? " ")] "
            case .list, .orderedList:
                checkbox = ""
            case .blockquote, .markTaskCompleted:
                preconditionFailure("Not a list command")
            }

            let prefix = existing.container + marker + checkbox
            return line.transformation(
                body: prefix + existing.content,
                oldPrefixLength: oldPrefixLength,
                newPrefixLength: line.leadingLength + (prefix as NSString).length
            )
        }
    }

    private func taskCompletionTransformations(
        for lines: [BlockCommandLine]
    ) -> [BlockLineTransformation] {
        lines.map { line in
            let prefix = listPrefix(in: line.body)
            guard prefix.checkboxState == " ",
                  let stateLocation = prefix.checkboxStateLocation
            else {
                return line.unchangedTransformation
            }

            let body = line.body as NSString
            let completedBody = body.replacingCharacters(
                in: NSRange(location: stateLocation, length: 1),
                with: "x"
            )
            return line.transformation(
                body: completedBody,
                oldPrefixLength: line.leadingLength + prefix.contentOffset,
                newPrefixLength: line.leadingLength + prefix.contentOffset
            )
        }
    }
}

private struct BlockLineTransformation {
    let replacement: String
    let oldPrefixLength: Int
    let newPrefixLength: Int
}

private struct BlockCommandLine {
    let leading: String
    let body: String
    let newline: String

    var leadingLength: Int {
        (leading as NSString).length
    }

    var bodyIsBlank: Bool {
        body.allSatisfy { $0 == " " || $0 == "\t" }
    }

    var unchangedTransformation: BlockLineTransformation {
        transformation(
            body: body,
            oldPrefixLength: leadingLength,
            newPrefixLength: leadingLength
        )
    }

    func transformation(
        body newBody: String,
        oldPrefixLength: Int,
        newPrefixLength: Int
    ) -> BlockLineTransformation {
        BlockLineTransformation(
            replacement: leading + newBody + newline,
            oldPrefixLength: oldPrefixLength,
            newPrefixLength: newPrefixLength
        )
    }
}

private struct MarkdownListPrefix {
    enum Marker {
        case unordered
        case ordered
    }

    let container: String
    let marker: Marker?
    let checkboxState: Character?
    let checkboxStateLocation: Int?
    let content: String
    let contentOffset: Int

    func matches(_ command: MarkdownBlockCommand) -> Bool {
        switch command {
        case .list:
            marker == .unordered && checkboxState == nil
        case .taskList:
            marker == .unordered && checkboxState != nil
        case .orderedList:
            marker == .ordered && checkboxState == nil
        case .orderedTaskList:
            marker == .ordered && checkboxState != nil
        case .blockquote, .markTaskCompleted:
            false
        }
    }
}

private func listPrefix(in body: String) -> MarkdownListPrefix {
    let nsBody = body as NSString
    var location = quoteContainerEnd(in: nsBody)
    let containerEnd = location
    let marker = listMarker(in: nsBody, location: &location)
    let checkbox = taskCheckbox(in: nsBody, location: &location)

    return MarkdownListPrefix(
        container: nsBody.substring(to: containerEnd),
        marker: marker,
        checkboxState: checkbox?.state,
        checkboxStateLocation: checkbox?.stateLocation,
        content: nsBody.substring(from: location),
        contentOffset: location
    )
}

private func quoteContainerEnd(in string: NSString) -> Int {
    var location = 0
    while location < string.length, string.character(at: location) == 0x3E { // '>'
        location += 1
        while location < string.length, isBlockHorizontalWhitespace(
            string.character(at: location)
        ) {
            location += 1
        }
    }
    return location
}

private func listMarker(
    in string: NSString,
    location: inout Int
) -> MarkdownListPrefix.Marker? {
    guard location < string.length else {
        return nil
    }

    let start = location
    let first = string.character(at: location)
    let marker: MarkdownListPrefix.Marker
    if first == 0x2D || first == 0x2B || first == 0x2A { // '-+*'
        marker = .unordered
        location += 1
    } else if first >= 0x30, first <= 0x39 { // '0' ... '9'
        repeat {
            location += 1
        } while location < string.length
            && string.character(at: location) >= 0x30
            && string.character(at: location) <= 0x39

        guard location < string.length,
              string.character(at: location) == 0x2E
              || string.character(at: location) == 0x29 // '.)'
        else {
            location = start
            return nil
        }
        marker = .ordered
        location += 1
    } else {
        return nil
    }

    guard location == string.length
        || isBlockHorizontalWhitespace(string.character(at: location))
    else {
        location = start
        return nil
    }
    while location < string.length, isBlockHorizontalWhitespace(
        string.character(at: location)
    ) {
        location += 1
    }
    return marker
}

private func taskCheckbox(
    in string: NSString,
    location: inout Int
) -> (state: Character, stateLocation: Int)? {
    let start = location
    guard start + 2 < string.length,
          string.character(at: start) == 0x5B, // '['
          string.character(at: start + 2) == 0x5D // ']'
    else {
        return nil
    }

    let stateCharacter = string.character(at: start + 1)
    guard stateCharacter == 0x20
        || stateCharacter == 0x78
        || stateCharacter == 0x58 // ' xX'
    else {
        return nil
    }

    location = start + 3
    guard location == string.length
        || isBlockHorizontalWhitespace(string.character(at: location))
    else {
        location = start
        return nil
    }
    while location < string.length, isBlockHorizontalWhitespace(
        string.character(at: location)
    ) {
        location += 1
    }

    return (Character(UnicodeScalar(stateCharacter)!), start + 1)
}

private func quoteMarkerLength(in body: String) -> Int {
    let nsBody = body as NSString
    var location = 1
    while location < nsBody.length, isBlockHorizontalWhitespace(
        nsBody.character(at: location)
    ) {
        location += 1
    }
    return location
}

private func blockCommandLines(in nsString: NSString) -> [BlockCommandLine] {
    guard nsString.length > 0 else {
        return [BlockCommandLine(leading: "", body: "", newline: "")]
    }

    var lines: [BlockCommandLine] = []
    var location = 0
    while location < nsString.length {
        let lineRange = nsString.lineRange(
            for: NSRange(location: location, length: 0)
        )
        let boundedRange = NSRange(
            location: location,
            length: min(NSMaxRange(lineRange), nsString.length) - location
        )
        lines.append(blockCommandLine(from: nsString.substring(with: boundedRange)))
        location = NSMaxRange(boundedRange)
    }
    return lines
}

private func blockCommandLine(from line: String) -> BlockCommandLine {
    let nsLine = line as NSString
    let newlineLength: Int
    if line.hasSuffix("\r\n") {
        newlineLength = 2
    } else if line.hasSuffix("\n") || line.hasSuffix("\r") {
        newlineLength = 1
    } else {
        newlineLength = 0
    }

    let bodyLength = nsLine.length - newlineLength
    var leadingLength = 0
    while leadingLength < bodyLength, isBlockHorizontalWhitespace(
        nsLine.character(at: leadingLength)
    ) {
        leadingLength += 1
    }

    return BlockCommandLine(
        leading: nsLine.substring(with: NSRange(
            location: 0,
            length: leadingLength
        )),
        body: nsLine.substring(with: NSRange(
            location: leadingLength,
            length: bodyLength - leadingLength
        )),
        newline: nsLine.substring(from: bodyLength)
    )
}

private func isBlockHorizontalWhitespace(_ character: unichar) -> Bool {
    character == 0x20 || character == 0x09 // ' ' or '\t'
}
