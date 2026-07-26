import AppKit
import Testing

@testable import Markwasnice

/// Switching the system between light and dark has to repaint the document in
/// the other theme variant. The editor resolves the variant from its effective
/// appearance, so the whole path is exercisable without a window.
@MainActor
struct EditorAppearanceTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeEditor(appearance: NSAppearance.Name) -> MarkdownEditorView {
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        editor.appearance = NSAppearance(named: appearance)
        editor.setString("Обычный текст со `código` и **жирным**", clearsUndo: true)
        if let result = MarkdownParseService.parse(
            text: editor.string,
            version: 1,
            previous: nil
        ) {
            editor.applyParsedStyles(result.spans, dirtyRanges: nil)
        }
        return editor
    }

    private func foreground(_ editor: MarkdownEditorView, at location: Int) -> NSColor? {
        editor.textView.textStorage?.attribute(
            .foregroundColor,
            at: location,
            effectiveRange: nil
        ) as? NSColor
    }

    @Test func switchingToDarkRepaintsTheDocument() {
        let editor = makeEditor(appearance: .aqua)
        let light = foreground(editor, at: 0)

        editor.appearance = NSAppearance(named: .darkAqua)

        #expect(light != nil)
        #expect(foreground(editor, at: 0) != light)
    }

    @Test func switchingToLightRepaintsTheDocument() {
        let editor = makeEditor(appearance: .darkAqua)
        let dark = foreground(editor, at: 0)

        editor.appearance = NSAppearance(named: .aqua)

        #expect(dark != nil)
        #expect(foreground(editor, at: 0) != dark)
    }

    /// The background follows the same push, and it is the one the user reads
    /// as "the theme did not change" when it stays behind.
    @Test func switchingAppearanceRepaintsTheBackground() {
        let editor = makeEditor(appearance: .aqua)
        let light = editor.textView.backgroundColor

        editor.appearance = NSAppearance(named: .darkAqua)

        #expect(editor.textView.backgroundColor != light)
    }

    /// The real switch is a system one: nothing assigns an appearance to the
    /// editor, it inherits the window's. A view that pins its own appearance
    /// stops inheriting, which reads exactly as "the theme never changes".
    @Test func inheritedAppearanceChangeRepaintsTheDocument() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let editor = MarkdownEditorView(
            settings: Self.settings,
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        window.contentView = editor
        window.appearance = NSAppearance(named: .aqua)
        editor.setString("Обычный текст со `código` и **жирным**", clearsUndo: true)
        if let result = MarkdownParseService.parse(
            text: editor.string,
            version: 1,
            previous: nil
        ) {
            editor.applyParsedStyles(result.spans, dirtyRanges: nil)
        }
        let light = foreground(editor, at: 0)

        window.appearance = NSAppearance(named: .darkAqua)

        #expect(light != nil)
        #expect(editor.appearance == nil)
        #expect(foreground(editor, at: 0) != light)
    }
}
