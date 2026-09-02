@preconcurrency import AppKit
import Combine
import QuartzCore
import SwiftUI

enum EditorWindowTabbing {
    static let identifier = "Markwasnice.EditorWindow"
}

/// Owns every editor window and its controller. Windows are created by AppKit,
/// receive their session before they are shown, and therefore can join a tab
/// group (including one on another Space or in fullscreen) without a transient
/// SwiftUI scene window. The controller also owns the public newWindowForTab:
/// responder entry point, so the native tab-bar "+" needs no runtime patching.
@MainActor
final class EditorWindowCoordinator {
    private let appState: MarkwasniceAppState
    private var controllers: [EditorDocumentSession.ID: EditorWindowController] = [:]
    private var didStart = false
    private var isDrainingPendingWindows = false

    init(appState: MarkwasniceAppState) {
        self.appState = appState
        appState.onWindowPresentationNeeded = { [weak self] in
            self?.openPendingWindows()
        }
    }

    func start() async {
        guard !didStart else {
            return
        }

        if let initialID = await appState.initialSessionID() {
            openWindow(for: initialID)
        }
        didStart = true
        openPendingWindows()
    }

    var hasVisibleEditorWindows: Bool {
        controllers.values.contains { $0.window?.isVisible == true }
    }

    func openPendingWindows() {
        guard didStart, !isDrainingPendingWindows else {
            return
        }

        isDrainingPendingWindows = true
        defer { isDrainingPendingWindows = false }
        for id in appState.takePendingWindowIDs() {
            openWindow(for: id)
        }
    }

    private func openWindow(for sessionID: EditorDocumentSession.ID) {
        guard controllers[sessionID] == nil,
              let session = appState.session(for: sessionID)
        else {
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        let controller = EditorWindowController(editorWindow: window)
        controller.onWindowClosed = { [weak self] in
            // Release outside AppKit's close notification so the controller
            // and window stay alive for the complete teardown callout.
            DispatchQueue.main.async {
                self?.controllers[sessionID] = nil
            }
        }
        controllers[sessionID] = controller

        controller.configure(session: session, appState: appState)
        let tabTarget = appState.takeTabAttachTarget(
            for: sessionID
        ) { [weak self] leadID in
            self?.controllers[leadID]?.window
        }
        if tabTarget == nil,
           appState.hasPendingRestoreTabLead(for: sessionID)
        {
            appState.abandonRestoreTabLead(for: sessionID)
        }
        controller.present(attachedTo: tabTarget)
    }
}

/// Owns configuration, observation, placement and delegate callbacks for one
/// editor window. Window creation no longer depends on a SwiftUI background
/// view being laid out before AppKit can present it.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    weak var appState: MarkwasniceAppState?
    var onWindowClosed: (() -> Void)?
    private var session: EditorDocumentSession?
    private let chromeToolbarController = ChromeToolbarController()
    private var tabGroupObservation: NSKeyValueObservation?
    private var contentLayoutObservation: NSKeyValueObservation?
    private var titleCancellable: AnyCancellable?
    private var systemChromeVisibilityCancellable: AnyCancellable?
    private var isTabChromeRefreshPending = false
    private var didConfigure = false

    init(editorWindow: NSWindow) {
        super.init(window: editorWindow)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(
        session: EditorDocumentSession,
        appState: MarkwasniceAppState
    ) {
        guard !didConfigure, let window else {
            return
        }

        didConfigure = true
        self.session = session
        self.appState = appState
        chromeToolbarController.session = session

        window.delegate = self
        window.title = session.title
        window.tabbingIdentifier = EditorWindowTabbing.identifier
        window.tabbingMode = .automatic
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        EditorWindowChrome.installBaseToolbar(on: window)
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.contentMinSize = NSSize(width: 640, height: 420)
        applyWindowBackground()

        // Establish AppKit's titlebar hierarchy before mounting a
        // full-size hosting view. Otherwise the hosting layer can be placed
        // above the tab accessory and traffic-light buttons: the controls
        // remain functional but are not drawn.
        let contentView = AppearanceTrackingHostingView(
            rootView: EditorWindowView(session: session)
                .environmentObject(appState)
        )
        contentView.onAppearanceChanged = { [weak self] in
            self?.applyWindowBackground()
        }
        window.contentView = contentView
        observeTabChrome(of: window)
        observeTitle(of: window, shellState: session.shellState)
        observeSystemChromeVisibility(
            of: window,
            shellState: session.shellState
        )
    }

    func present(attachedTo target: NSWindow?) {
        guard let window, let session else {
            return
        }

        if let target, target !== window, target.isVisible {
            if target.styleMask.contains(.fullScreen) {
                window.setFrame(target.frame, display: false)
            }
            for accessory in target.titlebarAccessoryViewControllers {
                accessory.isHidden = false
            }
            let previouslySelectedWindow = target.tabGroup?.selectedWindow ?? target
            target.addTabbedWindow(window, ordered: .above)
            for accessory in window.titlebarAccessoryViewControllers {
                accessory.isHidden = false
            }
            if session.restoredTabSelection == false {
                previouslySelectedWindow.makeKeyAndOrderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }

            refreshTabChrome()
            if window.styleMask.contains(.fullScreen),
               !session.shellState.isFullScreen
            {
                session.setFullScreen(true)
                chromeToolbarController.install(in: window)
            }
        } else {
            placeStandaloneWindow(window, session: session)
            window.makeKeyAndOrderFront(nil)
        }

        appState?.revealPendingDocument(of: session, in: window)
        focusEditor(remainingAttempts: 3)
    }

    override func newWindowForTab(_: Any?) {
        appState?.requestNewTab(attachedTo: window)
    }

    private func placeStandaloneWindow(
        _ window: NSWindow,
        session: EditorDocumentSession
    ) {
        if let frame = session.takeRestoredWindowFrame(),
           frameIsOnScreen(frame)
        {
            window.setFrame(frame, display: false)
            return
        }

        window.setContentSize(NSSize(width: 960, height: 640))
        window.center()
    }

    private func frameIsOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return intersection.width >= 200 && intersection.height >= 100
        }
    }

    private func focusEditor(remainingAttempts: Int) {
        guard let window, let session else {
            return
        }
        guard session.editorView.window === window else {
            guard remainingAttempts > 0 else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.focusEditor(remainingAttempts: remainingAttempts - 1)
            }
            return
        }

        session.editorView.focus()
    }

    private func applyWindowBackground() {
        guard let window else {
            return
        }

        window.backgroundColor = EditorThemeColors.default
            .variant(for: window.effectiveAppearance)
            .background
    }

    private func observeTabChrome(of window: NSWindow) {
        tabGroupObservation = window.observe(
            \.tabGroup?.isTabBarVisible,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.scheduleTabChromeRefresh()
            }
        }
        contentLayoutObservation = window.observe(
            \.contentLayoutRect,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.scheduleTabChromeRefresh()
            }
        }
    }

    private func scheduleTabChromeRefresh() {
        guard !isTabChromeRefreshPending else {
            return
        }

        isTabChromeRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            isTabChromeRefreshPending = false
            refreshTabChrome()
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
                window.tab.title = EditorWindowTabTitle.make(
                    title: title,
                    isEdited: isEdited
                )
            }
    }

    private func observeSystemChromeVisibility(
        of window: NSWindow,
        shellState: EditorShellState
    ) {
        systemChromeVisibilityCancellable = shellState.$isToolbarVisible
            .combineLatest(shellState.$isFullScreen)
            .sink { [weak self, weak window] isVisible, isFullScreen in
                guard let self, let window, self.window === window else {
                    return
                }

                applySystemChromeVisibility(
                    isVisible: isVisible,
                    isSystemManaged: isFullScreen,
                    to: window
                )
            }
    }

    private func applySystemChromeVisibility(
        isVisible: Bool,
        isSystemManaged: Bool,
        to window: NSWindow
    ) {
        window.titlebarAppearsTransparent = true
        if !isSystemManaged {
            EditorWindowChrome.installBaseToolbar(on: window)
        }

        let alpha = isSystemManaged || isVisible ? 1.0 : 0.0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for buttonType in [
                NSWindow.ButtonType.closeButton,
                .miniaturizeButton,
                .zoomButton,
            ] {
                window.standardWindowButton(buttonType)?.animator().alphaValue = alpha
            }
        }
    }

    private func refreshTabChrome() {
        guard let window, let session,
              !session.isTabBarTemporarilyHidden
        else {
            return
        }

        let isTabBarVisible = window.tabGroup?.isTabBarVisible ?? false
        let rowHeight = tabBarRowHeight(in: window)
        let safeAreaTop = window.contentView?.safeAreaInsets.top ?? 0
        if !session.shellState.isFullScreen {
            let toolbarHeight = safeAreaTop
                - (isTabBarVisible ? rowHeight : 0)
            session.setFullScreenToolbarHeight(toolbarHeight)
        }
        session.setTabBarChrome(
            isVisible: isTabBarVisible,
            topInset: isTabBarVisible && !session.shellState.isFullScreen
                ? safeAreaTop
                : 0,
            rowHeight: rowHeight
        )
    }

    private func tabBarRowHeight(in window: NSWindow) -> CGFloat {
        let accessory = window.titlebarAccessoryViewControllers.first {
            !$0.isHidden
        }
        guard let height = accessory?.view.frame.height, height > 0 else {
            return EditorShellState.tabBarRowHeightEstimate
        }

        return height
    }

    func windowDidBecomeKey(_: Notification) {
        guard let session else {
            return
        }

        appState?.activate(session)
        appState?.noteSelectedTabChanged()
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
        if let session {
            appState?.remove(session)
        }
        onWindowClosed?()
    }

    func windowDidMove(_: Notification) {
        appState?.noteWindowLayoutChanged()
    }

    func windowDidEndLiveResize(_: Notification) {
        appState?.noteWindowLayoutChanged()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        refreshTabChrome()
        session?.setFullScreen(true)
        chromeToolbarController.install(in: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        chromeToolbarController.uninstall(from: window)
        session?.setFullScreen(false)
        scheduleTabChromeRefresh()
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

private struct EditorWindowView: View {
    @ObservedObject private var session: EditorDocumentSession

    @EnvironmentObject private var appState: MarkwasniceAppState

    init(session: EditorDocumentSession) {
        self.session = session
    }

    var body: some View {
        EditorShellView(editorView: session.editorView, state: session.shellState)
            .background(
                WindowWidthBridge { width in
                    session.updateWindowWidth(width)
                }
            )
            .onAppear {
                if session.restoredTabSelection != false {
                    appState.activate(session)
                }
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

private final class AppearanceTrackingHostingView<Content: View>:
    NSHostingView<Content>
{
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
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
            // Sized to fit: a fixed width narrower than the content makes
            // SwiftUI center the overflow, pushing the trailing button
            // past the frame and visually against the screen edge.
            item.view = hostingView(
                EditorTopBarControls(state: session.shellState),
                width: nil
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
        width: CGFloat?
    ) -> NSView {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.widthAnchor.constraint(
                equalToConstant: width ?? hostingView.fittingSize.width
            ),
            hostingView.heightAnchor.constraint(
                equalToConstant: 36
            ),
        ])
        return hostingView
    }
}
