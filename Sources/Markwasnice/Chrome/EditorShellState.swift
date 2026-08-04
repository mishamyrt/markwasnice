import SwiftUI

@MainActor
final class EditorShellState: ObservableObject {
    static let toolbarRevealHeight: CGFloat = 60
    static let toolbarBackgroundHeight: CGFloat = 52
    static let toolbarCursorExclusionHeight: CGFloat = 52
    static let toolbarContentHeight: CGFloat = 50
    static let searchAreaHeight: CGFloat = 40
    static let replaceAreaHeight: CGFloat = 28
    static let statusBarHeight: CGFloat = 28

    /// The hairline marking the bottom edge of the top chrome. Drawn twice —
    /// by the in-content band in SwiftUI and by the fullscreen toolbar window
    /// in AppKit — so the two cannot drift apart.
    static let topChromeSeparatorThickness: CGFloat = 0.67
    static let topChromeSeparatorOpacity: CGFloat = 0.05

    @Published var title = "Untitled"
    @Published var isEdited = false
    @Published var wordCount = 0
    @Published var characterCount = 0
    @Published var isToolbarVisible = true
    @Published var isStatusBarVisible = true
    @Published var isFullScreen = false
    @Published var isFocusModeEnabled = false
    @Published var focusMode: EditorFocusMode = .focus
    @Published var isProofreadingEnabled = false
    @Published var isSearchPresented = false
    @Published var isTabBarVisible = false
    @Published var tabBarTopInset: CGFloat = 0
    @Published var tabBarRowHeight = EditorShellState.tabBarRowHeightEstimate
    @Published var searchQuery = ""
    @Published var searchOptions = EditorSearchOptions()
    @Published var searchMatchCount = 0
    @Published var selectedSearchMatchIndex: Int?
    @Published var searchFocusRequest = 0
    @Published var isReplaceEnabled = false
    @Published var replaceQuery = ""
    @Published var isPreviewActive = false
    @Published var isContentScrolled = false

    var onTopHoverChanged: ((Bool) -> Void)?
    var onFocusModeEnabledChanged: ((Bool) -> Void)?
    var onFocusModeSelected: ((EditorFocusMode) -> Void)?
    var onProofreadingEnabledChanged: ((Bool) -> Void)?
    var onSearchPresentationChanged: ((Bool) -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?
    var onSearchOptionsChanged: ((EditorSearchOptions) -> Void)?
    var onNextSearchMatch: (() -> Void)?
    var onPreviousSearchMatch: (() -> Void)?
    var onReplaceEnabledChanged: ((Bool) -> Void)?
    var onReplaceMatch: (() -> Void)?
    var onReplaceAllMatches: (() -> Void)?
    var onPreviewActiveChanged: ((Bool) -> Void)?

    static let readingWordsPerMinute = 200.0

    var wordCountText: String {
        wordCount == 1 ? "1 word" : "\(wordCount) words"
    }

    var characterCountText: String {
        characterCount == 1 ? "1 character" : "\(characterCount) characters"
    }

    var readingTimeText: String {
        let seconds = Int(
            (Double(wordCount) / Self.readingWordsPerMinute * 60).rounded()
        )
        if seconds < 60 {
            return "\(seconds) sec"
        }

        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 {
            return "\(minutes) min"
        }

        return "\(Int((Double(minutes) / 60).rounded())) h"
    }

    var searchBarHeight: CGFloat {
        Self.searchAreaHeight + (isReplaceEnabled ? Self.replaceAreaHeight : 0)
    }

    /// The native tab bar accessory row keeps 8pt of empty space below the
    /// tab capsules; without the search area the chrome band ends tight
    /// under the capsules instead of highlighting that padding.
    static let tabBarBottomPadding: CGFloat = 8

    /// While the tab bar is visible the topbar content lives in the native
    /// NSToolbar above the tabs, so the in-content chrome band collapses to
    /// the system chrome height (toolbar + tab bar) plus the search area.
    var topChromeInsetHeight: CGFloat {
        guard isTabBarVisible else {
            return Self.toolbarRevealHeight
                + (isSearchPresented ? searchBarHeight : 0)
        }

        return isSearchPresented
            ? tabBarTopInset + searchBarHeight
            : max(0, tabBarTopInset - Self.tabBarBottomPadding)
    }

    /// The toolbar band is shorter than the reveal zone it lives in: the
    /// chrome itself is 52pt tall, while the hover reveal zone and the text
    /// inset keep the larger `toolbarRevealHeight` band. With tabs or the
    /// search bar the band height is dictated by that chrome instead.
    ///
    /// The tab bar row is deliberately left out of the band: AppKit gives the
    /// tab capsules glass of their own and keeps their row transparent, so the
    /// band stops where the toolbar row ends and the text keeps showing
    /// through behind the capsules — the way a native tab bar reads.
    var topChromeBackgroundHeight: CGFloat {
        guard !isTabBarVisible else {
            return max(0, tabBarTopInset - tabBarRowHeight)
        }

        return isSearchPresented
            ? topChromeInsetHeight
            : Self.toolbarBackgroundHeight
    }

    /// With the tab row left transparent the search bar can no longer share
    /// one band with the toolbar; it gets a band of its own below the tabs.
    var isSearchBandDetached: Bool {
        isTabBarVisible && isSearchPresented
    }

    /// The band ends tight above the tab capsules there, so a hairline would
    /// read as a line through the tab bar rather than as the chrome edge —
    /// with the tab bar up the detached search band carries it instead.
    var isTopChromeSeparatorVisible: Bool {
        isContentScrolled && !isTabBarVisible
    }

    /// Measured height of the auto-hidden fullscreen chrome overlay (the
    /// toolbar window with the tab bar, plus the menu bar where it overlaps
    /// the content); 0 until the toolbar window has been measured.
    var fullScreenChromeOverlayHeight: CGFloat = 0

    /// Estimates used before the fullscreen toolbar window exists, so the
    /// text does not start under the reveal zone during the transition:
    /// the unified toolbar row and the tab bar accessory row.
    static let fullScreenToolbarOverlayEstimate: CGFloat = 52
    static let fullScreenTabBarOverlayEstimate: CGFloat = tabBarRowHeightEstimate

    /// Height of the tab bar accessory row, used until the live one has been
    /// measured off the window's titlebar accessory.
    static let tabBarRowHeightEstimate: CGFloat = 36

    /// In fullscreen the system chrome slides down over the content on
    /// reveal; unscrolled text has to start below that band (and below the
    /// search bar when it is shown) so revealing never covers it.
    var fullScreenTopChromeInsetHeight: CGFloat {
        let overlayHeight =
            fullScreenChromeOverlayHeight > 0
                ? fullScreenChromeOverlayHeight
                : Self.fullScreenToolbarOverlayEstimate
                + (isTabBarVisible ? Self.fullScreenTabBarOverlayEstimate : 0)
        return max(overlayHeight, isSearchPresented ? searchBarHeight : 0)
    }

    var topChromeCursorExclusionHeight: CGFloat {
        if isTabBarVisible || isSearchPresented {
            topChromeInsetHeight
        } else {
            Self.toolbarCursorExclusionHeight
        }
    }

    func updateTitle(_ title: String, isEdited: Bool) {
        if self.title != title {
            self.title = title
        }
        if self.isEdited != isEdited {
            self.isEdited = isEdited
        }
    }

    func toggleFocusMode() {
        setFocusModeEnabled(!isFocusModeEnabled)
    }

    func setFocusModeEnabled(_ isEnabled: Bool) {
        guard isFocusModeEnabled != isEnabled else {
            return
        }

        isFocusModeEnabled = isEnabled
        onFocusModeEnabledChanged?(isEnabled)
    }

    func toggleProofreading() {
        setProofreadingEnabled(!isProofreadingEnabled)
    }

    func setProofreadingEnabled(_ isEnabled: Bool) {
        guard isProofreadingEnabled != isEnabled else {
            return
        }

        isProofreadingEnabled = isEnabled
        onProofreadingEnabledChanged?(isEnabled)
    }

    func selectFocusMode(_ mode: EditorFocusMode) {
        guard focusMode != mode else {
            return
        }

        focusMode = mode
        onFocusModeSelected?(mode)
    }

    func togglePreview() {
        setPreviewActive(!isPreviewActive)
    }

    func setPreviewActive(_ isActive: Bool) {
        guard isPreviewActive != isActive else {
            return
        }

        isPreviewActive = isActive
        onPreviewActiveChanged?(isActive)
    }

    func showSearch() {
        searchFocusRequest += 1
        guard !isSearchPresented else {
            return
        }

        isSearchPresented = true
        onSearchPresentationChanged?(true)
    }

    func closeSearch() {
        guard isSearchPresented else {
            return
        }

        isSearchPresented = false
        onSearchPresentationChanged?(false)
    }

    func setSearchQuery(_ query: String) {
        guard searchQuery != query else {
            return
        }

        searchQuery = query
        onSearchQueryChanged?(query)
    }

    func setSearchIgnoresCase(_ ignoresCase: Bool) {
        guard searchOptions.ignoresCase != ignoresCase else {
            return
        }

        searchOptions.ignoresCase = ignoresCase
        onSearchOptionsChanged?(searchOptions)
    }

    func setSearchMode(_ mode: EditorSearchMode) {
        guard searchOptions.mode != mode else {
            return
        }

        searchOptions.mode = mode
        onSearchOptionsChanged?(searchOptions)
    }

    func setReplaceEnabled(_ isEnabled: Bool) {
        guard isReplaceEnabled != isEnabled else {
            return
        }

        isReplaceEnabled = isEnabled
        onReplaceEnabledChanged?(isEnabled)
    }

    func replaceCurrentMatch() {
        onReplaceMatch?()
    }

    func replaceAllMatches() {
        onReplaceAllMatches?()
    }

    /// @Published fires objectWillChange even for equal values; this is
    /// called on every find keystroke and match step, so equal writes are
    /// skipped to avoid invalidating the whole SwiftUI shell.
    func updateSearchResults(count: Int, selectedIndex: Int?) {
        if searchMatchCount != count {
            searchMatchCount = count
        }
        if selectedSearchMatchIndex != selectedIndex {
            selectedSearchMatchIndex = selectedIndex
        }
    }

    func selectNextSearchMatch() {
        onNextSearchMatch?()
    }

    func selectPreviousSearchMatch() {
        onPreviousSearchMatch?()
    }
}
