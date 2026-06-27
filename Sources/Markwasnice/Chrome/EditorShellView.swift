import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class EditorShellState: ObservableObject {
    static let toolbarRevealHeight: CGFloat = 60
    static let toolbarCursorExclusionHeight: CGFloat = 52
    static let toolbarContentHeight: CGFloat = 50
    static let searchAreaHeight: CGFloat = 40

    @Published var title = "Untitled"
    @Published var isEdited = false
    @Published var wordCount = 0
    @Published var isToolbarVisible = true
    @Published var isStatusBarVisible = true
    @Published var isFullScreen = false
    @Published var isFocusModeEnabled = false
    @Published var focusMode: EditorFocusMode = .focus
    @Published var isSearchPresented = false
    @Published var searchQuery = ""
    @Published var searchOptions = EditorSearchOptions()
    @Published var searchMatchCount = 0
    @Published var selectedSearchMatchIndex: Int?
    @Published var searchFocusRequest = 0

    var onTopHoverChanged: ((Bool) -> Void)?
    var onFocusModeEnabledChanged: ((Bool) -> Void)?
    var onFocusModeSelected: ((EditorFocusMode) -> Void)?
    var onSearchPresentationChanged: ((Bool) -> Void)?
    var onSearchQueryChanged: ((String) -> Void)?
    var onSearchOptionsChanged: ((EditorSearchOptions) -> Void)?
    var onNextSearchMatch: (() -> Void)?
    var onPreviousSearchMatch: (() -> Void)?

    var wordCountText: String {
        wordCount == 1 ? "1 word" : "\(wordCount) words"
    }

    var topChromeInsetHeight: CGFloat {
        Self.toolbarRevealHeight + (isSearchPresented ? Self.searchAreaHeight : 0)
    }

    var topChromeCursorExclusionHeight: CGFloat {
        isSearchPresented ? topChromeInsetHeight : Self.toolbarCursorExclusionHeight
    }

    func updateTitle(_ title: String, isEdited: Bool) {
        self.title = title
        self.isEdited = isEdited
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

    func selectFocusMode(_ mode: EditorFocusMode) {
        guard focusMode != mode else {
            return
        }

        focusMode = mode
        onFocusModeSelected?(mode)
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

    init(editorView: MarkdownEditorView, state: EditorShellState) {
        self.editorView = editorView
        self.state = state
    }

    var body: some View {
        ZStack(alignment: .top) {
            MarkdownEditorRepresentable(editorView: editorView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .background(Color(nsColor: Self.editorBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            editorView.setChromeVisible(state.isToolbarVisible)
        }
        .onChange(of: state.isToolbarVisible) { _, isVisible in
            editorView.setChromeVisible(isVisible)
        }
    }

    private var toolbarHoverLayer: some View {
        ZStack(alignment: .top) {
            TopHoverTrackingBridge { isHovering in
                state.onTopHoverChanged?(isHovering)
            }
            .isDragEnabled(state.isToolbarVisible)
            .frame(height: EditorShellState.toolbarRevealHeight)

            BackdropBlurOverlay(isSearchActive: state.isSearchPresented)
                .frame(height: EditorShellState.toolbarRevealHeight)
                .opacity(toolbarContentOpacity)
                .allowsHitTesting(false)

            EditorTopBarContent(state: state)
                .opacity(toolbarContentOpacity)
                .allowsHitTesting(state.isToolbarVisible)
                .animation(.easeOut(duration: 0.1), value: state.isToolbarVisible)
        }
        .frame(height: EditorShellState.toolbarRevealHeight)
    }

    private var windowedSearchLayer: some View {
        ZStack(alignment: .top) {
            BackdropBlurOverlay(isSearchActive: true)
                .frame(height: EditorShellState.searchAreaHeight)
                .allowsHitTesting(false)

            EditorSearchBar(state: state)
                .padding(.leading, 132)
                .padding(.trailing, 78)
        }
        .frame(height: EditorShellState.searchAreaHeight)
        .offset(y: EditorShellState.toolbarRevealHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var fullScreenSearchLayer: some View {
        ZStack(alignment: .top) {
            BackdropBlurOverlay(isSearchActive: true)
                .frame(height: EditorShellState.searchAreaHeight)
                .allowsHitTesting(false)

            EditorSearchBar(state: state)
                .padding(.leading, 132)
                .padding(.trailing, 78)
        }
        .frame(height: EditorShellState.searchAreaHeight)
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
            EditorTopBarPreviewButton()
        }
    }
}

private struct EditorSearchBar: View {
    @ObservedObject private var state: EditorShellState

    @FocusState private var isSearchFieldFocused: Bool

    init(state: EditorShellState) {
        self.state = state
    }

    var body: some View {
        HStack(spacing: 8) {
            searchField

            HStack(spacing: 2) {
                Button {
                    state.selectPreviousSearchMatch()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 22)
                }
                .disabled(state.searchMatchCount == 0)

                Button {
                    state.selectNextSearchMatch()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 22)
                }
                .disabled(state.searchMatchCount == 0)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary.opacity(0.66))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            Button("Done") {
                state.closeSearch()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.82))
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
            )

            Toggle("Replace", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .font(.system(size: 11, weight: .medium))
                .disabled(true)
        }
        .frame(height: EditorShellState.searchAreaHeight)
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: state.searchFocusRequest) { _, _ in
            isSearchFieldFocused = true
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
                .stroke(searchFieldBorderColor, lineWidth: searchFieldBorderWidth)
        )
    }

    private var searchFieldBorderColor: Color {
        isSearchFieldFocused
            ? Color(nsColor: .keyboardFocusIndicatorColor)
            : Color.primary.opacity(0.08)
    }

    private var searchFieldBorderWidth: CGFloat {
        isSearchFieldFocused ? 3 : 1
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
                    .font(.system(size: 11, weight: .semibold))
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
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: 420)
    }
}

struct EditorTopBarPreviewButton: View {
    var body: some View {
        EditorToolbarButton(systemName: "play.fill", help: "Preview", isDisabled: true) {}
    }
}

extension EditorShellView {
    private var toolbarContentOpacity: Double {
        state.isToolbarVisible ? 1 : 0
    }

    private var statusBar: some View {
        HStack {
            Spacer(minLength: 0)
            Text(state.wordCountText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 18)
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
    }

    private static var editorBackgroundColor: NSColor {
        EditorThemeColors.default.variant(for: NSApp.effectiveAppearance).background
    }
}

private struct BackdropBlurOverlay: NSViewRepresentable {
    let isSearchActive: Bool

    func makeNSView(context _: Context) -> BackdropBlurView {
        let view = BackdropBlurView(frame: .zero)
        view.isSearchActive = isSearchActive
        return view
    }

    func updateNSView(_ view: BackdropBlurView, context _: Context) {
        view.isSearchActive = isSearchActive
    }
}

private struct EditorToolbarButton: View {
    let systemName: String
    let help: String
    var isDisabled = false
    var hasBackground = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    isDisabled
                        ? Color.secondary.opacity(0.45)
                        : Color.primary
                        .opacity(0.72)
                )
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .modifier(EditorToolbarButtonBackground(isVisible: hasBackground))
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
            if !isSystemManaged, window.toolbar == nil {
                let toolbar = NSToolbar()
                toolbar.allowsUserCustomization = false
                toolbar.displayMode = .iconOnly
                window.toolbar = toolbar
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

        window?.performDrag(with: event)
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
