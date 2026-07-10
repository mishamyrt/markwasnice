import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct FocusModeGeometryTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeEditor() -> MarkdownEditorView {
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.setString("asdasdasd\n\nasdasd\nasdasd\n\nasdasd", clearsUndo: true)
        editor.layoutSubtreeIfNeeded()
        return editor
    }

    /// Focus/typewriter mode adds overscroll padding so the caret line can be
    /// centered even on the first and last document lines.
    @Test func enablingFocusModeAddsOverscrollPadding() {
        let editor = makeEditor()
        let clipHeight = editor.textView.enclosingScrollView!.contentView.bounds.height

        editor.setFocusMode(.typewriter)
        editor.setFocusModeEnabled(true)
        editor.layoutSubtreeIfNeeded()

        #expect(editor.textView.topContentPadding >= clipHeight / 2 - 20)
        #expect(editor.textView.bottomContentPadding >= clipHeight / 2 - 20)
    }

    /// Disabling the mode must shrink the text view frame back — NSTextView
    /// grows for a larger inset but never shrinks on its own, which used to
    /// leave a dead band of empty scroll range at the top of the document.
    @Test func disablingFocusModeRestoresTextViewGeometry() {
        let editor = makeEditor()
        let frameBefore = editor.textView.frame
        let insetBefore = editor.textView.textContainerInset

        editor.setFocusMode(.typewriter)
        editor.setFocusModeEnabled(true)
        editor.textView.setSelectedRange(NSRange(location: 12, length: 0))
        editor.layoutSubtreeIfNeeded()
        editor.setFocusModeEnabled(false)
        editor.layoutSubtreeIfNeeded()

        #expect(editor.textView.frame == frameBefore)
        #expect(editor.textView.textContainerInset == insetBefore)
        #expect(editor.textView.textContainerOrigin.y == 0)
    }
}
