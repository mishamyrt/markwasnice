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

/// A SwiftUI scene window materializes on whichever space is active at that
/// moment, which corrupts a tab attach whenever the target window lives on a
/// different space. With a fullscreen target the new window lands in a
/// fullscreen space of its own — no orderFront to pre-empt, no
/// willEnterFullScreen transition — and attaching it afterwards merges the
/// two spaces, stranding the old one as a black husk. With a target on
/// another desktop (an external open arriving from a different space, while
/// the activation-driven space switch is still in flight) the newborn window
/// pulls the target's tab group onto the caller's space, so the switch
/// finishes on a desktop the group has just left. Such tabs therefore bypass
/// SwiftUI window creation entirely: a plain AppKit window hosts the same
/// editor content and joins the tab group before it is ever shown — never
/// having been on any space, it has none to drag the group to.
@MainActor
enum EditorTabWindowFactory {
    private static var controllers: [ObjectIdentifier: NSWindowController] = [:]

    static func open(
        session: EditorDocumentSession,
        appState: MarkwasniceAppState,
        attachedTo target: NSWindow
    ) {
        let window = NSWindow(
            contentRect: target.frame,
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        let controller = EditorTabWindowController(window: window)
        controller.appState = appState
        controllers[ObjectIdentifier(window)] = controller

        var closeObserver: NSObjectProtocol?
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            // Released outside the close callout so the window is not
            // deallocated mid-teardown.
            DispatchQueue.main.async {
                guard let window else {
                    return
                }

                MainActor.assumeIsolated {
                    controllers[ObjectIdentifier(window)] = nil
                }
            }
        }

        window.contentView = NSHostingView(
            rootView: EditorWindowView(session: session)
                .environmentObject(appState)
        )
        // The hosting view materializes its AppKit subtree lazily; forcing
        // layout makes WindowLifecycleView configure the window and run the
        // tab attach while the window is still unshown.
        window.layoutIfNeeded()
    }
}

/// Keeps the native tab bar "+" button functional on factory-made windows:
/// the button only appears when a responder implements newWindowForTab:.
@MainActor
private final class EditorTabWindowController: NSWindowController {
    weak var appState: MarkwasniceAppState?

    override func newWindowForTab(_: Any?) {
        appState?.requestNewTab(attachedTo: window)
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
    private let fullScreenToolbarController = FullScreenToolbarController()
    private var didConfigureWindow = false
    private var tabGroupObservation: NSKeyValueObservation?
    private var contentLayoutObservation: NSKeyValueObservation?
    private var titleCancellable: AnyCancellable?
    private var isTabChromeRefreshPending = false
    private var isHiddenWhileRestoringTab = false
    private weak var unclippedAccessoryContainer: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tabGroupObservation = nil
            contentLayoutObservation = nil
            titleCancellable = nil
            fullScreenToolbarController.stopObserving()
        }
        configureWindowIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWindowBackground()
        fullScreenToolbarController.syncAppearance()
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
        delegateProxy.fullScreenToolbarController = fullScreenToolbarController
        chromeToolbarController.session = session
        window.delegate = delegateProxy
        window.title = session.title
        window.tabbingIdentifier = EditorWindowTabbing.identifier
        window.tabbingMode = .automatic
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        EditorWindowChrome.installBaseToolbar(on: window)
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
            if appState.hasPendingRestoreTabLead(for: session.id) {
                isHiddenWhileRestoringTab = true
                window.alphaValue = 0
            }
            placeWindow(window, session: session, appState: appState, attempt: 0)
            appState.revealPendingDocument(of: session, in: window)
            DispatchQueue.main.async { [weak window, weak session] in
                guard session?.editorView.window === window else {
                    return
                }

                session?.editorView.focus()
            }
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
            // AppKit enrolls the new tab's fullscreen chrome with whatever
            // geometry the window has at attach time; the stale pre-attach
            // frame would park the toolbar window at that stale position.
            if target.styleMask.contains(.fullScreen) {
                window.setFrame(target.frame, display: false)
            }
            let previouslySelectedWindow = target.tabGroup?.selectedWindow ?? target
            target.addTabbedWindow(window, ordered: .above)
            revealRestoredTabWindow(window)
            if session.restoredTabSelection == false {
                previouslySelectedWindow.makeKeyAndOrderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }

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
                placeStandaloneWindow(window, session: session)
                revealRestoredTabWindow(window)
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

        placeStandaloneWindow(window, session: session)
    }

    private func revealRestoredTabWindow(_ window: NSWindow) {
        guard isHiddenWhileRestoringTab else {
            return
        }

        isHiddenWhileRestoringTab = false
        window.alphaValue = 1
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

    /// A frame saved on a display arrangement that no longer exists would
    /// reopen the window out of reach; such frames fall back to centering.
    private func frameIsOnScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return intersection.width >= 200 && intersection.height >= 100
        }
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

    /// contentLayoutRect re-fires for every frame of a live resize, and both
    /// observations answer the same question, so a refresh already queued for
    /// this runloop turn absorbs the rest instead of running the whole chrome
    /// pass once per notification.
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

        fullScreenToolbarController.refresh(editorWindow: window, session: session)

        // The chrome auto-hide temporarily collapses the tab bar (via its
        // titlebar accessory, so isTabBarVisible stays true); keep the
        // logical tab chrome (insets, backdrop) frozen so the text does not
        // shift and the reveal restores everything in place.
        if session.isTabBarTemporarilyHidden {
            return
        }

        let isTabBarVisible = window.tabGroup?.isTabBarVisible ?? false
        if isTabBarVisible {
            unclipTitlebarAccessories(in: window)
        }

        let topInset = isTabBarVisible && !session.shellState.isFullScreen
            ? (window.contentView?.safeAreaInsets.top ?? 0)
            : 0
        session.setTabBarChrome(
            isVisible: isTabBarVisible,
            topInset: topInset,
            rowHeight: tabBarRowHeight(in: window)
        )
    }

    /// The safe area covers the toolbar row and the tab bar row as one; the
    /// chrome band has to stop where the toolbar row does, so the accessory
    /// row is measured off the window rather than assumed. Its estimate
    /// stands in whenever AppKit has not attached the accessory (yet).
    private func tabBarRowHeight(in window: NSWindow) -> CGFloat {
        let accessory = window.titlebarAccessoryViewControllers.first {
            !$0.isHidden
        }
        guard let height = accessory?.view.frame.height, height > 0 else {
            return EditorShellState.tabBarRowHeightEstimate
        }

        return height
    }

    /// The new-tab button scales up while pressed, but the tab bar lives in a
    /// 36pt accessory container that masks to its own bounds, so the grown
    /// circle is sliced along the row's top edge. The mask is dropped; the
    /// enclosing NSTitlebarContainerView still clips the whole band, so the
    /// reveal and fullscreen slides are unaffected.
    private func unclipTitlebarAccessories(in window: NSWindow) {
        // This is reached from a refresh that also runs per frame of a live
        // resize, so the theme-frame walk is redone only once the container
        // it found stops answering for the mask: deallocated, detached, moved
        // to another window, or handed its mask back by AppKit.
        if let container = unclippedAccessoryContainer,
           container.window === window,
           container.superview != nil,
           !container.clipsToBounds,
           container.layer?.masksToBounds != true
        {
            return
        }

        guard let themeFrame = window.contentView?.superview else {
            return
        }

        var container: NSView?
        themeFrame.forEachDescendant { view in
            guard view.hasExactClass(
                PrivateChromeClass.titlebarAccessoryContainer
            ) else {
                return true
            }

            view.clipsToBounds = false
            view.layer?.masksToBounds = false
            container = container ?? view
            // Nothing below a container is a container in turn.
            return false
        }
        unclippedAccessoryContainer = container
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

@MainActor
private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
    weak var session: EditorDocumentSession?
    weak var appState: MarkwasniceAppState?
    weak var chromeToolbarController: ChromeToolbarController?
    weak var fullScreenToolbarController: FullScreenToolbarController?

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
        guard let session else {
            return
        }

        appState?.remove(session)
    }

    func windowDidMove(_: Notification) {
        appState?.noteWindowLayoutChanged()
    }

    func windowDidChangeScreen(_: Notification) {
        fullScreenToolbarController?.handleScreenChange()
    }

    func windowDidEndLiveResize(_: Notification) {
        appState?.noteWindowLayoutChanged()
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
