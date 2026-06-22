import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, MarkdownEditorViewDelegate, NSWindowDelegate {
    private let editorView: MarkdownEditorView
    private let contentView: EditorChromeView
    private let autosaveStore: AutosaveStore
    private let parseService = MarkdownParseService()
    private var autosaveWorkItem: DispatchWorkItem?
    private var wordCountTask: Task<Void, Never>?
    private var chromeHideWorkItem: DispatchWorkItem?
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
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.acceptsMouseMovedEvents = true
        window.title = draft?.fileURL?.lastPathComponent ?? "Untitled"
        window.center()
        window.contentView = contentView

        super.init(window: window)

        contentView.onTopHover = { [weak self] in self?.showChrome() }
        contentView.onLeaveTopHover = { [weak self] in self?.scheduleChromeHide() }
        contentView.onUndo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("undo:")), with: nil)
        }
        contentView.onRedo = { [weak self] in
            self?.window?.firstResponder?.tryToPerform(Selector(("redo:")), with: nil)
        }

        editorView.delegate = self
        editorView.setChromeInsets(top: EditorChromeView.topChromeHeight, bottom: 188)
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
            self.resolvedStyleSpans = result.spans.compactMap { span in
                guard let range = sourceMap.nsRange(for: span.range) else {
                    return nil
                }

                return ResolvedMarkdownStyleSpan(range: range, kind: span.kind)
            }
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

    nonisolated private static func wordCount(in text: String) -> Int {
        text.split { character in
            character.isWhitespace || character.isPunctuation
        }.count
    }

    private func showChrome() {
        chromeHideWorkItem?.cancel()
        chromeHideWorkItem = nil
        contentView.setChromeVisible(true)
        setWindowButtonsVisible(true)
    }

    private func hideChrome() {
        chromeHideWorkItem?.cancel()
        chromeHideWorkItem = nil
        contentView.setChromeVisible(false)
        setWindowButtonsVisible(false)
    }

    private func scheduleChromeHide() {
        chromeHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideChrome()
        }
        chromeHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func setWindowButtonsVisible(_ visible: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window?.standardWindowButton(button) else {
                continue
            }

            button.animator().alphaValue = visible ? 1 : 0
            button.isEnabled = visible
        }
    }
}

@MainActor
private final class EditorChromeView: NSView {
    static let topChromeHeight: CGFloat = 72

    var onTopHover: (() -> Void)?
    var onLeaveTopHover: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private let editorView: MarkdownEditorView
    private let topChrome = NSVisualEffectView()
    private let statusBar = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Untitled")
    private let dirtyDotLabel = NSTextField(labelWithString: "•")
    private let wordCountLabel = NSTextField(labelWithString: "0 words")
    private let undoButton = ChromeIconButton(symbolName: "arrow.uturn.backward")
    private let redoButton = ChromeIconButton(symbolName: "arrow.uturn.forward")
    private let previewButton = ChromeIconButton(symbolName: "eye")
    private var trackingArea: NSTrackingArea?
    private var isHoveringTop = false
    private var isChromeVisible = true

    init(editorView: MarkdownEditorView) {
        self.editorView = editorView
        super.init(frame: .zero)

        configureEditorView()
        configureTopChrome()
        configureStatusBar()
        updateTitle("Untitled", isEdited: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let isInTopZone = bounds.maxY - location.y <= 96
        if isInTopZone {
            isHoveringTop = true
            onTopHover?()
        } else if isHoveringTop {
            isHoveringTop = false
            onLeaveTopHover?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringTop = false
        onLeaveTopHover?()
    }

    func setChromeVisible(_ visible: Bool) {
        guard visible != isChromeVisible else {
            return
        }

        isChromeVisible = visible
        if visible {
            topChrome.isHidden = false
            statusBar.isHidden = false
        }

        setControlsEnabled(visible)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            topChrome.animator().alphaValue = visible ? 1 : 0
            statusBar.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.topChrome.isHidden = !visible
                self.statusBar.isHidden = !visible
            }
        }
    }

    func updateTitle(_ title: String, isEdited: Bool) {
        titleLabel.stringValue = title
        dirtyDotLabel.isHidden = !isEdited
    }

    func updateWordCount(_ count: Int) {
        wordCountLabel.stringValue = count == 1 ? "1 word" : "\(count) words"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureEditorView() {
        editorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editorView)
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorView.topAnchor.constraint(equalTo: topAnchor),
            editorView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureTopChrome() {
        topChrome.material = .headerView
        topChrome.blendingMode = .withinWindow
        topChrome.state = .active
        topChrome.translatesAutoresizingMaskIntoConstraints = false
        topChrome.wantsLayer = true
        topChrome.layer?.mask = topGradientMask()

        let leftStack = NSStackView(views: [undoButton, redoButton])
        leftStack.orientation = .horizontal
        leftStack.spacing = 6
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        configureChromeButton(undoButton, action: #selector(undoPressed(_:)))
        configureChromeButton(redoButton, action: #selector(redoPressed(_:)))
        configureChromeButton(previewButton, action: #selector(previewPressed(_:)))
        previewButton.isEnabled = false

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        dirtyDotLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        dirtyDotLabel.textColor = .secondaryLabelColor
        dirtyDotLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(topChrome)
        topChrome.addSubview(leftStack)
        topChrome.addSubview(titleLabel)
        topChrome.addSubview(dirtyDotLabel)
        topChrome.addSubview(previewButton)

        NSLayoutConstraint.activate([
            topChrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            topChrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            topChrome.topAnchor.constraint(equalTo: topAnchor),
            topChrome.heightAnchor.constraint(equalToConstant: Self.topChromeHeight),

            leftStack.leadingAnchor.constraint(equalTo: topChrome.leadingAnchor, constant: 84),
            leftStack.centerYAnchor.constraint(equalTo: topChrome.topAnchor, constant: 32),

            titleLabel.centerXAnchor.constraint(equalTo: topChrome.centerXAnchor, constant: -5),
            titleLabel.centerYAnchor.constraint(equalTo: leftStack.centerYAnchor),
            titleLabel.widthAnchor.constraint(
                lessThanOrEqualTo: topChrome.widthAnchor, multiplier: 0.42),

            dirtyDotLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            dirtyDotLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            previewButton.trailingAnchor.constraint(
                equalTo: topChrome.trailingAnchor, constant: -18),
            previewButton.centerYAnchor.constraint(equalTo: leftStack.centerYAnchor),
        ])
    }

    private func configureStatusBar() {
        statusBar.material = .hudWindow
        statusBar.blendingMode = .withinWindow
        statusBar.state = .active
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        wordCountLabel.alignment = .right
        wordCountLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        wordCountLabel.textColor = .secondaryLabelColor
        wordCountLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(statusBar)
        statusBar.addSubview(wordCountLabel)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),

            wordCountLabel.trailingAnchor.constraint(
                equalTo: statusBar.trailingAnchor, constant: -18),
            wordCountLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    private func configureChromeButton(_ button: ChromeIconButton, action: Selector) {
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setControlsEnabled(_ enabled: Bool) {
        undoButton.isEnabled = enabled
        redoButton.isEnabled = enabled
        previewButton.isEnabled = false
    }

    private func topGradientMask() -> CALayer {
        let gradient = CAGradientLayer()
        gradient.frame = NSRect(x: 0, y: 0, width: 2000, height: Self.topChromeHeight)
        gradient.colors = [
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.9).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
        ]
        gradient.locations = [0, 0.68, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        return gradient
    }

    @objc private func undoPressed(_ sender: Any?) {
        onUndo?()
    }

    @objc private func redoPressed(_ sender: Any?) {
        onRedo?()
    }

    @objc private func previewPressed(_ sender: Any?) {
    }
}

@MainActor
private final class ChromeIconButton: NSControl {
    private let effectView = NSVisualEffectView()
    private let imageView = NSImageView()

    init(symbolName: String) {
        super.init(frame: .zero)

        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        configureView()
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.4
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }

        alphaValue = 0.72
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else {
            return
        }

        alphaValue = 1
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            sendAction(action, to: target)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureView() {
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false

        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        imageView.contentTintColor = .labelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(effectView)
        effectView.addSubview(imageView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }
}
