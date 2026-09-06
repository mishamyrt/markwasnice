import Foundation
import Markdown

/// Product-level Markdown semantics for rendered output. Styling keeps the
/// original source coordinates and uses the same frontmatter, shifted-region
/// and checkbox scanners without rewriting the user's text.
enum MarkdownDocument {
    static func parse(_ source: String) -> Document {
        let body: String
        if let frontmatter = MarkdownFrontmatter.range(in: source) {
            body = (source as NSString).substring(from: NSMaxRange(frontmatter))
        } else {
            body = source
        }
        return MarkdownShiftedContentReparser.document(parsing: body)
    }
}
