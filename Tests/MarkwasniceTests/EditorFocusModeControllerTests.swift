import AppKit
import Testing
@testable import Markwasnice

/// EditorFocusModeController state cluster: the active-paragraph dimming
/// decision, the scroll-induced suppression episode, and the edit-time
/// range adjustment.
@MainActor
struct EditorFocusModeControllerTests {
    private func makeController(
        text: String
    ) -> (controller: EditorFocusModeController, textView: MarkdownTextView) {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(
                width: 400,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        layoutManager.addTextContainer(container)
        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        let controller = EditorFocusModeController(
            textView: textView,
            scrollView: scrollView,
            clipView: scrollView.contentView
        )
        return (controller, textView)
    }

    @Test func dimmedRangesExcludeActiveParagraph() {
        let (controller, textView) = makeController(text: "one\n\ntwo\n\nthree")
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        controller.setEnabled(true)

        let fullRange = NSRange(
            location: 0,
            length: (textView.string as NSString).length
        )
        #expect(controller.activeParagraphRange == NSRange(location: 5, length: 4))
        #expect(controller.dimmedRanges(in: fullRange) == [
            NSRange(location: 0, length: 5),
            NSRange(location: 9, length: 6),
        ])
    }

    @Test func disablingClearsActiveParagraphAndDimming() {
        let (controller, textView) = makeController(text: "one\n\ntwo")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        let fullRange = NSRange(
            location: 0,
            length: (textView.string as NSString).length
        )

        controller.setEnabled(true)
        controller.setEnabled(false)

        #expect(controller.activeParagraphRange == nil)
        #expect(controller.dimmedRanges(in: fullRange).isEmpty)
    }

    @Test func scrollSuppressionClearsDimmingUntilRestored() {
        let (controller, textView) = makeController(text: "one\n\ntwo\n\nthree")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        let fullRange = NSRange(
            location: 0,
            length: (textView.string as NSString).length
        )
        controller.setEnabled(true)

        controller.suppressForUserScroll()
        #expect(controller.isTemporarilySuppressed)
        #expect(controller.dimmedRanges(in: fullRange).isEmpty)

        var didRestyleAll = false
        controller.restyleAllText = { didRestyleAll = true }
        controller.restoreAfterEditorInteraction()
        #expect(!controller.isTemporarilySuppressed)
        // Lifting the suppression must re-dim the whole document.
        #expect(didRestyleAll)
        #expect(!controller.dimmedRanges(in: fullRange).isEmpty)
    }

    @Test func typewriterModeNeverDims() {
        let (controller, textView) = makeController(text: "one\n\ntwo")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        let fullRange = NSRange(
            location: 0,
            length: (textView.string as NSString).length
        )

        controller.setMode(.typewriter)
        controller.setEnabled(true)

        #expect(controller.dimmedRanges(in: fullRange).isEmpty)
    }

    @Test func textEditShiftsActiveParagraph() {
        let (controller, textView) = makeController(text: "one\n\ntwo\n")
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        controller.setEnabled(true)
        #expect(controller.activeParagraphRange == NSRange(location: 5, length: 4))

        // An insertion of two characters at the front shifts the active
        // paragraph right by the change in length.
        controller.handleTextEdit(
            editedRange: NSRange(location: 0, length: 2),
            changeInLength: 2,
            sourceLength: 11
        )

        #expect(controller.activeParagraphRange == NSRange(location: 7, length: 4))
    }
}
