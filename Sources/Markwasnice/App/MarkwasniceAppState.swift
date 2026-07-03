import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MarkwasniceAppState: ObservableObject {
    @Published private(set) var sessions: [EditorDocumentSession
        .ID: EditorDocumentSession] = [:]
    @Published private(set) var pendingWindowIDs: [EditorDocumentSession.ID] = []
    @Published private(set) var settings: EditorSettings

    private let settingsStore = EditorSettingsStore()
    private let autosaveStore: AutosaveStore
    private var autosaveWorkItem: DispatchWorkItem?
    private var autosaveTask: Task<Void, Never>?
    private var preferencesWindowController: PreferencesWindowController?
    private var didCreateInitialSessions = false
    private var activeSessionID: EditorDocumentSession.ID?
    private var tabAttachTargets: [EditorDocumentSession.ID: WeakWindowBox] = [:]

    init(autosaveStore: AutosaveStore = AutosaveStore()) {
        self.autosaveStore = autosaveStore
        settings = settingsStore.load()
    }

    func session(for id: EditorDocumentSession.ID?) -> EditorDocumentSession? {
        guard let id else {
            return nil
        }

        return sessions[id]
    }

    func initialSessionID() async -> EditorDocumentSession.ID? {
        if !pendingWindowIDs.isEmpty {
            return pendingWindowIDs.removeFirst()
        }

        guard !didCreateInitialSessions else {
            return nil
        }

        didCreateInitialSessions = true
        if let session = await autosaveStore.loadSession(), !session.drafts.isEmpty {
            let restoredSessions = await restoredSessions(from: session.drafts)
            for session in restoredSessions {
                sessions[session.id] = session
            }
            pendingWindowIDs.append(contentsOf: restoredSessions.dropFirst().map(\.id))
            return restoredSessions[0].id
        }

        return newSession().id
    }

    @discardableResult
    func newSession() -> EditorDocumentSession {
        let session = EditorDocumentSession(
            text: "",
            fileURL: nil,
            isEdited: false,
            settings: settings
        ) { [weak self] in
            self?.scheduleAutosave()
        }
        sessions[session.id] = session
        activate(session)
        scheduleAutosave()
        return session
    }

    func requestNewTab(attachedTo window: NSWindow?) {
        let session = newSession()
        if let window,
           window.tabbingIdentifier == EditorWindowTabbing.identifier
        {
            tabAttachTargets[session.id] = WeakWindowBox(window: window)
        }
        pendingWindowIDs.append(session.id)
    }

    func takeTabAttachTarget(
        for id: EditorDocumentSession.ID
    ) -> NSWindow? {
        tabAttachTargets.removeValue(forKey: id)?.window
    }

    @discardableResult
    func queueOpen(_ url: URL) -> Bool {
        Task {
            await open(url, queuesWindow: true)
        }
        return true
    }

    func openDocuments() -> [EditorDocumentSession.ID] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "markdown") ?? .plainText,
        ]

        guard panel.runModal() == .OK else {
            return []
        }

        for url in panel.urls {
            queueOpen(url)
        }
        return []
    }

    func takePendingWindowIDs() -> [EditorDocumentSession.ID] {
        let ids = pendingWindowIDs
        pendingWindowIDs = []
        return ids
    }

    func activate(_ session: EditorDocumentSession) {
        activeSessionID = session.id
    }

    func remove(_ session: EditorDocumentSession) {
        sessions[session.id] = nil
        if activeSessionID == session.id {
            activeSessionID = sessions.keys.first
        }
        scheduleAutosave()
    }

    func saveActiveSession() {
        activeSession?.save()
    }

    func saveActiveSessionAs() {
        activeSession?.saveAs()
    }

    func pasteAsLink() {
        activeSession?.pasteAsLink()
    }

    func applyMarkup(_ command: MarkdownMarkupCommand) {
        activeSession?.applyMarkup(command)
    }

    func showSearch() {
        activeSession?.showSearch()
    }

    func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                settings: settings
            ) { [weak self] settings in
                self?.applySettings(settings)
            }
        }

        preferencesWindowController?.update(settings: settings)
        preferencesWindowController?.showWindow(sender)
        preferencesWindowController?.window?.center()
        preferencesWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    func flushAutosave(force: Bool = false) {
        guard force || !sessions.isEmpty else {
            return
        }

        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        autosaveTask?.cancel()
        let session = AutosavedSession(drafts: sessions.values.map(\.autosavedDraft))
        autosaveTask = Task.detached(priority: .utility) { [autosaveStore, session] in
            guard !Task.isCancelled else {
                return
            }

            await autosaveStore.saveSession(session)
        }
    }

    func flushAutosaveAndWait(force: Bool = false) async {
        flushAutosave(force: force)
        await autosaveTask?.value
    }

    private var activeSession: EditorDocumentSession? {
        activeSessionID.flatMap { sessions[$0] }
    }

    private func open(_ url: URL, queuesWindow: Bool) async {
        if let existing = sessions.values.first(where: { $0.fileURL == url }) {
            activate(existing)
            if queuesWindow {
                pendingWindowIDs.append(existing.id)
            }
            return
        }

        do {
            let text = try await FileIO.readUTF8(from: url)
            let session = EditorDocumentSession(
                text: text,
                fileURL: url,
                isEdited: false,
                settings: settings
            ) { [weak self] in
                self?.scheduleAutosave()
            }
            sessions[session.id] = session
            activate(session)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            scheduleAutosave()
            if queuesWindow {
                pendingWindowIDs.append(session.id)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func makeSession(
        from draft: AutosavedDraft,
        isEdited: Bool
    ) -> EditorDocumentSession {
        EditorDocumentSession(
            text: draft.text,
            fileURL: draft.fileURL,
            isEdited: isEdited,
            settings: settings
        ) { [weak self] in
            self?.scheduleAutosave()
        }
    }

    private func restoredSessions(from drafts: [AutosavedDraft]) async
        -> [EditorDocumentSession]
    {
        var restoredSessions: [EditorDocumentSession] = []
        for draft in drafts {
            let isEdited = await isDraftEdited(draft)
            restoredSessions.append(makeSession(
                from: draft,
                isEdited: isEdited
            ))
        }
        return restoredSessions
    }

    private func applySettings(_ settings: EditorSettings) {
        self.settings = settings
        settingsStore.save(settings)
        for session in sessions.values {
            session.applySettings(settings)
        }
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushAutosave()
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func isDraftEdited(_ draft: AutosavedDraft) async -> Bool {
        guard !draft.text.isEmpty else {
            return false
        }

        guard let fileURL = draft.fileURL else {
            return true
        }

        return await FileIO.hasDifferentUTF8Contents(at: fileURL, from: draft.text)
    }
}

private struct WeakWindowBox {
    weak var window: NSWindow?
}

struct MarkwasniceCommands: Commands {
    @ObservedObject private var appState: MarkwasniceAppState
    @Environment(\.openWindow) private var openWindow

    init(appState: MarkwasniceAppState) {
        self.appState = appState
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                openWindow(value: appState.newSession().id)
            }
            .keyboardShortcut("n")

            Button("New Tab") {
                appState.requestNewTab(
                    attachedTo: NSApp.keyWindow ?? NSApp.mainWindow
                )
            }
            .keyboardShortcut("t")

            Button("Open...") {
                for id in appState.openDocuments() {
                    openWindow(value: id)
                }
            }
            .keyboardShortcut("o")
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w")

            Divider()

            Button("Save") {
                appState.saveActiveSession()
            }
            .keyboardShortcut("s")

            Button("Save As...") {
                appState.saveActiveSessionAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                appState.showPreferences(nil)
            }
            .keyboardShortcut(",")
        }

        CommandGroup(after: .sidebar) {
            Button("Show Tab Bar") {
                NSApp.keyWindow?.toggleTabBar(nil)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
        }

        CommandGroup(after: .pasteboard) {
            Button("Paste as Link") {
                appState.pasteAsLink()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Button("Find") {
                appState.showSearch()
            }
            .keyboardShortcut("f")

            Divider()
            markdownCommand("Bold", .bold, keyEquivalent: "b")
            markdownCommand("Italic", .italic, keyEquivalent: "i")
            markdownCommand(
                "Strikethrough", .strikethrough,
                keyEquivalent: "u", modifiers: [.command, .option]
            )
            markdownCommand(
                "Highlight", .highlight,
                keyEquivalent: "u", modifiers: [.command, .shift]
            )
            markdownCommand("Link", .link, keyEquivalent: "k")
            markdownCommand(
                "Image Link", .imageLink,
                keyEquivalent: "k", modifiers: [.command, .option]
            )
            markdownCommand("Code", .code, keyEquivalent: "j")
            markdownCommand(
                "Code Block", .codeBlock,
                keyEquivalent: "j", modifiers: [.command, .shift]
            )
        }
    }

    private func markdownCommand(
        _ title: String,
        _ command: MarkdownMarkupCommand,
        keyEquivalent: KeyEquivalent,
        modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) {
            appState.applyMarkup(command)
        }
        .keyboardShortcut(keyEquivalent, modifiers: modifiers)
    }
}
