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
            return Self.pairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "**", closing: "**"
            )
        case .italic:
            return Self.pairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "*", closing: "*"
            )
        case .strikethrough:
            return Self.pairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "~~", closing: "~~"
            )
        case .highlight:
            return Self.pairEdit(
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
            return Self.pairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "`", closing: "`"
            )
        case .codeBlock:
            return Self.pairEdit(
                in: nsString, selectedRange: selectedRange,
                opening: "```\n", closing: "\n```"
            )
        }
    }

    private static func pairEdit(
        in nsString: NSString,
        selectedRange: NSRange,
        opening: String,
        closing: String
    ) -> MarkdownMarkupEdit {
        let target = targetRange(in: nsString, selectedRange: selectedRange)
        let openingLength = (opening as NSString).length
        let closingLength = (closing as NSString).length

        if target.range.length == 0 {
            if hasPairAroundCursor(
                in: nsString, location: target.range.location,
                opening: opening, closing: closing
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
            return MarkdownMarkupEdit(
                replacementRange: replacementRange,
                replacementString: selectedText,
                selectedRange: NSRange(
                    location: target.isExplicitSelection
                        ? replacementRange.location
                        : replacementRange.location + selectedText.utf16.count,
                    length: target.isExplicitSelection ? selectedText.utf16.count : 0
                )
            )
        }

        return MarkdownMarkupEdit(
            replacementRange: target.range,
            replacementString: opening + selectedText + closing,
            selectedRange: NSRange(
                location: target.isExplicitSelection
                    ? target.range.location + openingLength
                    : target.range.location + openingLength + selectedText.utf16.count,
                length: target.isExplicitSelection ? selectedText.utf16.count : 0
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

        return MarkupTarget(
            range: NSRange(
                location: location,
                length: selectedRange.location - location
            ),
            isExplicitSelection: false
        )
    }

    private static func isLetter(in nsString: NSString, at location: Int) -> Bool {
        nsString.substring(with: NSRange(location: location, length: 1))
            .rangeOfCharacter(from: .letters) != nil
    }

    private static func hasPairAroundCursor(
        in nsString: NSString,
        location: Int,
        opening: String,
        closing: String
    ) -> Bool {
        let openingLength = (opening as NSString).length
        let closingLength = (closing as NSString).length
        guard location >= openingLength,
              location + closingLength <= nsString.length
        else {
            return false
        }

        let openingRange = NSRange(
            location: location - openingLength, length: openingLength
        )
        let closingRange = NSRange(location: location, length: closingLength)
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
            in: nsString, startingAt: urlStart
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
        var searchLength = min(location, nsString.length)
        while searchLength >= prefix.utf16.count {
            let prefixRange = nsString.range(
                of: prefix,
                options: .backwards,
                range: NSRange(location: 0, length: searchLength)
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
                at: prefixRange.location, in: nsString, isImage: isImage
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
        isImage: Bool
    ) -> ExistingLink? {
        let prefixLength = isImage ? 2 : 1
        let labelStart = prefixLocation + prefixLength
        guard labelStart <= nsString.length else {
            return nil
        }

        let separatorRange = nsString.range(
            of: "](",
            range: NSRange(
                location: labelStart,
                length: nsString.length - labelStart
            )
        )
        guard separatorRange.location != NSNotFound else {
            return nil
        }

        let urlStart = NSMaxRange(separatorRange)
        guard let closingLocation = closingParenLocation(
            in: nsString, startingAt: urlStart
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

    private static func closingParenLocation(
        in nsString: NSString, startingAt urlStart: Int
    ) -> Int? {
        let range = nsString.range(
            of: ")",
            range: NSRange(location: urlStart, length: nsString.length - urlStart)
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

private struct MarkupTarget {
    let range: NSRange
    let isExplicitSelection: Bool
}

private struct ExistingLink {
    let fullRange: NSRange
    let labelRange: NSRange
}
