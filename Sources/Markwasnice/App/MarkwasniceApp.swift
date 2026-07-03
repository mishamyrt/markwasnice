import AppKit
import SwiftUI

@main
struct MarkwasniceApp: App {
    @NSApplicationDelegateAdaptor(SwiftUIAppDelegate.self)
    private var appDelegate
    @StateObject private var appState: MarkwasniceAppState

    init() {
        LilexFontProvider.registerFonts()
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
            await appState.flushAutosaveAndWait(force: true)
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
