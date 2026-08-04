import AppKit
import XCTest

@testable import Markwasnice

/// The preview's chrome insets go through the clip view directly: with
/// automaticallyAdjustsContentInsets disabled (the Tahoe glass-inset
/// workaround), NSScrollView's own contentInsets setter silently never
/// reaches the clip view, which is what clamps the scroll position —
/// content then starts flush under the window title bar.
@MainActor
final class MarkdownPreviewViewInsetTests: XCTestCase {
    func testTopInsetOffsetsContentAtTopOfDocument() {
        let preview = MarkdownPreviewView()
        preview.frame = NSRect(x: 0, y: 0, width: 600, height: 400)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = preview
        preview.layoutSubtreeIfNeeded()

        let text = NSAttributedString(
            string: Array(repeating: "line", count: 400).joined(separator: "\n"),
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        preview.setContent(
            text,
            colors: EditorThemeColors.default.variant(
                for: NSAppearance(named: .aqua)!
            )
        )
        preview.setInsets(top: 52, bottom: 72, horizontal: 20)
        preview.scrollToFraction(0)

        guard let scrollView = preview.subviews
            .compactMap({ $0 as? NSScrollView }).first
        else {
            XCTFail("Preview must host a scroll view")
            return
        }
        XCTAssertEqual(scrollView.contentView.contentInsets.top, 52, accuracy: 0.1)
        XCTAssertEqual(scrollView.contentView.contentInsets.bottom, 72, accuracy: 0.1)
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, -52, accuracy: 0.1)
        XCTAssertEqual(preview.scrollFraction, 0, accuracy: 0.001)

        // Clip-view insets are invisible to the scroll view's scroller
        // tiling, so the scroller offset must carry the full bar height.
        preview.setScrollerInsets(top: 52, bottom: 28)
        XCTAssertEqual(scrollView.scrollerInsets.top, 52, accuracy: 0.1)
        XCTAssertEqual(scrollView.scrollerInsets.bottom, 28, accuracy: 0.1)
    }
}
