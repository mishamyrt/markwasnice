import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct SystemMenuCustomizationTests {
    @Test func hidesOnlyDefaultWindowTabCommands() {
        let mainMenu = NSMenu(title: "Main")
        let viewMenu = NSMenu(title: "View")
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let defaultTabBar = NSMenuItem(
            title: "Show Tab Bar",
            action: #selector(NSWindow.toggleTabBar(_:)),
            keyEquivalent: ""
        )
        let defaultTabOverview = NSMenuItem(
            title: "Show All Tabs",
            action: #selector(NSWindow.toggleTabOverview(_:)),
            keyEquivalent: ""
        )
        let customTabBar = NSMenuItem(
            title: "Show Tab Bar",
            action: #selector(NSResponder.insertTab(_:)),
            keyEquivalent: "t"
        )
        viewMenu.items = [defaultTabBar, defaultTabOverview, customTabBar]

        SystemMenuCustomization.hideDefaultTabCommands(in: mainMenu)

        #expect(defaultTabBar.isHidden)
        #expect(defaultTabOverview.isHidden)
        #expect(!customTabBar.isHidden)
    }
}
