import AppKit
import SwiftUI

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

                statusBarHoverLayer
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
            updateEditorChromeVisibility()
        }
        .onChange(of: state.isToolbarVisible) { _, _ in
            updateEditorChromeVisibility()
        }
        .onChange(of: state.isStatusBarVisible) { _, _ in
            updateEditorChromeVisibility()
        }
    }

    private var topChromeBackdropLayer: some View {
        // Unmount the backdrop entirely while the chrome is hidden: a
        // CABackdropLayer can keep sampling the content beneath it even at
        // zero opacity, taxing every frame of a scroll. The opacity change
        // was not animated anyway, so conditional mounting looks identical.
        ZStack(alignment: .top) {
            if state.isToolbarVisible {
                BackdropBlurOverlay()
                    .frame(height: state.topChromeBackgroundHeight)
                    .overlay(alignment: .bottom) {
                        topChromeSeparator(
                            isVisible: state.isTopChromeSeparatorVisible
                        )
                    }
                    .allowsHitTesting(false)

                // The tab row between the two bands stays clear on purpose,
                // so the text scrolls on behind the capsules.
                if state.isSearchBandDetached {
                    BackdropBlurOverlay()
                        .frame(height: state.searchBarHeight)
                        .overlay(alignment: .bottom) {
                            topChromeSeparator(isVisible: state.isContentScrolled)
                        }
                        .offset(y: state.tabBarTopInset)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Only marks the chrome edge once content has moved under it; at the
    /// top of the document the band and the text share one flat surface.
    private func topChromeSeparator(isVisible: Bool) -> some View {
        Rectangle()
            .fill(
                Color.primary
                    .opacity(EditorShellState.topChromeSeparatorOpacity)
            )
            .frame(height: EditorShellState.topChromeSeparatorThickness)
            .opacity(isVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.1), value: isVisible)
    }

    private var toolbarHoverLayer: some View {
        ZStack(alignment: .top) {
            HoverTrackingBridge { isHovering in
                state.onToolbarHoverChanged?(isHovering)
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
            BackdropBlurOverlay()
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
        guard let url = ResourceBundle.current.url(
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
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            statusMetric(state.characterCountText)
            statusMetric(state.wordCountText)
            statusMetric(state.sentenceCountText)
            statusMetric(state.readingTimeText)
            statusMetric(state.speakingTimeText)
        }
        .font(.body)
        .foregroundStyle(Color(nsColor: editorForegroundColor))
        .padding(.trailing, 18)
        .frame(height: EditorShellState.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: editorBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .allowsHitTesting(false)
    }

    private func statusMetric(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(
                        state.selectionStatistics == nil
                            ? Color.clear
                            : Color(nsColor: editorSelectionColor)
                    )
            }
    }

    private var statusBarHoverLayer: some View {
        ZStack {
            HoverTrackingBridge { isHovering in
                state.onStatusBarHoverChanged?(isHovering)
            }

            statusBar
                .opacity(state.isStatusBarVisible ? 1 : 0)
                .animation(
                    .easeInOut(duration: 0.1),
                    value: state.isStatusBarVisible
                )
        }
        .frame(height: EditorShellState.statusBarHeight)
    }

    private func updateEditorChromeVisibility() {
        editorView.setChromeVisibility(
            toolbarVisible: state.isToolbarVisible,
            statusBarVisible: state.isStatusBarVisible
        )
    }

    private var editorForegroundColor: NSColor {
        let colors = EditorThemeColors.default
        return colorScheme == .dark ? colors.dark.foreground : colors.light.foreground
    }

    /// Derived from the SwiftUI color scheme rather than NSApp's appearance:
    /// reading NSApp.effectiveAppearance here leaves SwiftUI unaware of the
    /// dependency, so the background would not refresh on theme changes.
    private var editorBackgroundColor: NSColor {
        let colors = EditorThemeColors.default
        return colorScheme == .dark ? colors.dark.background : colors.light.background
    }

    private var editorSelectionColor: NSColor {
        let colors = EditorThemeColors.default
        return colorScheme == .dark ? colors.dark.selection : colors.light.selection
    }
}

private struct BackdropBlurOverlay: NSViewRepresentable {
    func makeNSView(context _: Context) -> BackdropBlurView {
        BackdropBlurView(frame: .zero)
    }

    func updateNSView(_: BackdropBlurView, context _: Context) {}
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
