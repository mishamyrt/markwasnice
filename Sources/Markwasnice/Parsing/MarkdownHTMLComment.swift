import Foundation

enum MarkdownHTMLComment {
    private static let expression = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?(?:-->|\z)"#
    )

    static func ranges(in source: String) -> [NSRange] {
        expression.matches(
            in: source,
            range: NSRange(location: 0, length: source.utf16.count)
        ).map(\.range)
    }

    static func removing(from html: String) -> String {
        expression.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: html.utf16.count),
            withTemplate: ""
        )
    }
}
