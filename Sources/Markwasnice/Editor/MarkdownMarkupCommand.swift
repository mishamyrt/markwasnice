import Foundation

struct MarkdownMarkupEdit: Equatable {
    let replacementRange: NSRange
    let replacementString: String
    let selectedRange: NSRange
}

enum MarkdownMarkupCommand: Int {
    case bold
    case italic
    case strikethrough
    case highlight
    case link
    case imageLink
    case code
    case codeBlock
    case heading1
    case heading2
    case heading3
    case heading4
    case heading5
    case heading6

    func edit(in text: String, selectedRange: NSRange) -> MarkdownMarkupEdit? {
        let nsString = text as NSString
        guard selectedRange.location != NSNotFound,
              selectedRange.location <= nsString.length,
              NSMaxRange(selectedRange) <= nsString.length
        else {
            return nil
        }

        switch self {
        case .bold:
            return Self.inlinePairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "**", closing: "**"
            )
        case .italic:
            return Self.inlinePairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "*", closing: "*"
            )
        case .strikethrough:
            return Self.inlinePairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "~~", closing: "~~"
            )
        case .highlight:
            return Self.inlinePairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "==", closing: "=="
            )
        case .link:
            return Self.linkEdit(
                in: nsString, selectedRange: selectedRange, isImage: false
            )
        case .imageLink:
            return Self.linkEdit(
                in: nsString, selectedRange: selectedRange, isImage: true
            )
        case .code:
            return Self.inlinePairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "`", closing: "`"
            )
        case .codeBlock:
            return Self.pairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "```\n", closing: "\n```"
            )
        case .heading1:
            return Self.headingEdit(in: nsString, level: 1, selectedRange: selectedRange)
        case .heading2:
            return Self.headingEdit(in: nsString, level: 2, selectedRange: selectedRange)
        case .heading3:
            return Self.headingEdit(in: nsString, level: 3, selectedRange: selectedRange)
        case .heading4:
            return Self.headingEdit(in: nsString, level: 4, selectedRange: selectedRange)
        case .heading5:
            return Self.headingEdit(in: nsString, level: 5, selectedRange: selectedRange)
        case .heading6:
            return Self.headingEdit(in: nsString, level: 6, selectedRange: selectedRange)
        }
    }

    private static func headingEdit(
        in nsString: NSString,
        level: Int,
        selectedRange: NSRange
    ) -> MarkdownMarkupEdit {
        let lineRange = nsString.lineRange(for: selectedRange)
        let lineParts = markupLineParts(
            in: nsString.substring(with: lineRange) as NSString
        )
        let marker = String(repeating: "#", count: level) + " "
        let headings = lineParts.map { headingParts(of: $0.content) }
        let contentLines = zip(lineParts, headings).filter { !$0.0.content.isEmpty }
        // Pressing the shortcut of the level every content line already has
        // toggles the heading off; any other state (re)applies that level.
        let removesMarker = !contentLines.isEmpty
            && contentLines.allSatisfy { $0.1?.level == level }

        var replacement = ""
        var firstLineOldPrefixLength = 0
        var firstLineNewPrefixLength = 0
        for (index, (part, heading)) in zip(lineParts, headings).enumerated() {
            let rest = heading?.rest ?? part.content
            let keepsBlankLine = part.content.isEmpty && lineParts.count > 1
            if keepsBlankLine {
                replacement += part.original
            } else if removesMarker {
                replacement += part.leading + rest + part.trailing + part.newline
            } else {
                replacement += part.leading + marker + rest + part.trailing
                    + part.newline
            }

            if index == 0 {
                let oldMarkerLength = part.content.utf16.count - rest.utf16.count
                let newMarkerLength = removesMarker || keepsBlankLine
                    ? 0
                    : marker.utf16.count
                firstLineOldPrefixLength = part.leading.utf16.count + oldMarkerLength
                firstLineNewPrefixLength = part.leading.utf16.count + newMarkerLength
            }
        }

        guard selectedRange.length > 0 else {
            let offsetInLine = selectedRange.location - lineRange.location
            let newOffset = offsetInLine <= firstLineOldPrefixLength
                ? firstLineNewPrefixLength
                : offsetInLine - firstLineOldPrefixLength + firstLineNewPrefixLength
            return MarkdownMarkupEdit(
                replacementRange: lineRange,
                replacementString: replacement,
                selectedRange: NSRange(
                    location: lineRange.location + newOffset,
                    length: 0
                )
            )
        }

        return MarkdownMarkupEdit(
            replacementRange: lineRange,
            replacementString: replacement,
            selectedRange: NSRange(
                location: lineRange.location,
                length: replacement.utf16.count
            )
        )
    }

    private static func headingParts(
        of content: String
    ) -> (level: Int, rest: String)? {
        let nsContent = content as NSString
        var hashCount = 0
        while hashCount < nsContent.length,
              nsContent.character(at: hashCount) == 0x23 // '#'
        {
            hashCount += 1
        }
        guard (1 ... 6).contains(hashCount) else {
            return nil
        }

        if hashCount == nsContent.length {
            return (hashCount, "")
        }

        var restStart = hashCount
        while restStart < nsContent.length,
              isHorizontalWhitespace(nsContent, at: restStart)
        {
            restStart += 1
        }
        guard restStart > hashCount else {
            return nil
        }

        return (hashCount, nsContent.substring(from: restStart))
    }

    private static func pairEdit(
        in nsString: NSString,
        selectedRange: NSRange,
        opening: String,
        closing: String
    ) -> MarkdownMarkupEdit {
        let target = targetRange(in: nsString, selectedRange: selectedRange)
        return pairEdit(for: target, in: nsString, opening: opening, closing: closing)
    }

    private static func inlinePairEdit(
        in nsString: NSString,
        selectedRange: NSRange,
        opening: String,
        closing: String
    ) -> MarkdownMarkupEdit {
        let target = targetRange(in: nsString, selectedRange: selectedRange)
        guard target.isExplicitSelection else {
            return pairEdit(for: target, in: nsString, opening: opening, closing: closing)
        }

        if nsString.substring(with: target.range).contains("\n") {
            return multilinePairEdit(
                in: nsString, range: target.range, opening: opening, closing: closing
            )
        }

        return singleLinePairEdit(
            in: nsString, range: target.range, opening: opening, closing: closing
        )
    }

    private static func pairEdit(
        for target: MarkupTarget,
        in nsString: NSString,
        opening: String,
        closing: String
    ) -> MarkdownMarkupEdit {
        let openingLength = (opening as NSString).length
        let closingLength = (closing as NSString).length

        if target.range.length == 0 {
            if hasWrappedRange(
                target.range, in: nsString, opening: opening, closing: closing
            ) {
                return MarkdownMarkupEdit(
                    replacementRange: NSRange(
                        location: target.range.location - openingLength,
                        length: openingLength + closingLength
                    ),
                    replacementString: "",
                    selectedRange: NSRange(
                        location: target.range.location - openingLength,
                        length: 0
                    )
                )
            }

            return MarkdownMarkupEdit(
                replacementRange: target.range,
                replacementString: opening + closing,
                selectedRange: NSRange(
                    location: target.range.location + openingLength,
                    length: 0
                )
            )
        }

        let selectedText = nsString.substring(with: target.range)
        if hasWrappedRange(
            target.range, in: nsString, opening: opening, closing: closing
        ) {
            let replacementRange = NSRange(
                location: target.range.location - openingLength,
                length: openingLength + target.range.length + closingLength
            )
            let collapsedLocation = target.cursorLocation
                .map { $0 - openingLength }
                ?? replacementRange.location + selectedText.utf16.count
            return MarkdownMarkupEdit(
                replacementRange: replacementRange,
                replacementString: selectedText,
                selectedRange: NSRange(
                    location: target.isExplicitSelection
                        ? replacementRange.location
                        : collapsedLocation,
                    length: target.isExplicitSelection ? selectedText.utf16.count : 0
                )
            )
        }

        let wrappedCollapsedLocation = target.cursorLocation
            .map { $0 + openingLength }
            ?? target.range.location + openingLength + selectedText.utf16.count
        return MarkdownMarkupEdit(
            replacementRange: target.range,
            replacementString: opening + selectedText + closing,
            selectedRange: NSRange(
                location: target.isExplicitSelection
                    ? target.range.location + openingLength
                    : wrappedCollapsedLocation,
                length: target.isExplicitSelection ? selectedText.utf16.count : 0
            )
        )
    }

    private static func singleLinePairEdit(
        in nsString: NSString,
        range: NSRange,
        opening: String,
        closing: String
    ) -> MarkdownMarkupEdit {
        let contentRange = horizontallyTrimmedRange(in: nsString, range: range)
        guard contentRange.length > 0 else {
            return pairEdit(
                for: MarkupTarget(
                    range: NSRange(location: range.location, length: 0),
                    isExplicitSelection: false
                ),
                in: nsString, opening: opening, closing: closing
            )
        }

        let openingLength = (opening as NSString).length
        if hasWrappedRange(
            contentRange,
            in: nsString,
            opening: opening,
            closing: closing
        ) {
            let content = nsString.substring(with: contentRange)
            let replacementRange = NSRange(
                location: contentRange.location - openingLength,
                length: openingLength + contentRange.length + (closing as NSString).length
            )
            return MarkdownMarkupEdit(
                replacementRange: replacementRange,
                replacementString: content,
                selectedRange: NSRange(
                    location: replacementRange.location,
                    length: content.utf16.count
                )
            )
        }

        let (leadingText, content, trailingText) = trimmedSelectionParts(
            in: nsString, range: range, contentRange: contentRange
        )

        if hasInternalPair(content, opening: opening, closing: closing) {
            let unwrappedContent = (content as NSString).substring(with: NSRange(
                location: openingLength,
                length: (content as NSString)
                    .length - openingLength - (closing as NSString).length
            ))
            let replacement = leadingText + unwrappedContent + trailingText
            return MarkdownMarkupEdit(
                replacementRange: range,
                replacementString: replacement,
                selectedRange: NSRange(
                    location: range.location + leadingText.utf16.count,
                    length: unwrappedContent.utf16.count
                )
            )
        }

        let replacement = leadingText + opening + content + closing + trailingText
        return MarkdownMarkupEdit(
            replacementRange: range,
            replacementString: replacement,
            selectedRange: NSRange(
                location: range.location + leadingText.utf16.count + openingLength,
                length: content.utf16.count
            )
        )
    }

    private static func multilinePairEdit(
        in nsString: NSString,
        range: NSRange,
        opening: String,
        closing: String
    ) -> MarkdownMarkupEdit {
        guard let (replacement, _) = multilineReplacement(
            in: nsString, range: range,
            lineUnwraps: { hasInternalPair($0, opening: opening, closing: closing) },
            transform: { content, unwraps in
                guard unwraps else {
                    return (opening + content + closing, nil)
                }

                let nsContent = content as NSString
                return (nsContent.substring(with: NSRange(
                    location: (opening as NSString).length,
                    length: nsContent.length - (opening as NSString)
                        .length - (closing as NSString).length
                )), nil)
            }
        ) else {
            return pairEdit(
                for: MarkupTarget(
                    range: NSRange(location: range.location, length: 0),
                    isExplicitSelection: false
                ),
                in: nsString, opening: opening, closing: closing
            )
        }

        return MarkdownMarkupEdit(
            replacementRange: range,
            replacementString: replacement,
            selectedRange: NSRange(
                location: range.location,
                length: replacement.utf16.count
            )
        )
    }

    private static func linkEdit(
        in nsString: NSString,
        selectedRange: NSRange,
        isImage: Bool
    ) -> MarkdownMarkupEdit {
        let target = targetRange(in: nsString, selectedRange: selectedRange)
        let prefix = isImage ? "![" : "["
        let prefixLength = (prefix as NSString).length

        if let existingLink = linkAroundTarget(
            target, in: nsString, isImage: isImage
        ) {
            let label = nsString.substring(with: existingLink.labelRange)
            return MarkdownMarkupEdit(
                replacementRange: existingLink.fullRange,
                replacementString: label,
                selectedRange: NSRange(
                    location: target.isExplicitSelection
                        ? existingLink.fullRange.location
                        : existingLink.fullRange.location + label.utf16.count,
                    length: target.isExplicitSelection ? label.utf16.count : 0
                )
            )
        }

        if target.isExplicitSelection {
            if nsString.substring(with: target.range).contains("\n") {
                return multilineLinkEdit(
                    in: nsString, range: target.range, isImage: isImage
                )
            }

            return singleLineLinkEdit(
                in: nsString, range: target.range, isImage: isImage
            )
        }

        if target.range.length == 0 {
            return MarkdownMarkupEdit(
                replacementRange: target.range,
                replacementString: prefix + "]()",
                selectedRange: NSRange(
                    location: target.range.location + prefixLength,
                    length: 0
                )
            )
        }

        let label = escapeLinkLabel(nsString.substring(with: target.range))
        return MarkdownMarkupEdit(
            replacementRange: target.range,
            replacementString: prefix + label + "]()",
            selectedRange: NSRange(
                location: target.range.location + prefixLength + label.utf16.count + 2,
                length: 0
            )
        )
    }

    private static func singleLineLinkEdit(
        in nsString: NSString,
        range: NSRange,
        isImage: Bool
    ) -> MarkdownMarkupEdit {
        let contentRange = horizontallyTrimmedRange(in: nsString, range: range)
        guard contentRange.length > 0 else {
            return linkEdit(
                in: nsString,
                selectedRange: NSRange(location: range.location, length: 0),
                isImage: isImage
            )
        }

        let (leadingText, content, trailingText) = trimmedSelectionParts(
            in: nsString, range: range, contentRange: contentRange
        )
        if let link = internalLink(in: content, isImage: isImage) {
            let label = (content as NSString).substring(with: link.labelRange)
            let replacement = leadingText + label + trailingText
            return MarkdownMarkupEdit(
                replacementRange: range,
                replacementString: replacement,
                selectedRange: NSRange(
                    location: range.location + leadingText.utf16.count,
                    length: label.utf16.count
                )
            )
        }

        let prefix = isImage ? "![" : "["
        let label = escapeLinkLabel(content)
        let replacement = leadingText + prefix + label + "]()" + trailingText
        return MarkdownMarkupEdit(
            replacementRange: range,
            replacementString: replacement,
            selectedRange: NSRange(
                location: range.location + leadingText.utf16.count + prefix.utf16
                    .count + label.utf16.count + 2,
                length: 0
            )
        )
    }

    private static func multilineLinkEdit(
        in nsString: NSString,
        range: NSRange,
        isImage: Bool
    ) -> MarkdownMarkupEdit {
        let prefix = isImage ? "![" : "["
        guard let (replacement, firstURLLocation) = multilineReplacement(
            in: nsString, range: range,
            lineUnwraps: { internalLink(in: $0, isImage: isImage) != nil },
            transform: { content, unwraps in
                if unwraps, let link = internalLink(in: content, isImage: isImage) {
                    return ((content as NSString).substring(with: link.labelRange), nil)
                }

                let body = prefix + escapeLinkLabel(content) + "]()"
                // The cursor lands between the URL parentheses.
                return (body, body.utf16.count - 1)
            }
        ) else {
            return linkEdit(
                in: nsString,
                selectedRange: NSRange(location: range.location, length: 0),
                isImage: isImage
            )
        }

        return MarkdownMarkupEdit(
            replacementRange: range,
            replacementString: replacement,
            selectedRange: NSRange(
                location: firstURLLocation ?? range.location,
                length: 0
            )
        )
    }

    /// Shared skeleton of the multiline pair and link edits: walks the
    /// selected lines, keeps blank lines untouched, and rebuilds every other
    /// line via `transform`. All non-empty lines unwrap together or wrap
    /// together, decided by `lineUnwraps`. The transform may report a cursor
    /// offset within the produced body; the first reported offset comes back
    /// as an absolute location. Returns nil when every line is blank.
    private static func multilineReplacement(
        in nsString: NSString,
        range: NSRange,
        lineUnwraps: (String) -> Bool,
        transform: (_ content: String, _ unwraps: Bool)
            -> (body: String, cursorOffset: Int?)
    ) -> (replacement: String, cursorLocation: Int?)? {
        let selectedNSString = nsString.substring(with: range) as NSString
        let lineParts = markupLineParts(in: selectedNSString)
        let nonEmptyLineParts = lineParts.filter { !$0.content.isEmpty }
        guard !nonEmptyLineParts.isEmpty else {
            return nil
        }

        let unwraps = nonEmptyLineParts.allSatisfy { lineUnwraps($0.content) }
        var replacement = ""
        var cursorLocation: Int?
        for linePart in lineParts {
            if linePart.content.isEmpty {
                replacement += linePart.original
                continue
            }

            let (body, cursorOffset) = transform(linePart.content, unwraps)
            replacement += linePart.leading
            if cursorLocation == nil, let cursorOffset {
                cursorLocation = range.location + replacement.utf16.count
                    + cursorOffset
            }
            replacement += body + linePart.trailing + linePart.newline
        }

        return (replacement, cursorLocation)
    }

    private static func targetRange(
        in nsString: NSString, selectedRange: NSRange
    ) -> MarkupTarget {
        if selectedRange.length > 0 {
            return MarkupTarget(range: selectedRange, isExplicitSelection: true)
        }

        guard selectedRange.location > 0,
              isLetter(in: nsString, at: selectedRange.location - 1)
        else {
            return MarkupTarget(range: selectedRange, isExplicitSelection: false)
        }

        var location = selectedRange.location - 1
        while location > 0, isLetter(in: nsString, at: location - 1) {
            location -= 1
        }

        var endLocation = selectedRange.location
        while endLocation < nsString.length, isLetter(in: nsString, at: endLocation) {
            endLocation += 1
        }

        return MarkupTarget(
            range: NSRange(
                location: location,
                length: endLocation - location
            ),
            isExplicitSelection: false,
            cursorLocation: selectedRange.location
        )
    }

    private static func isLetter(in nsString: NSString, at location: Int) -> Bool {
        // A lone surrogate half is not a letter by itself.
        guard let scalar = UnicodeScalar(nsString.character(at: location)) else {
            return false
        }
        return CharacterSet.letters.contains(scalar)
    }

    /// Splits the selected range into the text before, inside, and after the
    /// whitespace-trimmed content range.
    private static func trimmedSelectionParts(
        in nsString: NSString,
        range: NSRange,
        contentRange: NSRange
    ) -> (leading: String, content: String, trailing: String) {
        let selectedNSString = nsString.substring(with: range) as NSString
        let relativeContentRange = NSRange(
            location: contentRange.location - range.location,
            length: contentRange.length
        )
        return (
            leading: selectedNSString.substring(
                with: NSRange(location: 0, length: relativeContentRange.location)
            ),
            content: selectedNSString.substring(with: relativeContentRange),
            trailing: selectedNSString.substring(
                from: NSMaxRange(relativeContentRange)
            )
        )
    }

    private static func horizontallyTrimmedRange(
        in nsString: NSString, range: NSRange
    ) -> NSRange {
        var location = range.location
        var endLocation = NSMaxRange(range)
        while location < endLocation, isHorizontalWhitespace(nsString, at: location) {
            location += 1
        }

        while endLocation > location,
              isHorizontalWhitespace(nsString, at: endLocation - 1)
        {
            endLocation -= 1
        }

        return NSRange(location: location, length: endLocation - location)
    }

    private static func hasWrappedRange(
        _ range: NSRange,
        in nsString: NSString,
        opening: String,
        closing: String
    ) -> Bool {
        let openingLength = (opening as NSString).length
        let closingLength = (closing as NSString).length
        guard range.location >= openingLength,
              NSMaxRange(range) + closingLength <= nsString.length
        else {
            return false
        }

        let openingRange = NSRange(
            location: range.location - openingLength, length: openingLength
        )
        let closingRange = NSRange(
            location: NSMaxRange(range), length: closingLength
        )
        guard nsString.substring(with: openingRange) == opening,
              nsString.substring(with: closingRange) == closing
        else {
            return false
        }

        return isExactDelimiterRun(
            in: nsString, openingRange: openingRange,
            closingRange: closingRange, delimiter: opening
        )
    }

    private static func isExactDelimiterRun(
        in nsString: NSString,
        openingRange: NSRange,
        closingRange: NSRange,
        delimiter: String
    ) -> Bool {
        guard delimiter.utf16.count == 1 else {
            return true
        }

        if openingRange.location > 0,
           nsString.substring(with: NSRange(
               location: openingRange.location - 1, length: 1
           )) == delimiter
        {
            return false
        }

        if NSMaxRange(closingRange) < nsString.length,
           nsString.substring(with: NSRange(
               location: NSMaxRange(closingRange), length: 1
           )) == delimiter
        {
            return false
        }

        return true
    }

    private static func hasInternalPair(
        _ string: String, opening: String, closing: String
    ) -> Bool {
        let nsString = string as NSString
        let openingLength = (opening as NSString).length
        let closingLength = (closing as NSString).length
        guard nsString.length >= openingLength + closingLength,
              nsString
              .substring(with: NSRange(location: 0, length: openingLength)) == opening,
              nsString.substring(with: NSRange(
                  location: nsString.length - closingLength,
                  length: closingLength
              )) == closing
        else {
            return false
        }

        let openingRange = NSRange(location: 0, length: openingLength)
        let closingRange = NSRange(
            location: nsString.length - closingLength,
            length: closingLength
        )
        return isExactDelimiterRun(
            in: nsString, openingRange: openingRange,
            closingRange: closingRange, delimiter: opening
        )
    }

    private static func linkAroundTarget(
        _ target: MarkupTarget,
        in nsString: NSString,
        isImage: Bool
    ) -> ExistingLink? {
        if target.range.length > 0,
           let link = linkWithLabelRange(target.range, in: nsString, isImage: isImage)
        {
            return link
        }

        if !target.isExplicitSelection,
           let link = enclosingLink(
               at: target.range.location, in: nsString, isImage: isImage
           )
        {
            return link
        }

        return nil
    }

    private static func linkWithLabelRange(
        _ labelRange: NSRange,
        in nsString: NSString,
        isImage: Bool
    ) -> ExistingLink? {
        let prefix = isImage ? "![" : "["
        let prefixLength = (prefix as NSString).length
        guard labelRange.location >= prefixLength else {
            return nil
        }

        let prefixLocation = labelRange.location - prefixLength
        if !isImage, prefixLocation > 0,
           nsString.substring(with: NSRange(
               location: prefixLocation - 1, length: 1
           )) == "!"
        {
            return nil
        }

        guard nsString.substring(with: NSRange(
            location: prefixLocation, length: prefixLength
        )) == prefix,
            NSMaxRange(labelRange) + 2 <= nsString.length,
            nsString.substring(with: NSRange(
                location: NSMaxRange(labelRange), length: 2
            )) == "]("
        else {
            return nil
        }

        let urlStart = NSMaxRange(labelRange) + 2
        guard let closingLocation = closingParenLocation(
            in: nsString, startingAt: urlStart, upTo: nsString.length
        ) else {
            return nil
        }

        return ExistingLink(
            fullRange: NSRange(
                location: prefixLocation,
                length: closingLocation - prefixLocation + 1
            ),
            labelRange: labelRange
        )
    }

    private static func enclosingLink(
        at location: Int,
        in nsString: NSString,
        isImage: Bool
    ) -> ExistingLink? {
        let prefix = isImage ? "![" : "["
        // Markdown links never span lines, so the scan stays within the
        // caret's line; an unbounded scan made every "[ ]" checkbox above
        // the caret a candidate for a link ending on a later line.
        let lineRange = nsString.lineRange(
            for: NSRange(location: min(location, nsString.length), length: 0)
        )
        let lineEnd = NSMaxRange(lineRange)
        var searchLength = min(location, nsString.length)
        while searchLength - lineRange.location >= prefix.utf16.count {
            let prefixRange = nsString.range(
                of: prefix,
                options: .backwards,
                range: NSRange(
                    location: lineRange.location,
                    length: searchLength - lineRange.location
                )
            )
            guard prefixRange.location != NSNotFound else {
                return nil
            }

            if !isImage, prefixRange.location > 0,
               nsString.substring(with: NSRange(
                   location: prefixRange.location - 1, length: 1
               )) == "!"
            {
                searchLength = prefixRange.location
                continue
            }

            if let link = linkStarting(
                at: prefixRange.location, in: nsString, isImage: isImage,
                upTo: lineEnd
            ),
                location >= link.labelRange.location,
                location <= NSMaxRange(link.fullRange)
            {
                return link
            }

            searchLength = prefixRange.location
        }

        return nil
    }

    private static func linkStarting(
        at prefixLocation: Int,
        in nsString: NSString,
        isImage: Bool,
        upTo limit: Int
    ) -> ExistingLink? {
        let prefixLength = isImage ? 2 : 1
        let labelStart = prefixLocation + prefixLength
        guard labelStart <= limit else {
            return nil
        }

        let separatorRange = nsString.range(
            of: "](",
            range: NSRange(
                location: labelStart,
                length: limit - labelStart
            )
        )
        guard separatorRange.location != NSNotFound else {
            return nil
        }

        let urlStart = NSMaxRange(separatorRange)
        guard let closingLocation = closingParenLocation(
            in: nsString, startingAt: urlStart, upTo: limit
        ) else {
            return nil
        }

        return ExistingLink(
            fullRange: NSRange(
                location: prefixLocation,
                length: closingLocation - prefixLocation + 1
            ),
            labelRange: NSRange(
                location: labelStart,
                length: separatorRange.location - labelStart
            )
        )
    }

    private static func internalLink(in string: String, isImage: Bool) -> ExistingLink? {
        let nsString = string as NSString
        guard let link = linkStarting(
            at: 0, in: nsString, isImage: isImage, upTo: nsString.length
        ),
            link.fullRange.length == nsString.length
        else {
            return nil
        }

        return link
    }

    private static func closingParenLocation(
        in nsString: NSString, startingAt urlStart: Int, upTo limit: Int
    ) -> Int? {
        let range = nsString.range(
            of: ")",
            range: NSRange(location: urlStart, length: limit - urlStart)
        )
        guard range.location != NSNotFound else {
            return nil
        }

        return range.location
    }

    private static func escapeLinkLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "]", with: "\\]")
    }
}

private struct MarkupLinePart {
    let original: String
    let leading: String
    let content: String
    let trailing: String
    let newline: String
}

private func markupLineParts(in nsString: NSString) -> [MarkupLinePart] {
    var lineParts: [MarkupLinePart] = []
    var location = 0
    repeat {
        let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
        let boundedLineRange = NSRange(
            location: lineRange.location,
            length: min(NSMaxRange(lineRange), nsString.length) - lineRange.location
        )
        let line = nsString.substring(with: boundedLineRange)
        lineParts.append(markupLinePart(from: line))
        location = NSMaxRange(boundedLineRange)
    } while location < nsString.length

    return lineParts
}

private func markupLinePart(from line: String) -> MarkupLinePart {
    let nsLine = line as NSString
    let newlineLength: Int
    if line.hasSuffix("\r\n") {
        newlineLength = 2
    } else if line.hasSuffix("\n") || line.hasSuffix("\r") {
        newlineLength = 1
    } else {
        newlineLength = 0
    }

    let bodyRange = NSRange(location: 0, length: nsLine.length - newlineLength)
    let body = nsLine.substring(with: bodyRange)
    let newline = newlineLength > 0
        ? nsLine.substring(with: NSRange(
            location: bodyRange.length,
            length: newlineLength
        ))
        : ""
    let bodyNSString = body as NSString
    var contentStart = 0
    var contentEnd = bodyNSString.length
    while contentStart < contentEnd, isHorizontalWhitespace(
        bodyNSString,
        at: contentStart
    ) {
        contentStart += 1
    }

    while contentEnd > contentStart,
          isHorizontalWhitespace(bodyNSString, at: contentEnd - 1)
    {
        contentEnd -= 1
    }

    return MarkupLinePart(
        original: line,
        leading: bodyNSString.substring(with: NSRange(location: 0, length: contentStart)),
        content: bodyNSString.substring(with: NSRange(
            location: contentStart,
            length: contentEnd - contentStart
        )),
        trailing: bodyNSString.substring(with: NSRange(
            location: contentEnd,
            length: bodyNSString.length - contentEnd
        )),
        newline: newline
    )
}

private func isHorizontalWhitespace(_ nsString: NSString, at location: Int) -> Bool {
    let character = nsString.character(at: location)
    return character == 0x20 || character == 0x09 // ' ' or '\t'
}

private struct MarkupTarget {
    let range: NSRange
    let isExplicitSelection: Bool
    var cursorLocation: Int?
}

private struct ExistingLink {
    let fullRange: NSRange
    let labelRange: NSRange
}
