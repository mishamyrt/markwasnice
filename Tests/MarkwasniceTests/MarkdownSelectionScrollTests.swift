import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownSelectionScrollTests {
    @Test(arguments: [-1.0, 1.0], [60.0, 120.0])
    func scrollFollowsFrameTimeWithoutReversals(
        direction: CGFloat,
        frameRate: Double
    ) throws {
        let (editor, window) = try makeEditor()
        defer { window.close() }
        let textView = editor.textView
        let clipView = try #require(textView.enclosingScrollView?.contentView)
        var previousOffset = clipView.bounds.minY
        let initialOffset = previousOffset
        textView.advanceSelectionAutoscroll(distance: direction * 80, at: 0)
        #expect(clipView.bounds.minY == initialOffset)

        for frame in 1 ... Int(frameRate) {
            textView.advanceSelectionAutoscroll(
                distance: direction * 80, at: Double(frame) / frameRate
            )
            let offset = clipView.bounds.minY
            let step = (offset - previousOffset) * direction
            #expect(step > 0 && step <= 17)
            #expect(offset * window
                .backingScaleFactor == (offset * window.backingScaleFactor).rounded())
            previousOffset = offset
        }
        #expect(abs((previousOffset - initialOffset) * direction - 960) < 1)

        // A stalled frame must not turn into a large jump when tracking resumes.
        textView.advanceSelectionAutoscroll(distance: direction * 80, at: 10)
        #expect((clipView.bounds.minY - previousOffset) * direction <= 32)
        previousOffset = clipView.bounds.minY
        textView.advanceSelectionAutoscroll(distance: -direction * 80, at: 10 + 1 / 60)
        #expect((clipView.bounds.minY - previousOffset) * direction < 0)
    }

    @Test(arguments: [-1.0, 1.0])
    func scrollingStopsAtDocumentBoundaries(direction: CGFloat) throws {
        let (editor, window) = try makeEditor()
        defer { window.close() }
        let textView = editor.textView
        let clipView = try #require(textView.enclosingScrollView?.contentView)
        let boundary = clipView.constrainBoundsRect(
            clipView.bounds.offsetBy(dx: 0, dy: direction * textView.bounds.height)
        ).origin.y
        clipView.setBoundsOrigin(NSPoint(x: 0, y: boundary - direction * 10))
        for frame in 0 ... 20 {
            textView.advanceSelectionAutoscroll(
                distance: direction * 1000, at: Double(frame) / 60
            )
            #expect((clipView.bounds.minY - boundary) * direction <= 0)
        }
        #expect(clipView.bounds.minY == boundary)
    }

    @Test func detachingTheViewResetsTheScrollClock() throws {
        let (editor, window) = try makeEditor()
        defer { window.close() }
        let textView = editor.textView
        let clipView = try #require(textView.enclosingScrollView?.contentView)
        textView.advanceSelectionAutoscroll(distance: 80, at: 0)
        textView.advanceSelectionAutoscroll(distance: 80, at: 1 / 60)
        window.contentView = nil
        window.contentView = editor
        let offset = clipView.bounds.minY
        textView.advanceSelectionAutoscroll(distance: 80, at: 10)
        #expect(clipView.bounds.minY == offset)
    }

    private func makeEditor() throws -> (MarkdownEditorView, NSWindow) {
        let editor = MarkdownEditorView(
            settings: EditorSettings(
                textSizeScale: 1,
                maxTextColumns: 64,
                tabInsertionMode: .spaces,
                tabWidth: 4
            ),
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: editor.frame,
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = editor
        editor.setString(
            String(repeating: "alpha beta gamma delta\n", count: 500),
            clearsUndo: true
        )
        editor.layoutSubtreeIfNeeded()
        try editor.textView.layoutManager?
            .ensureLayout(for: #require(editor.textView.textContainer))
        editor.textView.sizeToFit()
        editor.textView.enclosingScrollView?.contentView.setBoundsOrigin(NSPoint(
            x: 0,
            y: 3000
        ))
        return (editor, window)
    }
}
