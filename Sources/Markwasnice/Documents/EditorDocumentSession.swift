import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorDocumentSession: ObservableObject, Identifiable,
    @preconcurrency MarkdownEditorViewDelegate
{
    static let editorTopInset: CGFloat = 0
    static let editorBottomInset: CGFloat = 72

    /// Single source of truth for the open and save panels' type lists so
    /// they cannot drift apart again.
    static let markdownContentTypes: [UTType] = [
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText,
        .plainText,
    ]

    let id = UUID()
    let editorView: MarkdownEditorView
    let shellState: EditorShellState

    /// Opens files dropped onto this session's window; wired by the app state,
    /// which owns the session registry and the open flow.
    var onOpenFiles: (([URL], NSWindow?) -> Void)?
    var onFocusModeEnabledChanged: ((Bool) -> Void)?
    var onProofreadingEnabledChanged: ((Bool) -> Void)?
    /// App-level URL reservation keeps two sessions from saving to the same
    /// canonical document. Standalone sessions used by focused UI tests can
    /// leave these callbacks unset.
    var reserveSaveDestination: ((URL) throws -> DocumentRegistry.SaveClaim)?
    var finishSaveDestination: ((DocumentRegistry.SaveClaim, URL?, Bool) -> Void)?

    private let stylingController: MarkdownStylingController
    private let onAutosaveNeeded: () -> Void
    private var statisticsTask: Task<Void, Never>?
    private var isCloseApproved = false
    private var isPromptVisible = false
    private(set) var isTabBarTemporarilyHidden = false
    private weak var hiddenTabBarAccessory: NSTitlebarAccessoryViewController?
    private var text: String
    private var fileRevision: FileIO.Revision?
    private var saveTask: Task<Void, Never>?
    private var searchMatches: [NSRange] = []
    private var selectedSearchMatchIndex: Int?
    /// False only for a tab restored as inactive. Nil keeps normal and legacy
    /// window creation behavior unchanged.
    let restoredTabSelection: Bool?

    /// These observers are the single title-update mechanism: assign `text`
    /// first when it changes, and don't call updateTitle() after assignments
    /// — didSet fires even when the value is unchanged.
    private(set) var fileURL: URL? {
        didSet {
            updateTitle()
        }
    }

    private var hasUnsavedFileChanges: Bool {
        didSet {
            updateTitle()
        }
    }

    init(
        text: String,
        fileURL: URL?,
        isEdited: Bool,
        settings: EditorSettings,
        fileRevision: FileIO.Revision? = nil,
        selectedRange: NSRange? = nil,
        restoredTabSelection: Bool? = nil,
        onAutosaveNeeded: @escaping () -> Void
    ) {
        self.text = text
        self.fileURL = fileURL
        self.fileRevision = fileRevision
        self.restoredTabSelection = restoredTabSelection
        hasUnsavedFileChanges = isEdited
        self.onAutosaveNeeded = onAutosaveNeeded
        editorView = MarkdownEditorView(settings: settings)
        shellState = EditorShellState(
            readingWordsPerMinute: settings.readingWordsPerMinute,
            speakingWordsPerMinute: settings.speakingWordsPerMinute
        )
        stylingController = MarkdownStylingController(editorView: editorView)

        shellState.onToolbarHoverChanged = { [weak self] isHovering in
            self?.handleToolbarHoverChanged(isHovering)
        }
        shellState.onStatusBarHoverChanged = { [weak self] isHovering in
            self?.handleStatusBarHoverChanged(isHovering)
        }
        shellState.onFocusModeEnabledChanged = { [weak self] isEnabled in
            self?.editorView.setFocusModeEnabled(isEnabled)
            self?.onFocusModeEnabledChanged?(isEnabled)
        }
        shellState.onFocusModeSelected = { [weak self] mode in
            self?.editorView.setFocusMode(mode)
        }
        shellState.onProofreadingEnabledChanged = { [weak self] isEnabled in
            // Editor view first so tracking and decoration state are ready
            // before the first check result arrives.
            self?.editorView.setProofreadingEnabled(isEnabled)
            self?.stylingController.setProofreadingEnabled(isEnabled)
            self?.onProofreadingEnabledChanged?(isEnabled)
        }
        shellState.onSearchPresentationChanged = { [weak self] isPresented in
            self?.handleSearchPresentationChanged(isPresented)
        }
        shellState.onSearchQueryChanged = { [weak self] _ in
            self?.refreshSearchMatches(selectsFirstMatch: true)
        }
        shellState.onSearchOptionsChanged = { [weak self] _ in
            self?.refreshSearchMatches(selectsFirstMatch: true)
        }
        shellState.onNextSearchMatch = { [weak self] in
            self?.selectNextSearchMatch()
        }
        shellState.onPreviousSearchMatch = { [weak self] in
            self?.selectPreviousSearchMatch()
        }
        shellState.onReplaceEnabledChanged = { [weak self] _ in
            self?.handleReplaceEnabledChanged()
        }
        shellState.onReplaceMatch = { [weak self] in
            self?.replaceCurrentMatch()
        }
        shellState.onReplaceAllMatches = { [weak self] in
            self?.replaceAllMatches()
        }
        shellState.onPreviewActiveChanged = { [weak self] isActive in
            self?.handlePreviewActiveChanged(isActive)
        }
        editorView.onPreviewExitRequested = { [weak self] in
            self?.shellState.setPreviewActive(false)
        }

        editorView.delegate = self
        editorView.documentURL = fileURL
        editorView.setString(text, clearsUndo: true)
        editorView.restoreSelectedRange(selectedRange)
        applyChromeInsets(isFullScreen: false)
        stylingController.scheduleParse(text: text)
        // didSet observers don't fire during init.
        updateTitle()
        scheduleStatistics(text: text)
    }

    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView) {
        handleConfirmedTextChange(in: editorView)
    }

    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        didChangeTextAt _: Int
    ) {
        handleConfirmedTextChange(in: editorView)
    }

    private func handleConfirmedTextChange(in editorView: MarkdownEditorView) {
        // Read the current value once for all downstream consumers. The editor
        // generation already proves that characters changed, so an O(n)
        // comparison with the previous document would only repeat that work.
        let newText = editorView.string
        text = newText
        if !hasUnsavedFileChanges {
            hasUnsavedFileChanges = true
        }
        onAutosaveNeeded()
        stylingController.scheduleParse(text: newText)
        scheduleStatistics(text: newText)
        refreshSearchMatches(selectsFirstMatch: false)
        hideChrome()
    }

    func markdownEditorView(
        _: MarkdownEditorView,
        didChangeSelectionText selectedText: String?
    ) {
        shellState.selectionStatistics = selectedText.map(Self.statistics(in:))
        onAutosaveNeeded()
    }

    func markdownEditorViewDidScroll(_: MarkdownEditorView) {
        hideChrome()
    }

    func markdownEditorView(
        _: MarkdownEditorView,
        didChangeScrolledFromTop isScrolled: Bool
    ) {
        guard shellState.isContentScrolled != isScrolled else {
            return
        }

        shellState.isContentScrolled = isScrolled
    }

    func markdownEditorViewShowSearch(_: MarkdownEditorView) {
        showSearch()
    }

    func markdownEditorViewRequestInsertTable(_: MarkdownEditorView) {
        requestInsertTable()
    }

    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        requestOpenFileURLs urls: [URL]
    ) {
        onOpenFiles?(urls, editorView.window)
    }

    func updateWindowWidth(_ width: CGFloat) {
        stylingController.updateWindowWidthFontScale(for: width)
    }

    func setFullScreen(_ isFullScreen: Bool) {
        guard shellState.isFullScreen != isFullScreen else {
            return
        }

        shellState.isFullScreen = isFullScreen
        applyChromeInsets(isFullScreen: isFullScreen)
    }

    func setFullScreenChromeOverlayHeight(_ height: CGFloat) {
        guard shellState.fullScreenChromeOverlayHeight != height else {
            return
        }

        shellState.fullScreenChromeOverlayHeight = height
        if shellState.isFullScreen {
            applyChromeInsets(isFullScreen: true)
        }
    }

    func setTabBarChrome(
        isVisible: Bool,
        topInset: CGFloat,
        rowHeight: CGFloat = EditorShellState.tabBarRowHeightEstimate
    ) {
        if isVisible {
            isTabBarTemporarilyHidden = false
            hiddenTabBarAccessory = nil
        }

        guard shellState.isTabBarVisible != isVisible
            || shellState.tabBarTopInset != topInset
            || shellState.tabBarRowHeight != rowHeight
        else {
            return
        }

        shellState.isTabBarVisible = isVisible
        shellState.tabBarTopInset = topInset
        shellState.tabBarRowHeight = rowHeight
        applyChromeInsets(isFullScreen: shellState.isFullScreen)
        if isVisible {
            showChrome()
        }
    }

    func applySettings(_ settings: EditorSettings) {
        stylingController.applySettings(settings)
        if shellState.readingWordsPerMinute != settings.readingWordsPerMinute {
            shellState.readingWordsPerMinute = settings.readingWordsPerMinute
        }
        if shellState.speakingWordsPerMinute != settings.speakingWordsPerMinute {
            shellState.speakingWordsPerMinute = settings.speakingWordsPerMinute
        }
    }

    var isEmptyDocument: Bool {
        fileURL == nil && editorView.string.isEmpty
    }

    func adoptFile(
        url: URL,
        text: String,
        revision: FileIO.Revision? = nil
    ) {
        self.text = text
        fileURL = url
        fileRevision = revision
        hasUnsavedFileChanges = false
        editorView.documentURL = url
        editorView.setString(text, clearsUndo: true)
        stylingController.scheduleParse(text: text)
        scheduleStatistics(text: text)
        refreshSearchMatches(selectsFirstMatch: false)
        onAutosaveNeeded()
    }

    func pasteAsLink() {
        guard !shellState.isPreviewActive else {
            return
        }

        editorView.pasteAsLink()
    }

    func applyMarkup(_ command: MarkdownMarkupCommand) {
        guard !shellState.isPreviewActive else {
            return
        }

        editorView.applyMarkup(command)
    }

    func moveLines(_ command: MarkdownLineMoveCommand) {
        guard !shellState.isPreviewActive else {
            return
        }

        editorView.moveLines(command)
    }

    func requestInsertTable() {
        guard !shellState.isPreviewActive,
              let window = editorView.window
        else {
            return
        }

        InsertTableDialog.present(in: window) { [weak self] rows, columns in
            self?.editorView.insertTable(rows: rows, columns: columns)
            self?.editorView.focus()
        }
    }

    func fixTypography() {
        guard !shellState.isPreviewActive else {
            return
        }

        editorView.fixTypography(spans: stylingController.freshStyleSpans)
    }

    func showSearch() {
        guard !shellState.isPreviewActive else {
            return
        }

        showChrome()
        if let selectedText = editorView.selectedTextForSearch {
            shellState.setSearchQuery(selectedText)
        }
        shellState.showSearch()
        applyChromeInsets(isFullScreen: shellState.isFullScreen)
        refreshSearchMatches(selectsFirstMatch: true)
    }

    func save() {
        guard let fileURL else {
            saveAs()
            return
        }

        save(to: fileURL)
    }

    func saveAs() {
        let panel = makeSavePanel()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        save(to: url)
    }

    /// The app's only gate against losing unsaved work, so every state that
    /// is not provably safe answers "don't close".
    func windowShouldClose(_ window: NSWindow, onApprovedClose: @escaping () -> Void)
        -> Bool
    {
        // The user already answered the prompt for this close; letting it
        // through is the whole point of the re-entrant path.
        guard !isCloseApproved else {
            return true
        }

        // The prompt owns the window until it is answered — including the
        // gap after "Save" where the sheet is gone but the write is still in
        // flight and nothing at the AppKit level blocks a second Cmd+W.
        // Unsaved changes are guaranteed here, so the close is refused and
        // the pending question brought back in front of the user.
        guard !isPromptVisible else {
            window.makeKeyAndOrderFront(nil)
            return false
        }

        guard hasUnsavedFileChanges else {
            return true
        }

        promptToSaveBeforeClosing(window, onApprovedClose: onApprovedClose)
        return false
    }

    /// Applies the asynchronously refined edited flag computed during launch
    /// restore. Ignored once the user has changed the text, so a slow file
    /// read can never clear an edit made in the meantime.
    func applyRestoredEditedState(
        _ isEdited: Bool,
        expectedText: String,
        expectedFileURL: URL,
        fileRevision: FileIO.Revision? = nil
    ) {
        guard let fileURL,
              fileURL.standardizedFileURL == expectedFileURL.standardizedFileURL
        else {
            // Save As completed while the launch-time read was in flight;
            // its revision belongs to the new file and must win.
            return
        }

        self.fileRevision = fileRevision
        guard text == expectedText, hasUnsavedFileChanges != isEdited else {
            return
        }

        hasUnsavedFileChanges = isEdited
    }

    func autosavedDraft(
        windowID: UUID?,
        windowFrame: String?,
        isSelectedTab: Bool = true
    ) -> AutosavedDraft {
        AutosavedDraft(
            text: fileURL != nil && fileRevision != nil && !hasUnsavedFileChanges
                ? nil
                : text,
            fileURL: fileURL,
            windowID: windowID,
            windowFrame: windowFrame,
            selection: AutosavedTextSelection(editorView.selectedRange),
            isSelectedTab: isSelectedTab
        )
    }

    /// Frame restored from the autosaved draft; consumed once by the window
    /// placement pass so later re-configurations never re-apply it.
    var restoredWindowFrame: NSRect?

    func takeRestoredWindowFrame() -> NSRect? {
        defer { restoredWindowFrame = nil }
        return restoredWindowFrame
    }

    var title: String {
        if let fileURL {
            return fileURL.lastPathComponent
        }

        return DocumentTitleSuggester.title(from: text) ?? "Untitled"
    }

    private var suggestedSaveFileName: String {
        fileURL?.lastPathComponent
            ?? DocumentTitleSuggester.fileName(from: text)
            ?? "Untitled.md"
    }

    private func makeSavePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.markdownContentTypes
        panel.nameFieldStringValue = suggestedSaveFileName
        return panel
    }

    private func save(
        to url: URL,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        let previousURL = fileURL
        // Capture identity before any suspension. The user-visible URL may be
        // a symlink whose target changes while the write is queued.
        let previousDocumentURL = previousURL.map {
            FileIO.canonicalDocumentURL(for: $0)
        }
        let isSameRequestedURL = previousURL.map {
            $0.standardizedFileURL == url.standardizedFileURL
        } ?? false
        let isCurrentDocument = isSameRequestedURL
            || previousDocumentURL == FileIO.canonicalDocumentURL(for: url)
        if isCurrentDocument, fileRevision == nil {
            NSAlert(
                error: FileIO.ConditionalWriteError.revisionUnavailable(url)
            ).runModal()
            onCompletion?(false)
            return
        }

        let claim: DocumentRegistry.SaveClaim?
        do {
            claim = try reserveSaveDestination?(url)
        } catch {
            NSAlert(error: error).runModal()
            onCompletion?(false)
            return
        }

        let savedText = text
        let previousSaveTask = saveTask
        let finishSaveDestination = finishSaveDestination
        previousSaveTask?.cancel()
        saveTask = Task { [weak self, savedText, url] in
            // Every exit has to answer, or a caller waiting on the outcome
            // waits forever: the close prompt keeps its window hostage that
            // way, since an unanswered prompt refuses to close.
            var didReportOutcome = false
            var didFinishClaim = false
            defer {
                if let claim, !didFinishClaim {
                    finishSaveDestination?(claim, previousDocumentURL, false)
                }
                if !didReportOutcome {
                    onCompletion?(false)
                }
            }

            // The superseded save's detached write cannot be interrupted;
            // wait for it so two quick saves to the same URL cannot land
            // with the older content last.
            await previousSaveTask?.value
            // If another save superseded us while we were only queued, no
            // bytes from this snapshot have started moving yet. Skip it so a
            // burst of saves coalesces to the in-flight and latest versions.
            guard !Task.isCancelled else {
                return
            }

            let expectedRevision: FileIO.Revision?
            if isCurrentDocument {
                // A superseded save still writes before this task starts. Use
                // the revision it produced, rather than the revision captured
                // before waiting, or our own write looks externally modified.
                guard let revision = self?.fileRevision else {
                    guard !Task.isCancelled else {
                        return
                    }
                    NSAlert(
                        error: FileIO.ConditionalWriteError.revisionUnavailable(url)
                    ).runModal()
                    didReportOutcome = true
                    onCompletion?(false)
                    return
                }
                expectedRevision = revision
            } else {
                expectedRevision = nil
            }

            let savedRevision: FileIO.Revision
            do {
                if let expectedRevision {
                    savedRevision = try await FileIO.writeUTF8(
                        savedText,
                        to: url,
                        ifUnmodifiedSince: expectedRevision
                    )
                } else if let claimedDocumentURL = claim?.documentURL {
                    savedRevision = try await FileIO.writeUTF8(
                        savedText,
                        to: url,
                        resolvingTo: claimedDocumentURL
                    )
                } else {
                    savedRevision = try await FileIO.writeUTF8(savedText, to: url)
                }
            } catch {
                // A superseded save must not alert: the newer save owns
                // the outcome the user will see.
                guard !Task.isCancelled else {
                    return
                }

                NSAlert(error: error).runModal()
                didReportOutcome = true
                onCompletion?(false)
                return
            }

            // A newer save may have cancelled this task but is deliberately
            // waiting for its uninterruptible write. Publish the resulting
            // baseline so that newer conditional write can continue safely.
            if isCurrentDocument {
                self?.fileRevision = savedRevision
            }

            guard !Task.isCancelled else {
                return
            }

            guard let self else {
                return
            }

            if let claim {
                finishSaveDestination?(claim, previousDocumentURL, true)
                didFinishClaim = true
            }
            fileURL = url
            fileRevision = savedRevision
            editorView.documentURL = url
            let didSaveCurrentText = text == savedText
            hasUnsavedFileChanges = !didSaveCurrentText
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            onAutosaveNeeded()
            didReportOutcome = true
            onCompletion?(didSaveCurrentText)
        }
    }

    private func promptToSaveBeforeClosing(
        _ window: NSWindow,
        onApprovedClose: @escaping () -> Void
    ) {
        isPromptVisible = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to \"\(title)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                return
            }

            switch response {
            case .alertFirstButtonReturn:
                self.saveBeforeClosing(window, onApprovedClose: onApprovedClose)
            case .alertSecondButtonReturn:
                self.closeAfterUserApproval(onApprovedClose)
            default:
                self.isPromptVisible = false
            }
        }
    }

    private func saveBeforeClosing(
        _ window: NSWindow,
        onApprovedClose: @escaping () -> Void
    ) {
        if let fileURL {
            save(to: fileURL) { [weak self] didSave in
                guard let self else {
                    return
                }

                if didSave {
                    self.closeAfterUserApproval(onApprovedClose)
                } else {
                    self.isPromptVisible = false
                }
            }
            return
        }

        let panel = makeSavePanel()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                return
            }

            guard response == .OK, let url = panel.url else {
                self.isPromptVisible = false
                return
            }

            self.save(to: url) { [weak self] didSave in
                guard let self else {
                    return
                }

                if didSave {
                    self.closeAfterUserApproval(onApprovedClose)
                } else {
                    self.isPromptVisible = false
                }
            }
        }
    }

    private func closeAfterUserApproval(_ onApprovedClose: () -> Void) {
        isCloseApproved = true
        isPromptVisible = false
        onApprovedClose()
    }

    private func updateTitle() {
        shellState.updateTitle(title, isEdited: hasUnsavedFileChanges)
    }

    private func scheduleStatistics(text: String) {
        statisticsTask?.cancel()
        statisticsTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }

            let words = Self.wordCount(in: text)
            let characters = text.count
            let sentences = Self.sentenceCount(in: text)
            await MainActor.run {
                guard !Task.isCancelled, let shellState = self?.shellState else {
                    return
                }

                // @Published fires objectWillChange even for equal values;
                // skip unchanged counts so typing doesn't invalidate the
                // whole shell every debounce tick.
                if shellState.wordCount != words {
                    shellState.wordCount = words
                }
                if shellState.characterCount != characters {
                    shellState.characterCount = characters
                }
                if shellState.sentenceCount != sentences {
                    shellState.sentenceCount = sentences
                }
            }
        }
    }

    private func applyChromeInsets(isFullScreen: Bool) {
        let toolbarHeight = isFullScreen
            ? shellState.fullScreenTopChromeInsetHeight
            : shellState.topChromeInsetHeight
        let cursorExclusionHeight = isFullScreen
            ? fullScreenSearchChromeHeight
            : shellState.topChromeCursorExclusionHeight
        editorView.setChromeInsets(
            top: toolbarHeight + Self.editorTopInset,
            bottom: Self.editorBottomInset,
            protectedTop: cursorExclusionHeight,
            scrollerBottomInset: EditorShellState.statusBarHeight
        )
    }

    private var fullScreenSearchChromeHeight: CGFloat {
        shellState.isSearchPresented ? shellState.searchBarHeight : 0
    }

    nonisolated private static func wordCount(in text: String) -> Int {
        text.split { character in
            character.isWhitespace || character.isPunctuation
        }.count
    }

    nonisolated static func sentenceCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex ..< text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }

    nonisolated private static func statistics(in text: String) -> EditorTextStatistics {
        EditorTextStatistics(
            characterCount: text.count,
            wordCount: wordCount(in: text),
            sentenceCount: sentenceCount(in: text)
        )
    }

    private func showChrome() {
        showToolbar()
        showStatusBar()
    }

    private func showToolbar() {
        // @Published fires objectWillChange even for equal values; avoid
        // invalidating the whole SwiftUI shell for an already-visible bar.
        if !shellState.isToolbarVisible {
            shellState.isToolbarVisible = true
        }
        restoreTabBarIfNeeded()
    }

    private func showStatusBar() {
        if !shellState.isStatusBarVisible {
            shellState.isStatusBarVisible = true
        }
    }

    private func hideChrome() {
        guard !shellState.isSearchPresented else {
            return
        }

        hideChromeNow()
    }

    private func hideChromeNow() {
        guard !shellState.isSearchPresented else {
            return
        }

        if shellState.isToolbarVisible {
            shellState.isToolbarVisible = false
        }
        if shellState.isStatusBarVisible {
            shellState.isStatusBarVisible = false
        }
        hideTabBarTemporarilyIfNeeded()
    }

    /// The tab bar hides with the chrome and reveals with the toolbar.
    /// While it is temporarily hidden the logical tab chrome state (insets,
    /// prominent backdrop) is kept frozen so the text does not shift; the
    /// KVO refresh in WindowLifecycleView skips updates for this state.
    // toggleTabBar(_:) silently no-ops for groups with several tabs (AppKit
    // disables Hide Tab Bar there), so the bar is collapsed by hiding its
    // titlebar accessory instead — the only accessory these windows have.
    // NSWindowTabGroup.isTabBarVisible stays true while the accessory is
    // hidden, which is why the KVO refresh keys on the temporary-hide flag.
    private func hideTabBarTemporarilyIfNeeded() {
        guard !isTabBarTemporarilyHidden,
              shellState.isTabBarVisible,
              !shellState.isFullScreen,
              let window = editorView.window,
              window.tabGroup?.isTabBarVisible == true,
              let accessory = window.titlebarAccessoryViewControllers
              .first(where: { !$0.isHidden })
        else {
            return
        }

        isTabBarTemporarilyHidden = true
        hiddenTabBarAccessory = accessory
        accessory.isHidden = true
    }

    private func restoreTabBarIfNeeded() {
        guard isTabBarTemporarilyHidden else {
            return
        }

        isTabBarTemporarilyHidden = false
        if let accessory = hiddenTabBarAccessory {
            hiddenTabBarAccessory = nil
            accessory.isHidden = false
        } else {
            // The tab bar went away while it was hidden (e.g. the remaining
            // tabs closed); drop the frozen tab chrome.
            setTabBarChrome(isVisible: false, topInset: 0)
        }
    }

    private func handleToolbarHoverChanged(_ isHovering: Bool) {
        if isHovering {
            showToolbar()
        }
    }

    private func handleStatusBarHoverChanged(_ isHovering: Bool) {
        if isHovering {
            showStatusBar()
        }
    }

    private func handleSearchPresentationChanged(_ isPresented: Bool) {
        showChrome()
        applyChromeInsets(isFullScreen: shellState.isFullScreen)
        if isPresented {
            refreshSearchMatches(selectsFirstMatch: true)
        } else {
            clearSearchMatches()
            editorView.focus()
        }
    }

    private func refreshSearchMatches(selectsFirstMatch: Bool) {
        guard shellState.isSearchPresented,
              !shellState.searchQuery.isEmpty
        else {
            clearSearchMatches()
            return
        }

        searchMatches = EditorSearchMatcher.matches(
            for: shellState.searchQuery,
            in: text,
            options: shellState.searchOptions
        )

        if searchMatches.isEmpty {
            selectedSearchMatchIndex = nil
        } else if selectsFirstMatch || selectedSearchMatchIndex == nil {
            selectedSearchMatchIndex = 0
        } else if let selectedSearchMatchIndex,
                  selectedSearchMatchIndex >= searchMatches.count
        {
            self.selectedSearchMatchIndex = searchMatches.count - 1
        }

        applySearchMatches(selectsMatch: selectsFirstMatch)
    }

    private func clearSearchMatches() {
        let hadMatches = !searchMatches.isEmpty || selectedSearchMatchIndex != nil
        searchMatches = []
        selectedSearchMatchIndex = nil
        guard hadMatches else {
            return
        }

        shellState.updateSearchResults(count: 0, selectedIndex: nil)
        editorView.setSearchMatches([], selectedIndex: nil)
    }

    private func handleReplaceEnabledChanged() {
        applyChromeInsets(isFullScreen: shellState.isFullScreen)
    }

    private func handlePreviewActiveChanged(_ isActive: Bool) {
        if isActive {
            shellState.closeSearch()
        }
        editorView.setPreviewActive(isActive)
    }

    private func replaceCurrentMatch() {
        guard let index = selectedSearchMatchIndex,
              searchMatches.indices.contains(index)
        else {
            return
        }

        guard editorView.replaceSearchMatch(
            searchMatches[index],
            with: shellState.replaceQuery
        ) else {
            return
        }

        // The text change has already refreshed the matches synchronously;
        // scroll to the match that took over the replaced one's index.
        applySearchMatches(selectsMatch: true)
    }

    private func replaceAllMatches() {
        guard !searchMatches.isEmpty else {
            return
        }

        editorView.replaceSearchMatches(
            searchMatches,
            with: shellState.replaceQuery
        )
    }

    private func selectNextSearchMatch() {
        guard !searchMatches.isEmpty else {
            return
        }

        selectedSearchMatchIndex =
            ((selectedSearchMatchIndex ?? -1) + 1)
                % searchMatches.count
        applySearchMatches(selectsMatch: true)
    }

    private func selectPreviousSearchMatch() {
        guard !searchMatches.isEmpty else {
            return
        }

        let currentIndex = selectedSearchMatchIndex ?? 0
        selectedSearchMatchIndex =
            (currentIndex - 1 + searchMatches.count)
                % searchMatches.count
        applySearchMatches(selectsMatch: true)
    }

    private func applySearchMatches(selectsMatch: Bool) {
        shellState.updateSearchResults(
            count: searchMatches.count,
            selectedIndex: selectedSearchMatchIndex
        )
        editorView.setSearchMatches(
            searchMatches,
            selectedIndex: selectedSearchMatchIndex
        )

        guard selectsMatch,
              let selectedSearchMatchIndex,
              searchMatches.indices.contains(selectedSearchMatchIndex)
        else {
            return
        }

        editorView.selectSearchMatch(searchMatches[selectedSearchMatchIndex])
    }
}
