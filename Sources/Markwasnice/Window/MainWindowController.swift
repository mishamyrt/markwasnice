import AppKit
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let fullScreenHistory = NSToolbarItem.Identifier("FullScreenHistory")
    static let fullScreenDocumentTitle = NSToolbarItem.Identifier("FullScreenDocumentTitle")
    static let fullScreenPreview = NSToolbarItem.Identifier("FullScreenPreview")
}

@MainActor
final class MainWindowController: NSWindowController, MarkdownEditorViewDelegate, NSWindowDelegate, NSToolbarDelegate {
    private let editorView: MarkdownEditorView
    private let contentView: EditorChromeView
    private let autosaveStore: AutosaveStore
    private let windowChromeToolbar = NSToolbar(identifier: "WindowChromeToolbar")
    private let fullScreenToolbar = NSToolbar(identifier: "FullScreenToolbar")
    private let fullScreenHistoryControl = ChromeHistoryControl()
    private let fullScreenPreviewButton = ChromeIconButton(symbolName: "eye")
    private let fullScreenTitleLabel = NSTextField(labelWithString: "Untitled")
    private let fullScreenDirtyDotLabel = NSTextField(labelWithString: "•")
    private let fullScreenTitleView = NSStackView()
    private let parseService = MarkdownParseService()
    private var autosaveWorkItem: DispatchWorkItem?
    private var wordCountTask: Task<Void, Never>?
    private var chromeHideWorkItem: DispatchWorkItem?
    private var isChromeSuppressed = false
    private var isPointerInChromeRevealZone = false
    private var isInFullScreen = false
    private var latestParseResult: MarkdownParseResult?
    private var resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = []
    private var currentFileURL: URL?
    private var documentEdited = false {
        didSet {
            window?.isDocumentEdited = documentEdited
            updateChromeTitle()
        }
    }

    init(settings: EditorSettings, autosaveStore: AutosaveStore, draft: AutosavedDraft?) {
        editorView = MarkdownEditorView(settings: settings)
        contentView = EditorChromeView(editorView: editorView)
        self.autosaveStore = autosaveStore

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // HACK: add an empty toolbar to move the window controls into the content area.
        window.toolbar = windowChromeToolbar
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.acceptsMouseMovedEvents = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.title = draft?.fileURL?.lastPathComponent ?? "Untitled"
        window.center()
        window.contentView = contentView

        super.init(window: window)

        configureFullScreenToolbar()

        contentView.onTopHoverChanged = { [weak self] isHovering in
            self?.handleTopHoverChanged(isHovering)
        }
        contentView.onUndo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("undo:")), with: nil)
        }
        contentView.onRedo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("redo:")), with: nil)
        }

        editorView.delegate = self
        editorView.setChromeInsets(top: EditorChromeView.topChromeHeight, bottom: 188)
        editorView.updateWindowWidthFontScale(for: window.frame.width, spans: resolvedStyleSpans)
        if let draft {
            currentFileURL = draft.fileURL
            editorView.documentURL = draft.fileURL
            editorView.setString(draft.text, clearsUndo: true)
            documentEdited = !draft.text.isEmpty
        }
        parseService.onParse = { [weak self] result in
            guard let self else {
                return
            }

            self.latestParseResult = result
            guard result.sourceLength == self.editorView.string.utf16.count else {
                return
            }

            let sourceMap = SourceMap(text: self.editorView.string)
            let resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = result.spans.compactMap { span in
                guard let range = sourceMap.nsRange(for: span.range) else {
                    return nil
                }

                return ResolvedMarkdownStyleSpan(range: range, kind: span.kind)
            }
            self.resolvedStyleSpans = MarkdownLinkStyleResolver.resolve(
                spans: resolvedStyleSpans, in: self.editorView.string)
            self.editorView.applyStyles(self.resolvedStyleSpans)
        }
        window.delegate = self
        updateChromeTitle()
        parseService.scheduleParse(text: editorView.string)
        scheduleWordCount()
    }

    func applySettings(_ settings: EditorSettings) {
        editorView.applySettings(settings, spans: resolvedStyleSpans)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window else {
            return
        }

        editorView.updateWindowWidthFontScale(for: window.frame.width, spans: resolvedStyleSpans)
    }

    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        var options = proposedOptions
        options.insert(.autoHideMenuBar)
        options.insert(.autoHideToolbar)
        return options
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        setFullScreenChromeMode(true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        setFullScreenChromeMode(true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        setFullScreenChromeMode(false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        setFullScreenChromeMode(false)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        fullScreenToolbarItemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        fullScreenToolbarItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .fullScreenHistory:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = fullScreenHistoryControl
            return item
        case .fullScreenDocumentTitle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = fullScreenTitleView
            item.isBordered = false
            return item
        case .fullScreenPreview:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = fullScreenPreviewButton
            return item
        default:
            return nil
        }
    }

    func newDocument() -> Bool {
        flushAutosave()
        currentFileURL = nil
        editorView.documentURL = nil
        editorView.setString("", clearsUndo: true)
        documentEdited = false
        latestParseResult = nil
        resolvedStyleSpans = []
        parseService.scheduleParse(text: editorView.string)
        updateWindowTitle()
        editorView.focus()
        scheduleAutosave()
        scheduleWordCount()
        return true
    }

    func displayMarkdown(_ text: String, from url: URL) {
        flushAutosave()
        currentFileURL = url
        editorView.documentURL = url
        editorView.setString(text, clearsUndo: true)
        documentEdited = false
        latestParseResult = nil
        resolvedStyleSpans = []
        parseService.scheduleParse(text: text)
        updateWindowTitle()
        editorView.focus()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        scheduleAutosave()
        scheduleWordCount()
    }

    func saveDocument(_ sender: Any?) {
        if let url = currentFileURL {
            save(to: url)
        } else {
            saveDocumentAs(sender)
        }
    }

    func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Untitled.md"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        save(to: url)
    }

    func pasteAsLink() {
        editorView.pasteAsLink()
    }

    func wrapSelectionWithQuotes(opening: String, closing: String) {
        editorView.wrapSelectionWithQuotes(opening: opening, closing: closing)
    }

    func flushAutosave() {
        autosaveWorkItem?.cancel()
        autosaveWorkItem = nil
        autosaveStore.save(AutosavedDraft(text: editorView.string, fileURL: currentFileURL))
    }

    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView) {
        documentEdited = true
        parseService.scheduleParse(text: editorView.string)
        scheduleAutosave()
        scheduleWordCount()
        hideChrome()
    }

    func markdownEditorViewDidScroll(_ editorView: MarkdownEditorView) {
        hideChrome()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        flushAutosave()
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func save(to url: URL) {
        do {
            try editorView.string.write(to: url, atomically: true, encoding: .utf8)
            currentFileURL = url
            editorView.documentURL = url
            documentEdited = false
            updateWindowTitle()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            scheduleAutosave()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func updateWindowTitle() {
        window?.title = currentFileURL?.lastPathComponent ?? "Untitled"
        updateChromeTitle()
    }

    private func updateChromeTitle() {
        contentView.updateTitle(
            currentFileURL?.lastPathComponent ?? "Untitled", isEdited: documentEdited)
        fullScreenTitleLabel.stringValue = currentFileURL?.lastPathComponent ?? "Untitled"
        fullScreenDirtyDotLabel.isHidden = !documentEdited
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.flushAutosave()
            }
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
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

                self?.contentView.updateWordCount(count)
            }
        }
    }

    private var fullScreenToolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [
            .fullScreenHistory,
            .flexibleSpace,
            .fullScreenDocumentTitle,
            .flexibleSpace,
            .fullScreenPreview,
        ]
    }

    private func configureFullScreenToolbar() {
        fullScreenToolbar.delegate = self
        fullScreenToolbar.allowsUserCustomization = false
        fullScreenToolbar.autosavesConfiguration = false
        fullScreenToolbar.displayMode = .iconOnly
        fullScreenToolbar.sizeMode = .regular
        fullScreenToolbar.centeredItemIdentifier = .fullScreenDocumentTitle

        fullScreenHistoryControl.onUndo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("undo:")), with: nil)
        }
        fullScreenHistoryControl.onRedo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("redo:")), with: nil)
        }
        fullScreenHistoryControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fullScreenHistoryControl.widthAnchor.constraint(equalToConstant: 72),
            fullScreenHistoryControl.heightAnchor.constraint(equalToConstant: 36),
        ])

        fullScreenPreviewButton.target = self
        fullScreenPreviewButton.action = #selector(fullScreenPreviewPressed(_:))
        fullScreenPreviewButton.isEnabled = false
        fullScreenPreviewButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fullScreenPreviewButton.widthAnchor.constraint(equalToConstant: 36),
            fullScreenPreviewButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        fullScreenTitleLabel.alignment = .center
        fullScreenTitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        fullScreenTitleLabel.lineBreakMode = .byTruncatingMiddle
        fullScreenTitleLabel.textColor = .labelColor

        fullScreenDirtyDotLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        fullScreenDirtyDotLabel.textColor = .secondaryLabelColor

        fullScreenTitleView.orientation = .horizontal
        fullScreenTitleView.alignment = .centerY
        fullScreenTitleView.spacing = 4
        fullScreenTitleView.addArrangedSubview(fullScreenTitleLabel)
        fullScreenTitleView.addArrangedSubview(fullScreenDirtyDotLabel)
        fullScreenTitleView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            fullScreenTitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            fullScreenTitleView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func setFullScreenChromeMode(_ isFullScreen: Bool) {
        guard let window else {
            return
        }

        isInFullScreen = isFullScreen
        contentView.setUsesSystemTopBar(isFullScreen)
        editorView.setChromeInsets(
            top: isFullScreen ? 0 : EditorChromeView.topChromeHeight,
            bottom: 188
        )
        setWindowButtonsVisible(true, animated: false)

        if isFullScreen {
            window.toolbar = fullScreenToolbar
            window.toolbar?.isVisible = true
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
        } else {
            window.toolbar = windowChromeToolbar
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if isChromeSuppressed && !isPointerInChromeRevealZone {
                hideChromeNow()
            }
        }
    }

    @objc private func fullScreenPreviewPressed(_ sender: Any?) {
    }

    nonisolated private static func wordCount(in text: String) -> Int {
        text.split { character in
            character.isWhitespace || character.isPunctuation
        }.count
    }

    private func showChrome() {
        guard !isInFullScreen else {
            return
        }

        chromeHideWorkItem?.cancel()
        chromeHideWorkItem = nil
        contentView.setChromeVisible(true)
        setWindowButtonsVisible(true)
    }

    private func hideChrome() {
        isChromeSuppressed = true
        guard !isInFullScreen else {
            return
        }

        guard !isPointerInChromeRevealZone else {
            return
        }

        hideChromeNow()
    }

    private func hideChromeNow() {
        guard !isInFullScreen else {
            setWindowButtonsVisible(true)
            return
        }

        chromeHideWorkItem?.cancel()
        chromeHideWorkItem = nil
        contentView.setChromeVisible(false)
        setWindowButtonsVisible(false)
    }

    private func handleTopHoverChanged(_ isHovering: Bool) {
        isPointerInChromeRevealZone = isHovering
        guard !isInFullScreen else {
            return
        }

        if isHovering {
            showChrome()
        } else if isChromeSuppressed {
            hideChromeNow()
        }
    }

    private func setWindowButtonsVisible(_ visible: Bool, animated: Bool = true) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window?.standardWindowButton(button) else {
                continue
            }

            if animated {
                button.animator().alphaValue = visible ? 1 : 0
            } else {
                button.alphaValue = visible ? 1 : 0
            }
            button.isEnabled = visible
        }
    }
}
