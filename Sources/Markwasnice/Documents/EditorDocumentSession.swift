import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorDocumentSession: ObservableObject, Identifiable,
    @preconcurrency MarkdownEditorViewDelegate
{
    static let editorTopInset: CGFloat = 0
    static let editorBottomInset: CGFloat = 72

    let id = UUID()
    let editorView: MarkdownEditorView
    let shellState: EditorShellState

    /// Opens files dropped onto this session's window; wired by the app state,
    /// which owns the session registry and the open flow.
    var onOpenFiles: (([URL], NSWindow?) -> Void)?

    private let stylingController: MarkdownStylingController
    private let onAutosaveNeeded: () -> Void
    private var wordCountTask: Task<Void, Never>?
    private var isCloseApproved = false
    private var isPromptVisible = false
    private var isPointerInChromeRevealZone = false
    private(set) var isTabBarTemporarilyHidden = false
    private weak var hiddenTabBarAccessory: NSTitlebarAccessoryViewController?
    private var text: String
    private var saveTask: Task<Void, Never>?
    private var searchMatches: [NSRange] = []
    private var selectedSearchMatchIndex: Int?

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
        onAutosaveNeeded: @escaping () -> Void
    ) {
        self.text = text
        self.fileURL = fileURL
        hasUnsavedFileChanges = isEdited
        self.onAutosaveNeeded = onAutosaveNeeded
        editorView = MarkdownEditorView(settings: settings)
        shellState = EditorShellState()
        stylingController = MarkdownStylingController(editorView: editorView)

        shellState.onTopHoverChanged = { [weak self] isHovering in
            self?.handleTopHoverChanged(isHovering)
        }
        shellState.onFocusModeEnabledChanged = { [weak self] isEnabled in
            self?.editorView.setFocusModeEnabled(isEnabled)
        }
        shellState.onFocusModeSelected = { [weak self] mode in
            self?.editorView.setFocusMode(mode)
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
        applyChromeInsets(isFullScreen: false)
        stylingController.scheduleParse(text: text)
        // didSet observers don't fire during init.
        updateTitle()
        scheduleWordCount()
    }

    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView) {
        guard editorView.string != text else {
            return
        }

        text = editorView.string
        hasUnsavedFileChanges = true
        onAutosaveNeeded()
        stylingController.scheduleParse(text: editorView.string)
        scheduleWordCount()
        refreshSearchMatches(selectsFirstMatch: false)
        hideChrome()
    }

    func markdownEditorViewDidScroll(_: MarkdownEditorView) {
        hideChrome()
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

    func setTabBarChrome(isVisible: Bool, topInset: CGFloat) {
        if isVisible {
            isTabBarTemporarilyHidden = false
            hiddenTabBarAccessory = nil
        }

        guard shellState.isTabBarVisible != isVisible
            || shellState.tabBarTopInset != topInset
        else {
            return
        }

        shellState.isTabBarVisible = isVisible
        shellState.tabBarTopInset = topInset
        applyChromeInsets(isFullScreen: shellState.isFullScreen)
        if isVisible {
            showChrome()
        }
    }

    func applySettings(_ settings: EditorSettings) {
        stylingController.applySettings(settings)
    }

    var isEmptyDocument: Bool {
        fileURL == nil && editorView.string.isEmpty
    }

    func adoptFile(url: URL, text: String) {
        self.text = text
        fileURL = url
        hasUnsavedFileChanges = false
        editorView.documentURL = url
        editorView.setString(text, clearsUndo: true)
        stylingController.scheduleParse(text: text)
        scheduleWordCount()
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

        editorView.fixTypography()
    }

    func showSearch() {
        guard !shellState.isPreviewActive else {
            return
        }

        showChrome()
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = suggestedSaveFileName

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        save(to: url)
    }

    func windowShouldClose(_ window: NSWindow, onApprovedClose: @escaping () -> Void)
        -> Bool
    {
        guard !isCloseApproved,
              !isPromptVisible,
              hasUnsavedFileChanges
        else {
            return true
        }

        promptToSaveBeforeClosing(window, onApprovedClose: onApprovedClose)
        return false
    }

    func autosavedDraft(windowID: UUID?, windowFrame: String?) -> AutosavedDraft {
        AutosavedDraft(
            text: text,
            fileURL: fileURL,
            windowID: windowID,
            windowFrame: windowFrame
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

    private func save(
        to url: URL,
        onCompletion: ((Bool) -> Void)? = nil
    ) {
        let savedText = text
        saveTask?.cancel()
        saveTask = Task { [weak self, savedText, url] in
            do {
                try await FileIO.writeUTF8(savedText, to: url)
            } catch {
                NSAlert(error: error).runModal()
                onCompletion?(false)
                return
            }

            guard !Task.isCancelled else {
                return
            }

            guard let self else {
                return
            }

            fileURL = url
            editorView.documentURL = url
            let didSaveCurrentText = text == savedText
            hasUnsavedFileChanges = !didSaveCurrentText
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            onAutosaveNeeded()
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

        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = suggestedSaveFileName
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

    private func scheduleWordCount() {
        wordCountTask?.cancel()
        let text = editorView.string
        wordCountTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }

            let words = Self.wordCount(in: text)
            let characters = text.count
            await MainActor.run {
                guard !Task.isCancelled else {
                    return
                }

                self?.shellState.wordCount = words
                self?.shellState.characterCount = characters
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
            protectedTop: cursorExclusionHeight
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

    private func showChrome() {
        // @Published fires objectWillChange even for equal values; writing on
        // every scroll tick invalidates the whole SwiftUI shell per frame.
        if !shellState.isToolbarVisible {
            shellState.isToolbarVisible = true
        }
        if !shellState.isStatusBarVisible {
            shellState.isStatusBarVisible = true
        }
        restoreTabBarIfNeeded()
    }

    private func hideChrome() {
        guard !shellState.isSearchPresented else {
            return
        }

        updatePointerInChromeRevealZone()

        guard !isPointerInChromeRevealZone else {
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

    /// The tab bar hides and reveals together with the rest of the chrome.
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

    private func handleTopHoverChanged(_ isHovering: Bool) {
        isPointerInChromeRevealZone = isHovering
        if isHovering {
            showChrome()
        }
    }

    private func updatePointerInChromeRevealZone() {
        guard let window = editorView.window,
              let contentView = window.contentView,
              let revealRect = TopChromeGeometry.revealRectInContentView(
                  window: window,
                  revealHeight: shellState.isFullScreen
                      ? 0 : shellState.topChromeInsetHeight
              )
        else {
            isPointerInChromeRevealZone = false
            return
        }

        let pointInWindow = window.mouseLocationOutsideOfEventStream
        let pointInContentView = contentView.convert(pointInWindow, from: nil)
        let isHovering = revealRect.contains(pointInContentView)

        guard isHovering != isPointerInChromeRevealZone else {
            return
        }

        handleTopHoverChanged(isHovering)
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
