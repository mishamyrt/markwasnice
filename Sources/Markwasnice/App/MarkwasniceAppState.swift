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
    /// True while the most recent autosave write failed; cleared by the next
    /// successful flush.
    @Published private(set) var isAutosaveFailing = false

    private let settingsStore: EditorSettingsStore
    private let autosaveStore: AutosaveStore
    private var documentRegistry = DocumentRegistry()
    private var autosaveWorkItem: DispatchWorkItem?
    /// Resolves to false when the write failed; a cancelled (superseded)
    /// flush counts as success because the newer flush covers it.
    private var autosaveTask: Task<Bool, Never>?
    private var autosaveGeneration: UInt64 = 0
    /// Clean documents that could not be reopened at launch. They carry no
    /// text, but their manifest entries must survive subsequent autosaves so
    /// a transiently unavailable volume does not silently lose the tab.
    private var unresolvedAutosavedDrafts: [AutosavedDraft] = []
    /// An unexpected recovery read/quarantine failure must not be followed by
    /// a successful overwrite of the file we could not inspect.
    private var areAutosaveWritesBlocked = false
    /// The failure alert is shown at most once per launch; a session that
    /// cannot autosave has already been told, and repeating it on every
    /// later failure would only get in the way of saving files by hand.
    private var didReportAutosaveFailure = false
    private var preferencesWindowController: PreferencesWindowController?
    /// Trailing edge of a settings drag: see `applySettings(_:phase:)`.
    private var settingsRolloutWorkItem: DispatchWorkItem?
    private var didCreateInitialSessions = false
    /// Set while the launch-time sessions are being read back from autosave:
    /// for that moment the app has neither a session nor a window.
    private var isResolvingInitialSessions = false
    @Published private var activeSessionID: EditorDocumentSession.ID?
    /// Externally opened documents whose window has not materialized yet: they
    /// still owe the app an activation (see `revealDocument`).
    private var sessionsAwaitingActivation: Set<EditorDocumentSession.ID> = []
    private var tabAttachTargets: [EditorDocumentSession.ID: WeakWindowBox] = [:]
    /// Follower session → lead session of its restored tab group. Resolved to
    /// the lead's window lazily, because at restore time no windows exist yet.
    private var restoreTabLeads: [EditorDocumentSession.ID: EditorDocumentSession.ID] =
        [:]

    init(
        autosaveStore: AutosaveStore = AutosaveStore(),
        settingsStore: EditorSettingsStore = EditorSettingsStore()
    ) {
        self.autosaveStore = autosaveStore
        self.settingsStore = settingsStore
        settings = settingsStore.load()
    }

    /// SwiftUI restores its own scene windows at launch with no session value,
    /// and the editor host dismisses them again. Quitting on those closures
    /// would kill the app before its real windows have appeared, so the app
    /// only quits once no session is left and none is on its way.
    var canTerminateAfterLastWindowClosed: Bool {
        sessions.isEmpty && !isResolvingInitialSessions
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
        isResolvingInitialSessions = true
        defer {
            isResolvingInitialSessions = false
            scheduleAutosave()
        }
        let autosaved = await loadAutosavedSession()

        if let autosaved, !autosaved.drafts.isEmpty {
            let drafts = deduplicatedDrafts(autosaved.drafts)
            let restoredSessions = await restoredSessions(from: drafts)
            guard let firstRestoredSession = restoredSessions.first else {
                return newSession().id
            }

            var leadSessionIDs: [UUID: EditorDocumentSession.ID] = [:]
            for (draft, session) in restoredSessions {
                guard let windowID = draft.windowID else {
                    continue
                }
                if let leadID = leadSessionIDs[windowID] {
                    restoreTabLeads[session.id] = leadID
                } else {
                    leadSessionIDs[windowID] = session.id
                }
            }
            pendingWindowIDs.append(
                contentsOf: restoredSessions.dropFirst().map(\.session.id)
            )
            return firstRestoredSession.session.id
        }

        return newSession().id
    }

    private func loadAutosavedSession() async -> AutosavedSession? {
        do {
            switch try await autosaveStore.loadSession() {
            case .missing:
                return nil
            case let .loaded(session):
                return session
            case let .corruptFileQuarantined(backupURL):
                Self.autosaveLogger.error(
                    "Quarantined an unreadable autosave at \(backupURL.path, privacy: .public)"
                )
                return nil
            }
        } catch {
            // Keep the recovery file untouched for this launch. A later write
            // becoming possible must not destroy data that a transient read
            // or quarantine failure prevented us from inspecting.
            areAutosaveWritesBlocked = true
            isAutosaveFailing = true
            didReportAutosaveFailure = true
            Self.autosaveLogger.error(
                "Failed to read autosaved session: \(error.localizedDescription, privacy: .public)"
            )

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Autosaved drafts could not be read."
            alert.informativeText =
                "Markwasnice will not overwrite its recovery file during this "
                    + "launch. \(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }
    }

    private func deduplicatedDrafts(_ drafts: [AutosavedDraft]) -> [AutosavedDraft] {
        var documentURLs: Set<URL> = []
        return drafts.compactMap { draft in
            guard let fileURL = draft.fileURL else {
                return draft
            }

            guard !documentURLs.insert(
                FileIO.canonicalDocumentURL(for: fileURL)
            ).inserted else {
                return draft
            }

            // Older builds could autosave two editors for one URL. Preserve a
            // later recovery payload as an untitled document. A clean entry
            // has no second copy of the text to preserve and can be skipped.
            guard draft.text != nil else {
                return nil
            }
            var recoveredCopy = draft
            recoveredCopy.fileURL = nil
            return recoveredCopy
        }
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
            // Fullscreen targets and targets on another space both need the
            // tab to join the group before it is ever shown (see
            // EditorTabWindowFactory); the latter happens when an external
            // open arrives from a space the editor is not on.
            if tabTarget.styleMask.contains(.fullScreen)
                || !tabTarget.isOnActiveSpace
            {
                EditorTabWindowFactory.open(
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

        if let leadID = takeRestoreTabLead(for: id, ifReady: { leadID in
            sessions[leadID]?.editorView.window?.isVisible == true
        }),
            let leadWindow = sessions[leadID]?.editorView.window
        {
            return leadWindow
        }

        return nil
    }

    /// Keeps the follower mapping intact until its lead window is ready for attachment.
    func takeRestoreTabLead(
        for id: EditorDocumentSession.ID,
        ifReady: (EditorDocumentSession.ID) -> Bool
    ) -> EditorDocumentSession.ID? {
        guard let leadID = restoreTabLeads[id], ifReady(leadID) else {
            return nil
        }

        restoreTabLeads[id] = nil
        return leadID
    }

    /// True while a restored tab group still waits for its lead window to
    /// materialize; the caller should retry the attach shortly.
    func hasPendingRestoreTabLead(for id: EditorDocumentSession.ID) -> Bool {
        restoreTabLeads[id] != nil
    }

    func abandonRestoreTabLead(for id: EditorDocumentSession.ID) {
        restoreTabLeads[id] = nil
    }

    func queueOpen(_ url: URL, inTabOf window: NSWindow? = nil) {
        queueOpen(url, placement: .window(window))
    }

    /// Opens a file requested from outside the app — Finder, `open`, or the
    /// `markwasnice` command line launcher — next to the document the user is
    /// already looking at.
    func queueExternalOpen(_ url: URL) {
        queueOpen(url, placement: .frontmostTab)
    }

    /// Awaitable open entry point used by callers that need the document
    /// registry transaction to finish before continuing.
    func openDocument(_ url: URL) async {
        await open(url, queuesWindow: false)
    }

    private func queueOpen(_ url: URL, placement: OpenPlacement) {
        Task {
            await open(url, queuesWindow: true, placement: placement)
        }
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
        documentRegistry.removeSession(session.id)
        sessions[session.id] = nil
        sessionsAwaitingActivation.remove(session.id)
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

    func applyBlockCommand(_ command: MarkdownBlockCommand) {
        activeSession?.applyBlockCommand(command)
    }

    func moveLines(_ command: MarkdownLineMoveCommand) {
        activeSession?.moveLines(command)
    }

    func applyIndent(_ command: MarkdownIndentCommand) {
        activeSession?.applyIndent(command)
    }

    func insertTable() {
        activeSession?.requestInsertTable()
    }

    func fixTypography(in window: NSWindow?) {
        session(in: window)?.fixTypography()
    }

    func showSearch() {
        activeSession?.showSearch()
    }

    func toggleFocusMode() {
        activeSession?.shellState.toggleFocusMode()
    }

    var focusModeToggleTitle: String {
        activeSession?.shellState.focusModeToggleTitle ?? "Enable Focus Mode"
    }

    func toggleProofreading() {
        activeSession?.shellState.toggleProofreading()
    }

    var styleCheckToggleTitle: String {
        activeSession?.shellState.styleCheckToggleTitle ?? "Enable Style Check"
    }

    func increaseTextSize() {
        adjustTextSize(by: 1)
    }

    func decreaseTextSize() {
        adjustTextSize(by: -1)
    }

    func resetTextSize() {
        var updatedSettings = settings
        updatedSettings.textSizeScale = EditorSettings.defaultTextSizeScale
        applySettings(updatedSettings, phase: .committed)
        preferencesWindowController?.update(settings: settings)
    }

    private func adjustTextSize(by stepCount: Int) {
        var updatedSettings = settings
        let proposedScale = settings.textSizeScale
            + CGFloat(stepCount) * EditorSettings.textSizeScaleStep
        updatedSettings.textSizeScale = min(
            max(proposedScale, EditorSettings.textSizeScaleRange.lowerBound),
            EditorSettings.textSizeScaleRange.upperBound
        )
        applySettings(updatedSettings, phase: .committed)
        preferencesWindowController?.update(settings: settings)
    }

    func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                settings: settings
            ) { [weak self] settings, phase in
                self?.applySettings(settings, phase: phase)
            }
        }

        preferencesWindowController?.update(settings: settings)
        preferencesWindowController?.showWindow(sender)
        preferencesWindowController?.window?.center()
        preferencesWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    /// `reportsFailure` is off for callers that await the flush themselves
    /// and warn about the failure in their own words (the terminate path);
    /// two alerts about the same failed write would stack up.
    func flushAutosave(force: Bool = false, reportsFailure: Bool = true) {
        // The recovery manifest is incomplete while clean file-backed tabs
        // are being reopened. A reentrant external open must not overwrite it
        // with only the sessions materialized so far.
        guard !isResolvingInitialSessions else {
            return
        }
        guard force || !sessions.isEmpty else {
            return
        }
        guard !areAutosaveWritesBlocked else {
            isAutosaveFailing = true
            return
        }

        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        autosaveTask?.cancel()
        autosaveGeneration += 1
        let generation = autosaveGeneration
        let session = AutosavedSession(drafts: autosavedDrafts())
        let task = Task.detached(priority: .utility) {
            [autosaveStore, generation, session] in
            guard !Task.isCancelled else {
                return true
            }

            do {
                try await autosaveStore.saveSession(
                    session,
                    generation: generation
                )
                return true
            } catch {
                Self.autosaveLogger.error(
                    "Failed to write autosaved session: \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        }
        autosaveTask = task

        guard reportsFailure else {
            return
        }

        Task { [weak self] in
            let didWrite = await task.value
            // A superseded flush must not report: the newer flush owns the
            // outcome, and its write may well succeed.
            guard let self, autosaveTask == task else {
                return
            }

            noteAutosaveOutcome(didWrite: didWrite)
        }
    }

    /// Autosave failures were only ever visible in the log until the user
    /// tried to quit — which is no help in the crash and force-quit cases
    /// autosave exists for. The user is told the first time a write fails,
    /// and only then: the flush runs every 0.4s, so a full disk would
    /// otherwise put an alert on screen for as long as the app is open.
    private func noteAutosaveOutcome(didWrite: Bool) {
        guard !didWrite else {
            isAutosaveFailing = false
            return
        }

        isAutosaveFailing = true
        guard !didReportAutosaveFailure else {
            return
        }

        didReportAutosaveFailure = true
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Unsaved drafts could not be saved."
        alert.informativeText =
            "Autosaving your open documents failed. Save your work to a file: "
                + "recent changes in unsaved documents will be lost if the app "
                + "stops unexpectedly."
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            let selectedWindow = window.tabGroup?.selectedWindow ?? window
            for tabWindow in groupWindows {
                guard let tabSession = session(of: tabWindow),
                      savedSessionIDs.insert(tabSession.id).inserted
                else {
                    continue
                }
                drafts.append(tabSession.autosavedDraft(
                    windowID: windowID,
                    windowFrame: windowFrame,
                    isSelectedTab: tabWindow === selectedWindow
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
                windowFrame: session.restoredWindowFrame.map(NSStringFromRect),
                isSelectedTab: session.restoredTabSelection ?? true
            ))
        }

        unresolvedAutosavedDrafts.removeAll { draft in
            guard let fileURL = draft.fileURL else {
                return true
            }
            return documentRegistry.sessionID(
                for: FileIO.canonicalDocumentURL(for: fileURL)
            ) != nil
        }
        drafts.append(contentsOf: unresolvedAutosavedDrafts)
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
        guard !areAutosaveWritesBlocked else {
            return false
        }
        flushAutosave(force: force, reportsFailure: false)
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

    func noteSelectedTabChanged() {
        scheduleAutosave()
    }

    private var activeSession: EditorDocumentSession? {
        activeSessionID.flatMap { sessions[$0] }
    }

    /// Menu commands are application-wide, so route them from the window that
    /// received the shortcut instead of trusting asynchronously updated scene
    /// state. The fallback covers launch and tab-transition moments where the
    /// editor window is temporarily unavailable.
    private func session(in window: NSWindow?) -> EditorDocumentSession? {
        guard let window else {
            return activeSession
        }

        return sessions.values.first { $0.editorView.window === window }
            ?? activeSession
    }

    /// Brings a freshly opened document to the front, and the app with it when
    /// the request came from outside. The launch-time activation in
    /// `applicationDidFinishLaunching` happens before any editor window exists
    /// — too early for the system to bring the window forward — so a document
    /// whose window is still on its way is activated once it appears.
    ///
    /// The deprecated `activate(ignoringOtherApps:)` is deliberate: cooperative
    /// `NSApplication.activate()` leaves the app behind the terminal it was
    /// launched from, because by the time the window exists the app no longer
    /// holds the activation the `open` command granted it.
    private func revealDocument(
        of session: EditorDocumentSession,
        activatesApp: Bool
    ) {
        guard let window = session.editorView.window else {
            if activatesApp {
                sessionsAwaitingActivation.insert(session.id)
            }
            return
        }

        window.makeKeyAndOrderFront(nil)
        if activatesApp {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Completes the activation of an externally opened document once the
    /// window bridge has a window for it.
    func revealPendingDocument(
        of session: EditorDocumentSession,
        in window: NSWindow
    ) {
        guard sessionsAwaitingActivation.remove(session.id) != nil else {
            return
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func tabTarget(for placement: OpenPlacement) -> NSWindow? {
        switch placement {
        case let .window(window):
            window
        case .frontmostTab:
            frontmostEditorWindow
        }
    }

    /// The key window is preferred, with the window order as a fallback: an
    /// external open reaches a backgrounded app, where no window is key.
    private var frontmostEditorWindow: NSWindow? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           Self.isEditorWindow(window)
        {
            return window
        }

        return NSApp.orderedWindows.first(where: Self.isEditorWindow)
    }

    /// Editor windows carry the shared tabbing identifier; the preferences
    /// window and windows still being configured during launch do not.
    private static func isEditorWindow(_ window: NSWindow) -> Bool {
        window.isVisible
            && window.tabbingIdentifier == EditorWindowTabbing.identifier
    }

    private func revealRegisteredDocument(
        at documentURL: URL,
        queuesWindow: Bool,
        placement: OpenPlacement
    ) -> Bool {
        guard let sessionID = documentRegistry.sessionID(for: documentURL) else {
            return false
        }
        guard let existing = sessions[sessionID] else {
            documentRegistry.removeSession(sessionID)
            return false
        }

        activate(existing)
        if existing.editorView.window != nil {
            revealDocument(of: existing, activatesApp: placement.isFrontmostTab)
        } else if queuesWindow, !pendingWindowIDs.contains(existing.id) {
            pendingWindowIDs.append(existing.id)
        }
        return true
    }

    private func open(
        _ url: URL,
        queuesWindow: Bool,
        placement: OpenPlacement = .window(nil)
    ) async {
        let documentURL = FileIO.canonicalDocumentURL(for: url)
        if revealRegisteredDocument(
            at: documentURL,
            queuesWindow: queuesWindow,
            placement: placement
        ) {
            return
        }
        // This claim spans the suspension in FileIO. MainActor isolation alone
        // does not make the check/read/register sequence atomic.
        guard documentRegistry.beginOpening(documentURL) else {
            return
        }
        defer { documentRegistry.finishOpening(documentURL) }

        do {
            let snapshot = try await FileIO.readUTF8Snapshot(
                from: url,
                resolvingTo: documentURL
            )
            if revealRegisteredDocument(
                at: documentURL,
                queuesWindow: queuesWindow,
                placement: placement
            ) {
                return
            }

            // Resolved only now: an external open can arrive mid-launch,
            // before the first editor window has been configured.
            let tabTarget = tabTarget(for: placement)

            // Opening into a window whose current document is still empty
            // reuses that document instead of spawning a tab next to it.
            // External opens reuse it even when no window is up yet, so a
            // launch triggered by the CLI leaves no empty window behind.
            if tabTarget != nil || placement.isFrontmostTab,
               let active = activeSession,
               active.isEmptyDocument
            {
                guard documentRegistry.register(documentURL, to: active.id) else {
                    _ = revealRegisteredDocument(
                        at: documentURL,
                        queuesWindow: queuesWindow,
                        placement: placement
                    )
                    return
                }
                active.adoptFile(
                    url: url,
                    text: snapshot.text,
                    revision: snapshot.revision
                )
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                scheduleAutosave()
                revealDocument(of: active, activatesApp: placement.isFrontmostTab)
                return
            }

            let session = makeSession(
                text: snapshot.text,
                fileURL: url,
                isEdited: false,
                fileRevision: snapshot.revision,
                registeredDocumentURL: documentURL
            )
            activate(session)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            scheduleAutosave()
            placeSession(session, tabTarget: tabTarget, queuesWindow: queuesWindow)
            revealDocument(of: session, activatesApp: placement.isFrontmostTab)
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
        isEdited: Bool,
        fileRevision: FileIO.Revision? = nil,
        registeredDocumentURL: URL? = nil,
        selectedRange: NSRange? = nil,
        restoredTabSelection: Bool? = nil
    ) -> EditorDocumentSession {
        let session = EditorDocumentSession(
            text: text,
            fileURL: fileURL,
            isEdited: isEdited,
            settings: settings,
            fileRevision: fileRevision,
            selectedRange: selectedRange,
            restoredTabSelection: restoredTabSelection
        ) { [weak self] in
            self?.scheduleAutosave()
        }
        if let fileURL {
            let didRegister = documentRegistry.register(
                registeredDocumentURL
                    ?? FileIO.canonicalDocumentURL(for: fileURL),
                to: session.id
            )
            precondition(didRegister, "A document URL must have exactly one session")
        }

        let sessionID = session.id
        session.onFocusModeEnabledChanged = { [weak self] _ in
            guard self?.activeSessionID == sessionID else {
                return
            }
            self?.objectWillChange.send()
        }
        session.onProofreadingEnabledChanged = { [weak self] _ in
            guard self?.activeSessionID == sessionID else {
                return
            }
            self?.objectWillChange.send()
        }
        session.reserveSaveDestination = { [weak self] url in
            guard let self else {
                throw CancellationError()
            }
            return try documentRegistry.reserveSave(
                to: FileIO.canonicalDocumentURL(for: url),
                for: sessionID
            )
        }
        session.finishSaveDestination = {
            [weak self] claim, previousDocumentURL, succeeded in
            guard let self else {
                return
            }
            // A write may finish after its window was closed. Release its
            // claim, but never resurrect ownership for a removed session.
            let shouldCommitOwnership = succeeded && sessions[sessionID] != nil
            documentRegistry.finishSave(
                claim,
                previousDocumentURL: previousDocumentURL,
                succeeded: shouldCommitOwnership
            )
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
        text: String,
        isEdited: Bool,
        fileRevision: FileIO.Revision? = nil,
        registeredDocumentURL: URL? = nil
    ) -> EditorDocumentSession {
        let session = makeSession(
            text: text,
            fileURL: draft.fileURL,
            isEdited: isEdited,
            fileRevision: fileRevision,
            registeredDocumentURL: registeredDocumentURL,
            selectedRange: draft.selection?.range,
            restoredTabSelection: draft.isSelectedTab
        )
        if let descriptor = draft.windowFrame {
            let frame = NSRectFromString(descriptor)
            if !frame.isEmpty {
                session.restoredWindowFrame = frame
            }
        }
        return session
    }

    /// Recovery payloads are materialized before the first suspension so an
    /// external open cannot claim their URLs while clean documents are read.
    /// Clean file-backed entries are then populated from their source files;
    /// no temporary empty session is exposed to the user.
    private func restoredSessions(
        from drafts: [AutosavedDraft]
    ) async -> [(draft: AutosavedDraft, session: EditorDocumentSession)] {
        var sessionsByDraftIndex: [Int: EditorDocumentSession] = [:]
        var restoredDraftsByIndex: [Int: AutosavedDraft] = [:]
        unresolvedAutosavedDrafts = []

        for (index, draft) in drafts.enumerated() {
            guard let recoveryText = draft.text else {
                continue
            }

            var restoredDraft = draft
            var registeredDocumentURL: URL?
            if let fileURL = draft.fileURL {
                let documentURL = FileIO.canonicalDocumentURL(for: fileURL)
                if documentRegistry.beginOpening(documentURL) {
                    registeredDocumentURL = documentURL
                } else {
                    // A document opened while the autosave file was loading.
                    // Keep the recovery payload as an untitled document rather
                    // than crashing registration or discarding either text.
                    restoredDraft.fileURL = nil
                }
            }

            let session = makeSession(
                from: restoredDraft,
                text: recoveryText,
                // File-backed recovery stays edited until its contents and
                // revision have been verified against disk. Detached conflict
                // copies stay edited even when their recovery text is empty.
                isEdited: draft.fileURL != nil || !recoveryText.isEmpty,
                registeredDocumentURL: registeredDocumentURL
            )
            if let registeredDocumentURL {
                documentRegistry.finishOpening(registeredDocumentURL)
                refineRestoredEditedState(
                    of: session,
                    from: restoredDraft,
                    recoveryText: recoveryText,
                    documentURL: registeredDocumentURL
                )
            }
            sessionsByDraftIndex[index] = session
            restoredDraftsByIndex[index] = restoredDraft
        }

        var cleanDocumentURLs: [Int: URL] = [:]
        for (index, draft) in drafts.enumerated() where draft.text == nil {
            guard let fileURL = draft.fileURL else {
                continue
            }
            let documentURL = FileIO.canonicalDocumentURL(for: fileURL)
            if documentRegistry.sessionID(for: documentURL) != nil {
                continue
            }
            guard documentRegistry.beginOpening(documentURL) else {
                unresolvedAutosavedDrafts.append(draft)
                continue
            }
            cleanDocumentURLs[index] = documentURL
        }
        defer {
            for documentURL in cleanDocumentURLs.values {
                documentRegistry.finishOpening(documentURL)
            }
        }

        for (index, draft) in drafts.enumerated() where draft.text == nil {
            guard let fileURL = draft.fileURL,
                  let documentURL = cleanDocumentURLs[index]
            else {
                continue
            }

            do {
                let snapshot = try await FileIO.readUTF8Snapshot(
                    from: fileURL,
                    resolvingTo: documentURL
                )
                sessionsByDraftIndex[index] = makeSession(
                    from: draft,
                    text: snapshot.text,
                    isEdited: false,
                    fileRevision: snapshot.revision,
                    registeredDocumentURL: documentURL
                )
                restoredDraftsByIndex[index] = draft
            } catch {
                unresolvedAutosavedDrafts.append(draft)
                Self.autosaveLogger.error(
                    "Could not reopen clean document at \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return drafts.indices.compactMap { index in
            sessionsByDraftIndex[index].map {
                (restoredDraftsByIndex[index] ?? drafts[index], $0)
            }
        }
    }

    private func refineRestoredEditedState(
        of session: EditorDocumentSession,
        from draft: AutosavedDraft,
        recoveryText: String,
        documentURL: URL
    ) {
        // Without a backing file the provisional flag is already exact. An
        // empty draft still has to be compared: deleting the whole contents
        // of a saved file is an edit like any other, and skipping the read
        // would restore it as unedited and lose the deletion on close.
        guard let fileURL = draft.fileURL else {
            return
        }

        Task { [weak session] in
            do {
                let snapshot = try await FileIO.readUTF8Snapshot(
                    from: fileURL,
                    resolvingTo: documentURL
                )
                session?.applyRestoredEditedState(
                    snapshot.text != recoveryText,
                    expectedText: recoveryText,
                    expectedFileURL: fileURL,
                    fileRevision: snapshot.revision
                )
            } catch {
                // A missing/unreadable backing file is never proof that the
                // recovery text is safe to discard.
                session?.applyRestoredEditedState(
                    true,
                    expectedText: recoveryText,
                    expectedFileURL: fileURL
                )
            }
        }
    }

    private func applySettings(
        _ settings: EditorSettings,
        phase: PreferencesWindowController.ChangePhase
    ) {
        // Continuous slider drags resend unchanged values; skip the
        // whole-document restyle of every session when nothing changed.
        guard settings != self.settings else {
            return
        }

        self.settings = settings
        switch phase {
        case .live:
            // Every tick of a drag would otherwise restyle each open document
            // in full, synchronously, between two frames of the slider. Only
            // the document the user is watching keeps up live; the others —
            // and the defaults write — ride the trailing edge.
            activeSession?.applySettings(settings)
            scheduleSettingsRollout()
        case .committed:
            commitSettings()
        }
    }

    private func scheduleSettingsRollout() {
        settingsRolloutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.commitSettings()
        }
        settingsRolloutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    /// Rolls the current settings out to every session and persists them.
    /// A backstop as much as a trailing edge: a drag that ends without a
    /// mouse-up reaching the control still lands here.
    private func commitSettings() {
        settingsRolloutWorkItem?.cancel()
        settingsRolloutWorkItem = nil
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

/// Where a newly opened document should be placed.
private enum OpenPlacement {
    /// Tab of this window when it accepts editor tabs, own window otherwise.
    case window(NSWindow?)
    /// Tab of whichever editor window is frontmost when the file is ready.
    case frontmostTab

    var isFrontmostTab: Bool {
        if case .frontmostTab = self {
            return true
        }

        return false
    }
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
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])

            Button(appState.focusModeToggleTitle) {
                appState.toggleFocusMode()
            }
            .keyboardShortcut("d")

            Button(appState.styleCheckToggleTitle) {
                appState.toggleProofreading()
            }
            .keyboardShortcut("r")

            Divider()

            Menu("Text Size") {
                Button("Increase Text Size") {
                    appState.increaseTextSize()
                }
                .keyboardShortcut("+")

                Button("Decrease Text Size") {
                    appState.decreaseTextSize()
                }
                .keyboardShortcut("-")

                Button("Reset Text Size") {
                    appState.resetTextSize()
                }
                .keyboardShortcut("0")
            }
        }

        CommandGroup(after: .pasteboard) {
            Button("Paste as Link") {
                appState.pasteAsLink()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])

            Button("Fix Typography") {
                appState.fixTypography(in: NSApp.keyWindow ?? NSApp.mainWindow)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandGroup(after: .textEditing) {
            Button("Find") {
                appState.showSearch()
            }
            .keyboardShortcut("f")
        }

        CommandGroup(after: .textFormatting) {
            markdownCommand("Bold", .bold, keyEquivalent: "b")
            markdownCommand("Italic", .italic, keyEquivalent: "i")
            markdownCommand(
                "Strikethrough", .strikethrough,
                keyEquivalent: "u", modifiers: [.command, .option]
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
            blockCommand("Blockquote", .blockquote, keyEquivalent: ">")
            Menu("Lists") {
                blockCommand("List", .list, keyEquivalent: "l")
                blockCommand(
                    "Task List", .taskList,
                    keyEquivalent: "l", modifiers: [.command, .option]
                )
                blockCommand(
                    "Ordered List", .orderedList,
                    keyEquivalent: "l", modifiers: [.command, .shift]
                )
                blockCommand(
                    "Ordered Task List", .orderedTaskList,
                    keyEquivalent: "l", modifiers: [.command, .option, .shift]
                )

                Divider()

                blockCommand(
                    "Toggle Task Completion", .toggleTaskCompletion,
                    keyEquivalent: "x", modifiers: [.command, .option]
                )
            }

            Divider()
            Menu("Heading") {
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
            Menu("Structure") {
                Button("Indent") {
                    appState.applyIndent(.indent)
                }

                Button("Outdent") {
                    appState.applyIndent(.outdent)
                }

                Divider()

                Button("Move Line Up") {
                    appState.moveLines(.up)
                }
                .keyboardShortcut(.upArrow, modifiers: .option)

                Button("Move Line Down") {
                    appState.moveLines(.down)
                }
                .keyboardShortcut(.downArrow, modifiers: .option)
            }
            Button("Add Table...") {
                appState.insertTable()
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
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

    private func blockCommand(
        _ title: String,
        _ command: MarkdownBlockCommand,
        keyEquivalent: KeyEquivalent,
        modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) {
            appState.applyBlockCommand(command)
        }
        .keyboardShortcut(keyEquivalent, modifiers: modifiers)
    }
}
