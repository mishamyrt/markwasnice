import Foundation
import Testing
@testable import Markwasnice

/// The line-prefix grammar is spelled once and compiled into the regexes and
/// literal scanners of four subsystems. These tests walk the grammar's own
/// token sets, so widening one (another bullet character, another checkbox
/// state) fails here for every consumer that did not pick it up — the
/// per-file suites all hardcode their own examples and would stay green.
struct MarkdownLineGrammarTests {
    @Test func everyBulletCharacterContinuesAListAndOpensAPrefix() throws {
        for bullet in MarkdownLineGrammar.bulletCharacters {
            let text = "\(bullet) first"
            let edit = try #require(
                MarkdownContinuationCommand.edit(
                    in: text as NSString,
                    selectedRange: NSRange(
                        location: (text as NSString).length,
                        length: 0
                    )
                ),
                "\(bullet) is not continued"
            )

            #expect(edit.replacementString == "\n\(bullet) ")
            #expect(DocumentTitleSuggester.title(from: text) == "first")
        }
    }

    @Test func everyOrderedSeparatorContinuesAListAndOpensAPrefix() throws {
        for separator in MarkdownLineGrammar.orderedMarkerSeparators {
            let text = "1\(separator) first"
            let edit = try #require(
                MarkdownContinuationCommand.edit(
                    in: text as NSString,
                    selectedRange: NSRange(
                        location: (text as NSString).length,
                        length: 0
                    )
                ),
                "1\(separator) is not continued"
            )

            #expect(edit.replacementString == "\n2\(separator) ")
            #expect(DocumentTitleSuggester.title(from: text) == "first")
        }
    }

    @Test func everyCheckboxStateIsScannedContinuedAndStripped() throws {
        for state in MarkdownLineGrammar.checkboxStateCharacters {
            let text = "[\(state)] task"
            let spans = MarkdownTaskCheckboxScanner.spans(in: text, excluding: [])
            #expect(
                spans.map(\.range) == [NSRange(location: 0, length: 3)],
                "[\(state)] is not scanned"
            )

            let edit = try #require(
                MarkdownContinuationCommand.edit(
                    in: text as NSString,
                    selectedRange: NSRange(
                        location: (text as NSString).length,
                        length: 0
                    )
                ),
                "[\(state)] is not continued"
            )
            #expect(edit.replacementString == "\n[ ] ")
            #expect(DocumentTitleSuggester.title(from: text) == "task")
        }
    }

    /// The literals the character-walking scanners use have to stay in step
    /// with the character class the regexes are built from.
    @Test func checkboxLiteralsCoverEveryState() {
        #expect(
            MarkdownLineGrammar.checkboxLiterals
                == MarkdownLineGrammar.checkboxStateCharacters.map { "[\($0)] " }
        )
    }
}
