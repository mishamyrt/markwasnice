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
    private var pendingKickWorkItem: DispatchWorkItem?

    private var isKickingToolbarAppearance = false
    private var didKickToolbarForFullScreenSession = false
    private var isToolbarKickPending = false

    /// When the tab bar appears inside a fullscreen window (manually or by
    /// adding a tab), AppKit's auto-hide can retract the NSToolbarFullScreenWindow
    /// by its pre-tab-bar height, leaving a strip of it stuck on screen. A
    /// settled toolbar window only has two valid resting positions — fully
    /// hidden, or fully revealed with the pointer keeping the reveal alive;
    /// once it stops moving anywhere else, clamp it fully off-screen.
    func refresh(editorWindow: NSWindow?, session: EditorDocumentSession?) {
        self.editorWindow = editorWindow
        self.session = session

        guard let window = editorWindow,
              window.styleMask.contains(.fullScreen)
        else {
            didKickToolbarForFullScreenSession = false
            isToolbarKickPending = false
            // Leaving fullscreen for real (not an ownership handoff):
            // AppKit dismantles the toolbar window, hand it back pristine.
            observedToolbarWindow?.alphaValue = 1
            observedToolbarWindow?.ignoresMouseEvents = false
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
        updateToolbarWindowFade(toolbarWindow)
        syncAppearance()
        reportChromeOverlayHeight()
        scheduleStrayToolbarWindowCheck()
        // A toolbar window first observed while already parked (app opened
        // straight into fullscreen) emits no move notifications, so the
        // pending kick has to be scheduled from here or it would discharge
        // on the first reveal instead.
        schedulePendingToolbarKick()
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

    /// Moving a fullscreen space between displays (an Exposé drag) leaves
    /// the toolbar window parked at offsets enrolled for the previous
    /// screen; until AppKit re-enrolls it there, reveals can land outside
    /// the fade's reveal zone and read as a toolbar that vanishes on tab
    /// clicks. Parking the window hidden at the new screen's top edge
    /// resets the geometry so the next reveal starts clean.
    func handleScreenChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let window = self.editorWindow,
                  window.styleMask.contains(.fullScreen),
                  self.hasSteadyFullScreenFrame(window),
                  let toolbarWindow = self.observedToolbarWindow
            else {
                return
            }

            var frame = toolbarWindow.frame
            frame.origin.y = window.frame.maxY
            toolbarWindow.setFrame(frame, display: false)
            self.updateToolbarWindowFade(toolbarWindow)
        }
    }

    func stopObserving() {
        strayToolbarCheckWorkItem?.cancel()
        strayToolbarCheckWorkItem = nil
        pendingKickWorkItem?.cancel()
        pendingKickWorkItem = nil
        toolbarAppearanceObservation = nil
        toolbarEffectiveAppearanceObservation = nil
        separatorView?.removeFromSuperview()
        separatorView = nil
        backdropView?.removeFromSuperview()
        backdropView = nil
        guard let observedToolbarWindow else {
            return
        }

        // Deliberately no alpha reset here: ownership of the shared
        // toolbar window hops between the tabs' controllers on tab
        // switches, and restoring alpha on a handoff would flash the
        // parked sliver back on screen. The next owner's fade pass (or
        // AppKit tearing the window down on fullscreen exit) takes over.
        NotificationCenter.default.removeObserver(
            self,
            name: nil,
            object: observedToolbarWindow
        )
        self.observedToolbarWindow = nil
    }

    /// The hidden-position guard alone is not enough to fire the kick: the
    /// first frames of a reveal animation also satisfy it (the window
    /// leaves its parked spot with alpha still 0), and a kick fired there
    /// paints the whole revealing band in the opposite theme for its 0.35s
    /// hold. Debouncing on move notifications means the kick only fires
    /// once the window has stopped moving — genuinely parked — never mid
    /// animation.
    private func schedulePendingToolbarKick() {
        guard isToolbarKickPending else {
            return
        }

        pendingKickWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performPendingToolbarKickIfHidden()
        }
        pendingKickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func performPendingToolbarKickIfHidden() {
        // Parked short of fully hidden (reserved menu bar band displays)
        // still counts: the window is faded out there, so the corrective
        // repaint cannot flash.
        guard isToolbarKickPending,
              let window = editorWindow,
              let toolbarWindow = observedToolbarWindow,
              toolbarWindow.frame.minY >= window.frame.maxY - 0.5
              || toolbarWindow.alphaValue < 0.05
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

        // The tab bar rides along as a titlebar accessory, wrapped in an
        // anonymous NSView sibling of NSToolbarView that sits lower in the
        // titlebar view. The opaque backdrop has to slot in below whichever
        // of the two is lowest, or it paints over the tab bar: invisible
        // tabs that still receive mouse events through the backdrop's nil
        // hitTest. The accessory container is only recognizable by its
        // NSTitlebarAccessoryClipView descendant, not by its own class.
        let anchorView = titlebarView.subviews.first { subview in
            subview !== backdropView
                && (String(describing: type(of: subview)) == "NSToolbarView"
                    || findSubview(
                        named: "NSTitlebarAccessoryClipView",
                        in: subview
                    ) != nil)
        }

        if let backdrop = backdropView, backdrop.superview === titlebarView {
            // A tab bar accessory that appears after the install (second
            // tab opened while already fullscreen) lands below the backdrop
            // and would be painted over; re-anchor when that happens.
            if let anchorView,
               let backdropIndex = titlebarView.subviews.firstIndex(of: backdrop),
               let anchorIndex = titlebarView.subviews.firstIndex(of: anchorView),
               backdropIndex > anchorIndex
            {
                backdrop.removeFromSuperview()
                titlebarView.addSubview(
                    backdrop,
                    positioned: .below,
                    relativeTo: anchorView
                )
            }
            return
        }

        backdropView?.removeFromSuperview()
        let backdrop = FullScreenToolbarBackdropView(frame: titlebarView.bounds)
        backdrop.autoresizingMask = [.width, .height]
        if let anchorView {
            titlebarView.addSubview(
                backdrop,
                positioned: .below,
                relativeTo: anchorView
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
            // The tab bar accessory draws its tabs with backdrop-backed
            // glass of its own; hiding those layers erases the tabs while
            // AppKit keeps reserving their row.
            let className = String(describing: type(of: subview))
            if className.contains("Accessory") || className.contains("TabBar") {
                continue
            }
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
            updateToolbarWindowFade(toolbarWindow)
            hideSystemToolbarBackdrop(in: toolbarWindow)
        }
        schedulePendingToolbarKick()
        reportChromeOverlayHeight()
        scheduleStrayToolbarWindowCheck()
    }

    /// AppKit owns the toolbar window's position: it re-asserts its parked
    /// spot within ~60ms of any displacement, and on displays with a
    /// reserved menu bar band that spot leaves a sliver of the tab bar
    /// inside the editor (the auto-hide offset predates the tab bar).
    /// Since the position cannot be corrected without a visible tug-of-war,
    /// visibility is handled here: the window's alpha is a pure function of
    /// how much of it is on screen — opaque through most of the travel,
    /// fading out over the last points, so the parked sliver rests
    /// invisible. Position-derived, hence no timers or direction heuristics,
    /// and it composes with whatever animation AppKit happens to run.
    private func updateToolbarWindowFade(_ toolbarWindow: NSWindow) {
        guard let window = editorWindow,
              window.styleMask.contains(.fullScreen),
              hasSteadyFullScreenFrame(window)
        else {
            return
        }

        let visibleBand = window.frame.maxY - toolbarWindow.frame.minY
        let alpha = Self.fadeAlpha(
            band: visibleBand,
            height: toolbarWindow.frame.height
        )
        if abs(toolbarWindow.alphaValue - alpha) > 0.001 {
            toolbarWindow.alphaValue = alpha
        }

        // The invisible sliver must not swallow clicks aimed at the text
        // below it.
        let ignoresMouse = alpha < 0.05
        if toolbarWindow.ignoresMouseEvents != ignoresMouse {
            toolbarWindow.ignoresMouseEvents = ignoresMouse
        }
    }

    /// Opaque only inside the legitimate reveal zone at the top of the
    /// screen. AppKit's parked "hidden" spots leave slivers of varying
    /// height on screen (12pt and 29pt observed), so anything up to 40pt
    /// rests invisible; a reveal parked below the slid-in menu bar can
    /// legitimately exceed the window height by ~30pt, so the plateau
    /// extends that far before fading back out — a window parked way
    /// outside the zone (AppKit creates new tabs' toolbar windows at the
    /// screen origin, i.e. the bottom edge) stays invisible too.
    private static func fadeAlpha(band: CGFloat, height: CGFloat) -> CGFloat {
        let riseStart: CGFloat = 40
        let riseEnd: CGFloat = 72
        let dropStart = height + 40
        let dropEnd = height + 72

        if band <= riseStart || band >= dropEnd {
            return 0
        }
        if band < riseEnd {
            return (band - riseStart) / (riseEnd - riseStart)
        }
        if band <= dropStart {
            return 1
        }
        return (dropEnd - band) / (dropEnd - dropStart)
    }

    /// A window mid tab-attach carries .fullScreen in its style mask while
    /// its frame is still the stale pre-attach one; chrome math against
    /// that frame would park or fade the toolbar window against geometry
    /// that never existed on screen.
    private func hasSteadyFullScreenFrame(_ window: NSWindow) -> Bool {
        guard let screen = window.screen else {
            return false
        }

        return abs(window.frame.width - screen.frame.width) < 1
            && window.frame.height > screen.frame.height * 0.7
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
              hasSteadyFullScreenFrame(window),
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

        // A partial band is AppKit's own parked position (its auto-hide
        // offset is short by the tab bar height on displays with a
        // reserved menu bar band). AppKit re-asserts that spot within
        // ~60ms of any displacement, so moving the window is a tug-of-war
        // that reads as flicker; the position-driven fade keeps the parked
        // sliver invisible instead.
        let revealedY = hiddenY - toolbarWindow.frame.height
        if minY > revealedY + 0.5 {
            return
        }

        // Fully revealed (allowing the menu bar shift) — legitimate only
        // while the pointer is near the top of the screen keeping the
        // reveal alive; with several displays the pointer also has to be
        // on this window's screen. A toolbar window born into an
        // already-fullscreen group is not enrolled in AppKit's auto-hide,
        // so once the pointer leaves it just stays; that stuck window is
        // the one worth clamping, and AppKit does not fight for it.
        // Anything parked below the reveal zone (AppKit creates new tabs'
        // toolbar windows at the screen origin — the bottom edge) is
        // never legitimate and gets clamped back to the top.
        // Tab selection deliberately plays no role here: on a tab switch
        // the deselected tab's controller can still hold the observation
        // of the shared toolbar window, and clamping from it would retract
        // a reveal the pointer is actively keeping alive (clicking a tab
        // happens with the pointer on the tab bar, inside the reveal zone).
        let pointer = NSEvent.mouseLocation
        let pointerOnScreen = window.screen.map { $0.frame.contains(pointer) }
            ?? true
        if pointerOnScreen,
           minY >= revealedY - 64, pointer.y >= minY - 250
        {
            // No move events arrive when the pointer leaves; keep
            // re-checking while the window remains on screen.
            scheduleStrayToolbarWindowCheck(after: 1.5)
            return
        }

        var frame = toolbarWindow.frame
        frame.origin.y = hiddenY

        // A window parked outside the reveal zone was never legitimately
        // on screen; animating it would drag it visibly across the whole
        // screen, so it snaps into the hidden spot instead.
        guard minY >= revealedY - 64 else {
            toolbarWindow.setFrame(frame, display: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            toolbarWindow.animator().setFrame(frame, display: false)
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
