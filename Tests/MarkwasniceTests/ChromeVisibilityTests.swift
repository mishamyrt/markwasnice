import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct ChromeVisibilityTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeSession() -> EditorDocumentSession {
        EditorDocumentSession(
            text: "",
            fileURL: nil,
            isEdited: false,
            settings: Self.settings
        ) {}
    }

    @Test func hoverRevealsEachBarWithoutHidingTheOther() {
        let session = makeSession()
        let state = session.shellState

        session.markdownEditorViewDidScroll(session.editorView)
        #expect(!state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)

        state.onToolbarHoverChanged?(true)
        #expect(state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)

        state.onStatusBarHoverChanged?(true)
        #expect(state.isToolbarVisible)
        #expect(state.isStatusBarVisible)

        session.markdownEditorViewDidScroll(session.editorView)
        state.onStatusBarHoverChanged?(true)
        #expect(!state.isToolbarVisible)
        #expect(state.isStatusBarVisible)

        state.onToolbarHoverChanged?(true)
        #expect(state.isToolbarVisible)
        #expect(state.isStatusBarVisible)
    }

    @Test func typingAndScrollingHideBothBars() {
        let session = makeSession()
        let state = session.shellState

        session.markdownEditorViewDidScroll(session.editorView)
        #expect(!state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)

        state.onToolbarHoverChanged?(true)
        state.onStatusBarHoverChanged?(true)
        session.editorView.setString("a", clearsUndo: false)
        session.editorView.textView.didChangeText()
        #expect(!state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)
    }

    @Test func selectionDoesNotChangeStatusBarVisibility() async {
        let session = makeSession()
        let state = session.shellState

        session.markdownEditorViewDidScroll(session.editorView)
        session.markdownEditorView(
            session.editorView,
            didChangeSelectionText: "Two selected sentences. Really!"
        )

        #expect(!state.isStatusBarVisible)
        await session.waitForSelectionStatistics()
        #expect(!state.isStatusBarVisible)
        #expect(state.characterCountText == "31 characters")
        #expect(state.wordCountText == "4 words")
        #expect(state.sentenceCountText == "2 sentences")

        state.onStatusBarHoverChanged?(true)
        #expect(state.isStatusBarVisible)

        session.markdownEditorViewDidScroll(session.editorView)
        #expect(!state.isStatusBarVisible)
    }

    @Test(arguments: [false, true])
    func hoverDuringScrollAnimationKeepsChromeVisible(inPreview: Bool) throws {
        let session = makeSession()
        let state = session.shellState
        let text = String(repeating: "A line in a long document.\n", count: 400)
        let surface: NSView
        if inPreview {
            let preview = MarkdownPreviewView()
            preview.setContent(
                NSAttributedString(string: text), colors: EditorThemeColors.default.light
            )
            preview.onScroll = {
                session.markdownEditorViewDidScroll(session.editorView)
            }
            surface = preview
        } else {
            session.editorView.setString(text, clearsUndo: true)
            surface = session.editorView
        }
        surface.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: surface.frame, styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = surface
        defer { window.close() }
        surface.layoutSubtreeIfNeeded()
        let scrollView = try #require(surface.subviews
            .compactMap { $0 as? NSScrollView }.first)
        let clipView = scrollView.contentView

        // A user scroll hides chrome; hover can reveal either bar during its tail.
        try sendScroll(to: scrollView, phase: .began)
        #expect(!state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)
        state.onToolbarHoverChanged?(true)
        state.onStatusBarHoverChanged?(true)
        try sendScroll(to: scrollView, phase: .ended, delta: 0)
        try sendScroll(to: scrollView, momentum: .begin)
        try sendScroll(to: scrollView, momentum: .continuous)
        try sendScroll(to: scrollView, momentum: .end, delta: 0)

        // Elastic return continues changing bounds after momentum events end.
        for offsetY: CGFloat in [-48, -24, -8, 0] {
            clipView.setBoundsOrigin(NSPoint(x: 0, y: offsetY))
            #expect(state.isToolbarVisible)
            #expect(state.isStatusBarVisible)
        }
        state.onToolbarHoverChanged?(false)
        state.onStatusBarHoverChanged?(false)
        clipView.setBoundsOrigin(NSPoint(x: 0, y: 1))
        #expect(state.isToolbarVisible)
        #expect(state.isStatusBarVisible)

        // Both a new trackpad gesture and a legacy mouse wheel still hide chrome.
        for phase: CGScrollPhase? in [.began, nil] {
            try sendScroll(to: scrollView, phase: phase)
            #expect(!state.isToolbarVisible)
            #expect(!state.isStatusBarVisible)
            state.onToolbarHoverChanged?(true)
            state.onStatusBarHoverChanged?(true)
        }
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
        #expect(!state.isToolbarVisible)
        #expect(!state.isStatusBarVisible)
    }

    private func sendScroll(
        to scrollView: NSScrollView,
        phase: CGScrollPhase? = nil,
        momentum: CGMomentumScrollPhase = .none,
        delta: Int32 = -10
    ) throws {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0
        ))
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0)
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue)
        )
        scrollView.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    }
}
