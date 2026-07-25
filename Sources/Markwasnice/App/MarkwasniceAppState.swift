import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MarkwasniceAppState: ObservableObject {
    nonisolated private static let autosaveLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Markwasnice",
        category: "autosave"
    )

    @Published private(set) var sessions: [EditorDocumentSession
        .ID: EditorDocumentSession] = [:]
    @Published private(set) var pendingWindowIDs: [EditorDocumentSession.ID] = []
    @Published private(set) var settings: EditorSettings

    private let settingsStore = EditorSettingsStore()
    private let autosaveStore: AutosaveStore
    private var autosaveWorkItem: DispatchWorkItem?
    /// Resolves to false when the write failed; a cancelled (superseded)
    /// flush counts as success because the newer flush covers it.
    private var autosaveTask: Task<Bool, Never>?
    private var preferencesWindowController: PreferencesWindowController?
    private var didCreateInitialSessions = false
    private var activeSessionID: EditorDocumentSession.ID?
    private var tabAttachTargets: [EditorDocumentSession.ID: WeakWindowBox] = [:]
    /// Follower session → lead session of its restored tab group. Resolved to
    /// the lead's window lazily, because at restore time no windows exist yet.
    private var restoreTabLeads: [EditorDocumentSession.ID: EditorDocumentSession.ID] =
        [:]

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
            let drafts = session.drafts
            let restoredSessions = restoredSessions(from: drafts)
            var leadSessionIDs: [UUID: EditorDocumentSession.ID] = [:]
            for (draft, session) in zip(drafts, restoredSessions) {
                guard let windowID = draft.windowID else {
                    continue
                }
                if let leadID = leadSessionIDs[windowID] {
                    restoreTabLeads[session.id] = leadID
                } else {
                    leadSessionIDs[windowID] = session.id
                }
            }
            pendingWindowIDs.append(contentsOf: restoredSessions.dropFirst().map(\.id))
            return restoredSessions[0].id
        }

        return newSession().id
    }

    @discardableResult
    func newSession() -> EditorDocumentSession {
        let session = makeSession(text: "", fileURL: nil, isEdited: false)
        activate(session)
        scheduleAutosave()
        return session
    }

    func requestNewTab(attachedTo window: NSWindow?) {
        let session = newSession()
        placeSession(session, tabTarget: window, queuesWindow: true)
    }

    /// Routes a session toward a window: registers a tab-attach target when
    /// the target window supports editor tabs (with fullscreen targets
    /// getting their tab window opened directly), otherwise queues a regular
    /// window when requested.
    private func placeSession(
        _ session: EditorDocumentSession,
        tabTarget: NSWindow?,
        queuesWindow: Bool
    ) {
        if let tabTarget,
           tabTarget.tabbingIdentifier == EditorWindowTabbing.identifier
        {
            tabAttachTargets[session.id] = WeakWindowBox(window: tabTarget)
            if tabTarget.styleMask.contains(.fullScreen) {
                FullScreenTabWindowFactory.open(
                    session: session,
                    appState: self,
                    attachedTo: tabTarget
                )
                return
            }
        }
        if queuesWindow {
            pendingWindowIDs.append(session.id)
        }
    }

    func takeTabAttachTarget(
        for id: EditorDocumentSession.ID
    ) -> NSWindow? {
        if let window = tabAttachTargets.removeValue(forKey: id)?.window {
            return window
        }

        if let leadID = restoreTabLeads[id],
           let leadWindow = sessions[leadID]?.editorView.window
        {
            restoreTabLeads[id] = nil
            return leadWindow
        }

        return nil
    }

    /// True while a restored tab group still waits for its lead window to
    /// materialize; the caller should retry the attach shortly.
    func hasPendingRestoreTabLead(for id: EditorDocumentSession.ID) -> Bool {
        restoreTabLeads[id] != nil
    }

    func abandonRestoreTabLead(for id: EditorDocumentSession.ID) {
        restoreTabLeads[id] = nil
    }

    @discardableResult
    func queueOpen(_ url: URL, inTabOf window: NSWindow? = nil) -> Bool {
        Task {
            await open(url, queuesWindow: true, tabTarget: window)
        }
        return true
    }

    func openDocuments() {
        // Captured before the panel runs: while the modal panel is up the
        // editor window is no longer key.
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = EditorDocumentSession.markdownContentTypes

        guard panel.runModal() == .OK else {
            return
        }

        for url in panel.urls {
            queueOpen(url, inTabOf: targetWindow)
        }
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

    func insertTable() {
        activeSession?.requestInsertTable()
    }

    func fixTypography() {
        activeSession?.fixTypography()
    }

    func showSearch() {
        activeSession?.showSearch()
    }

    func toggleFocusMode() {
        activeSession?.shellState.toggleFocusMode()
    }

    func toggleProofreading() {
        activeSession?.shellState.toggleProofreading()
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
        let session = AutosavedSession(drafts: autosavedDrafts())
        autosaveTask = Task.detached(priority: .utility) { [autosaveStore, session] in
            guard !Task.isCancelled else {
                return true
            }

            do {
                try await autosaveStore.saveSession(session)
                return true
            } catch {
                Self.autosaveLogger.error(
                    "Failed to write autosaved session: \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        }
    }

    /// Drafts ordered window by window (tabs in their on-screen order), with
    /// a shared window identifier per tab group so the window configuration
    /// can be rebuilt on the next launch.
    private func autosavedDrafts() -> [AutosavedDraft] {
        var drafts: [AutosavedDraft] = []
        var savedSessionIDs = Set<EditorDocumentSession.ID>()

        func session(of window: NSWindow) -> EditorDocumentSession? {
            sessions.values.first { $0.editorView.window === window }
        }

        var visitedGroups = Set<ObjectIdentifier>()
        for window in NSApp.windows {
            guard let windowSession = session(of: window),
                  !savedSessionIDs.contains(windowSession.id)
            else {
                continue
            }

            let groupWindows: [NSWindow]
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                guard visitedGroups.insert(ObjectIdentifier(tabGroup)).inserted
                else {
                    continue
                }
                groupWindows = tabGroup.windows
            } else {
                groupWindows = [window]
            }

            let windowID = UUID()
            let windowFrame = windowFrameDescriptor(for: window)
            for tabWindow in groupWindows {
                guard let tabSession = session(of: tabWindow),
                      savedSessionIDs.insert(tabSession.id).inserted
                else {
                    continue
                }
                drafts.append(tabSession.autosavedDraft(
                    windowID: windowID,
                    windowFrame: windowFrame
                ))
            }
        }

        // Sessions whose window has not materialized yet (e.g. an autosave
        // fired mid-launch) are kept as standalone windows; a frame restored
        // from the previous session but not yet applied is carried over so
        // an early autosave does not wipe it.
        for session in sessions.values where !savedSessionIDs.contains(session.id) {
            drafts.append(session.autosavedDraft(
                windowID: nil,
                windowFrame: session.restoredWindowFrame.map(NSStringFromRect)
            ))
        }
        return drafts
    }

    /// One frame is saved per tab group, read from its selected window:
    /// AppKit syncs a tab window's frame only when that tab is selected, so
    /// hidden tabs carry whatever frame they had when last shown and would
    /// pin the restored group to a long-stale position. Fullscreen frames
    /// are not saved: restoring one as a regular window frame would fill
    /// the screen instead of returning to the last windowed size.
    private func windowFrameDescriptor(for window: NSWindow) -> String? {
        let source = window.tabGroup?.selectedWindow ?? window
        guard !source.styleMask.contains(.fullScreen) else {
            return nil
        }

        return NSStringFromRect(source.frame)
    }

    /// Returns false when the flush failed to write, so the terminate path
    /// can warn before drafts are discarded.
    @discardableResult
    func flushAutosaveAndWait(force: Bool = false) async -> Bool {
        flushAutosave(force: force)
        guard let autosaveTask else {
            return true
        }

        return await autosaveTask.value
    }

    /// Window move/resize only changes the frames stored alongside the
    /// drafts; reuse the debounced autosave so live drags coalesce.
    func noteWindowLayoutChanged() {
        scheduleAutosave()
    }

    private var activeSession: EditorDocumentSession? {
        activeSessionID.flatMap { sessions[$0] }
    }

    private func open(
        _ url: URL,
        queuesWindow: Bool,
        tabTarget: NSWindow? = nil
    ) async {
        if let existing = sessions.values.first(where: { $0.fileURL == url }) {
            activate(existing)
            if queuesWindow {
                pendingWindowIDs.append(existing.id)
            }
            return
        }

        do {
            let text = try await FileIO.readUTF8(from: url)

            // Opening into a window whose current document is still empty
            // reuses that document instead of spawning a tab next to it.
            if tabTarget != nil,
               let active = activeSession,
               active.isEmptyDocument
            {
                active.adoptFile(url: url, text: text)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                scheduleAutosave()
                return
            }

            let session = makeSession(text: text, fileURL: url, isEdited: false)
            activate(session)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            scheduleAutosave()
            placeSession(session, tabTarget: tabTarget, queuesWindow: queuesWindow)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Single construction point for sessions: wires the autosave callback
    /// and registers the session in `sessions`. Activation, autosave
    /// scheduling, and window bookkeeping stay with the callers, which
    /// genuinely differ there.
    private func makeSession(
        text: String,
        fileURL: URL?,
        isEdited: Bool
    ) -> EditorDocumentSession {
        let session = EditorDocumentSession(
            text: text,
            fileURL: fileURL,
            isEdited: isEdited,
            settings: settings
        ) { [weak self] in
            self?.scheduleAutosave()
        }
        session.onOpenFiles = { [weak self] urls, window in
            for url in urls {
                self?.queueOpen(url, inTabOf: window)
            }
        }
        sessions[session.id] = session
        return session
    }

    private func makeSession(
        from draft: AutosavedDraft,
        isEdited: Bool
    ) -> EditorDocumentSession {
        let session = makeSession(
            text: draft.text,
            fileURL: draft.fileURL,
            isEdited: isEdited
        )
        if let descriptor = draft.windowFrame {
            let frame = NSRectFromString(descriptor)
            if !frame.isEmpty {
                session.restoredWindowFrame = frame
            }
        }
        return session
    }

    /// Sessions are created immediately with a provisional edited flag so
    /// the first window never waits on file reads; drafts backed by a file
    /// get the exact flag refined asynchronously.
    private func restoredSessions(
        from drafts: [AutosavedDraft]
    ) -> [EditorDocumentSession] {
        drafts.map { draft in
            let session = makeSession(
                from: draft,
                isEdited: draft.fileURL == nil && !draft.text.isEmpty
            )
            refineRestoredEditedState(of: session, from: draft)
            return session
        }
    }

    private func refineRestoredEditedState(
        of session: EditorDocumentSession,
        from draft: AutosavedDraft
    ) {
        // Without a backing file the provisional flag is already exact.
        guard let fileURL = draft.fileURL, !draft.text.isEmpty else {
            return
        }

        Task { [weak session] in
            let isEdited = await FileIO.hasDifferentUTF8Contents(
                at: fileURL,
                from: draft.text
            )
            session?.applyRestoredEditedState(isEdited, expectedText: draft.text)
        }
    }

    private func applySettings(_ settings: EditorSettings) {
        // Continuous slider drags resend unchanged values; skip the
        // whole-document restyle of every session when nothing changed.
        guard settings != self.settings else {
            return
        }

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
                appState.openDocuments()
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

            Button("Focus Mode") {
                appState.toggleFocusMode()
            }
            .keyboardShortcut("d")

            Button("Proofreading") {
                appState.toggleProofreading()
            }
            .keyboardShortcut("r")
        }

        CommandGroup(after: .pasteboard) {
            Button("Paste as Link") {
                appState.pasteAsLink()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Fix Typography") {
                appState.fixTypography()
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
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

            Divider()
            Button("Insert Table...") {
                appState.insertTable()
            }
            .keyboardShortcut("g", modifiers: [.command, .option])

            Divider()
            markdownCommand(
                "Heading 1", .heading1,
                keyEquivalent: "1", modifiers: [.command, .option]
            )
            markdownCommand(
                "Heading 2", .heading2,
                keyEquivalent: "2", modifiers: [.command, .option]
            )
            markdownCommand(
                "Heading 3", .heading3,
                keyEquivalent: "3", modifiers: [.command, .option]
            )
            markdownCommand(
                "Heading 4", .heading4,
                keyEquivalent: "4", modifiers: [.command, .option]
            )
            markdownCommand(
                "Heading 5", .heading5,
                keyEquivalent: "5", modifiers: [.command, .option]
            )
            markdownCommand(
                "Heading 6", .heading6,
                keyEquivalent: "6", modifiers: [.command, .option]
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
