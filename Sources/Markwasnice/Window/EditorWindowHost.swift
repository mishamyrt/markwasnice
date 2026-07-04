@preconcurrency import AppKit
import Combine
import ObjectiveC
import SwiftUI

enum EditorWindowTabbing {
    static let identifier = "Markwasnice.EditorWindow"
}

/// SwiftUI's own window controller sits ahead of the window delegate in the
/// responder chain and handles newWindowForTab: itself by opening a WindowGroup
/// window with a nil scene value. That window finds no session, dismisses
/// itself mid tab-insertion and corrupts the tab group state, crashing the app
/// on the next "+" click. Rerouting the controller's implementation into
/// requestNewTab keeps the native "+" button and system New Tab functional.
@MainActor
private enum NewTabActionInterceptor {
    private(set) weak static var appState: MarkwasniceAppState?
    private static var isInstalled = false

    static func installIfNeeded(
        on windowController: NSWindowController,
        appState: MarkwasniceAppState
    ) {
        Self.appState = appState
        guard !isInstalled else {
            return
        }

        let selector = NSSelectorFromString("newWindowForTab:")
        guard windowController.responds(to: selector),
              let method = class_getInstanceMethod(
                  type(of: windowController),
                  selector
              )
        else {
            return
        }

        isInstalled = true
        let block: @convention(block) (NSWindowController, Any?) -> Void = {
            controller, _ in
            MainActor.assumeIsolated {
                Self.appState?.requestNewTab(attachedTo: controller.window)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

struct EditorWindowHost: View {
    @Binding var sessionID: EditorDocumentSession.ID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: MarkwasniceAppState

    var body: some View {
        Group {
            if let session = appState.session(for: sessionID) {
                EditorWindowView(session: session)
            } else {
                ProgressView()
                    .task {
                        guard let id = await appState.initialSessionID() else {
                            dismiss()
                            return
                        }

                        sessionID = id
                        openPendingWindows()
                    }
            }
        }
        .onChange(of: appState.pendingWindowIDs) { _, _ in
            openPendingWindows()
        }
    }

    private func openPendingWindows() {
        for id in appState.takePendingWindowIDs() where id != sessionID {
            openWindow(value: id)
        }
    }
}

private struct EditorWindowView: View {
    @ObservedObject private var session: EditorDocumentSession

    @EnvironmentObject private var appState: MarkwasniceAppState

    init(session: EditorDocumentSession) {
        self.session = session
    }

    var body: some View {
        EditorShellView(editorView: session.editorView, state: session.shellState)
            .background(WindowLifecycleBridge(session: session, appState: appState))
            .background(
                WindowWidthBridge { width in
                    session.updateWindowWidth(width)
                }
            )
            .onAppear {
                appState.activate(session)
            }
    }
}

private struct WindowWidthBridge: NSViewRepresentable {
    let onWidthChanged: (CGFloat) -> Void

    func makeNSView(context _: Context) -> WindowWidthView {
        let view = WindowWidthView(frame: .zero)
        view.onWidthChanged = onWidthChanged
        return view
    }

    func updateNSView(_ view: WindowWidthView, context _: Context) {
        view.onWidthChanged = onWidthChanged
    }
}

private final class WindowWidthView: NSView {
    var onWidthChanged: ((CGFloat) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWidthChanged?(window?.frame.width ?? bounds.width)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onWidthChanged?(window?.frame.width ?? newSize.width)
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

private struct WindowLifecycleBridge: NSViewRepresentable {
    let session: EditorDocumentSession
    let appState: MarkwasniceAppState

    func makeNSView(context _: Context) -> WindowLifecycleView {
        let view = WindowLifecycleView(frame: .zero)
        view.session = session
        view.appState = appState
        return view
    }

    func updateNSView(_ view: WindowLifecycleView, context _: Context) {
        view.session = session
        view.appState = appState
    }
}

private final class WindowLifecycleView: NSView {
    var session: EditorDocumentSession?
    var appState: MarkwasniceAppState?

    private let delegateProxy = WindowDelegateProxy()
    private let chromeToolbarController = ChromeToolbarController()
    private var didConfigureWindow = false
    private var tabGroupObservation: NSKeyValueObservation?
    private var contentLayoutObservation: NSKeyValueObservation?
    private var titleCancellable: AnyCancellable?
    private weak var observedFullScreenToolbarWindow: NSWindow?
    private var strayToolbarCheckWorkItem: DispatchWorkItem?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tabGroupObservation = nil
            contentLayoutObservation = nil
            titleCancellable = nil
            stopObservingFullScreenToolbarWindow()
        }
        configureWindowIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWindowBackground()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    private func applyWindowBackground() {
        guard let window else {
            return
        }

        window.backgroundColor =
            EditorThemeColors.default
                .variant(for: window.effectiveAppearance)
                .background
    }

    private func configureWindowIfNeeded() {
        guard let window, let session, let appState else {
            return
        }

        delegateProxy.session = session
        delegateProxy.appState = appState
        delegateProxy.chromeToolbarController = chromeToolbarController
        chromeToolbarController.session = session
        window.delegate = delegateProxy
        window.title = session.title
        window.tabbingIdentifier = EditorWindowTabbing.identifier
        window.tabbingMode = .automatic
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        if window.toolbar == nil {
            let toolbar = NSToolbar()
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        applyWindowBackground()
        window.contentMinSize = NSSize(width: 640, height: 420)

        if let windowController = window.windowController {
            NewTabActionInterceptor.installIfNeeded(
                on: windowController,
                appState: appState
            )
        }

        observeTabChrome(of: window, session: session)
        observeTitle(of: window, shellState: session.shellState)

        if !didConfigureWindow {
            didConfigureWindow = true
            placeWindow(window, session: session, appState: appState, attempt: 0)
        }
    }

    private func placeWindow(
        _ window: NSWindow,
        session: EditorDocumentSession,
        appState: MarkwasniceAppState,
        attempt: Int
    ) {
        if let target = appState.takeTabAttachTarget(for: session.id),
           target !== window, target.isVisible
        {
            target.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)

            // A window attached to a fullscreen group becomes fullscreen
            // instantly, without the windowWillEnterFullScreen transition,
            // so the session state and the fullscreen toolbar have to be
            // set up here by hand.
            if window.styleMask.contains(.fullScreen),
               !session.shellState.isFullScreen
            {
                session.setFullScreen(true)
                chromeToolbarController.install(in: window)
            }
            return
        }

        // A restored tab group's lead window may not have materialized yet
        // when its followers configure during launch; retry briefly.
        if appState.hasPendingRestoreTabLead(for: session.id) {
            guard attempt < 20 else {
                appState.abandonRestoreTabLead(for: session.id)
                window.setContentSize(NSSize(width: 960, height: 640))
                window.center()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                [weak self, weak window, weak session, weak appState] in
                guard let self, let window, let session, let appState else {
                    return
                }

                self.placeWindow(
                    window,
                    session: session,
                    appState: appState,
                    attempt: attempt + 1
                )
            }
            return
        }

        window.setContentSize(NSSize(width: 960, height: 640))
        window.center()
    }

    private func observeTabChrome(
        of window: NSWindow,
        session _: EditorDocumentSession
    ) {
        tabGroupObservation = window.observe(
            \.tabGroup?.isTabBarVisible,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshTabChrome()
            }
        }
        contentLayoutObservation = window.observe(
            \.contentLayoutRect,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshTabChrome()
            }
        }
    }

    private func observeTitle(
        of window: NSWindow,
        shellState: EditorShellState
    ) {
        titleCancellable = shellState.$title
            .combineLatest(shellState.$isEdited)
            .sink { [weak self, weak window] title, isEdited in
                guard let window, self?.window === window else {
                    return
                }

                window.title = title
                window.isDocumentEdited = isEdited
            }
    }

    private func refreshTabChrome() {
        guard let window, let session else {
            return
        }

        // SwiftUI may attach the window controller after the initial
        // window configuration pass.
        if let windowController = window.windowController, let appState {
            NewTabActionInterceptor.installIfNeeded(
                on: windowController,
                appState: appState
            )
        }

        updateFullScreenToolbarMonitor()

        // The chrome auto-hide temporarily collapses the tab bar (via its
        // titlebar accessory, so isTabBarVisible stays true); keep the
        // logical tab chrome (insets, backdrop) frozen so the text does not
        // shift and the reveal restores everything in place.
        if session.isTabBarTemporarilyHidden {
            return
        }

        let isTabBarVisible = window.tabGroup?.isTabBarVisible ?? false
        let topInset = isTabBarVisible && !session.shellState.isFullScreen
            ? (window.contentView?.safeAreaInsets.top ?? 0)
            : 0
        session.setTabBarChrome(isVisible: isTabBarVisible, topInset: topInset)
    }

    /// When the tab bar appears inside a fullscreen window (manually or by
    /// adding a tab), AppKit's auto-hide can retract the NSToolbarFullScreenWindow
    /// by its pre-tab-bar height, leaving a strip of it stuck on screen. A
    /// settled toolbar window only has two valid resting positions — fully
    /// hidden, or fully revealed (the latter only for the selected tab); once
    /// it stops moving anywhere in between, clamp it fully off-screen.
    private func updateFullScreenToolbarMonitor() {
        guard let window,
              window.styleMask.contains(.fullScreen),
              let toolbarWindow = window.childWindows?.first(where: {
                  String(describing: type(of: $0)) == "NSToolbarFullScreenWindow"
              })
        else {
            stopObservingFullScreenToolbarWindow()
            return
        }

        if toolbarWindow !== observedFullScreenToolbarWindow {
            stopObservingFullScreenToolbarWindow()
            observedFullScreenToolbarWindow = toolbarWindow
            for name in [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(fullScreenToolbarWindowDidMove),
                    name: name,
                    object: toolbarWindow
                )
            }
        }

        scheduleStrayToolbarWindowCheck()
    }

    private func stopObservingFullScreenToolbarWindow() {
        strayToolbarCheckWorkItem?.cancel()
        strayToolbarCheckWorkItem = nil
        guard let observedFullScreenToolbarWindow else {
            return
        }

        NotificationCenter.default.removeObserver(
            self,
            name: nil,
            object: observedFullScreenToolbarWindow
        )
        self.observedFullScreenToolbarWindow = nil
    }

    @objc private func fullScreenToolbarWindowDidMove(_: Notification) {
        if let window, let toolbarWindow = observedFullScreenToolbarWindow {}
        scheduleStrayToolbarWindowCheck()
    }

    /// Debounced so reveal/hide animations, which move the window through
    /// intermediate positions every frame, are never interfered with.
    private func scheduleStrayToolbarWindowCheck(after delay: TimeInterval = 0.4) {
        strayToolbarCheckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clampStrayFullScreenToolbarWindow()
        }
        strayToolbarCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clampStrayFullScreenToolbarWindow() {
        guard let window,
              window.styleMask.contains(.fullScreen),
              let toolbarWindow = observedFullScreenToolbarWindow
        else {
            return
        }

        let hiddenY = window.frame.maxY
        let minY = toolbarWindow.frame.minY

        // Fully hidden — nothing to do.
        if minY >= hiddenY - 0.5 {
            return
        }

        let isSelectedTab = window.tabGroup.map { $0.selectedWindow === window }
            ?? true
        if isSelectedTab {
            // Fully revealed — legitimate only while the pointer is near the
            // top of the screen keeping the reveal alive. A toolbar window
            // born into an already-fullscreen group is not enrolled in
            // AppKit's auto-hide, so once the pointer leaves it just stays;
            // that is the stuck strip.
            let revealedY = hiddenY - toolbarWindow.frame.height
            if abs(minY - revealedY) < 0.5,
               NSEvent.mouseLocation.y >= revealedY - 250
            {
                // No move events arrive when the pointer leaves; keep
                // re-checking while the window remains on screen.
                scheduleStrayToolbarWindowCheck(after: 1.5)
                return
            }

            // Parked with just the tab bar row on screen — legitimate only
            // while that strip actually renders the tab bar. Applies to the
            // tab-bar-sized strip only, not to a fully revealed window.
            if hiddenY - minY <= 44,
               visibleStripShowsTabBar(
                   of: window,
                   toolbarWindow: toolbarWindow,
                   hiddenY: hiddenY
               )
            {
                scheduleStrayToolbarWindowCheck(after: 1.5)
                return
            }
        }

        var frame = toolbarWindow.frame
        frame.origin.y = hiddenY
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            toolbarWindow.animator().setFrame(frame, display: false)
        }
    }

    private func visibleStripShowsTabBar(
        of window: NSWindow,
        toolbarWindow: NSWindow,
        hiddenY: CGFloat
    ) -> Bool {
        let strip = NSRect(
            x: toolbarWindow.frame.minX,
            y: toolbarWindow.frame.minY,
            width: toolbarWindow.frame.width,
            height: hiddenY - toolbarWindow.frame.minY
        )
        return window.titlebarAccessoryViewControllers.contains { accessory in
            guard !accessory.isHidden,
                  !accessory.view.isHiddenOrHasHiddenAncestor,
                  accessory.view.window === toolbarWindow
            else {
                return false
            }

            let rectInWindow = accessory.view.convert(accessory.view.bounds, to: nil)
            return toolbarWindow.convertToScreen(rectInWindow).intersects(strip)
        }
    }
}

@MainActor
private final class ChromeToolbarController: NSObject, NSToolbarDelegate {
    weak var session: EditorDocumentSession?

    private let toolbarIdentifier = NSToolbar.Identifier(
        "Markwasnice.ChromeToolbar"
    )
    private let titleItemIdentifier = NSToolbarItem.Identifier(
        "Markwasnice.ChromeTitle"
    )
    private let controlsItemIdentifier = NSToolbarItem.Identifier(
        "Markwasnice.ChromeControls"
    )

    private weak var window: NSWindow?
    private var previousToolbar: NSToolbar?
    private var previousToolbarStyle: NSWindow.ToolbarStyle?
    private var previousTitleVisibility: NSWindow.TitleVisibility?

    func install(in window: NSWindow) {
        guard self.window !== window, session != nil else {
            return
        }

        self.window = window
        previousToolbar = window.toolbar
        previousToolbarStyle = window.toolbarStyle
        previousTitleVisibility = window.titleVisibility

        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifier = titleItemIdentifier

        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
    }

    func uninstall(from window: NSWindow) {
        guard self.window === window else {
            return
        }

        window.toolbar = previousToolbar
        if let previousToolbarStyle {
            window.toolbarStyle = previousToolbarStyle
        }
        if let previousTitleVisibility {
            window.titleVisibility = previousTitleVisibility
        }

        self.window = nil
        previousToolbar = nil
        previousToolbarStyle = nil
        previousTitleVisibility = nil
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItemIdentifiers
    }

    func toolbarSelectableItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        guard let session else { return nil }

        switch itemIdentifier {
        case titleItemIdentifier:
            let item = toolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Title"
            item.paletteLabel = "Title"
            item.view = hostingView(
                EditorTopBarTitle(state: session.shellState),
                width: 420
            )
            return item
        case controlsItemIdentifier:
            let item = toolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Controls"
            item.paletteLabel = "Controls"
            item.view = hostingView(
                EditorTopBarControls(state: session.shellState),
                width: 112
            )
            return item
        default:
            return nil
        }
    }

    private var toolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            titleItemIdentifier,
            .flexibleSpace,
            controlsItemIdentifier,
        ]
    }

    private func toolbarItem(
        itemIdentifier: NSToolbarItem.Identifier
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = false
        item.visibilityPriority = .high
        return item
    }

    private func hostingView(
        _ rootView: some View,
        width: CGFloat
    ) -> NSView {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.widthAnchor.constraint(equalToConstant: width),
            hostingView.heightAnchor.constraint(
                equalToConstant: 36
            ),
        ])
        return hostingView
    }
}

@MainActor
private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var session: EditorDocumentSession?
    weak var appState: MarkwasniceAppState?
    weak var chromeToolbarController: ChromeToolbarController?

    func windowDidBecomeKey(_: Notification) {
        guard let session else {
            return
        }

        appState?.activate(session)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session else {
            return true
        }

        return session.windowShouldClose(sender) {
            sender.close()
        }
    }

    func windowWillClose(_: Notification) {
        guard let session else {
            return
        }

        appState?.remove(session)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        session?.setFullScreen(true)
        chromeToolbarController?.install(in: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        chromeToolbarController?.uninstall(from: window)
        session?.setFullScreen(false)
    }

    func window(
        _: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication
            .PresentationOptions
    ) -> NSApplication.PresentationOptions {
        var options = proposedOptions
        options.insert(.autoHideMenuBar)
        options.insert(.autoHideToolbar)
        return options
    }
}
