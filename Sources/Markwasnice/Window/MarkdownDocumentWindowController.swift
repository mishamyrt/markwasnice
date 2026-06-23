import AppKit

@MainActor
final class MarkdownDocumentWindowController: NSWindowController,
    MarkdownEditorViewDelegate, NSWindowDelegate
{
    private static var nextWindowTopLeft: NSPoint?

    private let editorView: MarkdownEditorView
    private let contentView: EditorChromeView
    private let stylingController: MarkdownStylingController
    private weak var markdownDocument: MarkdownDocument?
    private lazy var closeCoordinator = DocumentCloseCoordinator { [weak self] in
        self?.isAppTerminating == true
    }

    private let windowChromeToolbar = NSToolbar(identifier: "WindowChromeToolbar")
    private let fullScreenToolbarController = FullScreenToolbarController()
    private var wordCountTask: Task<Void, Never>?
    private var chromeHideWorkItem: DispatchWorkItem?
    private var isClosingDocument = false
    private var isChromeSuppressed = false
    private var isPointerInChromeRevealZone = false
    private var isInFullScreen = false

    init(document: MarkdownDocument, settings: EditorSettings) {
        markdownDocument = document
        editorView = MarkdownEditorView(settings: settings)
        stylingController = MarkdownStylingController(editorView: editorView)
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
            from: Self.nextWindowTopLeft ?? NSPoint(
                x: window.frame.minX,
                y: window.frame.maxY
            )
        )
        window.contentView = contentView

        super.init(window: window)

        contentView.onTopHoverChanged = { [weak self] isHovering in
            self?.handleTopHoverChanged(isHovering)
        }
        contentView.onUndo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("undo:")), with: nil)
        }
        contentView.onRedo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("redo:")), with: nil)
        }
        fullScreenToolbarController.onUndo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("undo:")), with: nil)
        }
        fullScreenToolbarController.onRedo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("redo:")), with: nil)
        }

        editorView.delegate = self
        editorView.setChromeInsets(top: EditorChromeView.topChromeHeight, bottom: 188)
        stylingController.updateWindowWidthFontScale(for: window.frame.width)
        editorView.documentURL = document.fileURL
        editorView.setString(document.editorText, clearsUndo: true)
        window.delegate = self
        updateChromeTitle()
        stylingController.scheduleParse(text: editorView.string)
        scheduleWordCount()
    }

    func applySettings(_ settings: EditorSettings) {
        stylingController.applySettings(settings)
    }

    func windowDidResize(_: Notification) {
        guard let window else {
            return
        }

        stylingController.updateWindowWidthFontScale(for: window.frame.width)
    }

    func window(
        _: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication
            .PresentationOptions
    ) -> NSApplication.PresentationOptions {
        var options = proposedOptions
        options.insert(.autoHideMenuBar)
        options.insert(.autoHideToolbar)
        return options
    }

    func windowWillEnterFullScreen(_: Notification) {
        setFullScreenChromeMode(true)
    }

    func windowDidEnterFullScreen(_: Notification) {
        setFullScreenChromeMode(true)
    }

    func windowWillExitFullScreen(_: Notification) {
        setFullScreenChromeMode(false)
    }

    func windowDidExitFullScreen(_: Notification) {
        setFullScreenChromeMode(false)
    }

    func pasteAsLink() {
        editorView.pasteAsLink()
    }

    func wrapSelectionWithQuotes(opening: String, closing: String) {
        editorView.wrapSelectionWithQuotes(opening: opening, closing: closing)
    }

    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView) {
        markdownDocument?.editorTextDidChange(editorView.string)
        stylingController.scheduleParse(text: editorView.string)
        scheduleWordCount()
        hideChrome()
    }

    func markdownEditorViewDidScroll(_: MarkdownEditorView) {
        hideChrome()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeCoordinator.windowShouldClose(
            sender,
            document: markdownDocument,
            title: documentTitle
        ) {
            sender.close()
        }
    }

    func windowWillClose(_: Notification) {
        if isClosingDocument {
            return
        }

        isClosingDocument = true
        let document = markdownDocument
        document?.close()
        document?.flushAutosave()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
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
        fullScreenToolbarController.updateTitle(documentTitle, isEdited: isEdited)
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
            window.toolbar = fullScreenToolbarController.toolbar
            window.toolbar?.isVisible = true
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
        } else {
            window.toolbar = windowChromeToolbar
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if isChromeSuppressed, !isPointerInChromeRevealZone {
                hideChromeNow()
            }
        }
    }

    private var documentTitle: String {
        markdownDocument?.fileURL?.lastPathComponent ?? "Untitled"
    }

    private var isAppTerminating: Bool {
        (NSApp.delegate as? AppDelegate)?.isTerminating == true
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
