import AppKit
import QuartzCore
import SwiftUI

struct ToolbarVisibilityBridge: NSViewRepresentable {
    @Binding var isVisible: Bool
    let isSystemManaged: Bool

    func makeNSView(context _: Context) -> ToolbarVisibilityView {
        let view = ToolbarVisibilityView(frame: .zero)
        view.isToolbarVisible = isVisible
        view.isSystemManaged = isSystemManaged
        return view
    }

    func updateNSView(_ view: ToolbarVisibilityView, context _: Context) {
        view.isToolbarVisible = isVisible
        view.isSystemManaged = isSystemManaged
    }
}

final class ToolbarVisibilityView: NSView {
    var isToolbarVisible = true {
        didSet {
            guard isToolbarVisible != oldValue else {
                return
            }

            applyToolbarVisibility()
        }
    }

    var isSystemManaged = false {
        didSet {
            guard isSystemManaged != oldValue else {
                return
            }

            applyToolbarVisibility()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToolbarVisibility()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    private func applyToolbarVisibility() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else {
                return
            }

            window.titlebarAppearsTransparent = true
            if !isSystemManaged {
                EditorWindowChrome.installBaseToolbar(on: window)
            }

            let alpha = isSystemManaged || isToolbarVisible ? 1.0 : 0.0
            let buttonTypes: [NSWindow.ButtonType] = [
                .closeButton,
                .miniaturizeButton,
                .zoomButton,
            ]

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)

                for buttonType in buttonTypes {
                    window.standardWindowButton(buttonType)?.animator().alphaValue = alpha
                }
            }
        }
    }
}

struct TopHoverTrackingBridge: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    private var isDragEnabled = false

    init(onHoverChanged: @escaping (Bool) -> Void) {
        self.onHoverChanged = onHoverChanged
    }

    func isDragEnabled(_ isDragEnabled: Bool) -> Self {
        var copy = self
        copy.isDragEnabled = isDragEnabled
        return copy
    }

    func makeNSView(context _: Context) -> TopHoverTrackingView {
        let view = TopHoverTrackingView(frame: .zero)
        view.onHoverChanged = onHoverChanged
        view.isDragEnabled = isDragEnabled
        return view
    }

    func updateNSView(_ view: TopHoverTrackingView, context _: Context) {
        view.onHoverChanged = onHoverChanged
        view.isDragEnabled = isDragEnabled
    }
}

final class TopHoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var isDragEnabled = false {
        didSet {
            guard isDragEnabled != oldValue else {
                return
            }

            window?.invalidateCursorRects(for: self)
        }
    }

    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override var mouseDownCanMoveWindow: Bool {
        isDragEnabled
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isDragEnabled else {
            return
        }

        addCursorRect(cursorExclusionRect, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseMoved,
                .mouseEnteredAndExited,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(with: event)
        setHovering(true)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(with: event)
        setHovering(true)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(with: event)
    }

    override func mouseExited(with _: NSEvent) {
        setHovering(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isDragEnabled && cursorExclusionRect.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isDragEnabled else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            performTitlebarDoubleClickAction()
            return
        }

        window?.performDrag(with: event)
    }

    /// The drag band replaces the native titlebar, so the titlebar
    /// double-click gesture has to be reproduced here, honoring the same
    /// system preference the real titlebar reads.
    private func performTitlebarDoubleClickAction() {
        guard let window, !window.styleMask.contains(.fullScreen) else {
            return
        }

        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            window.performZoom(nil)
        }
    }

    private func updateCursor(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let isCursorExcluded = cursorExclusionRect.contains(point)

        guard isCursorExcluded else {
            return
        }

        NSCursor.arrow.set()
    }

    private var cursorExclusionRect: NSRect {
        TopChromeGeometry.topAlignedRect(
            height: EditorShellState.toolbarCursorExclusionHeight,
            in: bounds,
            isFlipped: isFlipped
        )
    }

    private func setHovering(_ isHovering: Bool) {
        guard isHovering != self.isHovering else {
            return
        }

        self.isHovering = isHovering
        onHoverChanged?(isHovering)
    }
}
