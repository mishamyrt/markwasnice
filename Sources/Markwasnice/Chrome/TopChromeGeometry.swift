import AppKit

@MainActor
enum TopChromeGeometry {
    static func revealRectInContentView(
        window: NSWindow,
        revealHeight: CGFloat
    ) -> NSRect? {
        guard revealHeight > 0, let contentView = window.contentView else {
            return nil
        }

        let bounds = contentView.bounds
        let height = min(revealHeight, bounds.height)
        let y = contentView.isFlipped ? bounds.minY : bounds.maxY - height

        return NSRect(
            x: bounds.minX,
            y: y,
            width: bounds.width,
            height: height
        )
    }
}
