import AppKit

/// Owns the fullscreen-toolbar patching for one editor window: watching
/// AppKit's NSToolbarFullScreenWindow, correcting its appearance, replacing
/// the stale glass backdrop, reporting the chrome overlay height, and
/// clamping the stray toolbar strip. Kept out of WindowLifecycleView so the
/// window lifecycle wiring stays readable and the kick-flag state machine
/// is local to this concern.
@MainActor
final class FullScreenToolbarController: NSObject {
    private weak var editorWindow: NSWindow?
    private weak var session: EditorDocumentSession?
    private weak var observedToolbarWindow: NSWindow?
    private var toolbarAppearanceObservation: NSKeyValueObservation?
    private var toolbarEffectiveAppearanceObservation: NSKeyValueObservation?
    private weak var separatorView: NSView?
    private weak var backdropView: NSView?
    private var strayToolbarCheckWorkItem: DispatchWorkItem?

    private var isKickingToolbarAppearance = false
    private var didKickToolbarForFullScreenSession = false
    private var isToolbarKickPending = false

    /// When the tab bar appears inside a fullscreen window (manually or by
    /// adding a tab), AppKit's auto-hide can retract the NSToolbarFullScreenWindow
    /// by its pre-tab-bar height, leaving a strip of it stuck on screen. A
    /// settled toolbar window only has two valid resting positions — fully
    /// hidden, or fully revealed (the latter only for the selected tab); once
    /// it stops moving anywhere in between, clamp it fully off-screen.
    func refresh(editorWindow: NSWindow?, session: EditorDocumentSession?) {
        self.editorWindow = editorWindow
        self.session = session

        guard let window = editorWindow,
              window.styleMask.contains(.fullScreen)
        else {
            didKickToolbarForFullScreenSession = false
            isToolbarKickPending = false
            stopObserving()
            session?.setFullScreenChromeOverlayHeight(0)
            return
        }

        guard let toolbarWindow = window.childWindows?.first(where: {
            String(describing: type(of: $0)) == "NSToolbarFullScreenWindow"
        })
        else {
            // The auto-hide detaches the toolbar window between reveals;
            // the fullscreen session (and its one-shot kick) is still on.
            stopObserving()
            session?.setFullScreenChromeOverlayHeight(0)
            return
        }

        if toolbarWindow !== observedToolbarWindow {
            stopObserving()
            observedToolbarWindow = toolbarWindow
            observeToolbarWindowAppearance(toolbarWindow)
            // Once per fullscreen session: the stale first render of the
            // item hosting views only needs one corrective flip. The flip
            // itself repaints the whole band in the opposite theme, so it
            // must wait until the toolbar window is parked off-screen —
            // kicking here, mid reveal animation, flashes on every entry.
            if !didKickToolbarForFullScreenSession {
                isToolbarKickPending = true
            }
            for name in [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(toolbarWindowDidMove),
                    name: name,
                    object: toolbarWindow
                )
            }
        }

        installSeparator(in: toolbarWindow)
        hideSystemToolbarBackdrop(in: toolbarWindow)
        syncAppearance()
        reportChromeOverlayHeight()
        scheduleStrayToolbarWindowCheck()
    }

    /// NSToolbarFullScreenWindow does not track system appearance changes:
    /// it keeps whatever appearance was in effect when the app launched, so
    /// after a theme switch the fullscreen toolbar renders in the stale
    /// theme. Pinning it to the editor window's effective appearance (and
    /// re-pinning from viewDidChangeEffectiveAppearance) keeps it in sync.
    func syncAppearance() {
        guard !isKickingToolbarAppearance,
              let window = editorWindow,
              let toolbarWindow = observedToolbarWindow
        else {
            return
        }

        let appearance = window.effectiveAppearance
        if toolbarWindow.appearance?.name != appearance.name {
            toolbarWindow.appearance = appearance
        }
    }

    func stopObserving() {
        strayToolbarCheckWorkItem?.cancel()
        strayToolbarCheckWorkItem = nil
        toolbarAppearanceObservation = nil
        toolbarEffectiveAppearanceObservation = nil
        separatorView?.removeFromSuperview()
        separatorView = nil
        backdropView?.removeFromSuperview()
        backdropView = nil
        guard let observedToolbarWindow else {
            return
        }

        NotificationCenter.default.removeObserver(
            self,
            name: nil,
            object: observedToolbarWindow
        )
        self.observedToolbarWindow = nil
    }

    private func performPendingToolbarKickIfHidden() {
        guard isToolbarKickPending,
              let window = editorWindow,
              let toolbarWindow = observedToolbarWindow,
              toolbarWindow.frame.minY >= window.frame.maxY - 0.5
        else {
            return
        }

        isToolbarKickPending = false
        didKickToolbarForFullScreenSession = true
        performToolbarAppearanceKick()
    }

    /// The SwiftUI hosting views inside the toolbar items render their
    /// first frame with a stale color scheme and only fix themselves on a
    /// real appearance change, so the opposite appearance is held long
    /// enough for a render pass and then released. The flip stays on the
    /// content view: it cascades only down the chrome subtree, while any
    /// window-level flip on NSToolbarFullScreenWindow leaks the stale
    /// theme back into the whole fullscreen space.
    private func performToolbarAppearanceKick() {
        guard !isKickingToolbarAppearance,
              let window = editorWindow,
              let toolbarWindow = observedToolbarWindow,
              let chromeView = toolbarWindow.contentView
        else {
            return
        }

        let correct = window.effectiveAppearance
        let oppositeName: NSAppearance.Name =
            correct.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? .aqua
                : .darkAqua
        isKickingToolbarAppearance = true
        chromeView.appearance = NSAppearance(named: oppositeName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [
            weak self,
            weak chromeView
        ] in
            self?.isKickingToolbarAppearance = false
            chromeView?.appearance = nil
        }
    }

    /// The fullscreen toolbar slides down over the text without any band
    /// of its own between the two; a hairline at the toolbar window's
    /// bottom edge marks where the chrome ends, mirroring the status bar
    /// separator. The native titlebarSeparatorStyle stays hidden inside
    /// NSToolbarFullScreenWindow, so the line is drawn by hand.
    private func installSeparator(in toolbarWindow: NSWindow) {
        guard separatorView?.window !== toolbarWindow,
              let contentView = toolbarWindow.contentView
        else {
            return
        }

        separatorView?.removeFromSuperview()
        let separator = FullScreenToolbarSeparatorView(
            frame: NSRect(x: 0, y: 0, width: contentView.bounds.width, height: 1)
        )
        separator.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(separator)
        separatorView = separator
    }

    /// The Tahoe glass band inside NSToolbarFullScreenWindow renders with
    /// filter parameters cached at process launch and repaints them only on
    /// window-level appearance changes, which cannot be forced without
    /// leaking the flip into the editor window. Instead the stale band is
    /// hidden entirely and FullScreenToolbarBackdropView supplies the
    /// theme-correct background underneath the toolbar items.
    private func hideSystemToolbarBackdrop(in toolbarWindow: NSWindow) {
        guard let contentView = toolbarWindow.contentView else {
            return
        }

        hideBackdropLayerViews(in: contentView)
        installBackdrop(in: toolbarWindow)
    }

    /// AppKit re-shows its own band layers for the first frames of every
    /// reveal animation, faster than any notification lets us re-hide
    /// them. The opaque backdrop therefore sits inside NSTitlebarView,
    /// above every system background layer and directly below the toolbar
    /// items, so whatever flashes underneath is simply never visible.
    private func installBackdrop(in toolbarWindow: NSWindow) {
        guard let contentView = toolbarWindow.contentView,
              let titlebarView = findSubview(
                  named: "NSTitlebarView",
                  in: contentView
              )
        else {
            return
        }

        if let backdrop = backdropView,
           backdrop.superview === titlebarView
        {
            return
        }

        backdropView?.removeFromSuperview()
        let backdrop = FullScreenToolbarBackdropView(frame: titlebarView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        let toolbarView = titlebarView.subviews.first {
            String(describing: type(of: $0)) == "NSToolbarView"
        }
        if let toolbarView {
            titlebarView.addSubview(
                backdrop,
                positioned: .below,
                relativeTo: toolbarView
            )
        } else {
            titlebarView.addSubview(backdrop)
        }
        backdropView = backdrop
    }

    private func findSubview(named className: String, in view: NSView) -> NSView? {
        for subview in view.subviews {
            if String(describing: type(of: subview)) == className {
                return subview
            }
            if let match = findSubview(named: className, in: subview) {
                return match
            }
        }
        return nil
    }

    private func hideBackdropLayerViews(in view: NSView) {
        for subview in view.subviews {
            if !(subview is FullScreenToolbarBackdropView),
               let layer = subview.layer
            {
                let layerClass = String(describing: type(of: layer))
                // Backdrop layers carry the stale glass recipe; portal
                // layers can replay hidden sources during the reveal
                // animation frames.
                if layerClass == "CABackdropLayer" || layerClass == "CAPortalLayer",
                   !subview.isHidden
                {
                    subview.isHidden = true
                }
                // NSTitlebarBackgroundView keeps an opaque white backing
                // color even in dark mode; it flashes through during the
                // reveal animation when the glass band above it is gone.
                if String(describing: type(of: subview))
                    == "NSTitlebarBackgroundView",
                    layer.backgroundColor != nil
                {
                    layer.backgroundColor = nil
                    subview.isHidden = true
                }
            }
            hideBackdropLayerViews(in: subview)
        }
    }

    /// The editor keeps unscrolled text below the auto-hidden fullscreen
    /// chrome; the overlay is the toolbar window (toolbar + tab bar) plus
    /// whatever part of the menu bar slides over the content. On displays
    /// that reserve a band for the menu bar (notch) the fullscreen window
    /// stops below it and the menu bar never overlaps.
    private func reportChromeOverlayHeight() {
        guard let session, let window = editorWindow,
              let toolbarWindow = observedToolbarWindow
        else {
            return
        }

        var menuBarOverlap: CGFloat = 0
        if let screen = window.screen {
            let reservedAboveWindow = max(
                0, screen.frame.maxY - window.frame.maxY
            )
            menuBarOverlap = max(
                0,
                (NSApp.mainMenu?.menuBarHeight ?? 0) - reservedAboveWindow
            )
        }
        session.setFullScreenChromeOverlayHeight(
            toolbarWindow.frame.height + menuBarOverlap
        )
    }

    /// AppKit re-stamps its own cached appearance onto the toolbar window
    /// at the start of every reveal; reacting to move notifications
    /// repaints one frame too late, which reads as a theme flicker on each
    /// hover. Correcting from inside the KVO callback happens in the same
    /// runloop turn as the stamp, before the frame is committed.
    private func observeToolbarWindowAppearance(_ toolbarWindow: NSWindow) {
        toolbarAppearanceObservation = toolbarWindow.observe(
            \.appearance,
            options: [.new]
        ) { [weak self] toolbarWindow, _ in
            MainActor.assumeIsolated {
                self?.counterToolbarAppearanceStamp(on: toolbarWindow)
            }
        }
        toolbarEffectiveAppearanceObservation = toolbarWindow.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] toolbarWindow, _ in
            MainActor.assumeIsolated {
                self?.counterToolbarAppearanceStamp(on: toolbarWindow)
            }
        }
    }

    private func counterToolbarAppearanceStamp(on toolbarWindow: NSWindow) {
        guard !isKickingToolbarAppearance, let window = editorWindow else {
            return
        }

        let correct = window.effectiveAppearance
        guard toolbarWindow.appearance?.name != correct.name else {
            return
        }

        toolbarWindow.appearance = correct
    }

    @objc private func toolbarWindowDidMove(_: Notification) {
        // AppKit can rebuild parts of the chrome when the reveal state
        // changes; keep the stale glass band suppressed.
        if let toolbarWindow = observedToolbarWindow {
            hideSystemToolbarBackdrop(in: toolbarWindow)
        }
        performPendingToolbarKickIfHidden()
        reportChromeOverlayHeight()
        scheduleStrayToolbarWindowCheck()
    }

    /// Debounced so reveal/hide animations, which move the window through
    /// intermediate positions every frame, are never interfered with.
    private func scheduleStrayToolbarWindowCheck(after delay: TimeInterval = 0.4) {
        strayToolbarCheckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clampStrayToolbarWindow()
        }
        strayToolbarCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clampStrayToolbarWindow() {
        guard let window = editorWindow,
              window.styleMask.contains(.fullScreen),
              let toolbarWindow = observedToolbarWindow
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

/// Matches the status bar separator: 1pt of the primary color at 8%.
private final class FullScreenToolbarSeparatorView: NSView {
    override func draw(_: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

/// Theme-correct background for the fullscreen toolbar band, replacing the
/// system glass band that keeps its launch-time appearance on Tahoe. Fully
/// opaque: it also has to mask the system band layers that AppKit re-shows
/// beneath it during reveal animations.
private final class FullScreenToolbarBackdropView: NSView {
    override func draw(_: NSRect) {
        EditorThemeColors.default
            .variant(for: effectiveAppearance)
            .background
            .setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
