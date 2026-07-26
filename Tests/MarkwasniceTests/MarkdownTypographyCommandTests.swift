import Foundation
import Testing

@testable import Markwasnice

struct MarkdownTypographyCommandTests {
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

    /// Where the non-breaking spaces land is the library's business; these
    /// tests only assert the visible typography.
    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    @Test func processesWholeTextWithoutSelection() {
        #expect(
            normalized(apply("Он сказал \"привет\" - и ушел."))
                == "Он сказал «привет» — и ушел."
        )
    }

    @Test func processesOnlySelection() {
        let text = "\"один\" и \"два\""
        // Only the "два" part, including its quotes.
        let selection = NSRange(location: 9, length: 5)
        let result = apply(text, selectedRange: selection)
        #expect(result == "\"один\" и «два»")
    }

    @Test func skipsFencedCodeBlocks() {
        let text = "Текст - раз\n\n```\nlet a = \"b\" - c\n```\n\nТекст - два\n"
        let result = normalized(apply(text))
        #expect(result.contains("let a = \"b\" - c"))
        #expect(result.contains("Текст — раз"))
        #expect(result.contains("Текст — два"))
    }

    @Test func skipsInlineCode() {
        let text = "Код `\"x\" - y` и \"текст\""
        let result = apply(text)
        #expect(result.contains("`\"x\" - y`"))
        #expect(result.contains("«текст»"))
    }

    @Test func processesSelectionEntirelyInsideCodeBlock() {
        let text = "```\nпривет - мир\n```\n"
        // The "привет - мир" line inside the fence.
        let selection = NSRange(location: 4, length: 12)
        let result = normalized(apply(text, selectedRange: selection))
        #expect(result == "```\nпривет — мир\n```\n")
    }

    @Test func clipsProtectedRangeAtSelectionStart() {
        let text = "`aб` и \"привет\""
        // Selection starts inside the code span and runs to the end.
        let selection = NSRange(location: 2, length: (text as NSString).length - 2)
        let result = normalized(apply(text, selectedRange: selection))
        #expect(result == "`aб` и «привет»")
    }

    @Test func keepsListMarkers() {
        let text = "- первый пункт\n- второй пункт\n"
        #expect(apply(text) == text)
    }

    @Test func keepsIndentationAndBlankLines() {
        let text = "- пункт\n    - вложенный\n\n\n\nАбзац\n"
        #expect(apply(text) == text)
    }

    @Test func appliesEnglishRules() {
        let result = normalized(apply(
            "He said \"hello\" to me...",
            locale: .english
        ))
        #expect(result == "He said “hello” to me…")
    }

    @Test func adjustsCaretAfterReplacements() {
        let text = "Он сказал \"привет\" и ушел. Конец."
        let caret = NSRange(location: (text as NSString).length, length: 0)
        let replacements = MarkdownTypographyCommand.replacements(
            in: text,
            selectedRange: NSRange(location: 0, length: 0),
            locale: .russian
        )
        let adjusted = MarkdownTypographyCommand.adjustedSelection(
            caret,
            after: replacements
        )
        let result = apply(text)
        #expect(adjusted == NSRange(location: (result as NSString).length, length: 0))
    }

    @Test func adjustsSelectionLengthAfterReplacements() {
        let text = "\"привет\" и \"пока\""
        let selection = NSRange(location: 0, length: (text as NSString).length)
        let replacements = MarkdownTypographyCommand.replacements(
            in: text,
            selectedRange: selection,
            locale: .russian
        )
        let result = apply(text, selectedRange: selection)
        let adjusted = MarkdownTypographyCommand.adjustedSelection(
            selection,
            after: replacements
        )
        #expect(adjusted == NSRange(location: 0, length: (result as NSString).length))
    }

    // The sample must avoid short prepositions ("без", "и"): those
    // legitimately gain a non-breaking space, so text containing them is
    // not "unchanged".
    @Test func returnsNothingForUnchangedText() {
        #expect(MarkdownTypographyCommand.replacements(
            in: "Совершенно обычный текст",
            selectedRange: NSRange(location: 0, length: 0),
            locale: .russian
        ).isEmpty)
    }

    /// Text that already went through the command is typographically
    /// settled: a second pass must be a no-op, otherwise repeated "Fix
    /// Typography" invocations would keep dirtying the document.
    @Test func secondPassReturnsNothing() {
        let processed = apply("Он сказал \"привет\" - и ушел, без сомнений...")
        #expect(MarkdownTypographyCommand.replacements(
            in: processed,
            selectedRange: NSRange(location: 0, length: 0),
            locale: .russian
        ).isEmpty)
    }

    /// Handing the command the styling pipeline's spans spares it a second
    /// full parse on the main thread, so the two paths have to agree
    /// exactly — including which code and structure ranges stay protected.
    @Test func resolvedSpansMatchTheParsedProtectedRanges() {
        let text = """
        ---
        title: "Он сказал - привет"
        ---

        Обычный текст - с тире и `кодом - внутри`.

        ```
        код - остается как есть...
        ```

        ***

        - пункт - списка
        """
        let selection = NSRange(location: 0, length: 0)
        let spans = MarkdownParseService.parse(
            text: text,
            version: 0,
            previous: nil
        )?.spans

        #expect(spans != nil)
        #expect(MarkdownTypographyCommand.replacements(
            in: text,
            selectedRange: selection,
            locale: .russian,
            spans: spans
        ) == MarkdownTypographyCommand.replacements(
            in: text,
            selectedRange: selection,
            locale: .russian
        ))
    }

    /// Stale spans must never be substituted for a parse: the caller signals
    /// that with nil, and the command then protects code by parsing itself.
    @Test func missingSpansStillProtectCode() {
        let text = "Текст - снаружи и `код - внутри`"
        let replacements = MarkdownTypographyCommand.replacements(
            in: text,
            selectedRange: NSRange(location: 0, length: 0),
            locale: .russian,
            spans: nil
        )
        let codeRange = (text as NSString).range(of: "`код - внутри`")

        #expect(!replacements.isEmpty)
        #expect(!replacements.contains {
            NSIntersectionRange($0.range, codeRange).length > 0
        })
    }
}
