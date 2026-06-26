import AppKit

@MainActor
final class EditorClipView: NSClipView {
    var isWindowPointInTopChrome: ((NSPoint, NSWindow) -> Bool)?
    var topChromeRectProvider: (() -> NSRect?)?

    override func resetCursorRects() {
        guard let window,
              let contentView = window.contentView,
              let chromeRectInContentView = topChromeRectProvider?()
        else {
            addCursorRect(visibleRect, cursor: .iBeam)
            return
        }

        let visible = visibleRect
        let chromeRect = convert(chromeRectInContentView, from: contentView)
        let blocked = visible.intersection(chromeRect)

        if !blocked.isNull, !blocked.isEmpty {
            addCursorRect(blocked, cursor: .arrow)
        }

        for rect in visible.subtracting(blocked) where !rect.isEmpty {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let isTopChrome = eventIsInTopChrome(event)

        if isTopChrome {
            NSCursor.arrow.set()
            return
        }

        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let isTopChrome = eventIsInTopChrome(event)

        if isTopChrome {
            NSCursor.arrow.set()
            return
        }

        super.cursorUpdate(with: event)
    }

    private func eventIsInTopChrome(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? window else {
            return false
        }

        return isWindowPointInTopChrome?(event.locationInWindow, window) == true
    }
}
