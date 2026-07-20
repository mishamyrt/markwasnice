import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class EditorShellState: ObservableObject {
    static let toolbarRevealHeight: CGFloat = 60
    static let toolbarCursorExclusionHeight: CGFloat = 52
    static let toolbarContentHeight: CGFloat = 50
    static let searchAreaHeight: CGFloat = 40
    static let replaceAreaHeight: CGFloat = 28

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
    @Published var searchQuery = ""
    @Published var searchOptions = EditorSearchOptions()
    @Published var searchMatchCount = 0
    @Published var selectedSearchMatchIndex: Int?
    @Published var searchFocusRequest = 0
    @Published var isReplaceEnabled = false
    @Published var replaceQuery = ""
    @Published var isPreviewActive = false

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

    var usesProminentBackdrop: Bool {
        isSearchPresented || isTabBarVisible
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

    /// Measured height of the auto-hidden fullscreen chrome overlay (the
    /// toolbar window with the tab bar, plus the menu bar where it overlaps
    /// the content); 0 until the toolbar window has been measured.
    var fullScreenChromeOverlayHeight: CGFloat = 0

    /// Estimates used before the fullscreen toolbar window exists, so the
    /// text does not start under the reveal zone during the transition:
    /// the unified toolbar row and the tab bar accessory row.
    static let fullScreenToolbarOverlayEstimate: CGFloat = 52
    static let fullScreenTabBarOverlayEstimate: CGFloat = 36

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

    func updateSearchResults(count: Int, selectedIndex: Int?) {
        searchMatchCount = count
        selectedSearchMatchIndex = selectedIndex
    }

    func selectNextSearchMatch() {
        onNextSearchMatch?()
    }

    func selectPreviousSearchMatch() {
        onPreviousSearchMatch?()
    }
}

struct EditorShellView: View {
    let editorView: MarkdownEditorView

    @ObservedObject private var state: EditorShellState
    @Environment(\.colorScheme) private var colorScheme

    init(editorView: MarkdownEditorView, state: EditorShellState) {
        self.editorView = editorView
        self.state = state
    }

    var body: some View {
        ZStack(alignment: .top) {
            MarkdownEditorRepresentable(editorView: editorView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !state.isFullScreen {
                topChromeBackdropLayer
            }

            VStack(spacing: 0) {
                if !state.isFullScreen {
                    toolbarHoverLayer
                }

                Spacer(minLength: 0)

                statusBar
                    .opacity(state.isStatusBarVisible ? 1 : 0)
                    .animation(
                        .easeInOut(duration: 0.1),
                        value: state.isStatusBarVisible
                    )
            }

            if !state.isFullScreen, state.isSearchPresented {
                windowedSearchLayer
            }

            if state.isFullScreen, state.isSearchPresented {
                fullScreenSearchLayer
            }
        }
        .background(
            ToolbarVisibilityBridge(
                isVisible: $state.isToolbarVisible,
                isSystemManaged: state.isFullScreen
            )
        )
        .background(Color(nsColor: editorBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            editorView.setChromeVisible(state.isToolbarVisible)
        }
        .onChange(of: state.isToolbarVisible) { _, isVisible in
            editorView.setChromeVisible(isVisible)
        }
    }

    private var topChromeBackdropLayer: some View {
        // Unmount the backdrop entirely while the chrome is hidden: a
        // CABackdropLayer can keep sampling the content beneath it even at
        // zero opacity, taxing every frame of a scroll. The opacity change
        // was not animated anyway, so conditional mounting looks identical.
        ZStack(alignment: .top) {
            if state.isToolbarVisible {
                BackdropBlurOverlay(isProminent: state.usesProminentBackdrop)
                    .frame(height: state.topChromeInsetHeight)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var toolbarHoverLayer: some View {
        ZStack(alignment: .top) {
            TopHoverTrackingBridge { isHovering in
                state.onTopHoverChanged?(isHovering)
            }
            .isDragEnabled(state.isToolbarVisible)
            .frame(height: EditorShellState.toolbarRevealHeight)

            EditorTopBarContent(state: state)
                .opacity(toolbarContentOpacity)
                .allowsHitTesting(state.isToolbarVisible)
                .animation(.easeOut(duration: 0.1), value: state.isToolbarVisible)
        }
        .frame(height: EditorShellState.toolbarRevealHeight)
    }

    private var windowedSearchLayer: some View {
        ZStack(alignment: .top) {
            EditorSearchBar(state: state)
                .frame(maxWidth: 785)
                .padding(.horizontal, 6)
        }
        .frame(height: state.searchBarHeight)
        .offset(
            y: state.isTabBarVisible
                ? state.tabBarTopInset
                : EditorShellState.toolbarRevealHeight
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var fullScreenSearchLayer: some View {
        ZStack(alignment: .top) {
            BackdropBlurOverlay(isProminent: true)
                .frame(height: state.searchBarHeight)
                .allowsHitTesting(false)

            EditorSearchBar(state: state)
                .padding(.leading, 132)
                .padding(.trailing, 78)
        }
        .frame(height: state.searchBarHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct EditorTopBarContent: View {
    @ObservedObject private var state: EditorShellState

    init(state: EditorShellState) {
        self.state = state
    }

    var body: some View {
        ZStack {
            EditorTopBarTitle(state: state)
                .frame(maxWidth: .infinity, alignment: .center)
            HStack(spacing: 14) {
                Spacer(minLength: 16)
                EditorTopBarControls(state: state)
            }
            .padding(.leading, 18)
            .padding(.trailing, 9)
            .frame(height: EditorShellState.toolbarContentHeight)
            .frame(maxWidth: .infinity)
        }
    }
}

struct EditorTopBarControls: View {
    @ObservedObject private var state: EditorShellState

    init(state: EditorShellState) {
        self.state = state
    }

    var body: some View {
        HStack(spacing: 14) {
            EditorTopBarFocusModeButton(state: state)
            EditorTopBarPreviewButton(state: state)
        }
    }
}

private struct EditorSearchBar: View {
    @ObservedObject private var state: EditorShellState

    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isReplaceFieldFocused: Bool

    init(state: EditorShellState) {
        self.state = state
    }

    var body: some View {
        // A grid keeps the find and replace fields the same width even
        // though each row trails a different set of controls.
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                searchField
                findControls
            }

            if state.isReplaceEnabled {
                GridRow {
                    replaceField
                    replaceControls
                }
            }
        }
        .frame(height: state.searchBarHeight)
        .onAppear {
            focusSearchField()
        }
        .onChange(of: state.searchFocusRequest) { _, _ in
            focusSearchField()
        }
        .onChange(of: state.isReplaceEnabled) { _, isEnabled in
            if isEnabled {
                isReplaceFieldFocused = true
            } else {
                isSearchFieldFocused = true
            }
        }
    }

    /// Cmd+F can arrive while the editor already owns first responder and
    /// the focus binding still reads true from the previous grab, making a
    /// plain re-set a no-op; on first presentation the field is not in the
    /// window yet when onAppear runs. Dropping the value and re-requesting
    /// on the next runloop turn produces a fresh false→true transition
    /// after the field exists, so the request lands in both cases.
    private func focusSearchField() {
        isSearchFieldFocused = false
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    private var findControls: some View {
        HStack(spacing: 8) {
            SearchSplitButton(
                isDisabled: state.searchMatchCount == 0,
                onFirst: { state.selectPreviousSearchMatch() },
                onSecond: { state.selectNextSearchMatch() }
            ) {
                Image(systemName: "chevron.left")
                    .frame(width: 16)
            } secondLabel: {
                Image(systemName: "chevron.right")
                    .frame(width: 16)
            }

            if state.isReplaceEnabled {
                doneButton.hidden()
            } else {
                doneButton
            }

            Toggle(
                "Replace",
                isOn: Binding(
                    get: { state.isReplaceEnabled },
                    set: { state.setReplaceEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 11, weight: .regular))
            .frame(height: 20)
        }
    }

    private var replaceControls: some View {
        HStack(spacing: 8) {
            SearchSplitButton(
                isDisabled: state.searchMatchCount == 0,
                onFirst: { state.replaceCurrentMatch() },
                onSecond: { state.replaceAllMatches() }
            ) {
                Text("Replace")
                    .padding(.horizontal, 10)
            } secondLabel: {
                Text("All")
                    .padding(.horizontal, 10)
            }

            doneButton
        }
    }

    private var doneButton: some View {
        SearchDoneButton {
            state.closeSearch()
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Menu {
                Button {
                    state.setSearchIgnoresCase(!state.searchOptions.ignoresCase)
                } label: {
                    Label {
                        Text("Ignore Case")
                    } icon: {
                        if state.searchOptions.ignoresCase {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(EditorSearchMode.allCases, id: \.self) { mode in
                    Button {
                        state.setSearchMode(mode)
                    } label: {
                        Label {
                            Text(mode.title)
                        } icon: {
                            if state.searchOptions.mode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 16, height: 18)
            }
            .buttonStyle(.plain)
            .menuStyle(.button)
            .fixedSize()

            TextField(
                "Find",
                text: Binding(
                    get: { state.searchQuery },
                    set: { state.setSearchQuery($0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isSearchFieldFocused)
            .onKeyPress(.escape) {
                state.closeSearch()
                return .handled
            }
            .onSubmit {
                state.selectNextSearchMatch()
            }

            if !state.searchQuery.isEmpty {
                Text("\(state.searchMatchCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                    .padding(.trailing, 3)
            }

            if !state.searchQuery.isEmpty {
                Button {
                    state.setSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.72))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    fieldBorderColor(isFocused: isSearchFieldFocused),
                    lineWidth: fieldBorderWidth(isFocused: isSearchFieldFocused)
                )
        )
    }

    private var replaceField: some View {
        HStack(spacing: 5) {
            TextField(
                "Replace",
                text: Binding(
                    get: { state.replaceQuery },
                    set: { state.replaceQuery = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($isReplaceFieldFocused)
            .onKeyPress(.escape) {
                state.closeSearch()
                return .handled
            }
            .onSubmit {
                state.replaceCurrentMatch()
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    fieldBorderColor(isFocused: isReplaceFieldFocused),
                    lineWidth: fieldBorderWidth(isFocused: isReplaceFieldFocused)
                )
        )
    }

    private func fieldBorderColor(isFocused: Bool) -> Color {
        isFocused
            ? Color(nsColor: .keyboardFocusIndicatorColor)
            : Color.primary.opacity(0.08)
    }

    private func fieldBorderWidth(isFocused: Bool) -> CGFloat {
        isFocused ? 3 : 1
    }
}

/// Done styled to match SearchMatchStepper: the bordered system button
/// cannot be sized to the 24pt control height the search bar uses.
private struct SearchDoneButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.16 : 0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Two actions fused into one control: a shared pill with a divider on the
/// segment boundary that yields to a per-segment hover highlight.
private struct SearchSplitButton<FirstLabel: View, SecondLabel: View>: View {
    private let isDisabled: Bool
    private let onFirst: () -> Void
    private let onSecond: () -> Void
    private let firstLabel: FirstLabel
    private let secondLabel: SecondLabel

    @State private var isFirstHovered = false
    @State private var isSecondHovered = false

    init(
        isDisabled: Bool,
        onFirst: @escaping () -> Void,
        onSecond: @escaping () -> Void,
        @ViewBuilder firstLabel: () -> FirstLabel,
        @ViewBuilder secondLabel: () -> SecondLabel
    ) {
        self.isDisabled = isDisabled
        self.onFirst = onFirst
        self.onSecond = onSecond
        self.firstLabel = firstLabel()
        self.secondLabel = secondLabel()
    }

    var body: some View {
        HStack(spacing: 0) {
            segment(firstLabel, isHovered: $isFirstHovered, action: onFirst)
            segment(secondLabel, isHovered: $isSecondHovered, action: onSecond)
                // Drawn as an overlay straddling the segment boundary so
                // the divider never adds to the control's width.
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(width: 1, height: 11)
                        .offset(x: -0.5)
                        .opacity(isDividerVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
        }
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var isDividerVisible: Bool {
        isDisabled || (!isFirstHovered && !isSecondHovered)
    }

    private func segment(
        _ label: some View,
        isHovered: Binding<Bool>,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(
                    isDisabled ? Color.secondary.opacity(0.5) : Color.primary
                )
                .frame(height: 20)
                .background {
                    if isHovered.wrappedValue, !isDisabled {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(Color.primary.opacity(0.1))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered.wrappedValue = $0 }
    }
}

private struct EditorTopBarFocusModeButton: View {
    @ObservedObject private var state: EditorShellState
    @State private var isIconHovered = false
    @State private var isChevronHovered = false

    init(state: EditorShellState) {
        self.state = state
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
                .frame(width: 3)
            Button {
                state.toggleFocusMode()
            } label: {
                EditorFocusModeIconView(width: 25, height: 22)
                    .foregroundStyle(iconColor)
                    .frame(width: 33, height: 36)
                    .background(iconBackground)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NoPressedAnimationStyle())
            .help(state.isFocusModeEnabled ? "Disable Focus Mode" : "Enable Focus Mode")
            .onHover { isIconHovered = $0 }

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1, height: 18)
                .opacity(isSeparatorVisible ? 1 : 0)

            Menu {
                ForEach(EditorFocusMode.allCases, id: \.self) { mode in
                    Button {
                        state.selectFocusMode(mode)
                    } label: {
                        Label {
                            Text(mode.title)
                        } icon: {
                            if state.focusMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .frame(width: 33, height: 36)
                    .background(chevronBackground)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(NoPressedAnimationStyle())
            .help("Focus Mode Options")
            .onHover { isChevronHovered = $0 }
            Spacer()
                .frame(width: 3)
        }
        .frame(height: 36)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private var iconColor: Color {
        .primary
    }

    private var isSeparatorVisible: Bool {
        !isIconHovered && !isChevronHovered && !state.isFocusModeEnabled
    }

    @ViewBuilder private var iconBackground: some View {
        if state.isFocusModeEnabled || isIconHovered {
            Capsule()
                .fill(Color.primary.opacity(iconBackgroundOpacity))
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
        }
    }

    private var iconBackgroundOpacity: Double {
        if state.isFocusModeEnabled {
            isIconHovered ? 0.14 : 0.08
        } else {
            0.08
        }
    }

    @ViewBuilder private var chevronBackground: some View {
        if isChevronHovered {
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .padding(.horizontal, 1)
                .padding(.vertical, 4)
        }
    }
}

private struct NoPressedAnimationStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct EditorFocusModeIconView: View {
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: width, height: height)
        } else {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(.system(size: 10, weight: .semibold))
        }
    }

    private static let image: NSImage? = {
        guard let url = Bundle.module.url(
            forResource: "text.line.middle.and.arrowtriangle",
            withExtension: "svg"
        ),
            let image = NSImage(contentsOf: url)
        else {
            return nil
        }

        image.isTemplate = true
        return image
    }()
}

struct EditorTopBarTitle: View {
    @ObservedObject private var state: EditorShellState

    init(state: EditorShellState) {
        self.state = state
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(state.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if state.isEdited {
                Text("•")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: 420)
    }
}

struct EditorTopBarPreviewButton: View {
    @ObservedObject private var state: EditorShellState

    init(state: EditorShellState) {
        self.state = state
    }

    var body: some View {
        EditorToolbarButton(
            systemName: "play.fill",
            help: state.isPreviewActive ? "Edit" : "Preview",
            isActive: state.isPreviewActive
        ) {
            state.togglePreview()
        }
    }
}

extension EditorShellView {
    private var toolbarContentOpacity: Double {
        state.isToolbarVisible ? 1 : 0
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Text(state.characterCountText)
            Text(state.wordCountText)
            Text(state.readingTimeText)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.trailing, 18)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: editorBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .allowsHitTesting(false)
    }

    /// Derived from the SwiftUI color scheme rather than NSApp's appearance:
    /// reading NSApp.effectiveAppearance here leaves SwiftUI unaware of the
    /// dependency, so the background would not refresh on theme changes.
    private var editorBackgroundColor: NSColor {
        let colors = EditorThemeColors.default
        return colorScheme == .dark ? colors.dark.background : colors.light.background
    }
}

private struct BackdropBlurOverlay: NSViewRepresentable {
    let isProminent: Bool

    func makeNSView(context _: Context) -> BackdropBlurView {
        let view = BackdropBlurView(frame: .zero)
        view.isProminent = isProminent
        return view
    }

    func updateNSView(_ view: BackdropBlurView, context _: Context) {
        view.isProminent = isProminent
    }
}

private struct EditorToolbarButton: View {
    let systemName: String
    let help: String
    var isDisabled = false
    var hasBackground = true
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background {
                    if isActive {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .padding(4)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .modifier(EditorToolbarButtonBackground(isVisible: hasBackground))
    }

    private var iconColor: Color {
        if isDisabled {
            Color.secondary.opacity(0.45)
        } else if isActive {
            Color.primary
        } else {
            Color.primary.opacity(0.72)
        }
    }
}

private struct EditorToolbarButtonBackground: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        if isVisible {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
        }
    }
}

private struct MarkdownEditorRepresentable: NSViewRepresentable {
    let editorView: MarkdownEditorView

    func makeNSView(context _: Context) -> MarkdownEditorView {
        editorView
    }

    func updateNSView(_: MarkdownEditorView, context _: Context) {}
}

private struct ToolbarVisibilityBridge: NSViewRepresentable {
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

private final class ToolbarVisibilityView: NSView {
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

private struct TopHoverTrackingBridge: NSViewRepresentable {
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

private final class TopHoverTrackingView: NSView {
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
        let height = min(EditorShellState.toolbarCursorExclusionHeight, bounds.height)
        let y = isFlipped ? bounds.minY : bounds.maxY - height
        return NSRect(
            x: bounds.minX,
            y: y,
            width: bounds.width,
            height: height
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
