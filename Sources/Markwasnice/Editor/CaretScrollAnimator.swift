import AppKit

/// Display-link-driven smooth scroller for keyboard caret scrolling.
///
/// The system animated scroll (NSScrollAnimationHelper / NSAnimationManager)
/// starts a new animation on every key repeat while the previous one is
/// still running; the overlapping animations fight over the clip origin and
/// held-key scrolling visibly bounces. This animator keeps a single mutable
/// target instead: retargeting just moves the goalpost, and every tick moves
/// the clip origin toward it exponentially, so the offset stays monotonic
/// while the target moves in one direction.
@MainActor
final class CaretScrollAnimator: NSObject {
    /// Time constant of the exponential approach; the scroll visually
    /// settles in about three time constants after the last key repeat.
    private static let timeConstant: CGFloat = 0.05

    /// Ticks tolerated without the clip origin getting closer to the
    /// target. Something else owning the scroll position (a layout pass
    /// re-asserting its own offset every frame) resets each tick's motion,
    /// and without this cap the display link would spin forever.
    private static let maxStalledTicks = 10

    private weak var scrollView: NSScrollView?
    private var displayLink: CADisplayLink?
    private var previousDistanceToTarget: CGFloat?
    private var stalledTickCount = 0
    private(set) var targetOffsetY: CGFloat = 0

    var isAnimating: Bool {
        displayLink != nil
    }

    func scroll(_ scrollView: NSScrollView, toOffsetY targetY: CGFloat) {
        self.scrollView = scrollView
        targetOffsetY = targetY
        previousDistanceToTarget = nil
        stalledTickCount = 0
        guard displayLink == nil else {
            return
        }

        let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        previousDistanceToTarget = nil
        stalledTickCount = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView else {
            cancel()
            return
        }

        let clipView = scrollView.contentView
        let bounds = clipView.bounds

        let distanceToTarget = abs(targetOffsetY - bounds.origin.y)
        if let previousDistanceToTarget,
           distanceToTarget >= previousDistanceToTarget - 0.001
        {
            stalledTickCount += 1
            if stalledTickCount >= Self.maxStalledTicks {
                cancel()
                return
            }
        } else {
            stalledTickCount = 0
        }
        previousDistanceToTarget = distanceToTarget

        let frameInterval = link.targetTimestamp - link.timestamp
        let progress = 1 - exp(-CGFloat(frameInterval) / Self.timeConstant)
        var offsetY = bounds.origin.y + (targetOffsetY - bounds.origin.y) * progress
        if abs(targetOffsetY - offsetY) < 0.5 {
            offsetY = targetOffsetY
        }

        clipView.setBoundsOrigin(NSPoint(x: bounds.origin.x, y: offsetY))
        scrollView.reflectScrolledClipView(clipView)
        if offsetY == targetOffsetY {
            cancel()
        }
    }
}
