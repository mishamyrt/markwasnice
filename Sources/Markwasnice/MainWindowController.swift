import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ObjectiveC.runtime
import QuartzCore
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
    private var isChromeSuppressed = false
    private var isPointerInChromeRevealZone = false
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
        // HACK: add custom toolbar to make move window controls
        let customToolbar = NSToolbar()
        window.toolbar = customToolbar
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

    func windowDidResize(_ notification: Notification) {
        guard let window else {
            return
        }

        editorView.updateWindowWidthFontScale(for: window.frame.width, spans: resolvedStyleSpans)
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
        isChromeSuppressed = true
        guard !isPointerInChromeRevealZone else {
            return
        }

        hideChromeNow()
    }

    private func hideChromeNow() {
        chromeHideWorkItem?.cancel()
        chromeHideWorkItem = nil
        contentView.setChromeVisible(false)
        setWindowButtonsVisible(false)
    }

    private func handleTopHoverChanged(_ isHovering: Bool) {
        isPointerInChromeRevealZone = isHovering
        if isHovering {
            showChrome()
        } else if isChromeSuppressed {
            hideChromeNow()
        }
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
    static let topChromeHeight: CGFloat = 60

    var onTopHoverChanged: ((Bool) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private let editorView: MarkdownEditorView
    private let topChrome = HeaderChromeView()
    private let statusBar = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "Untitled")
    private let dirtyDotLabel = NSTextField(labelWithString: "•")
    private let wordCountLabel = NSTextField(labelWithString: "0 words")
    private let historyControl = ChromeHistoryControl()
    private let previewButton = ChromeIconButton(symbolName: "eye")
    private var trackingArea: NSTrackingArea?
    private var isChromeVisible = true
    private var isPointerInTopZone = false

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
        let isInTopZone = bounds.maxY - location.y <= 52
        updateTopHover(isInTopZone)
    }

    override func mouseExited(with event: NSEvent) {
        updateTopHover(false)
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
                guard self.isChromeVisible == visible else {
                    return
                }

                self.topChrome.isHidden = !visible
                self.statusBar.isHidden = !visible
            }
        }
    }

    private func updateTopHover(_ isHovering: Bool) {
        guard isHovering != isPointerInTopZone else {
            return
        }

        isPointerInTopZone = isHovering
        onTopHoverChanged?(isHovering)
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
        topChrome.translatesAutoresizingMaskIntoConstraints = false

        historyControl.onUndo = { [weak self] in
            self?.onUndo?()
        }
        historyControl.onRedo = { [weak self] in
            self?.onRedo?()
        }
        historyControl.translatesAutoresizingMaskIntoConstraints = false

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
        topChrome.contentView.addSubview(historyControl)
        topChrome.contentView.addSubview(titleLabel)
        topChrome.contentView.addSubview(dirtyDotLabel)
        topChrome.contentView.addSubview(previewButton)

        NSLayoutConstraint.activate([
            topChrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            topChrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            topChrome.topAnchor.constraint(equalTo: topAnchor),
            topChrome.heightAnchor.constraint(equalToConstant: Self.topChromeHeight),

            historyControl.leadingAnchor.constraint(
                equalTo: topChrome.contentView.leadingAnchor, constant: 94),
            historyControl.centerYAnchor.constraint(
                equalTo: topChrome.contentView.topAnchor, constant: 27),
            historyControl.widthAnchor.constraint(equalToConstant: 72),
            historyControl.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.centerXAnchor.constraint(
                equalTo: topChrome.contentView.centerXAnchor, constant: -5),
            titleLabel.centerYAnchor.constraint(equalTo: historyControl.centerYAnchor),
            titleLabel.widthAnchor.constraint(
                lessThanOrEqualTo: topChrome.contentView.widthAnchor, multiplier: 0.42),

            dirtyDotLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            dirtyDotLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            previewButton.trailingAnchor.constraint(
                equalTo: topChrome.contentView.trailingAnchor, constant: -9),
            previewButton.centerYAnchor.constraint(equalTo: historyControl.centerYAnchor),
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
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func setControlsEnabled(_ enabled: Bool) {
        historyControl.isEnabled = enabled
        previewButton.isEnabled = false
    }

    @objc private func previewPressed(_ sender: Any?) {
    }
}

@MainActor
private final class HeaderChromeView: NSView {
    private let blurView = PureBackdropBlurView()
    let contentView = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureView() {
        blurView.blurRadius = 2
        blurView.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(blurView)
        addSubview(contentView)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class PureBackdropBlurView: NSView {
    private let containerLayer = CALayer()
    private let backgroundGradientLayer = CAGradientLayer()
    private let backdropLayer: CALayer

    var blurRadius: CGFloat = 2 {
        didSet {
            updateBlurRadius()
        }
    }

    override init(frame frameRect: NSRect) {
        backdropLayer = Self.makeBackdropLayer()
        super.init(frame: frameRect)
        configureView()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = bounds
        backgroundGradientLayer.frame = bounds
        backdropLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundGradient()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureView() {
        wantsLayer = true
        guard let rootLayer = layer else {
            return
        }

        containerLayer.masksToBounds = true
        backgroundGradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        backgroundGradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        updateBackgroundGradient()

        backdropLayer.name = "pure-titlebar-backdrop"
        backdropLayer.backgroundColor = NSColor.clear.cgColor
        backdropLayer.masksToBounds = false
        backdropLayer.setValue(true, forKey: "allowsGroupBlending")
        backdropLayer.setValue(true, forKey: "allowsGroupOpacity")
        backdropLayer.setValue(true, forKey: "disablesOccludedBackdropBlurs")
        backdropLayer.setValue(true, forKey: "ignoresOffscreenGroups")
        backdropLayer.setValue(false, forKey: "allowsInPlaceFiltering")
        backdropLayer.setValue(0.5, forKey: "scale")
        backdropLayer.setValue(8.0, forKey: "bleedAmount")

        if let blur = Self.makeCAFilter(named: "variableBlur") {
            let gradientImage = makeGradientImage(startOffset: 0)
            blur.setValue(blurRadius, forKey: "inputRadius")
            blur.setValue(gradientImage, forKey: "inputMaskImage")
            blur.setValue(true, forKey: "inputNormalizeEdges")
            backdropLayer.filters = [blur]
        }

        containerLayer.addSublayer(backgroundGradientLayer)
        containerLayer.addSublayer(backdropLayer)
        rootLayer.addSublayer(containerLayer)
    }

    private func makeGradientImage(
        width: CGFloat = 100, height: CGFloat = 100, startOffset: CGFloat,
    ) -> CGImage {  // much lower resolution might be acceptable
        let ciGradientFilter = CIFilter.smoothLinearGradient()
        ciGradientFilter.color0 = CIColor.black
        ciGradientFilter.color1 = CIColor.clear
        ciGradientFilter.point0 = CGPoint(x: 0, y: height)
        ciGradientFilter.point1 = CGPoint(x: 0, y: startOffset * height)  // small negative value looks better with vertical lines

        return CIContext().createCGImage(
            ciGradientFilter.outputImage!, from: CGRect(x: 0, y: 0, width: width, height: height))!
    }

    private func updateBlurRadius() {
        backdropLayer.setValue(blurRadius, forKeyPath: "filters.variableBlur.inputRadius")
    }

    private func updateBackgroundGradient() {
        let background = EditorThemeColors.default
            .variant(for: effectiveAppearance)
            .background

        backgroundGradientLayer.colors = [
            background.withAlphaComponent(0.9).cgColor,
            background.withAlphaComponent(0).cgColor,
        ]
    }

    private static func makeBackdropLayer() -> CALayer {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else {
            assertionFailure("CABackdropLayer is unavailable")
            return CALayer()
        }

        return layerClass.init()
    }

    private static func makeCAFilter(named name: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") else {
            assertionFailure("CAFilter is unavailable")
            return nil
        }

        let selectors = [
            NSSelectorFromString("filterWithType:"),
            NSSelectorFromString("filterWithName:"),
        ]

        typealias Factory = @convention(c) (AnyClass, Selector, NSString) -> Unmanaged<AnyObject>?

        for selector in selectors {
            guard let method = class_getClassMethod(filterClass, selector) else {
                continue
            }

            let implementation = method_getImplementation(method)
            let factory = unsafeBitCast(implementation, to: Factory.self)
            return factory(filterClass, selector, name as NSString)?.takeUnretainedValue()
                as? NSObject
        }

        assertionFailure("No usable CAFilter factory selector found")
        return nil
    }
}

private final class ChromeHistoryControl: NSControl {
    private enum Segment {
        case undo
        case redo
    }

    private let glassView = NSGlassEffectView()
    private let glassContentView = NSView()
    private let undoHoverView = NSView()
    private let redoHoverView = NSView()
    private let dividerView = NSView()
    private let undoImageView = NSImageView()
    private let redoImageView = NSImageView()
    private var hoverSegment: Segment?
    private var trackingArea: NSTrackingArea?

    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
            updateHoverSegment(nil)
        }
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
        guard isEnabled else {
            return
        }

        updateHoverSegment(segment(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else {
            return
        }

        updateHoverSegment(segment(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        updateHoverSegment(nil)
    }

    override func mouseDown(with event: NSEvent) {
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else {
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        guard let segment = segment(at: location) else {
            return
        }

        if segment == .undo {
            onUndo?()
        } else {
            onRedo?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureView() {
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.cornerRadius = 18
        glassView.style = .regular
        glassView.contentView = glassContentView

        glassContentView.translatesAutoresizingMaskIntoConstraints = false

        configureHoverView(undoHoverView)
        configureHoverView(redoHoverView)

        dividerView.wantsLayer = true
        dividerView.layer?.backgroundColor =
            NSColor.separatorColor
            .withAlphaComponent(0.1)
            .cgColor
        dividerView.translatesAutoresizingMaskIntoConstraints = false

        configureImageView(undoImageView, symbolName: "chevron.left")
        configureImageView(redoImageView, symbolName: "chevron.right")

        addSubview(glassView)
        glassContentView.addSubview(undoHoverView)
        glassContentView.addSubview(redoHoverView)
        glassContentView.addSubview(dividerView)
        glassContentView.addSubview(undoImageView)
        glassContentView.addSubview(redoImageView)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),

            glassContentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            glassContentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            glassContentView.topAnchor.constraint(equalTo: glassView.topAnchor),
            glassContentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),

            undoHoverView.centerXAnchor.constraint(
                equalTo: glassContentView.leadingAnchor, constant: 18),
            undoHoverView.centerYAnchor.constraint(equalTo: glassContentView.centerYAnchor),
            undoHoverView.widthAnchor.constraint(equalToConstant: 28),
            undoHoverView.heightAnchor.constraint(equalToConstant: 28),

            redoHoverView.centerXAnchor.constraint(
                equalTo: glassContentView.trailingAnchor, constant: -18),
            redoHoverView.centerYAnchor.constraint(equalTo: glassContentView.centerYAnchor),
            redoHoverView.widthAnchor.constraint(equalToConstant: 28),
            redoHoverView.heightAnchor.constraint(equalToConstant: 28),

            dividerView.centerXAnchor.constraint(equalTo: glassContentView.centerXAnchor),
            dividerView.centerYAnchor.constraint(equalTo: glassContentView.centerYAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: 1),
            dividerView.heightAnchor.constraint(equalToConstant: 20),

            undoImageView.centerXAnchor.constraint(
                equalTo: glassContentView.leadingAnchor, constant: 18),
            undoImageView.centerYAnchor.constraint(equalTo: glassContentView.centerYAnchor),
            undoImageView.widthAnchor.constraint(equalToConstant: 14),
            undoImageView.heightAnchor.constraint(equalToConstant: 14),

            redoImageView.centerXAnchor.constraint(
                equalTo: glassContentView.trailingAnchor, constant: -18),
            redoImageView.centerYAnchor.constraint(equalTo: glassContentView.centerYAnchor),
            redoImageView.widthAnchor.constraint(equalToConstant: 14),
            redoImageView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    private func configureHoverView(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        view.layer?.cornerRadius = 14
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
    }

    private func configureImageView(_ imageView: NSImageView, symbolName: String) {
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        imageView.contentTintColor = .labelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func segment(at location: NSPoint) -> Segment? {
        guard bounds.contains(location) else {
            return nil
        }

        return location.x < bounds.midX ? .undo : .redo
    }

    private func updateHoverSegment(_ segment: Segment?) {
        hoverSegment = segment
        undoHoverView.isHidden = hoverSegment != .undo
        redoHoverView.isHidden = hoverSegment != .redo
    }
}

private final class ChromeIconButton: NSControl {
    private let glassView = NSGlassEffectView()
    private let glassContentView = NSView()
    private let imageView = NSImageView()

    init(symbolName: String) {
        super.init(frame: .zero)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        configureView()
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
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
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.cornerRadius = 18
        glassView.style = .regular
        glassView.contentView = glassContentView

        glassContentView.translatesAutoresizingMaskIntoConstraints = false

        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        imageView.contentTintColor = .labelColor
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glassView)
        glassContentView.addSubview(imageView)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),

            glassContentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            glassContentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            glassContentView.topAnchor.constraint(equalTo: glassView.topAnchor),
            glassContentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor),

            imageView.centerXAnchor.constraint(equalTo: glassContentView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: glassContentView.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }
}
