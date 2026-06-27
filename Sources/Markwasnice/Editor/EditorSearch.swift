import Foundation

enum EditorSearchMode: CaseIterable, Equatable {
    case contains
    case startsWith
    case fullWord

    var title: String {
        switch self {
        case .contains:
            "Contains"
        case .startsWith:
            "Starts With"
        case .fullWord:
            "Full Word"
        }
    }
}

struct EditorSearchOptions: Equatable {
    var ignoresCase = false
    var mode: EditorSearchMode = .contains
}

enum EditorSearchMatcher {
    static func matches(
        for query: String,
        in text: String,
        options: EditorSearchOptions
    ) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else {
            return []
        }

        let nsText = text as NSString
        let queryLength = (query as NSString).length
        guard queryLength > 0 else {
            return []
        }

        let findOptions: NSString.CompareOptions =
            options.ignoresCase
                ? [.caseInsensitive]
                : []
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: nsText.length)

        while searchRange.length > 0 {
            let range = nsText.range(
                of: query,
                options: findOptions,
                range: searchRange
            )
            guard range.location != NSNotFound else {
                break
            }

            if accepts(range: range, in: nsText, mode: options.mode) {
                result.append(range)
            }

            let nextLocation = max(range.location + range.length, range.location + 1)
            guard nextLocation <= nsText.length else {
                break
            }

            searchRange = NSRange(
                location: nextLocation,
                length: nsText.length - nextLocation
            )
        }

        return result
    }

    private static func accepts(
        range: NSRange,
        in text: NSString,
        mode: EditorSearchMode
    ) -> Bool {
        switch mode {
        case .contains:
            true
        case .startsWith:
            isWordStart(at: range.location, in: text)
        case .fullWord:
            isWordStart(at: range.location, in: text)
                && isWordEnd(at: range.location + range.length, in: text)
        }
    }

    private static func isWordStart(at location: Int, in text: NSString) -> Bool {
        location <= 0 || !isWordCharacter(before: location, in: text)
    }

    private static func isWordEnd(at location: Int, in text: NSString) -> Bool {
        location >= text.length || !isWordCharacter(at: location, in: text)
    }

    private static func isWordCharacter(before location: Int, in text: NSString) -> Bool {
        guard location > 0 else {
            return false
        }

        return isWordCharacter(at: location - 1, in: text)
    }

    private static func isWordCharacter(at location: Int, in text: NSString) -> Bool {
        guard location >= 0, location < text.length else {
            return false
        }

        let scalar = UnicodeScalar(text.character(at: location))
        return
            scalar
                .map { CharacterSet.alphanumerics.contains($0) || $0 == "_" } ?? false
    }
}
