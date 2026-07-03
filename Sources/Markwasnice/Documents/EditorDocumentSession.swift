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

    private let stylingController: MarkdownStylingController
    private let onAutosaveNeeded: () -> Void
    private var wordCountTask: Task<Void, Never>?
    private var isCloseApproved = false
    private var isPromptVisible = false
    private var isPointerInChromeRevealZone = false
    private var text: String
    private var saveTask: Task<Void, Never>?
    private var searchMatches: [NSRange] = []
    private var selectedSearchMatchIndex: Int?

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

        editorView.delegate = self
        editorView.documentURL = fileURL
        editorView.setString(text, clearsUndo: true)
        applyChromeInsets(isFullScreen: false)
        stylingController.scheduleParse(text: text)
        updateTitle()
        scheduleWordCount()
    }

    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView) {
        guard editorView.string != text else {
            return
        }

        text = editorView.string
        hasUnsavedFileChanges = true
        updateTitle()
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

    func setTabBarChrome(isVisible: Bool, topInset: CGFloat) {
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

    func pasteAsLink() {
        editorView.pasteAsLink()
    }

    func applyMarkup(_ command: MarkdownMarkupCommand) {
        editorView.applyMarkup(command)
    }

    func showSearch() {
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

    var autosavedDraft: AutosavedDraft {
        AutosavedDraft(text: text, fileURL: fileURL)
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

            let count = Self.wordCount(in: text)
            await MainActor.run {
                guard !Task.isCancelled else {
                    return
                }

                self?.shellState.wordCount = count
            }
        }
    }

    private func applyChromeInsets(isFullScreen: Bool) {
        let toolbarHeight = isFullScreen
            ? fullScreenSearchChromeHeight
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
        shellState.isSearchPresented ? EditorShellState.searchAreaHeight : 0
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
    }

    private func hideChrome() {
        guard !shellState.isSearchPresented, !shellState.isTabBarVisible else {
            return
        }

        updatePointerInChromeRevealZone()

        guard !isPointerInChromeRevealZone else {
            return
        }

        hideChromeNow()
    }

    private func hideChromeNow() {
        guard !shellState.isSearchPresented, !shellState.isTabBarVisible else {
            return
        }

        if shellState.isToolbarVisible {
            shellState.isToolbarVisible = false
        }
        if shellState.isStatusBarVisible {
            shellState.isStatusBarVisible = false
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
