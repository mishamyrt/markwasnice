import AppKit

@MainActor
enum MainMenu {
    static func install(delegate: AppDelegate) {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        appMenuItem.submenu = applicationMenu(delegate: delegate)

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        fileMenuItem.submenu = fileMenu(delegate: delegate)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        editMenuItem.submenu = editMenu(delegate: delegate)

        NSApp.mainMenu = mainMenu
    }

    private static func applicationMenu(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        let settingsItem = menu.addItem(
            withTitle: "Settings...",
            action: #selector(AppDelegate.showPreferences(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = delegate
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit Markwasnice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    private static func fileMenu(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.delegate = delegate
        let newItem = menu.addItem(
            withTitle: "New",
            action: #selector(AppDelegate.newDocument(_:)),
            keyEquivalent: "n"
        )
        newItem.target = delegate
        let openItem = menu.addItem(
            withTitle: "Open...",
            action: #selector(AppDelegate.openDocument(_:)),
            keyEquivalent: "o"
        )
        openItem.target = delegate
        let openRecentItem = menu.addItem(
            withTitle: "Open Recent",
            action: nil,
            keyEquivalent: ""
        )
        openRecentItem.submenu = openRecentMenu(delegate: delegate)
        menu.addItem(NSMenuItem.separator())
        let saveItem = menu.addItem(
            withTitle: "Save",
            action: #selector(AppDelegate.saveDocument(_:)),
            keyEquivalent: "s"
        )
        saveItem.target = delegate
        let saveAsItem = menu.addItem(
            withTitle: "Save As...",
            action: #selector(AppDelegate.saveDocumentAs(_:)),
            keyEquivalent: "S"
        )
        saveAsItem.target = delegate
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        return menu
    }

    private static func openRecentMenu(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Open Recent")
        populateOpenRecentMenu(menu, delegate: delegate)
        return menu
    }

    static func populateOpenRecentMenu(_ menu: NSMenu, delegate: AppDelegate) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let item = menu.addItem(
                withTitle: "No Recent Documents",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            return
        }

        for url in urls {
            let item = menu.addItem(
                withTitle: url.lastPathComponent,
                action: #selector(AppDelegate.openRecentDocument(_:)),
                keyEquivalent: ""
            )
            item.representedObject = url
            item.target = delegate
        }
    }

    private static func editMenu(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        menu.addItem(
            withTitle: "Paste as Link",
            action: #selector(AppDelegate.pasteAsLink(_:)),
            keyEquivalent: "V"
        ).target = delegate
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        return menu
    }
}
