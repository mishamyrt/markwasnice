import AppKit
import Testing

@testable import Markwasnice

@MainActor
struct MarkdownEditorScrollerInsetTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    @Test func visibleChromeInsetsScrollerByBothBars() throws {
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.setChromeInsets(
            top: 60,
            bottom: 72,
            protectedTop: 52,
            scrollerBottomInset: 28
        )

        let scrollView = try #require(
            editor.subviews.compactMap { $0 as? NSScrollView }.first
        )
        scrollView.scrollerStyle = .legacy
        editor.layoutSubtreeIfNeeded()

        #expect(scrollView.scrollerStyle == .overlay)
        #expect(scrollView.contentView.frame.width == scrollView.bounds.width)
        #expect(scrollView.scrollerInsets.top == 60)
        #expect(scrollView.scrollerInsets.bottom == 28)

        editor.setChromeVisible(false)
        #expect(scrollView.scrollerInsets.top == 0)
        #expect(scrollView.scrollerInsets.bottom == 0)
    }
}
