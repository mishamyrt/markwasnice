import AppKit
import Testing
@testable import Markwasnice

/// Pins the selected-search-match foreground handling in
/// MarkdownEditorView.setSearchMatches: only the selected match carries an
/// attribute (the dark text over the drawn yellow fill), and moving or
/// clearing the selection must restore the previous match's color — without
/// relying on a whole-document restyle.
@MainActor
struct EditorSearchHighlightDeltaTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeEditor(source: String) -> MarkdownEditorView {
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.setString(source, clearsUndo: true)
        return editor
    }

    private func foregroundColor(
        of editor: MarkdownEditorView,
        at location: Int
    ) -> NSColor? {
        editor.textView.textStorage?.attribute(
            .foregroundColor,
            at: location,
            effectiveRange: nil
        ) as? NSColor
    }

    @Test func selectedMatchColorFollowsNextPreviousSteps() {
        let source = "alpha match one\nbeta match two\ngamma text"
        let editor = makeEditor(source: source)
        let nsSource = source as NSString
        let firstMatch = nsSource.range(of: "match")
        let secondMatch = nsSource.range(of: "match", options: .backwards)
        let baseColor = foregroundColor(of: editor, at: firstMatch.location)

        editor.setSearchMatches([firstMatch, secondMatch], selectedIndex: 0)

        let selectedColor = foregroundColor(of: editor, at: firstMatch.location)
        #expect(selectedColor != nil)
        #expect(selectedColor != baseColor)
        #expect((selectedColor?.alphaComponent ?? 1) < 0.9)
        #expect(foregroundColor(of: editor, at: secondMatch.location) == baseColor)

        editor.setSearchMatches([firstMatch, secondMatch], selectedIndex: 1)

        #expect(foregroundColor(of: editor, at: firstMatch.location) == baseColor)
        #expect(
            (foregroundColor(of: editor, at: secondMatch.location)?
                .alphaComponent ?? 1) < 0.9
        )
    }

    @Test func clearingSearchRestoresSelectedMatchColor() {
        let source = "alpha match one\nbeta text"
        let editor = makeEditor(source: source)
        let match = (source as NSString).range(of: "match")
        let baseColor = foregroundColor(of: editor, at: match.location)

        editor.setSearchMatches([match], selectedIndex: 0)
        #expect((foregroundColor(of: editor, at: match.location)?
            .alphaComponent ?? 1) < 0.9)

        // The search-closed transition: the match set empties and the old
        // selected match no longer exists, yet its color must clear.
        editor.setSearchMatches([], selectedIndex: nil)
        #expect(foregroundColor(of: editor, at: match.location) == baseColor)
    }

    @Test func replacingMatchSetClearsStaleSelectedColor() {
        let source = "alpha match one\nbeta other two"
        let editor = makeEditor(source: source)
        let nsSource = source as NSString
        let oldMatch = nsSource.range(of: "match")
        let newMatch = nsSource.range(of: "other")
        let baseColor = foregroundColor(of: editor, at: oldMatch.location)

        editor.setSearchMatches([oldMatch], selectedIndex: 0)
        // A new query: the old selected match is gone from the set entirely.
        editor.setSearchMatches([newMatch], selectedIndex: 0)

        #expect(foregroundColor(of: editor, at: oldMatch.location) == baseColor)
        #expect((foregroundColor(of: editor, at: newMatch.location)?
            .alphaComponent ?? 1) < 0.9)
    }
}
