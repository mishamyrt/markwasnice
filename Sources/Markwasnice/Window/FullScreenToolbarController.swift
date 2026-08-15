import AppKit
import Combine

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
    private weak var separatorView: FullScreenToolbarSeparatorView?
    private var separatorAppearanceCancellable: AnyCancellable?
    private var isSeparatorVisible = false
    private var separatorOpacity = EditorShellState.topChromeSeparatorOpacity
    private weak var backdropView: NSView?
    /// The chrome views the backdrop is stacked against, kept between
    /// notifications: `installBackdrop` runs on every move of the reveal
    /// animation, and finding them means walking the toolbar window's
    /// hierarchy. Weak, because they belong to AppKit's toolbar window and
    /// their disappearance is itself the signal to look again.
    private weak var cachedTitlebarView: NSView?
    private weak var backdropAnchorView: NSView?
    private var backdropAnchorSiblingCount = 0
    private var strayToolbarCheckWorkItem: DispatchWorkItem?
    private var pendingKickWorkItem: DispatchWorkItem?

    /// The appearance-kick lifecycle for one fullscreen session. The kick
    /// is a one-shot: `done` survives toolbar-window detaches and handoffs
    /// so it never refires mid session, and only leaving fullscreen for
    /// real resets it to `idle`.
    private enum ToolbarKickState {
        /// No kick armed and none performed this fullscreen session.
        case idle
        /// Armed, waiting for the toolbar window to be genuinely parked.
        case pending
        /// The corrective flip is being held on `view`; `release` restores
        /// it after the hold.
        case kicking(
            view: WeakViewBox,
            firedAt: CFTimeInterval,
            release: DispatchWorkItem
        )
        /// The one-shot kick has run for this fullscreen session.
        case done
    }

    /// Enum associated values hold strong references; the kicked chrome
    /// view belongs to AppKit's toolbar window and must not be retained
    /// past its teardown, so the kicking state carries it through this box.
    private final class WeakViewBox {
        private(set) weak var view: NSView?

        init(_ view: NSView) {
            self.view = view
        }
    }

    private var kickState: ToolbarKickState = .idle

    private var isKickingToolbarAppearance: Bool {
        if case .kicking = kickState {
            return true
        }
        return false
    }

    /// When the tab bar appears inside a fullscreen window (manually or by
    /// adding a tab), AppKit's auto-hide can retract the NSToolbarFullScreenWindow
    /// by its pre-tab-bar height, leaving a strip of it stuck on screen. A
    /// settled toolbar window only has two valid resting positions — fully
    /// hidden, or fully revealed with the pointer keeping the reveal alive;
    /// once it stops moving anywhere else, clamp it fully off-screen.
    func refresh(editorWindow: NSWindow?, session: EditorDocumentSession?) {
        let didChangeSession = self.session !== session
        self.editorWindow = editorWindow
        self.session = session
        if didChangeSession {
            separatorAppearanceCancellable = nil
            if let session {
                observeSeparatorAppearance(of: session)
            }
        }

        guard let window = editorWindow,
              window.styleMask.contains(.fullScreen)
        else {
            resetKick()
            // Leaving fullscreen for real (not an ownership handoff):
            // AppKit dismantles the toolbar window, hand it back pristine.
            observedToolbarWindow?.alphaValue = 1
            observedToolbarWindow?.ignoresMouseEvents = false
            stopObserving()
            session?.setFullScreenChromeOverlayHeight(0)
            return
        }

        guard let toolbarWindow = window.childWindows?.first(where: {
            $0.hasExactClass(PrivateChromeClass.toolbarFullScreenWindow)
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
            // (stopObserving above settled any in-flight hold, so the
            // state here is never .kicking.)
            switch kickState {
            case .idle, .pending:
                kickState = .pending
            case .kicking, .done:
                break
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

        abortKickIfToolbarOnScreen()
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
        // A hold still in flight belongs to a toolbar window this
        // controller is letting go of; left alone, the kicking state would
        // keep suppressing syncAppearance until the stale release item
        // fires. Settle it now — the one-shot already fired, so the
        // session stays done. (Armed/done states survive on purpose: the
        // auto-hide detaches the toolbar window between reveals and the
        // kick must not refire per reattach.)
        if case .kicking = kickState {
            releaseToolbarAppearanceKick()
        }
        toolbarAppearanceObservation = nil
        toolbarEffectiveAppearanceObservation = nil
        separatorView?.removeFromSuperview()
        separatorView = nil
        backdropView?.removeFromSuperview()
        backdropView = nil
        cachedTitlebarView = nil
        backdropAnchorView = nil
        backdropAnchorSiblingCount = 0
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
        guard case .pending = kickState else {
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
        guard case .pending = kickState,
              let window = editorWindow,
              let toolbarWindow = observedToolbarWindow,
              toolbarWindow.frame.minY >= window.frame.maxY - 0.5
              || toolbarWindow.alphaValue < 0.05
        else {
            return
        }

        // The one-shot is spent even if the kick below cannot fire (no
        // content view yet): matching the flag pair this replaced, which
        // marked the session done before attempting the flip.
        kickState = .done
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
        let workItem = DispatchWorkItem { [weak self] in
            self?.releaseToolbarAppearanceKick()
        }
        kickState = .kicking(
            view: WeakViewBox(chromeView),
            firedAt: CACurrentMediaTime(),
            release: workItem
        )
        chromeView.appearance = NSAppearance(named: oppositeName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func releaseToolbarAppearanceKick() {
        guard case let .kicking(view, _, release) = kickState else {
            return
        }

        release.cancel()
        view.view?.appearance = nil
        kickState = .done
    }

    /// The single teardown for the kick lifecycle, used when leaving
    /// fullscreen for real: cancels an in-flight release item, restores
    /// the flipped appearance immediately, and disarms the one-shot so
    /// the next fullscreen session starts fresh.
    private func resetKick() {
        if case let .kicking(view, _, release) = kickState {
            release.cancel()
            view.view?.appearance = nil
        }
        kickState = .idle
    }

    /// A reveal can begin inside the kick's 0.35s hold: the hover both
    /// schedules the kick (the toolbar window is still parked when it
    /// fires) and, a beat later, starts the reveal animation — which would
    /// slide the whole band in wearing the opposite theme. The first move
    /// notification of the reveal arrives before its frame is committed,
    /// so releasing here keeps the flipped repaint off screen. A kick that
    /// held for less than one render pass is re-armed so a later parked
    /// period can redo it.
    private func abortKickIfToolbarOnScreen() {
        guard case let .kicking(_, firedAt, _) = kickState,
              let window = editorWindow,
              let toolbarWindow = observedToolbarWindow,
              toolbarWindow.frame.minY < window.frame.maxY - 0.5
        else {
            return
        }

        let rearm = CACurrentMediaTime() - firedAt < 0.05
        releaseToolbarAppearanceKick()
        if rearm {
            kickState = .pending
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
        let separator = FullScreenToolbarSeparatorView(frame: .zero)
        // The auto-hide detaches the toolbar window between reveals, so this
        // runs again per reveal: the fresh separator has to start at the
        // visibility the content is already in, without animating into it.
        separator.alphaValue = isSeparatorVisible ? 1 : 0
        separator.separatorOpacity = separatorOpacity
        contentView.addSubview(separator)
        separatorView = separator

        // Pinned by constraints rather than springs on purpose:
        // NSToolbarFullScreenContentView is flipped, so a spring-held view at
        // y = 0 with a flexible margin above it sticks to the *top* of the
        // band — the edge that slides in under the menu bar — while
        // bottomAnchor means the same edge in either coordinate system.
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor
            ),
            separator.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor
            ),
            separator.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor
            ),
            separator.heightAnchor.constraint(
                equalToConstant: EditorShellState.topChromeSeparatorThickness
            ),
        ])
    }

    /// Mirrors the in-content band's hairline: it only marks the chrome edge
    /// once content has moved under it, since at the top of the document the
    /// band and the text share one flat surface. Unlike the windowed rule
    /// this keeps the hairline while the tab bar is up — the toolbar window
    /// carries the accessory row's bottom padding, so its edge stays clear of
    /// the tab capsules instead of cutting through them.
    private func observeSeparatorAppearance(of session: EditorDocumentSession) {
        // @Published emits in willSet, so the sunk values are the new ones
        // while the state object still reads stale; drive the update from
        // the combined values rather than reading the state again.
        let state = session.shellState
        separatorAppearanceCancellable = Publishers.CombineLatest3(
            state.$isContentScrolled,
            state.$isTabBarVisible,
            state.$isSearchPresented
        )
        .sink { [weak self] values in
            let (isContentScrolled, isTabBarVisible, isSearchPresented) = values
            let opacity = EditorShellState.topChromeSeparatorOpacity
            self?.setSeparatorAppearance(
                isVisible: isContentScrolled,
                opacity: opacity
            )
        }
    }

    private func setSeparatorAppearance(
        isVisible: Bool,
        opacity: CGFloat
    ) {
        let visibilityChanged = isSeparatorVisible != isVisible
        isSeparatorVisible = isVisible
        separatorOpacity = opacity
        separatorView?.separatorOpacity = opacity

        guard visibilityChanged, let separatorView else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            separatorView.animator().alphaValue = isVisible ? 1 : 0
        }
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
        guard let titlebarView = resolvedTitlebarView(in: toolbarWindow) else {
            return
        }

        let siblings = titlebarView.subviews

        if let backdrop = backdropView, backdrop.superview === titlebarView {
            guard let backdropIndex = siblings.firstIndex(of: backdrop) else {
                return
            }

            // The anchor scan walks subtrees and this runs on every move of
            // the reveal animation, so its result is kept: the cached anchor
            // still describes the stacking as long as it is a sibling, the
            // backdrop is still below it, and the sibling list has neither
            // grown nor shrunk — the tab bar accessory arriving or leaving
            // changes that count, which is precisely when the anchor has to
            // be found again.
            if let anchorView = backdropAnchorView,
               anchorView.superview === titlebarView,
               siblings.count == backdropAnchorSiblingCount,
               let anchorIndex = siblings.firstIndex(of: anchorView),
               backdropIndex < anchorIndex
            {
                return
            }

            // A tab bar accessory that appears after the install (second
            // tab opened while already fullscreen) lands below the backdrop
            // and would be painted over; re-anchor when that happens.
            let anchorView = findBackdropAnchor(among: siblings)
            if let anchorView,
               let anchorIndex = siblings.firstIndex(of: anchorView),
               backdropIndex > anchorIndex
            {
                backdrop.removeFromSuperview()
                titlebarView.addSubview(
                    backdrop,
                    positioned: .below,
                    relativeTo: anchorView
                )
            }
            cacheBackdropAnchor(anchorView, in: titlebarView)
            return
        }

        backdropView?.removeFromSuperview()
        let anchorView = findBackdropAnchor(among: siblings)
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
        cacheBackdropAnchor(anchorView, in: titlebarView)
    }

    /// The tab bar rides along as a titlebar accessory, wrapped in an
    /// anonymous NSView sibling of NSToolbarView. The opaque backdrop has
    /// to slot in below whichever of the two sits lowest, or it paints
    /// over the tab bar: invisible tabs that still receive mouse events
    /// through the backdrop's nil hitTest.
    private func findBackdropAnchor(among siblings: [NSView]) -> NSView? {
        siblings.first { subview in
            subview !== backdropView
                && subview.containsView(
                    ofAnyClass: PrivateChromeClass.backdropAnchors
                )
        }
    }

    /// Recorded after the stacking has been mutated, so the sibling count
    /// includes the backdrop itself and the next pass compares like with
    /// like.
    private func cacheBackdropAnchor(_ anchorView: NSView?, in titlebarView: NSView) {
        backdropAnchorView = anchorView
        backdropAnchorSiblingCount = titlebarView.subviews.count
    }

    /// NSTitlebarView is found once and kept: AppKit only swaps it out by
    /// tearing the chrome down, which detaches the cached one first and so
    /// invalidates it here.
    private func resolvedTitlebarView(in toolbarWindow: NSWindow) -> NSView? {
        if let cachedTitlebarView,
           cachedTitlebarView.window === toolbarWindow,
           cachedTitlebarView.superview != nil
        {
            return cachedTitlebarView
        }

        guard let contentView = toolbarWindow.contentView else {
            cachedTitlebarView = nil
            return nil
        }

        let titlebarView = contentView.firstDescendant(
            ofClass: PrivateChromeClass.titlebarView
        )
        cachedTitlebarView = titlebarView
        return titlebarView
    }

    private func hideBackdropLayerViews(in view: NSView) {
        view.forEachDescendant { subview in
            // The tab bar accessory draws its tabs with backdrop-backed
            // glass of its own; hiding those layers erases the tabs while
            // AppKit keeps reserving their row. Matched on a fragment of the
            // class name rather than a fixed list: the accessory and tab bar
            // classes are renamed between releases, and skipping one row too
            // many is recoverable where erasing the tabs is not.
            let className = String(describing: type(of: subview))
            if className.contains("Accessory") || className.contains("TabBar") {
                return false
            }
            guard !(subview is FullScreenToolbarBackdropView),
                  let layer = subview.layer
            else {
                return true
            }

            // Backdrop layers carry the stale glass recipe; portal
            // layers can replay hidden sources during the reveal
            // animation frames.
            if layer.hasExactClass(anyOf: PrivateChromeClass.staleGlassLayers),
               !subview.isHidden
            {
                subview.isHidden = true
            }
            // NSTitlebarBackgroundView keeps an opaque white backing
            // color even in dark mode; it flashes through during the
            // reveal animation when the glass band above it is gone.
            if subview.hasExactClass(PrivateChromeClass.titlebarBackgroundView),
               layer.backgroundColor != nil
            {
                layer.backgroundColor = nil
                subview.isHidden = true
            }
            return true
        }
    }

    /// The part of the auto-hidden menu bar that slides over the fullscreen
    /// window. On displays that reserve a band for the menu bar (notch) the
    /// fullscreen window stops below it and the menu bar never overlaps, so
    /// the overlap is 0 there. Both the chrome overlay height and the
    /// toolbar window's legitimate reveal offset are measured against it.
    nonisolated static func menuBarOverlap(
        menuBarHeight: CGFloat,
        windowMaxY: CGFloat,
        screenMaxY: CGFloat
    ) -> CGFloat {
        max(0, menuBarHeight - max(0, screenMaxY - windowMaxY))
    }

    private var menuBarOverlap: CGFloat {
        guard let window = editorWindow, let screen = window.screen else {
            return 0
        }

        return Self.menuBarOverlap(
            menuBarHeight: NSApp.mainMenu?.menuBarHeight ?? 0,
            windowMaxY: window.frame.maxY,
            screenMaxY: screen.frame.maxY
        )
    }

    /// The editor keeps unscrolled text below the auto-hidden fullscreen
    /// chrome; the overlay is the toolbar window (toolbar + tab bar) plus
    /// whatever part of the menu bar slides over the content.
    private func reportChromeOverlayHeight() {
        guard let session, let toolbarWindow = observedToolbarWindow else {
            return
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
        abortKickIfToolbarOnScreen()
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
            height: toolbarWindow.frame.height,
            revealAllowance: menuBarOverlap
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

    /// AppKit's parked "hidden" spots leave slivers of varying height on
    /// screen (12pt and 29pt observed), so anything within this much of a
    /// resting position counts as being at that position.
    nonisolated private static let positionSlack: CGFloat = 40
    /// The points over which the band crosses between invisible and opaque.
    nonisolated private static let fadeSpan: CGFloat = 32

    /// Opaque only inside the legitimate reveal zone at the top of the
    /// screen. AppKit's parked "hidden" spots leave slivers on screen, so
    /// anything up to `positionSlack` rests invisible. A reveal slides in
    /// *under* the auto-hidden menu bar, so it legitimately rests lower
    /// than the fully revealed spot by exactly the part of the menu bar
    /// that overlaps the window — `revealAllowance` — and the plateau
    /// extends that far before fading back out. That overshoot used to be
    /// hardcoded at ~30pt, which faded (and then clamped away) a real
    /// reveal on displays with a taller menu bar. A window parked way
    /// outside the zone (AppKit creates new tabs' toolbar windows at the
    /// screen origin, i.e. the bottom edge) stays invisible too.
    nonisolated static func fadeAlpha(
        band: CGFloat,
        height: CGFloat,
        revealAllowance: CGFloat
    ) -> CGFloat {
        // The rise starts at a fixed offset so parked slivers keep resting
        // invisible however tall the menu bar is, and ends no later than
        // the fully revealed position: a toolbar window shorter than the
        // fade span (52pt with no tab bar, on a display whose menu bar
        // never overlaps) would otherwise sit mid-ramp — translucent —
        // exactly when it is all the way out.
        let fullyRevealed = height + revealAllowance
        let riseStart = positionSlack
        let riseEnd = max(
            riseStart + 1,
            min(riseStart + fadeSpan, fullyRevealed)
        )
        let dropStart = fullyRevealed + positionSlack
        let dropEnd = fullyRevealed + positionSlack + fadeSpan

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

    /// How far below the fully revealed spot a legitimate reveal can rest.
    /// Deliberately the same bound as `fadeAlpha`'s drop-off: everything
    /// past it has already faded to alpha 0, which is what makes clamping
    /// it back off screen invisible.
    nonisolated static func revealFloorOffset(revealAllowance: CGFloat) -> CGFloat {
        revealAllowance + positionSlack + fadeSpan
    }

    /// NSEvent.mouseLocation reports the top row of a display as exactly
    /// screen.frame.maxY, and CGRect.contains is half-open at the top edge
    /// — so a pointer parked in the slid-in menu bar, the one position that
    /// keeps a reveal alive, read as "off this screen" and had the reveal
    /// clamped away under it. One point of slop on every edge covers the
    /// convention mismatch without reaching a neighbouring display.
    nonisolated static func pointerBelongsToScreen(
        pointer: NSPoint,
        screenFrame: NSRect
    ) -> Bool {
        screenFrame.insetBy(dx: -1, dy: -1).contains(pointer)
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
        let pointerOnScreen = window.screen.map {
            Self.pointerBelongsToScreen(pointer: pointer, screenFrame: $0.frame)
        } ?? true
        let revealFloor = revealedY - Self.revealFloorOffset(
            revealAllowance: menuBarOverlap
        )
        if pointerOnScreen,
           minY >= revealFloor, pointer.y >= minY - 250
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
        guard minY >= revealFloor else {
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

/// Matches the in-content chrome separator, including its stronger plain-
/// toolbar treatment when neither tabs nor search are open.
private final class FullScreenToolbarSeparatorView: NSView {
    var separatorOpacity = EditorShellState.topChromeSeparatorOpacity {
        didSet {
            guard separatorOpacity != oldValue else {
                return
            }
            needsDisplay = true
        }
    }

    override func draw(_: NSRect) {
        NSColor.labelColor
            .withAlphaComponent(separatorOpacity)
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
