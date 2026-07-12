import Foundation
import Testing

@testable import Markwasnice

@Suite
struct MarkdownFrontmatterTests {
    @Test func detectsBasicBlock() {
        let text = "---\ntitle: x\n---\nbody\n"
        #expect(MarkdownFrontmatter.range(in: text) == NSRange(location: 0, length: 17))
    }

    @Test func acceptsEllipsisCloser() {
        let text = "---\na: b\n...\nbody\n"
        #expect(MarkdownFrontmatter.range(in: text) == NSRange(location: 0, length: 13))
    }

    @Test func acceptsEmptyBlock() {
        #expect(MarkdownFrontmatter.range(in: "---\n---\n")
            == NSRange(location: 0, length: 8))
    }

    @Test func toleratesTrailingWhitespaceOnDelimiters() {
        let text = "--- \nk: v\n---\t\nbody\n"
        #expect(MarkdownFrontmatter.range(in: text) == NSRange(location: 0, length: 15))
    }

    @Test func handlesCRLF() {
        let text = "---\r\nk: v\r\n---\r\nbody\r\n"
        #expect(MarkdownFrontmatter.range(in: text) == NSRange(location: 0, length: 16))
    }

    @Test func closerAtEndOfFileWithoutNewline() {
        let text = "---\nk: v\n---"
        #expect(MarkdownFrontmatter.range(in: text) == NSRange(location: 0, length: 12))
    }

    @Test func rejectsUnclosedBlock() {
        #expect(MarkdownFrontmatter.range(in: "---\nk: v\n") == nil)
        #expect(MarkdownFrontmatter.range(in: "---") == nil)
        #expect(MarkdownFrontmatter.range(in: "---\n") == nil)
    }

    @Test func rejectsNonDelimiterOpenings() {
        // "----" is a thematic break, not a frontmatter delimiter.
        #expect(MarkdownFrontmatter.range(in: "----\nk: v\n---\n") == nil)
        #expect(MarkdownFrontmatter.range(in: " ---\nk: v\n---\n") == nil)
        #expect(MarkdownFrontmatter.range(in: "\u{FEFF}---\nk: v\n---\n") == nil)
        #expect(MarkdownFrontmatter.range(in: "x\n---\nk: v\n---\n") == nil)
        #expect(MarkdownFrontmatter.range(in: "") == nil)
    }

    @Test func rejectsCloserBeyondScanCap() {
        let filler = String(
            repeating: "a",
            count: MarkdownFrontmatter.maximumScanLength
        )
        #expect(MarkdownFrontmatter.range(in: "---\n\(filler)\n---\n") == nil)
    }
}

@Suite
struct MarkdownFrontmatterParseTests {
    private func spans(in text: String) -> [ResolvedMarkdownStyleSpan] {
        MarkdownParseService.parse(text: text, version: 0, previous: nil)?
            .spans ?? []
    }

    @Test func emitsSingleFrontmatterSpanAndKeepsBody() {
        let text = "---\ntitle: x\n---\n# Head\n"
        let parsed = spans(in: text)
        let frontmatter = parsed.filter { $0.kind == .frontmatter }
        #expect(frontmatter == [ResolvedMarkdownStyleSpan(
            range: NSRange(location: 0, length: 17),
            kind: .frontmatter
        )])
        // Nothing else may claim the block: cmark reads "---" as a thematic
        // break and "title: x\n---" as a setext heading.
        let intruders = parsed.filter {
            $0.kind != .frontmatter
                && NSIntersectionRange($0.range, NSRange(location: 0, length: 17))
                .length > 0
        }
        #expect(intruders.isEmpty)
        #expect(parsed.contains { $0.kind == .heading })
    }

    @Test func suppressesSetextHeadingInsideBlock() {
        let parsed = spans(in: "---\nkey: value\n---\n")
        #expect(parsed.map(\.kind) == [.frontmatter])
    }

    @Test func loneLeadingDashesStayAThematicBreak() {
        let parsed = spans(in: "---\n\nТекст\n")
        #expect(parsed.contains { $0.kind == .thematicBreak })
        #expect(!parsed.contains { $0.kind == .frontmatter })
    }
}

@Suite
struct FrontmatterTypographyTests {
    private func apply(
        _ text: String,
        selectedRange: NSRange? = nil,
        locale: EditorSettings.TypographyLocale = .russian
    ) -> String {
        let replacements = MarkdownTypographyCommand.replacements(
            in: text,
            selectedRange: selectedRange ?? NSRange(location: 0, length: 0),
            locale: locale
        )
        let result = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            result.replaceCharacters(
                in: replacement.range,
                with: replacement.replacement
            )
        }
        return result as String
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func touchesOnlyValues() {
        let text = """
        ---
        title: Привет - мир
        # comment - untouched
        list:
          - пункт - раз
        ---
        Тело - текст
        """
        let result = normalized(apply(text))
        #expect(result.contains("title: Привет — мир"))
        #expect(result.contains("# comment - untouched"))
        #expect(result.contains("  - пункт — раз"))
        #expect(result.contains("Тело — текст"))
    }

    @Test func keepsDoubleQuoteDelimitersConvertsInnerQuotes() {
        let text = "---\ntitle: \"Он сказал \"привет\" - мир\"\n---\n"
        let result = normalized(apply(text))
        #expect(result == "---\ntitle: \"Он сказал «привет» — мир\"\n---\n")
    }

    @Test func keepsSingleQuoteDelimiters() {
        let text = "---\ntitle: 'цитата - раз'\n---\n"
        let result = normalized(apply(text))
        #expect(result == "---\ntitle: 'цитата — раз'\n---\n")
    }

    @Test func appliesEnglishRulesInsideQuotedValue() {
        let text = "---\ntitle: \"He said \"hello\" to me...\"\n---\n"
        let result = normalized(apply(text, locale: .english))
        #expect(result == "---\ntitle: \"He said “hello” to me…\"\n---\n")
    }

    @Test func processesUnquotedScalarFully() {
        let text = "---\nsubtitle: Он сказал \"да\" - и ушел\n---\n"
        let result = normalized(apply(text))
        #expect(result == "---\nsubtitle: Он сказал «да» — и ушел\n---\n")
    }

    @Test func processesSequenceItems() {
        let text = "---\ntags:\n  - \"цитата - раз\"\n  - значение - тут\n---\n"
        let result = normalized(apply(text))
        #expect(result.contains("- \"цитата — раз\""))
        #expect(result.contains("- значение — тут"))
    }

    @Test func processesBlockScalars() {
        let text = """
        ---
        description: |
          Он сказал "да" - и ушел
          Вторая - строка
        summary: >
          Текст - раз
        ---
        """
        let result = normalized(apply(text))
        #expect(result.contains("Он сказал «да» — и ушел"))
        #expect(result.contains("Вторая — строка"))
        #expect(result.contains("Текст — раз"))
        #expect(result.contains("description: |"))
        #expect(result.contains("summary: >"))
    }

    @Test func keepsInlineComments() {
        let text = "---\nkey: значение - тут # keep - this\n---\n"
        let result = normalized(apply(text))
        #expect(result == "---\nkey: значение — тут # keep - this\n---\n")
    }

    @Test func skipsFlowCollections() {
        let text = "---\ntags: [раз - два, \"три\"]\n---\n"
        #expect(apply(text) == text)
    }

    @Test func selectionInsideFrontmatterProcessesOnlyIntersectingValues() {
        let text = "---\ntitle: \"привет - мир\"\nother: тоже - да\n---\nТело - текст\n"
        let selection = (text as NSString).range(of: "\"привет - мир\"")
        let result = normalized(apply(text, selectedRange: selection))
        #expect(result.contains("title: \"привет — мир\""))
        #expect(result.contains("other: тоже - да"))
        #expect(result.contains("Тело - текст"))
    }

    @Test func bodyThematicBreakStaysProtected() {
        let text = "---\nk: v\n---\nТекст - раз\n\n---\n\nТекст - два\n"
        let result = normalized(apply(text))
        #expect(result.contains("Текст — раз"))
        #expect(result.contains("Текст — два"))
        #expect(result.contains("\n---\n\n"))
    }

    /// Without a closing delimiter there is no frontmatter: the leading
    /// "---" is a protected thematic break and the rest is ordinary prose.
    @Test func unclosedBlockIsProcessedAsProse() {
        let text = "---\ntitle: \"привет\"\n"
        let result = normalized(apply(text))
        #expect(result == "---\ntitle: «привет»\n")
    }

    @Test func secondPassReturnsNothing() {
        let processed = apply(
            "---\ntitle: \"Он сказал \"привет\" - и ушел\"\nplain: без сомнений...\n---\nТело - текст...\n"
        )
        #expect(MarkdownTypographyCommand.replacements(
            in: processed,
            selectedRange: NSRange(location: 0, length: 0),
            locale: .russian
        ).isEmpty)
    }
}
