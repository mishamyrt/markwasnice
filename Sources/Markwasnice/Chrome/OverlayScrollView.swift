import AppKit

/// Keeps the document viewport full-width when AppKit reacts to a mouse by
/// trying to restore the user's preferred legacy scroller style.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}
