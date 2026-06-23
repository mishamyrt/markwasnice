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
