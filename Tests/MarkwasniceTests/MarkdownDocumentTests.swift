import AppKit
import Markdown
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownDocumentTests {
    @Test(arguments: [
        ("    # Heading", MarkdownStyleKind.heading, "Heading"),
        ("\t**Жирный🙂**", .strong, "Жирный🙂"),
        ("---\ntitle: Private\n---\nBody", .frontmatter, "Body"),
        ("[ ] todo\n[x] **done**", .taskCheckbox, "☐ todo\n☑ done"),
        ("    ```\n    # Code\n    ```", .codeBlock, "# Code"),
        ("```\n[x] **literal**\n```", .codeBlock, "[x] **literal**"),
    ])
    func stylingPreviewAndCopyAgree(
        source: String,
        kind: MarkdownStyleKind,
        expectedText: String
    ) throws {
        let parse = try #require(MarkdownParseService.parse(
            text: source,
            version: 1,
            previous: nil
        ))
        #expect(parse.spans.contains { $0.kind == kind })
        #expect(MarkdownCopyFormat.plainText.convert(source) == expectedText)

        let rendered = MarkdownPreviewRenderer(theme: .init(
            baseFontSize: 20,
            colors: EditorThemeColors.default.light
        )).render(source)
        let expectedWords = expectedText.split(whereSeparator: \.isWhitespace)
        #expect(rendered.string.split(whereSeparator: \.isWhitespace) == expectedWords)
    }

    @Test
    func shiftingAListPreservesItsNestedStructure() throws {
        let document = MarkdownDocument.parse("    - first\n        - nested")
        let outer = try #require(document.child(at: 0) as? UnorderedList)
        let item = try #require(outer.child(at: 0) as? ListItem)
        let nested = try #require(item.child(at: 1) as? UnorderedList)
        let paragraph = nested.child(at: 0)?.child(at: 0) as? Paragraph
        #expect(paragraph?.plainText == "nested")
    }

    @Test
    func taskListCopyPreservesCheckedState() {
        #expect(MarkdownCopyFormat.plainText.convert("- [x] done\n- [ ] todo")
            == "☑ done\n☐ todo")
        #expect(MarkdownCopyFormat.telegram.convert("    # Heading") == "**Heading**")
    }

    @Test
    func escapedCheckboxAndLinkLabelStayLiteral() {
        #expect(MarkdownCopyFormat.plainText.convert(#"\[x] literal"#) == "[x] literal")
        #expect(MarkdownCopyFormat.plainText.convert("[[x] label](https://example.com)")
            == "[x] label (https://example.com)")
    }
}
