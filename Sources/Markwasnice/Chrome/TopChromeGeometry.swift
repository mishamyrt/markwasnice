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

        return topAlignedRect(
            height: revealHeight,
            in: contentView.bounds,
            isFlipped: contentView.isFlipped
        )
    }

    /// The full-width band along the top edge of `bounds`, clamped to its
    /// height. The single place that knows which edge "top" is in a flipped
    /// coordinate space — every consumer of the same physical band (the reveal
    /// rect, the toolbar's cursor exclusion) goes through here, so the band
    /// cannot drift apart between them.
    static func topAlignedRect(
        height: CGFloat,
        in bounds: NSRect,
        isFlipped: Bool
    ) -> NSRect {
        let height = min(height, bounds.height)
        return NSRect(
            x: bounds.minX,
            y: isFlipped ? bounds.minY : bounds.maxY - height,
            width: bounds.width,
            height: height
        )
    }
}
