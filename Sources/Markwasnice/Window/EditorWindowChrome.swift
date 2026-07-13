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
