import AppKit

/// Keeps the document viewport full-width when AppKit reacts to a mouse by
/// trying to restore the user's preferred legacy scroller style.
final class OverlayScrollView: NSScrollView {
    /// Direct input only: momentum and elastic return must not hide chrome
    /// that the user has revealed while a scroll animation is finishing.
    var onUserScroll: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userScrollWillStart),
            name: NSScrollView.willStartLiveScrollNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }

    override static var isCompatibleWithResponsiveScrolling: Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase.isEmpty,
           event.phase.isEmpty || event.phase.contains(.began)
           || event.phase.contains(.changed),
           event.scrollingDeltaY != 0
        {
            onUserScroll?()
        }
        super.scrollWheel(with: event)
    }

    @objc private func userScrollWillStart() {
        // Also covers dragging the native scrollbar thumb.
        onUserScroll?()
    }
}
