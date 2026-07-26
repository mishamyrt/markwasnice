import AppKit

enum EditorWindowChrome {
    /// The single source of the transparent-titlebar placeholder toolbar
    /// configuration that the chrome geometry (toolbar reveal height, tab-bar
    /// insets) is calibrated against. Every path that (re)creates the base
    /// toolbar must go through here so the configuration cannot drift.
    /// ChromeToolbarController builds its own toolbar with items on top of
    /// this baseline; that one is intentionally different.
    static func installBaseToolbar(on window: NSWindow) {
        window.titlebarAppearsTransparent = true
        if window.toolbar == nil {
            let toolbar = NSToolbar()
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
        }
        window.toolbarStyle = .unified
    }
}

/// AppKit assembles the window chrome out of private classes with no public
/// API, so their names are the only handle the app has on them. Every such
/// name lives here, resolved to a class object once and matched by identity
/// afterwards: the walks below run on every frame of a fullscreen reveal and
/// of a live resize, where the per-view string work was the whole cost.
/// Resolution is deliberately nil-safe — a class that no longer exists on
/// this OS version resolves to nothing and then simply never matches, which
/// is exactly how a comparison against a name nothing answers to behaved.
@MainActor
enum PrivateChromeClass {
    /// The auxiliary window AppKit slides the fullscreen chrome in from.
    static let toolbarFullScreenWindow: AnyClass? = resolve(
        "NSToolbarFullScreenWindow"
    )

    /// The chrome container the opaque fullscreen backdrop is installed into.
    static let titlebarView: AnyClass? = resolve("NSTitlebarView")

    /// Keeps an opaque white backing color even in dark mode; it flashes
    /// through during the fullscreen reveal once the glass band above it is
    /// gone.
    static let titlebarBackgroundView: AnyClass? = resolve(
        "NSTitlebarBackgroundView"
    )

    /// The 36pt container the tab bar accessory row is masked by.
    static let titlebarAccessoryContainer: AnyClass? = resolve(
        "NSTitlebarAccessoryContainerView"
    )

    /// Everything the fullscreen backdrop must stay below, matched on the view
    /// itself or on a descendant. The accessory wrapper has no class of its
    /// own, so it is recognized by what it carries — and by more than one
    /// marker on purpose: the private container/clip classes come and go
    /// between releases (NSTitlebarAccessoryClipView is gone as of macOS 27),
    /// and a marker that stops matching silently puts the opaque backdrop on
    /// top of the tab bar.
    static let backdropAnchors = resolveAll(
        "NSToolbarView",
        "NSTitlebarAccessoryContainerView",
        "NSTitlebarAccessoryClipView",
        "NSTabBar"
    )

    /// Backdrop layers carry the stale glass recipe; portal layers can replay
    /// hidden sources during the reveal animation frames.
    static let staleGlassLayers = resolveAll("CABackdropLayer", "CAPortalLayer")

    private static func resolve(_ name: String) -> AnyClass? {
        NSClassFromString(name)
    }

    private static func resolveAll(_ names: String...) -> [AnyClass] {
        names.compactMap { NSClassFromString($0) }
    }
}

extension NSObject {
    /// Exact class identity: subclasses deliberately do not match, mirroring
    /// the class-name comparisons this replaced. An unresolved marker is nil
    /// and never matches.
    func hasExactClass(_ markerClass: AnyClass?) -> Bool {
        type(of: self) == markerClass
    }

    func hasExactClass(anyOf markerClasses: [AnyClass]) -> Bool {
        let ownClass: AnyClass = type(of: self)
        return markerClasses.contains { $0 == ownClass }
    }
}

extension NSView {
    /// Depth first, each subview before its own descendants and `self`
    /// excluded — the order the hand-rolled chrome walks used. Returning
    /// false from `visit` prunes that subview's subtree.
    func forEachDescendant(_ visit: (NSView) -> Bool) {
        for subview in subviews where visit(subview) {
            subview.forEachDescendant(visit)
        }
    }

    func firstDescendant(where matches: (NSView) -> Bool) -> NSView? {
        for subview in subviews {
            if matches(subview) {
                return subview
            }
            if let match = subview.firstDescendant(where: matches) {
                return match
            }
        }
        return nil
    }

    func firstDescendant(ofClass markerClass: AnyClass?) -> NSView? {
        guard markerClass != nil else {
            return nil
        }

        return firstDescendant { $0.hasExactClass(markerClass) }
    }

    /// True when `self` or any descendant is exactly one of `markerClasses`.
    /// One traversal for the whole marker list: the markers are alternative
    /// spellings of the same thing, so only the verdict matters.
    func containsView(ofAnyClass markerClasses: [AnyClass]) -> Bool {
        if hasExactClass(anyOf: markerClasses) {
            return true
        }

        return firstDescendant { $0.hasExactClass(anyOf: markerClasses) } != nil
    }
}
