import AppKit
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let fullScreenHistory = NSToolbarItem.Identifier("FullScreenHistory")
    static let fullScreenDocumentTitle = NSToolbarItem.Identifier("FullScreenDocumentTitle")
    static let fullScreenPreview = NSToolbarItem.Identifier("FullScreenPreview")
}

@MainActor
final class MainWindowController: NSWindowController, MarkdownEditorViewDelegate, NSWindowDelegate, NSToolbarDelegate {
    private static var nextWindowTopLeft: NSPoint?

    private let editorView: MarkdownEditorView
    private let contentView: EditorChromeView
    private weak var markdownDocument: MarkdownDocument?
    private let windowChromeToolbar = NSToolbar(identifier: "WindowChromeToolbar")
    private let fullScreenToolbar = NSToolbar(identifier: "FullScreenToolbar")
    private let fullScreenHistoryControl = ChromeHistoryControl()
    private let fullScreenPreviewButton = ChromeIconButton(symbolName: "eye")
    private let fullScreenTitleLabel = NSTextField(labelWithString: "Untitled")
    private let fullScreenDirtyDotLabel = NSTextField(labelWithString: "•")
    private let fullScreenTitleView = NSStackView()
    private let parseService = MarkdownParseService()
    private var wordCountTask: Task<Void, Never>?
    private var chromeHideWorkItem: DispatchWorkItem?
    private var isCloseApproved = false
    private var isClosingDocument = false
    private var isChromeSuppressed = false
    private var isPointerInChromeRevealZone = false
    private var isInFullScreen = false
    private var latestParseResult: MarkdownParseResult?
    private var resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = []

    init(document: MarkdownDocument, settings: EditorSettings) {
        markdownDocument = document
        editorView = MarkdownEditorView(settings: settings)
        contentView = EditorChromeView(editorView: editorView)

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
        window.title = document.fileURL?.lastPathComponent ?? "Untitled"
        window.center()
        Self.nextWindowTopLeft = window.cascadeTopLeft(
            from: Self.nextWindowTopLeft ?? NSPoint(x: window.frame.minX, y: window.frame.maxY)
        )
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
        editorView.documentURL = document.fileURL
        editorView.setString(document.editorText, clearsUndo: true)
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

    func pasteAsLink() {
        editorView.pasteAsLink()
    }

    func wrapSelectionWithQuotes(opening: String, closing: String) {
        editorView.wrapSelectionWithQuotes(opening: opening, closing: closing)
    }

    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView) {
        markdownDocument?.editorTextDidChange(editorView.string)
        parseService.scheduleParse(text: editorView.string)
        scheduleWordCount()
        hideChrome()
    }

    func markdownEditorViewDidScroll(_ editorView: MarkdownEditorView) {
        hideChrome()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isCloseApproved,
              !isAppTerminating,
              let markdownDocument,
              markdownDocument.hasUnsavedChangesForDisplay else {
            return true
        }

        promptToSaveBeforeClosing(sender, document: markdownDocument)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if isClosingDocument {
            return
        }

        isClosingDocument = true
        let document = markdownDocument
        document?.close()
        document?.flushAutosave()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refreshDocumentState() {
        editorView.documentURL = markdownDocument?.fileURL
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        window?.title = documentTitle
        window?.isDocumentEdited = markdownDocument?.hasUnsavedChangesForDisplay ?? false
        updateChromeTitle()
    }

    private func updateChromeTitle() {
        let isEdited = markdownDocument?.hasUnsavedChangesForDisplay ?? false
        contentView.updateTitle(documentTitle, isEdited: isEdited)
        fullScreenTitleLabel.stringValue = documentTitle
        fullScreenDirtyDotLabel.isHidden = !isEdited
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

    private var documentTitle: String {
        markdownDocument?.fileURL?.lastPathComponent ?? "Untitled"
    }

    private var isAppTerminating: Bool {
        (NSApp.delegate as? AppDelegate)?.isTerminating == true
    }

    private func promptToSaveBeforeClosing(_ window: NSWindow, document: MarkdownDocument) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to \"\(documentTitle)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self, weak document] response in
            guard let self, let document else {
                return
            }

            switch response {
            case .alertFirstButtonReturn:
                self.saveBeforeClosing(document, window: window)
            case .alertSecondButtonReturn:
                self.closeAfterUserApproval(window)
            default:
                break
            }
        }
    }

    private func saveBeforeClosing(_ document: MarkdownDocument, window: NSWindow) {
        if let url = document.fileURL {
            save(document, to: url, operation: .saveOperation, thenClose: window)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = "Untitled.md"
        panel.beginSheetModal(for: window) { [weak self, weak document] response in
            guard let self, let document, response == .OK, let url = panel.url else {
                return
            }

            self.save(document, to: url, operation: .saveAsOperation, thenClose: window)
        }
    }

    private func save(
        _ document: MarkdownDocument,
        to url: URL,
        operation: NSDocument.SaveOperationType,
        thenClose window: NSWindow
    ) {
        document.save(to: url, ofType: MarkdownDocument.fileType, for: operation) { [weak self] error in
            guard let self else {
                return
            }

            if let error {
                NSAlert(error: error).beginSheetModal(for: window)
                return
            }

            self.closeAfterUserApproval(window)
        }
    }

    private func closeAfterUserApproval(_ window: NSWindow) {
        isCloseApproved = true
        window.close()
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
