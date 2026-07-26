import AppKit
import Testing
@testable import Markwasnice

/// The fullscreen toolbar's visibility is a pure function of where AppKit
/// parked its window. These pin the positions that are legitimate — fully
/// revealed, and fully revealed pushed down under the slid-in menu bar —
/// against the ones that must stay invisible.
struct FullScreenToolbarGeometryTests {
    private static let toolbarHeight: CGFloat = 52
    private static let toolbarWithTabBarHeight: CGFloat = 88

    @Test(arguments: [CGFloat(0), 12, 29, 40])
    func parkedSliversStayInvisible(band: CGFloat) {
        let alpha = FullScreenToolbarController.fadeAlpha(
            band: band,
            height: Self.toolbarHeight,
            revealAllowance: 0
        )
        #expect(alpha == 0)
    }

    /// The regression: a reveal rests exactly one menu-bar overlap below the
    /// fully revealed spot, and used to fade (44pt) or vanish (72pt) there.
    @Test(arguments: [CGFloat(0), 24, 37, 44, 72])
    func revealPushedDownByTheMenuBarStaysOpaque(allowance: CGFloat) {
        let alpha = FullScreenToolbarController.fadeAlpha(
            band: Self.toolbarHeight + allowance,
            height: Self.toolbarHeight,
            revealAllowance: allowance
        )
        #expect(alpha == 1)
    }

    @Test
    func revealWithTabBarStaysOpaque() {
        let alpha = FullScreenToolbarController.fadeAlpha(
            band: Self.toolbarWithTabBarHeight + 44,
            height: Self.toolbarWithTabBarHeight,
            revealAllowance: 44
        )
        #expect(alpha == 1)
    }

    @Test
    func revealZoneRampsIn() {
        let alpha = FullScreenToolbarController.fadeAlpha(
            band: 56,
            height: Self.toolbarWithTabBarHeight,
            revealAllowance: 0
        )
        #expect(abs(alpha - 0.5) < 0.0001)
    }

    /// A toolbar window shorter than the fade span still has to be opaque
    /// once it is all the way out — the ramp ends at the revealed position
    /// rather than at a fixed offset.
    @Test
    func shortToolbarIsOpaqueWhenFullyRevealed() {
        let alpha = FullScreenToolbarController.fadeAlpha(
            band: Self.toolbarHeight,
            height: Self.toolbarHeight,
            revealAllowance: 0
        )
        #expect(alpha == 1)
    }

    @Test
    func pastTheAllowanceFadesBackOut() {
        let height = Self.toolbarHeight
        let allowance: CGFloat = 44
        let halfway = FullScreenToolbarController.fadeAlpha(
            band: height + allowance + 56,
            height: height,
            revealAllowance: allowance
        )
        #expect(abs(halfway - 0.5) < 0.0001)

        let gone = FullScreenToolbarController.fadeAlpha(
            band: height + allowance + 72,
            height: height,
            revealAllowance: allowance
        )
        #expect(gone == 0)
    }

    /// A taller menu bar widens the plateau, never the parked spot: the
    /// sliver AppKit leaves on screen has to stay invisible either way.
    @Test
    func allowanceDoesNotLiftTheRiseSide() {
        let alpha = FullScreenToolbarController.fadeAlpha(
            band: 40,
            height: Self.toolbarHeight,
            revealAllowance: 44
        )
        #expect(alpha == 0)
    }

    /// AppKit creates a new tab's toolbar window at the screen origin, so its
    /// band is a whole screen height — an order of magnitude past the plateau.
    @Test(arguments: [CGFloat(768), 900, 1080, 1440, 1692])
    func bottomBornToolbarWindowStaysInvisible(band: CGFloat) {
        let alpha = FullScreenToolbarController.fadeAlpha(
            band: band,
            height: Self.toolbarWithTabBarHeight,
            revealAllowance: 44
        )
        #expect(alpha == 0)
    }

    /// The invariant that makes clamping a stray toolbar window invisible:
    /// at the clamp floor the fade has already reached 0.
    @Test(arguments: [CGFloat(0), 24, 44, 72])
    func clampFloorMatchesTheFadeDropOff(allowance: CGFloat) {
        let height = Self.toolbarHeight
        let floorOffset = FullScreenToolbarController.revealFloorOffset(
            revealAllowance: allowance
        )
        let alpha = FullScreenToolbarController.fadeAlpha(
            band: height + floorOffset,
            height: height,
            revealAllowance: allowance
        )
        #expect(alpha == 0)
    }

    @Test
    func windowFlushWithTheScreenTopTakesTheWholeMenuBar() {
        let overlap = FullScreenToolbarController.menuBarOverlap(
            menuBarHeight: 44,
            windowMaxY: 1200,
            screenMaxY: 1200
        )
        #expect(overlap == 44)
    }

    /// Notched displays reserve a band for the menu bar; the fullscreen
    /// window stops below it, so nothing ever slides over the content.
    @Test
    func reservedMenuBarBandLeavesNoOverlap() {
        let overlap = FullScreenToolbarController.menuBarOverlap(
            menuBarHeight: 44,
            windowMaxY: 1156,
            screenMaxY: 1200
        )
        #expect(overlap == 0)
    }

    @Test
    func partiallyReservedBandOverlapsTheRemainder() {
        let overlap = FullScreenToolbarController.menuBarOverlap(
            menuBarHeight: 44,
            windowMaxY: 1180,
            screenMaxY: 1200
        )
        #expect(overlap == 24)
    }

    @Test
    func overlapNeverGoesNegative() {
        let overlap = FullScreenToolbarController.menuBarOverlap(
            menuBarHeight: 44,
            windowMaxY: 1140,
            screenMaxY: 1200
        )
        #expect(overlap == 0)
    }

    /// NSEvent.mouseLocation puts the top row of a display at exactly
    /// screen.frame.maxY, which plain CGRect.contains reports as outside.
    @Test
    func pointerOnTheTopRowBelongsToTheScreen() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1200)
        #expect(FullScreenToolbarController.pointerBelongsToScreen(
            pointer: NSPoint(x: 960, y: 1200),
            screenFrame: screenFrame
        ))
        #expect(FullScreenToolbarController.pointerBelongsToScreen(
            pointer: NSPoint(x: 960, y: 0),
            screenFrame: screenFrame
        ))
        #expect(FullScreenToolbarController.pointerBelongsToScreen(
            pointer: NSPoint(x: 1920, y: 600),
            screenFrame: screenFrame
        ))
    }

    @Test
    func pointerOnANeighbouringScreenDoesNot() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1200)
        #expect(!FullScreenToolbarController.pointerBelongsToScreen(
            pointer: NSPoint(x: 960, y: 1205),
            screenFrame: screenFrame
        ))
        #expect(!FullScreenToolbarController.pointerBelongsToScreen(
            pointer: NSPoint(x: 2400, y: 600),
            screenFrame: screenFrame
        ))
    }
}
