import AppKit
import Testing
@testable import Markwasnice

/// The blurred chrome band and the text inset are deliberately different
/// heights once the tab bar is up: the text still starts below the capsules,
/// while the band stops above them so the tab row stays see-through.
@MainActor
struct TopChromeBandGeometryTests {
    private static let toolbarRowHeight: CGFloat = 52
    private static let tabBarRowHeight: CGFloat = 36
    private static let safeAreaTop: CGFloat = toolbarRowHeight + tabBarRowHeight

    private func stateWithTabBar() -> EditorShellState {
        let state = EditorShellState()
        state.isTabBarVisible = true
        state.tabBarTopInset = Self.safeAreaTop
        state.tabBarRowHeight = Self.tabBarRowHeight
        return state
    }

    @Test func bandStopsAboveTheTabRow() {
        let state = stateWithTabBar()
        #expect(state.topChromeBackgroundHeight == Self.toolbarRowHeight)
    }

    /// The band shrinking must not pull the text up under the capsules.
    @Test func textStillStartsBelowTheTabCapsules() {
        let state = stateWithTabBar()
        #expect(
            state.topChromeInsetHeight
                == Self.safeAreaTop - EditorShellState.tabBarBottomPadding
        )
    }

    /// Opening the find bar must not re-cover the tab row: the search band
    /// detaches below it instead of growing the toolbar band.
    @Test func searchBandDetachesBelowTheTabRow() {
        let state = stateWithTabBar()
        state.isSearchPresented = true
        #expect(state.isSearchBandDetached)
        #expect(state.topChromeBackgroundHeight == Self.toolbarRowHeight)
    }

    @Test func searchBandStaysAttachedWithoutTabs() {
        let state = EditorShellState()
        state.isSearchPresented = true
        #expect(!state.isSearchBandDetached)
        #expect(state.topChromeBackgroundHeight == state.topChromeInsetHeight)
    }

    /// Without tabs the band keeps the plain toolbar chrome height, shorter
    /// than the reveal zone it lives in.
    @Test func bandKeepsToolbarHeightWithoutTabs() {
        let state = EditorShellState()
        #expect(
            state.topChromeBackgroundHeight
                == EditorShellState.toolbarBackgroundHeight
        )
    }

    @Test func progressiveBlurIsLimitedToThePlainToolbar() {
        let state = EditorShellState()
        #expect(state.usesProgressiveToolbarBlur)

        state.isSearchPresented = true
        #expect(!state.usesProgressiveToolbarBlur)

        state.isSearchPresented = false
        state.isTabBarVisible = true
        #expect(!state.usesProgressiveToolbarBlur)
    }

    /// The hairline would cut between the toolbar and the tabs; with the tab
    /// bar up the detached search band carries it instead.
    @Test func separatorStaysHiddenBehindTheTabBar() {
        let state = stateWithTabBar()
        state.isContentScrolled = true
        #expect(!state.isTopChromeSeparatorVisible)

        state.isSearchPresented = true
        #expect(!state.isTopChromeSeparatorVisible)
    }

    @Test func separatorFollowsScrollWithoutTabs() {
        let state = EditorShellState()
        #expect(!state.isTopChromeSeparatorVisible)

        state.isContentScrolled = true
        #expect(state.isTopChromeSeparatorVisible)
    }
}

/// The single flip-aware band every top-chrome consumer measures — the reveal
/// rect and the toolbar's cursor exclusion both come from here, so the two can
/// no longer drift apart.
@MainActor
struct TopAlignedRectTests {
    private static let bounds = NSRect(x: 10, y: 20, width: 300, height: 200)

    @Test func flippedBandHangsFromTheMinYEdge() {
        let rect = TopChromeGeometry.topAlignedRect(
            height: 52, in: Self.bounds, isFlipped: true
        )
        #expect(rect == NSRect(x: 10, y: 20, width: 300, height: 52))
    }

    @Test func unflippedBandHangsFromTheMaxYEdge() {
        let rect = TopChromeGeometry.topAlignedRect(
            height: 52, in: Self.bounds, isFlipped: false
        )
        #expect(rect == NSRect(x: 10, y: 168, width: 300, height: 52))
    }

    /// A band taller than the view fills it instead of hanging outside.
    @Test func heightIsClampedToTheBounds() {
        for isFlipped in [true, false] {
            let rect = TopChromeGeometry.topAlignedRect(
                height: 500, in: Self.bounds, isFlipped: isFlipped
            )
            #expect(rect == Self.bounds)
        }
    }
}
