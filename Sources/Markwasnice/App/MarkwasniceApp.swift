import AppKit
import SwiftUI

@main
struct MarkwasniceApp: App {
    @NSApplicationDelegateAdaptor(SwiftUIAppDelegate.self)
    private var appDelegate
    @StateObject private var appState: MarkwasniceAppState

    init() {
        LilexFontProvider.registerFonts()
        PlexSansFontProvider.registerFonts()
        _appState = StateObject(wrappedValue: MarkwasniceAppState())
    }

    var body: some Scene {
        WindowGroup("Markwasnice", for: EditorDocumentSession.ID.self) { $sessionID in
            EditorWindowHost(sessionID: $sessionID)
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .commands {
            MarkwasniceCommands(appState: appState)
        }
    }
}

@MainActor
final class SwiftUIAppDelegate: NSObject, NSApplicationDelegate {
    var appState: MarkwasniceAppState? {
        didSet {
            flushPendingOpenURLs()
        }
    }

    private var pendingOpenURLs: [URL] = []

    func applicationWillFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // SwiftUI disables automatic window tabbing for its scenes, which
        // also disables dragging a tab into another window's tab bar.
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else {
            return .terminateNow
        }

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
        guard let appState else {
            pendingOpenURLs.append(url)
            return
        }

        appState.queueOpen(url)
    }

    private func flushPendingOpenURLs() {
        guard let appState, !pendingOpenURLs.isEmpty else {
            return
        }

        let urls = pendingOpenURLs
        pendingOpenURLs = []
        for url in urls {
            _ = appState.queueOpen(url)
        }
    }
}
