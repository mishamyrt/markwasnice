import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settingsStore = EditorSettingsStore()
    private let autosaveStore = AutosaveStore()
    private var mainWindowController: MainWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var settings = EditorSettings(
        textSizeScale: EditorSettings.defaultTextSizeScale,
        maxTextColumns: EditorSettings.defaultMaxTextColumns,
        tabInsertionMode: EditorSettings.defaultTabInsertionMode,
        tabWidth: EditorSettings.defaultTabWidth
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        LilexFontProvider.registerFonts()
        settings = settingsStore.load()
        MainMenu.install(delegate: self)

        let controller = MainWindowController(settings: settings, autosaveStore: autosaveStore, draft: autosaveStore.load())
        mainWindowController = controller
        controller.showWindow(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindowController?.flushAutosave()
        return .terminateNow
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu.title == "File",
            let recentMenu = menu.item(withTitle: "Open Recent")?.submenu
        else {
            return
        }

        MainMenu.populateOpenRecentMenu(recentMenu, delegate: self)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText
        ]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        open(url)
    }

    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else {
            return
        }

        open(url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open(URL(fileURLWithPath: filename))
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let filename = filenames.first else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        sender.reply(toOpenOrPrint: open(URL(fileURLWithPath: filename)) ? .success : .failure)
    }

    @objc func newDocument(_ sender: Any?) {
        _ = mainWindowController?.newDocument()
    }

    @objc func saveDocument(_ sender: Any?) {
        mainWindowController?.saveDocument(sender)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        mainWindowController?.saveDocumentAs(sender)
    }

    @objc func pasteAsLink(_ sender: Any?) {
        mainWindowController?.pasteAsLink()
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(settings: settings) { [weak self] settings in
                guard let self else {
                    return
                }

                self.settings = settings
                self.settingsStore.save(settings)
                self.mainWindowController?.applySettings(settings)
            }
        }

        preferencesWindowController?.update(settings: settings)
        preferencesWindowController?.showWindow(sender)
        preferencesWindowController?.window?.center()
        preferencesWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @discardableResult
    private func open(_ url: URL) -> Bool {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            mainWindowController?.displayMarkdown(text, from: url)
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
    }
}

@MainActor
private enum MainMenu {
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
        let settingsItem = menu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
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
        let newItem = menu.addItem(withTitle: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n")
        newItem.target = delegate
        let openItem = menu.addItem(withTitle: "Open...", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        openItem.target = delegate
        let openRecentItem = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        openRecentItem.submenu = openRecentMenu(delegate: delegate)
        menu.addItem(NSMenuItem.separator())
        let saveItem = menu.addItem(withTitle: "Save", action: #selector(AppDelegate.saveDocument(_:)), keyEquivalent: "s")
        saveItem.target = delegate
        let saveAsItem = menu.addItem(withTitle: "Save As...", action: #selector(AppDelegate.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAsItem.target = delegate
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
            let item = menu.addItem(withTitle: "No Recent Documents", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return
        }

        for url in urls {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(AppDelegate.openRecentDocument(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = delegate
        }
    }

    private static func editMenu(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Paste as Link", action: #selector(AppDelegate.pasteAsLink(_:)), keyEquivalent: "V").target = delegate
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }
}
