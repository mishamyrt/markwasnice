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
