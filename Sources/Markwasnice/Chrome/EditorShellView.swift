import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class EditorShellState: ObservableObject {
    static let toolbarRevealHeight: CGFloat = 86
    static let toolbarCursorExclusionHeight: CGFloat = 52
    static let toolbarContentHeight: CGFloat = 50

    @Published var title = "Untitled"
    @Published var isEdited = false
    @Published var wordCount = 0
    @Published var isToolbarVisible = true
    @Published var isStatusBarVisible = true
    @Published var isFullScreen = false
    @Published var isFocusModeEnabled = false
    @Published var focusMode: EditorFocusMode = .focus

    var onTopHoverChanged: ((Bool) -> Void)?
    var onFocusModeEnabledChanged: ((Bool) -> Void)?
    var onFocusModeSelected: ((EditorFocusMode) -> Void)?

    var wordCountText: String {
        wordCount == 1 ? "1 word" : "\(wordCount) words"
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

            BackdropBlurOverlay()
                .frame(height: EditorShellState.toolbarRevealHeight)
                .opacity(toolbarContentOpacity)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.1), value: state.isToolbarVisible)

            EditorTopBarContent(state: state)
                .opacity(toolbarContentOpacity)
                .allowsHitTesting(state.isToolbarVisible)
                .animation(.easeOut(duration: 0.1), value: state.isToolbarVisible)
        }
        .frame(height: EditorShellState.toolbarRevealHeight)
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
