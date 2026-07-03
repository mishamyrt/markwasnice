import Foundation

/// Derives a display title and a suggested file name for unsaved documents
/// from the first meaningful line of markdown text.
enum DocumentTitleSuggester {
    static let maxTitleLength = 60

    static func title(from text: String) -> String? {
        var title: String?
        text.enumerateLines { line, stop in
            guard let candidate = titleCandidate(from: line) else {
                return
            }

            title = candidate
            stop = true
        }
        return title
    }

    static func fileName(from text: String) -> String? {
        guard let title = title(from: text) else {
            return nil
        }

        let sanitized = String(title.map { character in
            character == "/" || character == ":" ? "-" : character
        }).trimmingCharacters(in: .whitespaces)

        guard !sanitized.isEmpty else {
            return nil
        }

        return sanitized + ".md"
    }

    private static func titleCandidate(from line: String) -> String? {
        let unprefixed = strippingBlockPrefixes(from: Substring(line))
        let stripped = strippingInlineMarkup(from: String(unprefixed))
            .trimmingCharacters(in: .whitespaces)

        guard !stripped.isEmpty else {
            return nil
        }

        // Horizontal rules and setext underlines are markup, not content.
        guard !stripped.allSatisfy({ "-=_ ".contains($0) }) else {
            return nil
        }

        guard stripped.count > maxTitleLength else {
            return stripped
        }

        let truncated = stripped
            .prefix(maxTitleLength)
            .trimmingCharacters(in: .whitespaces)
        return truncated + "…"
    }

    private static func strippingBlockPrefixes(
        from line: Substring
    ) -> Substring {
        var rest = line.drop(while: \.isWhitespace)
        while true {
            let before = rest

            if rest.first == ">" {
                rest = rest.dropFirst().drop(while: \.isWhitespace)
            }

            let hashes = rest.prefix { $0 == "#" }
            if (1 ... 6).contains(hashes.count) {
                let after = rest.dropFirst(hashes.count)
                if after.isEmpty || after.first == " " {
                    rest = after.drop { $0 == " " }
                }
            }

            if let bullet = rest.first, "-*+".contains(bullet),
               rest.dropFirst().first == " "
            {
                rest = rest.dropFirst().drop { $0 == " " }
            }

            let digits = rest.prefix(while: \.isNumber)
            if !digits.isEmpty, digits.count <= 9 {
                let after = rest.dropFirst(digits.count)
                if let separator = after.first, ".)".contains(separator),
                   after.dropFirst().first == " "
                {
                    rest = after.dropFirst().drop { $0 == " " }
                }
            }

            for checkbox in ["[ ] ", "[x] ", "[X] "] where rest.hasPrefix(checkbox) {
                rest = rest.dropFirst(checkbox.count).drop { $0 == " " }
            }

            if rest == before {
                return rest
            }
        }
    }

    private static func strippingInlineMarkup(from text: String) -> String {
        var result = text
        result = result.replacing(/!\[([^\]]*)\]\([^)]*\)/) { match in
            String(match.output.1)
        }
        result = result.replacing(/\[([^\]]*)\]\([^)]*\)/) { match in
            String(match.output.1)
        }
        result = result.replacing(/\s+#+\s*$/, with: "")
        result = result.replacingOccurrences(of: "~~", with: "")
        result = result.replacingOccurrences(of: "==", with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        // Strip emphasis underscores at word edges while keeping snake_case.
        result = result
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { word in
                word.drop { $0 == "_" }
                    .reversed()
                    .drop { $0 == "_" }
                    .reversed()
            }
            .map(String.init)
            .joined(separator: " ")
        return result
    }
}
