import Foundation
import Testing
@testable import Markwasnice

@Suite
struct EditorSearchMatcherTests {
    @Test
    func containsFindsAllCaseSensitiveMatches() {
        let ranges = EditorSearchMatcher.matches(
            for: "app",
            in: "app App pineapple",
            options: EditorSearchOptions(ignoresCase: false)
        )

        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 12, length: 3),
        ])
    }

    @Test
    func ignoresCaseByDefault() {
        let ranges = EditorSearchMatcher.matches(
            for: "app",
            in: "app App",
            options: EditorSearchOptions()
        )

        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
        ])
    }

    @Test
    func ignoreCaseFindsCaseInsensitiveMatches() {
        let ranges = EditorSearchMatcher.matches(
            for: "app",
            in: "app App",
            options: EditorSearchOptions(ignoresCase: true)
        )

        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
        ])
    }

    @Test
    func startsWithMatchesOnlyWordStarts() {
        let ranges = EditorSearchMatcher.matches(
            for: "app",
            in: "app pineapple applet snap-app",
            options: EditorSearchOptions(mode: .startsWith)
        )

        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 14, length: 3),
            NSRange(location: 26, length: 3),
        ])
    }

    @Test
    func fullWordMatchesOnlyWholeWords() {
        let ranges = EditorSearchMatcher.matches(
            for: "app",
            in: "app applet snap app-app",
            options: EditorSearchOptions(mode: .fullWord)
        )

        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 16, length: 3),
            NSRange(location: 20, length: 3),
        ])
    }

    @Test
    func cyrillicWordBoundariesUseUnicodeLetters() {
        let ranges = EditorSearchMatcher.matches(
            for: "мир",
            in: "мир внутри-мир мирный",
            options: EditorSearchOptions(mode: .fullWord)
        )

        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 11, length: 3),
        ])
    }
}
