import AppKit
import SwiftUI

@main
struct MarkwasniceApp: App {
    @NSApplicationDelegateAdaptor(SwiftUIAppDelegate.self)
    private var appDelegate

    init() {
        LilexFontProvider.registerFonts()
        PlexSansFontProvider.registerFonts()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            MarkwasniceCommands(appState: appDelegate.appState)
        }
    }
}

@MainActor
final class SwiftUIAppDelegate: NSObject, NSApplicationDelegate {
    let appState: MarkwasniceAppState
    private let windowCoordinator: EditorWindowCoordinator
    private var pendingOpenURLs: [URL] = []
    private var didStartWindowCoordinator = false

    override init() {
        let appState = MarkwasniceAppState()
        self.appState = appState
        windowCoordinator = EditorWindowCoordinator(appState: appState)
        super.init()
    }

    func applicationWillFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // Opt the coordinator-owned editor windows into native tab grouping
        // and dragging between tab bars.
        NSWindow.allowsAutomaticWindowTabbing = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidAddItem(_:)),
            name: NSMenu.didAddItemNotification,
            object: nil
        )
        installOpenDocumentsHandler()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        SystemMenuCustomization.hideDefaultTabCommands(in: NSApp.mainMenu)
        Task {
            await windowCoordinator.start()
            NSApplication.shared.activate(ignoringOtherApps: true)
            didStartWindowCoordinator = true
            flushPendingOpenURLs()
        }
    }

    @objc private func menuDidAddItem(_: Notification) {
        SystemMenuCustomization.hideDefaultTabCommands(in: NSApp.mainMenu)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        appState.canTerminateAfterLastWindowClosed
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        if !windowCoordinator.hasVisibleEditorWindows {
            appState.requestNewWindow()
        }
        return true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        Task {
            let didFlush = await appState.flushAutosaveAndWait(force: true)
            let shouldTerminate = didFlush || Self.confirmTerminateAfterFailedFlush()
            NSApplication.shared.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    private static func confirmTerminateAfterFailedFlush() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Unsaved drafts could not be saved."
        alert.informativeText =
            "Autosaving your open documents failed. If you quit now, "
                + "recent changes in unsaved documents will be lost."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Handle Finder/CLI opens explicitly so all documents enter the same
    /// registry and AppKit window-coordinator path.
    private func installOpenDocumentsHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocumentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
    }

    @objc
    private func handleOpenDocumentsEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent _: NSAppleEventDescriptor
    ) {
        guard let directObject = event.paramDescriptor(forKeyword: keyDirectObject)
        else {
            return
        }

        for url in Self.fileURLs(in: directObject) {
            queueOpen(url)
        }
    }

    /// The direct object is a list of file descriptors, or a single one when
    /// exactly one file was opened.
    private static func fileURLs(in descriptor: NSAppleEventDescriptor) -> [URL] {
        guard descriptor.numberOfItems > 0 else {
            return [fileURL(from: descriptor)].compactMap(\.self)
        }

        return (1 ... descriptor.numberOfItems).compactMap { index in
            descriptor.atIndex(index).flatMap(fileURL(from:))
        }
    }

    private static func fileURL(from descriptor: NSAppleEventDescriptor) -> URL? {
        guard let coerced = descriptor.coerce(toDescriptorType: typeFileURL),
              let string = String(data: coerced.data, encoding: .utf8)
        else {
            return nil
        }

        return URL(string: string)
    }

    func application(_: NSApplication, openFile filename: String) -> Bool {
        queueOpen(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !filenames.isEmpty else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }

        for filename in filenames {
            queueOpen(URL(fileURLWithPath: filename))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private func queueOpen(_ url: URL) {
        guard didStartWindowCoordinator else {
            pendingOpenURLs.append(url)
            return
        }

        appState.queueExternalOpen(url)
    }

    private func flushPendingOpenURLs() {
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        for url in urls {
            appState.queueExternalOpen(url)
        }
    }
}

@MainActor
enum SystemMenuCustomization {
    static func hideDefaultTabCommands(in menu: NSMenu?) {
        guard let menu else {
            return
        }

        for item in menu.items {
            if item.action == #selector(NSWindow.toggleTabBar(_:))
                || item.action == #selector(NSWindow.toggleTabOverview(_:))
            {
                item.isHidden = true
            }
            hideDefaultTabCommands(in: item.submenu)
        }
    }
}
