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
        installOpenDocumentsHandler()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        ensureInitialSceneWindow(attempt: 0)
    }

    /// The WindowGroup normally materializes its first window before the app
    /// finishes launching, but a launch whose only purpose is opening a
    /// document can produce no scene at all: the open-documents event is
    /// claimed by this delegate (see installOpenDocumentsHandler), SwiftUI
    /// finds nothing to restore and nothing it should open itself, and the
    /// app ends up running with no window — and stuck, because the pending
    /// open URLs are only flushed once a window's host has appeared. A
    /// reopen event — the same thing clicking the Dock icon sends — makes
    /// the WindowGroup build its initial window, after which session
    /// restoration and the pending opens run their normal course.
    private func ensureInitialSceneWindow(attempt: Int) {
        guard appState == nil, attempt < 5 else {
            return
        }

        if attempt > 0 {
            sendSelfReopenEvent()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.ensureInitialSceneWindow(attempt: attempt + 1)
        }
    }

    private func sendSelfReopenEvent() {
        let target = NSAppleEventDescriptor(
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        guard let descriptor = event.aeDesc else {
            return
        }

        AESendMessage(descriptor, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        appState?.canTerminateAfterLastWindowClosed ?? true
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

    /// SwiftUI's scene machinery claims the open-documents Apple Event and
    /// answers it by opening WindowGroup windows with no scene value — windows
    /// the editor host can only dismiss again — while
    /// `application(_:openFiles:)` is never called at all. Handling the event
    /// here is what lets an editor built on WindowGroup (rather than
    /// DocumentGroup) see files opened from Finder, `open`, or the CLI. The
    /// delegate callbacks are kept as a fallback for the case where AppKit's
    /// own handler wins instead; only one of the two paths can be installed,
    /// so a file is never opened twice.
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
        guard let appState else {
            pendingOpenURLs.append(url)
            return
        }

        appState.queueExternalOpen(url)
    }

    private func flushPendingOpenURLs() {
        guard let appState, !pendingOpenURLs.isEmpty else {
            return
        }

        let urls = pendingOpenURLs
        pendingOpenURLs = []
        for url in urls {
            appState.queueExternalOpen(url)
        }
    }
}
