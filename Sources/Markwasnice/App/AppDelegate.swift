import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settingsStore = EditorSettingsStore()
    private let autosaveStore = AutosaveStore()
    private var autosaveWorkItem: DispatchWorkItem?
    private(set) var isTerminating = false
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

        DispatchQueue.main.async { [weak self] in
            guard let self, NSDocumentController.shared.documents.isEmpty else {
                return
            }

            if !self.restoreAutosavedSession() {
                self.newDocument(nil)
            }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        flushAutosave(force: true)
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText
        ]

        guard panel.runModal() == .OK else {
            return
        }

        for url in panel.urls {
            open(url)
        }
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
        guard !filenames.isEmpty else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        let didOpenAll = filenames.allSatisfy { filename in
            open(URL(fileURLWithPath: filename))
        }
        sender.reply(toOpenOrPrint: didOpenAll ? .success : .failure)
    }

    @objc func newDocument(_ sender: Any?) {
        let document = MarkdownDocument(settings: settings)
        show(document)
        scheduleAutosave()
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let document = currentDocument() else {
            return
        }

        guard let url = document.fileURL else {
            saveDocumentAs(sender)
            return
        }

        document.save(to: url, ofType: MarkdownDocument.fileType, for: .saveOperation) { error in
            self.presentSaveErrorIfNeeded(error)
            self.scheduleAutosave()
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let document = currentDocument() else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = document.fileURL?.lastPathComponent ?? "Untitled.md"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        document.save(to: url, ofType: MarkdownDocument.fileType, for: .saveAsOperation) { error in
            self.presentSaveErrorIfNeeded(error)
            self.scheduleAutosave()
        }
    }

    @objc func pasteAsLink(_ sender: Any?) {
        currentWindowController()?.pasteAsLink()
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(settings: settings) { [weak self] settings in
                guard let self else {
                    return
                }

                self.settings = settings
                self.settingsStore.save(settings)
                for document in NSDocumentController.shared.documents {
                    (document as? MarkdownDocument)?.applySettings(settings)
                }
            }
        }

        preferencesWindowController?.update(settings: settings)
        preferencesWindowController?.showWindow(sender)
        preferencesWindowController?.window?.center()
        preferencesWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @discardableResult
    private func open(_ url: URL) -> Bool {
        if let document = NSDocumentController.shared.document(for: url) {
            document.showWindows()
            return true
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let document = MarkdownDocument(settings: settings)
            document.loadText(text, from: url)
            show(document)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            scheduleAutosave()
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            return false
        }
    }

    private func show(_ document: MarkdownDocument) {
        document.onAutosaveNeeded = { [weak self] in
            self?.scheduleAutosave()
        }
        document.onAutosaveNow = { [weak self] in
            self?.flushAutosave()
        }
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    private func restoreAutosavedSession() -> Bool {
        guard let session = autosaveStore.loadSession(), !session.drafts.isEmpty else {
            return false
        }

        for draft in session.drafts {
            let document = MarkdownDocument(settings: settings)
            document.restore(draft)
            show(document)
        }

        return true
    }

    private func scheduleAutosave() {
        guard !isTerminating else {
            return
        }

        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushAutosave()
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func flushAutosave(force: Bool = false) {
        guard force || !isTerminating else {
            return
        }

        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil

        let drafts = NSDocumentController.shared.documents.compactMap { document in
            (document as? MarkdownDocument)?.autosavedDraft
        }
        autosaveStore.saveSession(AutosavedSession(drafts: drafts))
    }

    private func currentDocument() -> MarkdownDocument? {
        if let document = currentWindowController()?.document as? MarkdownDocument {
            return document
        }

        return NSDocumentController.shared.currentDocument as? MarkdownDocument
    }

    private func currentWindowController() -> MarkdownDocumentWindowController? {
        NSApp.keyWindow?.windowController as? MarkdownDocumentWindowController
    }

    private func presentSaveErrorIfNeeded(_ error: Error?) {
        guard let error else {
            return
        }

        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
