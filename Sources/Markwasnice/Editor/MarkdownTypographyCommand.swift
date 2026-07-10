import Foundation
import Typograf

struct MarkdownTypographyReplacement: Equatable {
    let range: NSRange
    let replacement: String
}

enum MarkdownTypographyCommand {
    /// Typography replacements for the selection, or for the whole text when
    /// there is no selection. Code spans are left untouched — unless the
    /// selection lies entirely inside one, in which case the user explicitly
    /// asked for that fragment and it is processed as-is.
    static func replacements(
        in text: String,
        selectedRange: NSRange,
        locale: EditorSettings.TypographyLocale
    ) -> [MarkdownTypographyReplacement] {
        let nsString = text as NSString
        guard nsString.length > 0,
              selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.length >= 0,
              NSMaxRange(selectedRange) <= nsString.length
        else {
            return []
        }

        let hasSelection = selectedRange.length > 0
        let targetRange = hasSelection
            ? selectedRange
            : NSRange(location: 0, length: nsString.length)

        let parsedRanges = parsedProtectedRanges(in: text)
        let segments: [NSRange]
        if hasSelection,
           parsedRanges.code.contains(where: { contains($0, selectedRange) })
        {
            segments = [targetRange]
        } else {
            let protected = (parsedRanges.code + parsedRanges.structure
                + markerPrefixRanges(in: nsString))
                .sorted { $0.location < $1.location }
            segments = subtracting(protected, from: targetRange)
        }

        let typograf = Typograf(configuration: configuration(for: locale))
        var replacements: [MarkdownTypographyReplacement] = []
        for segment in segments {
            let original = nsString.substring(with: segment)
            let processed = typograf.process(original)
            guard processed != original else {
                continue
            }

            replacements.append(MarkdownTypographyReplacement(
                range: segment,
                replacement: processed
            ))
        }
        return replacements
    }

    /// Where the original selection lands after the replacements are applied.
    static func adjustedSelection(
        _ selectedRange: NSRange,
        after replacements: [MarkdownTypographyReplacement]
    ) -> NSRange {
        guard selectedRange.length > 0 else {
            return NSRange(
                location: adjustedCaretLocation(
                    selectedRange.location,
                    after: replacements
                ),
                length: 0
            )
        }

        // Every replaced segment lies within the selection, so its start is
        // stable and only the length absorbs the total delta.
        let totalDelta = replacements.reduce(0) {
            $0 + ($1.replacement as NSString).length - $1.range.length
        }
        return NSRange(
            location: selectedRange.location,
            length: max(0, selectedRange.length + totalDelta)
        )
    }

    private static func adjustedCaretLocation(
        _ location: Int,
        after replacements: [MarkdownTypographyReplacement]
    ) -> Int {
        var shift = 0
        for replacement in replacements {
            let newLength = (replacement.replacement as NSString).length
            if NSMaxRange(replacement.range) <= location {
                shift += newLength - replacement.range.length
            } else if location > replacement.range.location {
                // The caret sits inside a rewritten segment; keep it inside.
                let offset = min(location - replacement.range.location, newLength)
                return replacement.range.location + shift + offset
            } else {
                break
            }
        }
        return location + shift
    }

    private static func configuration(
        for locale: EditorSettings.TypographyLocale
    ) -> TypografConfiguration {
        var configuration = TypografConfiguration(
            locale: locale == .russian ? .russian : .englishUS
        )
        configuration.disabledRules.formUnion([
            // Markdown gives structural meaning to whitespace: tabs and
            // leading spaces nest lists, two trailing spaces are a hard line
            // break, and blank-line runs separate blocks.
            RuleID(.commonSpaceReplaceTab),
            RuleID(.commonSpaceTrimLeft),
            RuleID(.commonSpaceTrimRight),
            RuleID(.commonSpaceDelTrailingBlanks),
            RuleID(.commonSpaceDelRepeatN),
            RuleID(.commonSpaceDelRepeatSpace),
            // "- item" at line start is a list marker, not direct speech;
            // mid-sentence dashes are still handled by ru/dash/main.
            RuleID(.russianDashDirectSpeech),
        ])
        return configuration
    }

    private static func parsedProtectedRanges(
        in text: String
    ) -> (code: [NSRange], structure: [NSRange]) {
        guard let result = MarkdownParseService.parse(
            text: text,
            version: 0,
            previous: nil
        ) else {
            return ([], [])
        }

        var code: [NSRange] = []
        var structure: [NSRange] = []
        for span in result.spans {
            switch span.kind {
            case .codeBlock, .inlineCode:
                code.append(span.range)
            case .thematicBreak:
                structure.append(span.range)
            default:
                break
            }
        }
        return (code.sorted { $0.location < $1.location }, structure)
    }

    /// Blockquote and list markers at the start of a line, including the
    /// indentation. Without this, the space-surrounded-dash rule reads an
    /// indented "- " marker as a dash between words and turns it into "—".
    private static let markerPrefixRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]*)*(?:(?:[-+*]|\d+[.)])[ \t]+)?"#,
        options: [.anchorsMatchLines]
    )

    private static func markerPrefixRanges(in nsString: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        markerPrefixRegex.enumerateMatches(
            in: nsString as String,
            range: NSRange(location: 0, length: nsString.length)
        ) { match, _, _ in
            if let range = match?.range, range.length > 0 {
                ranges.append(range)
            }
        }
        return ranges
    }

    private static func contains(_ range: NSRange, _ other: NSRange) -> Bool {
        other.location >= range.location && NSMaxRange(other) <= NSMaxRange(range)
    }

    private static func subtracting(
        _ excludedRanges: [NSRange],
        from range: NSRange
    ) -> [NSRange] {
        var segments = [range]
        for excludedRange in excludedRanges {
            segments = segments.flatMap { subtract(excludedRange, from: $0) }
        }
        return segments.filter { $0.length > 0 }
    }

    private static func subtract(
        _ excludedRange: NSRange,
        from range: NSRange
    ) -> [NSRange] {
        let intersection = NSIntersectionRange(range, excludedRange)
        guard intersection.length > 0 else {
            return [range]
        }

        var result: [NSRange] = []
        if intersection.location > range.location {
            result.append(NSRange(
                location: range.location,
                length: intersection.location - range.location
            ))
        }

        let excludedUpperBound = NSMaxRange(intersection)
        let rangeUpperBound = NSMaxRange(range)
        if excludedUpperBound < rangeUpperBound {
            result.append(NSRange(
                location: excludedUpperBound,
                length: rangeUpperBound - excludedUpperBound
            ))
        }

        return result
    }
}
