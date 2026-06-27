import AppKit
import SwiftUI

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
    private let fullScreenToolbarController = FullScreenToolbarController()
    private var didConfigureWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    private func configureWindowIfNeeded() {
        guard let window, let session, let appState else {
            return
        }

        delegateProxy.session = session
        delegateProxy.appState = appState
        delegateProxy.fullScreenToolbarController = fullScreenToolbarController
        fullScreenToolbarController.session = session
        window.delegate = delegateProxy
        window.title = session.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        if window.toolbar == nil {
            window.toolbar = NSToolbar()
        }
        window.toolbarStyle = .unified
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor =
            EditorThemeColors.default
                .variant(for: window.effectiveAppearance)
                .background
        window.contentMinSize = NSSize(width: 640, height: 420)

        if !didConfigureWindow {
            didConfigureWindow = true
            window.setContentSize(NSSize(width: 960, height: 640))
            window.center()
        }
    }
}

@MainActor
private final class FullScreenToolbarController: NSObject, NSToolbarDelegate {
    weak var session: EditorDocumentSession?

    private let toolbarIdentifier = NSToolbar.Identifier(
        "Markwasnice.FullScreenToolbar"
    )
    private let historyItemIdentifier = NSToolbarItem.Identifier(
        "Markwasnice.FullScreenHistory"
    )
    private let titleItemIdentifier = NSToolbarItem.Identifier(
        "Markwasnice.FullScreenTitle"
    )
    private let previewItemIdentifier = NSToolbarItem.Identifier(
        "Markwasnice.FullScreenPreview"
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
        case historyItemIdentifier:
            return historyToolbarItem()
        case titleItemIdentifier:
            let item = toolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Title"
            item.paletteLabel = "Title"
            item.view = hostingView(
                EditorTopBarTitle(state: session.shellState),
                width: 420
            )
            return item
        case previewItemIdentifier:
            let item = toolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Preview"
            item.paletteLabel = "Preview"
            item.view = hostingView(EditorTopBarPreviewButton(), width: 50)
            return item
        default:
            return nil
        }
    }

    private var toolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [
            historyItemIdentifier,
            .flexibleSpace,
            titleItemIdentifier,
            .flexibleSpace,
            previewItemIdentifier,
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

    private func historyToolbarItem() -> NSToolbarItemGroup {
        let item = NSToolbarItemGroup(
            itemIdentifier: historyItemIdentifier,
            images: [
                NSImage(
                    systemSymbolName: "chevron.left",
                    accessibilityDescription: "Undo"
                )!,
                NSImage(
                    systemSymbolName: "chevron.right",
                    accessibilityDescription: "Redo"
                )!,
            ],
            selectionMode: .momentary,
            labels: ["Undo", "Redo"],
            target: self,
            action: #selector(performHistoryAction(_:))
        )
        item.label = "History"
        item.paletteLabel = "History"
        item.controlRepresentation = .expanded
        item.visibilityPriority = .high
        return item
    }

    @objc private func performHistoryAction(_ sender: Any) {
        let selectedIndex: Int
        if let item = sender as? NSToolbarItemGroup {
            selectedIndex = item.selectedIndex
        } else if let control = sender as? NSSegmentedControl {
            selectedIndex = control.selectedSegment
        } else {
            return
        }

        switch selectedIndex {
        case 0:
            session?.shellState.onUndo?()
        case 1:
            session?.shellState.onRedo?()
        default:
            break
        }
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
    weak var fullScreenToolbarController: FullScreenToolbarController?

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
        fullScreenToolbarController?.install(in: window)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        fullScreenToolbarController?.uninstall(from: window)
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
