@preconcurrency import AppKit
import UniformTypeIdentifiers

protocol MarkdownEditorViewDelegate: AnyObject {
    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView)
    func markdownEditorViewDidScroll(_ editorView: MarkdownEditorView)
    func markdownEditorViewShowSearch(_ editorView: MarkdownEditorView)
    func markdownEditorViewRequestInsertTable(_ editorView: MarkdownEditorView)
    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        requestOpenFileURLs urls: [URL]
    )
}

private enum MarkdownEditorDiagnostics {
    private static let environment = ProcessInfo.processInfo.environment

    static let isEnabled = flag("MARKWASNICE_EDITOR_DIAGNOSTICS")
    static let disableParsedStylingAfterPaste = flag(
        "MARKWASNICE_EDITOR_DISABLE_PARSED_STYLING_AFTER_PASTE"
    )
    static let disableHeadingOutdent = flag(
        "MARKWASNICE_EDITOR_DISABLE_HEADING_OUTDENT"
    )
    static let disableFontTraits = flag("MARKWASNICE_EDITOR_DISABLE_FONT_TRAITS")
    static let disableKern = flag("MARKWASNICE_EDITOR_DISABLE_KERN")
    static let disableParagraphStyle = flag(
        "MARKWASNICE_EDITOR_DISABLE_PARAGRAPH_STYLE"
    )
    static let disableBackgroundColor = flag(
        "MARKWASNICE_EDITOR_DISABLE_BACKGROUND_COLOR"
    )
    static let disableVisibleLocalStylingAfterPaste = flag(
        "MARKWASNICE_EDITOR_DISABLE_VISIBLE_LOCAL_AFTER_PASTE"
    )
    static let disableBackgroundChunkStyling = flag(
        "MARKWASNICE_EDITOR_DISABLE_BACKGROUND_CHUNKS"
    )

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else {
            return
        }

        let time = String(format: "%.3f", Date().timeIntervalSince1970)
        let line = "[MarkwasniceEditorDiagnostics \(time)] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func flag(_ name: String) -> Bool {
        guard let value = environment[name]?.lowercased() else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(value)
    }
}

final class MarkdownEditorView: NSView, NSTextViewDelegate,
    @preconcurrency NSTextStorageDelegate,
    @preconcurrency MarkdownTextViewCommandDelegate
{
    weak var delegate: MarkdownEditorViewDelegate?
    var documentURL: URL?
    /// Fired when the preview asks to leave (Escape); the owning session
    /// flips the shell state, which calls back into setPreviewActive(false).
    var onPreviewExitRequested: (() -> Void)?

    private let scrollView = NSScrollView()
    private let clipView = NSClipView()
    // TextKit 1 stack: contiguous layout computes exact geometry for the whole
    // document, so the document height is deterministic and the caret-visible
    // scrolling never drifts. TextKit 2's viewport-estimated heights caused
    // scroll jumps and flicker while typing in large documents.
    private let editorTextStorage = NSTextStorage()
    private let editorLayoutManager = MarkdownLayoutManager()
    private let textContainer = NSTextContainer(
        containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    /// Internal for the regression test harness, which simulates real typing
    /// through the text input path and inspects the resulting attributes.
    let textView: MarkdownTextView

    private var settings: EditorSettings
    private var themeColors = EditorThemeColors.default
    private var windowWidthFontScale: CGFloat = 1
    private var paragraphGutter: CGFloat = 0
    private var textTopPadding: CGFloat = 0
    private var textBottomPadding: CGFloat = 160
    private var protectedTopPadding: CGFloat = 0
    private var isChromeVisible = true
    private var lastScrollOffsetY: CGFloat?
    private var lastScrollClipSize: NSSize?

    private var currentStyleSpans: [ResolvedMarkdownStyleSpan] = []
    private var codeInlineDrawRanges: [NSRange] = []
    private var codeBlockDrawRanges: [NSRange] = []
    private var searchMatchRanges: [NSRange] = []
    private var selectedSearchMatchIndex: Int?
    private var isApplyingStyles = false
    private var isSettingTextProgrammatically = false
    private var isNormalizingEditedText = false
    private var deferredStyleTask: Task<Void, Never>?
    private var styleGeneration = 0
    private var hasRecentLargeEdit = false
    private var pendingFullStyleRanges: [NSRange] = []
    private var isFocusModeEnabled = false
    private var focusMode: EditorFocusMode = .focus
    private lazy var previewPresenter = makePreviewPresenter()
    private var previewHorizontalInset: CGFloat = 6
    private var isFocusTemporarilySuppressed = false
    private var activeFocusParagraphRange: NSRange?
    private var focusScrollAdjustmentCount = 0
    private let focusScrollAnimator = CaretScrollAnimator()

    private var isAdjustingFocusScroll: Bool {
        focusScrollAdjustmentCount > 0 || focusScrollAnimator.isAnimating
    }

    private static let immediateStyleThreshold = 20000
    private static let visibleStyleBuffer = 6000
    private static let backgroundStyleIdleDelayMilliseconds = 160

    var string: String {
        get { textView.string }
        set { setString(newValue, clearsUndo: false) }
    }

    init(settings: EditorSettings, frame frameRect: NSRect = .zero) {
        self.settings = settings

        editorTextStorage.addLayoutManager(editorLayoutManager)
        editorLayoutManager.addTextContainer(textContainer)
        editorLayoutManager.allowsNonContiguousLayout = false
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        textView = MarkdownTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: frameRect)

        configureTextView()
        configureScrollView()
        configureCursorGeometry()
        registerForDraggedTypes([.fileURL])

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    deinit {
        deferredStyleTask?.cancel()
    }

    override func layout() {
        super.layout()
        let didChangeGutter = applyChromeInsets()
        if didChangeGutter {
            restyleAllText()
        }
        invalidateEditorCursorRects()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            focusScrollAnimator.cancel()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyEditorColors()
        restyleAllText()
        previewPresenter.refreshIfActive()
    }

    func setString(_ string: String, clearsUndo: Bool) {
        let selectedRange = textView.selectedRange()
        isSettingTextProgrammatically = true
        textView.string = string
        isSettingTextProgrammatically = false

        if clearsUndo {
            textView.undoManager?.removeAllActions()
        }

        let boundedLocation = min(selectedRange.location, (string as NSString).length)
        textView.setSelectedRange(NSRange(location: boundedLocation, length: 0))
        restyleAllText()
        previewPresenter.refreshIfActive()
    }

    func setPreviewActive(_ isActive: Bool) {
        previewPresenter.setActive(isActive)
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func applyParsedStyles(
        _ spans: [ResolvedMarkdownStyleSpan],
        dirtyRanges: [NSRange]?
    ) {
        MarkdownEditorDiagnostics.log(
            "applyParsedStyles spans=\(spans.count) textLength=\((textView.string as NSString).length) "
                + "dirty=\(dirtyRanges.map { "\($0.count)" } ?? "nil") "
                + "recentLargeEdit=\(hasRecentLargeEdit)"
        )
        guard !(MarkdownEditorDiagnostics
            .disableParsedStylingAfterPaste && hasRecentLargeEdit)
        else {
            MarkdownEditorDiagnostics.log("applyParsedStyles skipped by flag")
            return
        }

        currentStyleSpans = spans
        updateCodeBackgroundRanges()
        guard !textView.hasMarkedText() else {
            return
        }

        // Only mutate attributes where the styling actually changed. Rewriting
        // unchanged regions invalidates their layout, which makes TextKit 2
        // re-estimate fragment heights above the viewport and the scroll
        // position jump on every keystroke — proportionally to the amount of
        // content above the caret.
        guard let dirtyRanges, !hasRecentLargeEdit else {
            hasRecentLargeEdit = false
            restyleAllText()
            return
        }

        applyDirtyStyles(dirtyRanges, spans: spans)
    }

    private func applyDirtyStyles(
        _ dirtyRanges: [NSRange],
        spans: [ResolvedMarkdownStyleSpan]
    ) {
        let string = (textView.textStorage?.string ?? "") as NSString
        let ranges = MarkdownStylingEngine.mergedLineRanges(dirtyRanges, in: string)
        let totalLength = ranges.reduce(0) { $0 + $1.length }

        // A huge dirty area (e.g. an edit that reflows the whole document)
        // goes through the chunked deferred pass instead of one synchronous
        // sweep.
        guard totalLength <= MarkdownStylingEngine.styleChunkLength else {
            scheduleDeferredDocumentStyling(spans: spans)
            return
        }

        for range in ranges {
            guard let range = boundedRange(range), range.length > 0 else {
                continue
            }

            applyStyles(
                in: range,
                spans: MarkdownStylingEngine.spansForRange(range, from: spans)
            )
        }

        resumeFullStylingIfNeeded(spans: spans)
    }

    func applySettings(_ settings: EditorSettings, spans: [ResolvedMarkdownStyleSpan]) {
        self.settings = settings
        currentStyleSpans = spans
        _ = updateTextContainerInset()
        restyleAllText()
        previewPresenter.refreshIfActive()
    }

    func updateWindowWidthFontScale(
        for windowWidth: CGFloat,
        spans: [ResolvedMarkdownStyleSpan]
    ) {
        let newScale = Self.windowWidthFontScale(for: windowWidth)
        let didChangeScale = newScale != windowWidthFontScale
        windowWidthFontScale = newScale

        let didChangeGutter = updateTextContainerInset()
        if didChangeScale || didChangeGutter {
            currentStyleSpans = spans
            restyleAllText()
        }
        if didChangeScale {
            previewPresenter.refreshIfActive()
        }
    }

    func setChromeInsets(
        top: CGFloat,
        bottom: CGFloat,
        protectedTop: CGFloat = 0
    ) {
        textTopPadding = top
        textBottomPadding = bottom
        protectedTopPadding = protectedTop
        applyChromeInsets()
        updateScrollerInsets()
        invalidateEditorCursorRects()
    }

    func setChromeVisible(_ isVisible: Bool) {
        isChromeVisible = isVisible
        updateScrollerInsets()
    }

    /// Content insets are zero (padding lives inside the text view), so the
    /// scroller spans the full window height by default; when the top bar is
    /// visible it is inset by the bar's height.
    private func updateScrollerInsets() {
        let topInset = isChromeVisible ? textTopPadding : 0
        setScrollerTopInset(topInset)
        previewPresenter.setScrollerTopInset(topInset)
    }

    func setFocusModeEnabled(_ isEnabled: Bool) {
        guard isFocusModeEnabled != isEnabled else {
            return
        }

        isFocusModeEnabled = isEnabled
        isFocusTemporarilySuppressed = false
        activeFocusParagraphRange = isEnabled ? activeParagraphRangeAtSelection() : nil
        updateCaretScrollOwnership()
        _ = updateTextContainerInset()
        restyleAllText()
        if isEnabled {
            centerCaretLineInVisibleArea(animated: true)
        }
    }

    /// While focus centering recenters on every caret move it owns the
    /// scroll position, and the text view's own keyboard caret scrolling
    /// must stand down; when centering is suspended for a user scroll the
    /// text view takes over again.
    private func updateCaretScrollOwnership() {
        textView.skipsKeyboardCaretScrolling =
            isFocusModeEnabled && !isFocusTemporarilySuppressed
    }

    func setFocusMode(_ mode: EditorFocusMode) {
        guard focusMode != mode else {
            return
        }

        focusMode = mode
        isFocusTemporarilySuppressed = false
        activeFocusParagraphRange = activeParagraphRangeAtSelection()
        restyleAllText()
        if isFocusModeEnabled {
            centerCaretLineInVisibleArea(animated: true)
        }
    }

    // MARK: Preview

    private func makePreviewPresenter() -> MarkdownPreviewPresenter {
        let presenter = MarkdownPreviewPresenter(
            container: self,
            editorScrollView: scrollView
        )
        presenter.renderContent = { [weak self] preview in
            self?.renderPreviewContent(into: preview)
        }
        presenter.editorScrollFraction = { [weak self] in
            self?.editorScrollFraction ?? 0
        }
        presenter.focusEditor = { [weak self] in
            self?.focus()
        }
        presenter.onScroll = { [weak self] in
            guard let self else {
                return
            }

            delegate?.markdownEditorViewDidScroll(self)
        }
        presenter.onExitRequested = { [weak self] in
            self?.onPreviewExitRequested?()
        }
        presenter.onPreviewCreated = { [weak self] _ in
            self?.pushPreviewInsets()
            self?.updateScrollerInsets()
        }
        return presenter
    }

    private func renderPreviewContent(into preview: MarkdownPreviewView) {
        let renderer = MarkdownPreviewRenderer(theme: .init(
            baseFontSize: basePointSize,
            colors: colors
        ))
        preview.setContent(renderer.render(textView.string), colors: colors)
    }

    private func pushPreviewInsets() {
        previewPresenter.setInsets(
            top: textTopPadding,
            bottom: textBottomPadding,
            horizontal: previewHorizontalInset
        )
    }

    private var editorScrollFraction: CGFloat {
        let maxOffset = textView.frame.height - clipView.bounds.height
        guard maxOffset > 0 else {
            return 0
        }

        return min(max(clipView.bounds.origin.y / maxOffset, 0), 1)
    }

    func setSearchMatches(_ ranges: [NSRange], selectedIndex: Int?) {
        // The document session clears search matches on every text change;
        // when nothing actually changes this must stay a no-op — a full
        // restyle here runs before the parse result arrives and used to
        // repaint the document with stale span positions on every keystroke.
        guard ranges != searchMatchRanges
            || selectedIndex != selectedSearchMatchIndex
        else {
            return
        }

        searchMatchRanges = ranges
        selectedSearchMatchIndex = selectedIndex
        restyleAllText()
    }

    func selectSearchMatch(_ range: NSRange) {
        guard boundedRange(range) != nil else {
            return
        }

        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    @discardableResult
    func replaceSearchMatch(_ range: NSRange, with replacement: String) -> Bool {
        guard boundedRange(range) != nil else {
            return false
        }

        return replaceText(
            in: range,
            with: replacement,
            selectedRange: NSRange(
                location: range.location + (replacement as NSString).length,
                length: 0
            )
        )
    }

    func replaceSearchMatches(_ ranges: [NSRange], with replacement: String) {
        let validRanges = ranges
            .filter { boundedRange($0) != nil }
            .sorted { $0.location < $1.location }
        guard !validRanges.isEmpty,
              let textStorage = textView.textStorage,
              textView.shouldChangeText(
                  inRanges: validRanges.map { NSValue(range: $0) },
                  replacementStrings: validRanges.map { _ in replacement }
              )
        else {
            return
        }

        textStorage.beginEditing()
        for range in validRanges.reversed() {
            textStorage.replaceCharacters(in: range, with: replacement)
        }
        textStorage.endEditing()
        textView.didChangeText()
    }

    func pasteAsLink() {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0,
              let selectedText = (textView.string as NSString)
              .substring(with: selectedRange)
              .nilIfEmpty,
              let urlString = pasteboardURLString()
        else {
            return
        }

        replaceSelectedText(with: "[\(escapeLinkText(selectedText))](\(urlString))")
    }

    func applyMarkup(_ command: MarkdownMarkupCommand) {
        guard let edit = command.edit(
            in: textView.string,
            selectedRange: textView.selectedRange()
        ) else {
            return
        }

        replaceText(
            in: edit.replacementRange,
            with: edit.replacementString,
            selectedRange: edit.selectedRange
        )
    }

    func insertTable(rows: Int, columns: Int) {
        guard let edit = MarkdownTableCommand.edit(
            in: textView.string,
            selectedRange: textView.selectedRange(),
            rows: rows,
            columns: columns
        ) else {
            return
        }

        replaceText(
            in: edit.replacementRange,
            with: edit.replacementString,
            selectedRange: edit.selectedRange
        )
        textView.scrollRangeToVisible(edit.selectedRange)
    }

    func wrapSelectionWithQuotes(opening: String, closing: String) {
        _ = wrapSelection(opening: opening, closing: closing)
    }

    func fixTypography() {
        let selectedRange = textView.selectedRange()
        let replacements = MarkdownTypographyCommand.replacements(
            in: textView.string,
            selectedRange: selectedRange,
            locale: settings.typographyLocale
        )
        guard !replacements.isEmpty,
              let textStorage = textView.textStorage,
              textView.shouldChangeText(
                  inRanges: replacements.map { NSValue(range: $0.range) },
                  replacementStrings: replacements.map(\.replacement)
              )
        else {
            return
        }

        textStorage.beginEditing()
        for replacement in replacements.reversed() {
            textStorage.replaceCharacters(
                in: replacement.range,
                with: replacement.replacement
            )
        }
        textStorage.endEditing()
        textView.didChangeText()
        textView.setSelectedRange(MarkdownTypographyCommand.adjustedSelection(
            selectedRange,
            after: replacements
        ))
    }

    func markdownTextViewShowFind(_: NSTextView) {
        delegate?.markdownEditorViewShowSearch(self)
    }

    func markdownTextView(
        _: NSTextView, applyMarkup command: MarkdownMarkupCommand
    ) {
        applyMarkup(command)
    }

    func markdownTextViewRequestInsertTable(_: NSTextView) {
        delegate?.markdownEditorViewRequestInsertTable(self)
    }

    func markdownTextViewInsertTab(_: NSTextView) {
        applyIndent(.indent)
    }

    func markdownTextViewInsertBacktab(_: NSTextView) {
        applyIndent(.outdent)
    }

    private func applyIndent(_ command: MarkdownIndentCommand) {
        let indentUnit: String
        switch settings.tabInsertionMode {
        case .spaces:
            indentUnit = String(repeating: " ", count: settings.tabWidth)
        case .tab:
            indentUnit = "\t"
        }

        guard let edit = command.edit(
            in: textView.string,
            selectedRange: textView.selectedRange(),
            indentUnit: indentUnit,
            tabWidth: settings.tabWidth
        ) else {
            return
        }

        replaceText(
            in: edit.replacementRange,
            with: edit.replacementString,
            selectedRange: edit.selectedRange
        )
    }

    func markdownTextViewContinueMarkdownPrefix(_ textView: NSTextView) -> Bool {
        guard let edit = MarkdownContinuationCommand.edit(
            in: textView.string,
            selectedRange: textView.selectedRange()
        ) else {
            return false
        }

        return replaceText(
            in: edit.replacementRange,
            with: edit.replacementString,
            selectedRange: edit.selectedRange
        )
    }

    func markdownTextView(
        _: NSTextView,
        wrapSelectionWith opening: String,
        closing: String
    ) -> Bool {
        wrapSelection(opening: opening, closing: closing)
    }

    func markdownTextViewDraggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    func markdownTextViewPerformDragOperation(
        _ sender: NSDraggingInfo,
        in textView: NSTextView
    ) -> Bool {
        performFileDrop(sender, insertionView: textView)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performFileDrop(sender, insertionView: textView)
    }

    /// A drop of markdown/text files opens them as documents; a dropped image
    /// is inserted as a Markdown image link at the drop point. Opening takes
    /// precedence so dragging a `.md` file never pastes its path into the text.
    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        guard openableFileURLs(from: pasteboard).isEmpty else {
            return .copy
        }

        return imageFileURL(from: pasteboard) == nil ? [] : .copy
    }

    private func performFileDrop(
        _ sender: NSDraggingInfo,
        insertionView: NSTextView
    ) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let openableURLs = openableFileURLs(from: pasteboard)
        guard openableURLs.isEmpty else {
            delegate?.markdownEditorView(self, requestOpenFileURLs: openableURLs)
            return true
        }

        guard let url = imageFileURL(from: pasteboard) else {
            return false
        }

        let point = insertionView.convert(sender.draggingLocation, from: nil)
        insertMarkdownImage(for: url, at: point)
        return true
    }

    func textDidChange(_: Notification) {
        guard !isApplyingStyles, !isSettingTextProgrammatically else {
            return
        }

        updateFocusForSelection()
        delegate?.markdownEditorViewDidChangeText(self)
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength: Int
    ) {
        guard editedMask.contains(.editedCharacters),
              !isApplyingStyles,
              !isSettingTextProgrammatically,
              !isNormalizingEditedText,
              !textView.hasMarkedText(),
              textStorage.length > 0
        else {
            return
        }

        let isLargeEdit = MarkdownStylingEngine.isLargeEdit(
            editedRange: editedRange,
            changeInLength: changeInLength
        )
        MarkdownEditorDiagnostics.log(
            "textStorageEdit range=\(editedRange.location)..\(NSMaxRange(editedRange)) "
                + "rangeLength=\(editedRange.length) change=\(changeInLength) "
                + "textLength=\(textStorage.length) large=\(isLargeEdit)"
        )
        cancelDeferredStyling()

        // Keep span positions valid across the edit so that any restyle
        // running before the next parse result (search updates, appearance or
        // gutter changes, …) applies attributes at the right offsets. Spans
        // overlapping the edit are dropped; the local styling below re-derives
        // the edited line.
        currentStyleSpans = MarkdownStyleRangeDiffer.translatedSpansAfterSourceChange(
            currentStyleSpans,
            editRange: editedRange,
            lengthDelta: changeInLength,
            sourceLength: textStorage.length
        )

        // Keep the drawn code backgrounds glued to (and growing with) the text
        // until the next parse arrives.
        translateCodeBackgroundRangesForEdit(
            editedRange: editedRange,
            changeInLength: changeInLength,
            sourceLength: textStorage.length
        )

        // Keep the active focus paragraph glued to the text the same way:
        // the dimming applied below (and the paragraph-delta restyle on the
        // next selection change) subtract this range, and a stale one would
        // dim part of the paragraph being typed in.
        if let activeRange = activeFocusParagraphRange {
            activeFocusParagraphRange = MarkdownStylingEngine.editAdjustedRange(
                activeRange,
                editLocation: editedRange.location,
                changeInLength: changeInLength,
                editedLength: editedRange.length,
                sourceLength: textStorage.length
            )
        }

        let dirtyRange = MarkdownStylingEngine.editDirtyRange(
            editedRange: editedRange,
            in: textStorage.string as NSString
        )
        guard let range = boundedRange(dirtyRange), range.length > 0 else {
            return
        }

        guard !isLargeEdit else {
            currentStyleSpans = []
            updateCodeBackgroundRanges()
            pendingFullStyleRanges = []
            hasRecentLargeEdit = true
            isNormalizingEditedText = true
            textStorage.setAttributes(baseAttributes(), range: range)
            isNormalizingEditedText = false
            scheduleVisibleLocalStyling()
            return
        }

        isNormalizingEditedText = true
        let localSpans = localStyleSpans(in: range)
        reconcileInlineCodeDrawRanges(in: range, with: localSpans)
        applyStyles(in: range, spans: localSpans)
        isNormalizingEditedText = false
    }

    func textViewDidChangeSelection(_: Notification) {
        guard !isApplyingStyles else {
            return
        }

        textView.typingAttributes = baseAttributes()
        updateFocusForSelection()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureTextView() {
        textView.delegate = self
        textView.commandDelegate = self
        textView.onMouseDown = { [weak self] in
            self?.restoreFocusAfterEditorInteraction()
        }
        textView.onScrollWheel = { [weak self] event in
            self?.temporarilySuppressFocusForUserScroll(event: event)
        }
        textView.registerForDraggedTypes([.fileURL])
        // The editor renders one fixed font; without this, every
        // setTypingAttributes walks the selection for font-panel bookkeeping.
        textView.usesFontPanel = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        // drawsBackground must be true so AppKit invokes drawBackground(in:),
        // where code backgrounds are drawn behind the selection and glyphs.
        // The fill color matches the editor background, so this is visually
        // identical to the scroll view drawing it.
        textView.drawsBackground = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.enabledTextCheckingTypes = 0
        textView.textStorage?.delegate = self
        _ = updateTextContainerInset()
        applyEditorColors()
        textView.font = baseFont
        textView.typingAttributes = baseAttributes()
    }

    private func configureScrollView() {
        let defaultClipView = scrollView.contentView
        clipView.frame = defaultClipView.frame
        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.drawsBackground = defaultClipView.drawsBackground

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.backgroundColor = colors.background
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        // The scroll view's automaticallyAdjustsContentInsets=false is not
        // enough: the flag also lives on each clip view (default true), and
        // on Tahoe NSScrollView's tile pass reads the clip view's copy,
        // stamping its own 16pt glass insets onto the clip view on every
        // layout. That shifts the resting scroll offset to -16 while all
        // scroll math here assumes the zero insets set above — any
        // programmatic scroll to 0 then fights tile's re-assertion forever
        // (the caret animator's display link never converges, and the
        // resulting per-frame scroll events kept hiding the chrome).
        clipView.automaticallyAdjustsContentInsets = false
        scrollView.contentView = clipView
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    private func configureCursorGeometry() {
        textView.topChromeRectProvider = { [weak self] in
            guard let self, let window = self.window else {
                return nil
            }

            return self.topChromeRectInContentView(window: window)
        }
        textView.isWindowPointInTopChrome = { [weak self] point, window in
            self?.windowPointIsInTopChrome(point, window: window) == true
        }
    }

    @discardableResult
    private func applyChromeInsets() -> Bool {
        // Both vertical paddings live inside the text view (top/bottom
        // content padding): scroll-view content insets offset the overlay
        // scroller and make the padded areas unclickable.
        if !edgeInsets(scrollView.contentInsets, equalTo: NSEdgeInsetsZero) {
            scrollView.contentInsets = NSEdgeInsetsZero
        }

        return updateTextContainerInset()
    }

    /// Extra vertical padding while focus/typewriter mode is on, so the caret
    /// line can be scrolled to the viewport center even on the first and last
    /// lines of the document — without it the centering scroll clamps to the
    /// content edges and the caret stays off-center there.
    private var focusOverscrollPadding: CGFloat {
        guard isFocusModeEnabled else {
            return 0
        }

        return max(0, (clipView.bounds.height - lineHeight) / 2)
    }

    private func updateTextContainerInset() -> Bool {
        let availableWidth = scrollView.contentView.bounds.width > 0
            ? scrollView.contentView.bounds.width
            : bounds.width
        let minimumHorizontalInset = characterWidth()
            * Self.minimumHorizontalPaddingCharacters(for: availableWidth)
        let targetWidth = characterWidth() * CGFloat(settings.maxTextColumns)
        let horizontalInset = max(
            minimumHorizontalInset,
            floor((availableWidth - targetWidth) / 2)
        )
        // Sized for the widest heading marker, "###### " — 7 glyphs each
        // advanced by the letter-spacing kern, matching how markerWidth is
        // measured in applyHeadingStyle. Without the kern term the H6 marker
        // overflows the gutter and its text is pushed right.
        let markerGutter = (characterWidth() + baseLetterSpacing) * 7
        let containerInset = max(6, horizontalInset - markerGutter)
        let newParagraphGutter = max(0, horizontalInset - containerInset)
        let didChangeParagraphGutter = newParagraphGutter != paragraphGutter
        // The average of the two paddings on both sides; MarkdownTextView
        // shifts the container origin to make the padding asymmetric while
        // remaining part of the (clickable) text view.
        let topPadding = max(textTopPadding, focusOverscrollPadding)
        let bottomPadding = max(textBottomPadding, focusOverscrollPadding)
        let insetSize = NSSize(
            width: containerInset,
            height: (topPadding + bottomPadding) / 2
        )

        paragraphGutter = newParagraphGutter
        textView.topContentPadding = topPadding
        textView.bottomContentPadding = bottomPadding
        if textView.textContainerInset != insetSize {
            textView.textContainerInset = insetSize
            // NSTextView grows its frame for a larger inset but never shrinks
            // it back on its own; without this the frame keeps the focus-mode
            // overscroll after the mode is switched off, leaving a dead band
            // of empty scroll range at the top of the document.
            textView.sizeToFit()
        }
        // The preview has no marker gutter; its text starts where the
        // editor's paragraph text starts.
        previewHorizontalInset = containerInset + newParagraphGutter
        pushPreviewInsets()
        return didChangeParagraphGutter
    }

    @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else {
            return
        }

        // No cursor-rect invalidation here: AppKit refreshes cursor rects on
        // scroll by itself, and forcing a window-wide recompute on every
        // bounds tick costs scroll frames.

        let offsetY = clipView.bounds.origin.y
        let clipSize = clipView.bounds.size
        defer {
            lastScrollOffsetY = offsetY
            lastScrollClipSize = clipSize
        }
        MarkdownEditorDiagnostics.log(
            "boundsChanged y=\(offsetY) last=\(lastScrollOffsetY.map(String.init(describing:)) ?? "nil") "
                + "height=\(textView.frame.height) visible=\(textView.visibleRect) "
                + "isApplying=\(isApplyingStyles)"
        )
        // Bounds changes produced by our own centering animation must not
        // count as user scrolling (they would hide the chrome and suppress
        // focus mode).
        guard !isAdjustingFocusScroll else {
            return
        }

        // While focus dimming is suppressed for a user scroll, newly revealed
        // content may still carry dimming on long documents — the undim pass
        // at suppression start runs chunked in the background there. Restyle
        // just the viewport; short documents were already fully restyled
        // synchronously when the suppression began.
        if isFocusModeEnabled, isFocusTemporarilySuppressed, focusMode == .focus,
           let textStorage = textView.textStorage,
           textStorage.length > Self.immediateStyleThreshold
        {
            applyVisibleStyles(spans: currentStyleSpans)
        }

        // A user scroll moves only the bounds origin; window resizes (zoom,
        // live resize) change the clip size and shift the origin as a side
        // effect. Those shifts must not read as scrolling — they would hide
        // the chrome the user just revealed by resizing.
        guard let lastScrollOffsetY,
              let lastScrollClipSize,
              clipSize == lastScrollClipSize,
              abs(offsetY - lastScrollOffsetY) > 0.5
        else {
            return
        }

        delegate?.markdownEditorViewDidScroll(self)
    }

    private func updateCodeBackgroundRanges() {
        codeInlineDrawRanges = currentStyleSpans
            .filter { $0.kind == .inlineCode }
            .map(\.range)
        codeBlockDrawRanges = currentStyleSpans
            .filter { $0.kind == .codeBlock }
            .map(\.range)
        pushCodeBackgroundRanges()
    }

    private func pushCodeBackgroundRanges() {
        textView.setCodeBackgroundRanges(
            inline: codeInlineDrawRanges,
            block: codeBlockDrawRanges,
            gutter: paragraphGutter,
            fillColor: colors.codeBackground
        )
    }

    /// Shift/grow the drawn code ranges across an edit, so a code background
    /// stays put — and expands with the text — while typing inside it, instead
    /// of vanishing until the next parse arrives. Pending full-style chunks are
    /// shifted the same way so an interrupted full pass resumes at the right
    /// offsets.
    private func translateCodeBackgroundRangesForEdit(
        editedRange: NSRange,
        changeInLength: Int,
        sourceLength: Int
    ) {
        func adjusted(_ range: NSRange) -> NSRange? {
            MarkdownStylingEngine.editAdjustedRange(
                range,
                editLocation: editedRange.location,
                changeInLength: changeInLength,
                editedLength: editedRange.length,
                sourceLength: sourceLength
            )
        }

        codeInlineDrawRanges = codeInlineDrawRanges.compactMap(adjusted)
        codeBlockDrawRanges = codeBlockDrawRanges.compactMap(adjusted)
        pendingFullStyleRanges = pendingFullStyleRanges.compactMap(adjusted)
        pushCodeBackgroundRanges()
    }

    /// The edit translation above is geometric and, at a span boundary,
    /// cannot tell whether inserted text belongs to the code — Enter right
    /// after a closing backtick would stretch the drawn balloon over the new
    /// line for a frame. The local scanner re-derives the truth for the
    /// restyled lines within the same editing pass, so the drawn inline
    /// ranges there must come from it. Block ranges stay translated: they
    /// cannot be derived locally (see localStyleSpans) and growing across
    /// lines is correct for them.
    private func reconcileInlineCodeDrawRanges(
        in targetRange: NSRange,
        with localSpans: [ResolvedMarkdownStyleSpan]
    ) {
        guard let targetRange = boundedRange(targetRange) else {
            return
        }

        let string = textView.string as NSString
        let scannedLines = string.lineRange(for: targetRange)
        let derivedRanges = localSpans
            .filter { $0.kind == .inlineCode }
            .map(\.range)
        let keptRanges = codeInlineDrawRanges.filter {
            NSIntersectionRange($0, scannedLines).length == 0
        }
        codeInlineDrawRanges = (keptRanges + derivedRanges).sorted {
            ($0.location, $0.length) < ($1.location, $1.length)
        }
        pushCodeBackgroundRanges()
    }

    private func restyleAllText() {
        // Push (don't recompute) the drawn code ranges: between an edit and
        // the next parse the draw ranges carry a boundary expansion that the
        // translated spans intentionally drop. Recomputation happens where
        // fresh spans arrive (applyParsedStyles).
        pushCodeBackgroundRanges()
        guard let textStorage = textView.textStorage,
              textStorage.length > 0,
              !textView.hasMarkedText()
        else {
            textView.font = baseFont
            textView.typingAttributes = baseAttributes()
            return
        }

        guard textStorage.length <= Self.immediateStyleThreshold else {
            scheduleDeferredDocumentStyling(spans: currentStyleSpans)
            return
        }

        cancelDeferredStyling()
        pendingFullStyleRanges = []
        applyStyles(
            in: NSRange(location: 0, length: textStorage.length),
            spans: currentStyleSpans
        )
    }

    private func cancelDeferredStyling() {
        deferredStyleTask?.cancel()
        deferredStyleTask = nil
        styleGeneration += 1
    }

    private func scheduleDeferredDocumentStyling(spans: [ResolvedMarkdownStyleSpan]) {
        guard let textStorage = textView.textStorage,
              textStorage.length > 0,
              !textView.hasMarkedText()
        else {
            return
        }

        cancelDeferredStyling()
        MarkdownEditorDiagnostics.log(
            "scheduleDeferredDocumentStyling length=\(textStorage.length) "
                + "spans=\(spans.count)"
        )
        applyVisibleStyles(spans: spans)
        pendingFullStyleRanges = MarkdownStylingEngine.chunkedStyleRanges(
            in: textStorage.string as NSString,
            excluding: visibleBufferedCharacterRange()
        )
        startDeferredChunkStyling(spans: spans)
    }

    /// Continues an interrupted full styling pass. The chunked pass gets
    /// cancelled by edits; the remaining chunks (translated across those edits)
    /// are picked up again once the next parse result has been applied.
    private func resumeFullStylingIfNeeded(spans: [ResolvedMarkdownStyleSpan]) {
        guard !pendingFullStyleRanges.isEmpty, deferredStyleTask == nil else {
            return
        }

        MarkdownEditorDiagnostics.log(
            "resumeFullStyling remaining=\(pendingFullStyleRanges.count)"
        )
        startDeferredChunkStyling(spans: spans)
    }

    private func startDeferredChunkStyling(spans: [ResolvedMarkdownStyleSpan]) {
        guard !pendingFullStyleRanges.isEmpty else {
            return
        }

        guard !MarkdownEditorDiagnostics.disableBackgroundChunkStyling else {
            MarkdownEditorDiagnostics.log("background chunk styling skipped")
            pendingFullStyleRanges = []
            return
        }

        let generation = styleGeneration
        let sourceLength = textView.textStorage?.length ?? 0
        deferredStyleTask = Task { @MainActor [weak self, spans] in
            // Wait for a typing pause before doing background chunk work.
            // Each keystroke cancels this task, so during an active typing
            // burst no chunk ever competes with input handling — that
            // competition showed up as 20–70 ms input lag right after opening
            // a large document.
            do {
                try await Task.sleep(
                    for: .milliseconds(Self.backgroundStyleIdleDelayMilliseconds)
                )
            } catch {
                return
            }

            guard let self else {
                return
            }

            while !pendingFullStyleRanges.isEmpty {
                guard !Task.isCancelled,
                      generation == styleGeneration,
                      sourceLength == textView.textStorage?.length
                else {
                    return
                }

                let chunk = pendingFullStyleRanges.removeFirst()
                let string = (textView.textStorage?.string ?? "") as NSString
                guard let range = boundedRange(
                    MarkdownStylingEngine.lineNormalized(chunk, in: string)
                ), range.length > 0 else {
                    continue
                }

                MarkdownEditorDiagnostics.log(
                    "background chunk apply range=\(range.location)..\(NSMaxRange(range))"
                )
                applyStyles(
                    in: range,
                    spans: MarkdownStylingEngine.spansForRange(range, from: spans)
                )
                await Task.yield()
            }

            deferredStyleTask = nil
        }
    }

    private func scheduleVisibleLocalStyling() {
        guard let textStorage = textView.textStorage,
              textStorage.length > 0
        else {
            return
        }

        let generation = styleGeneration
        let sourceLength = textStorage.length
        MarkdownEditorDiagnostics
            .log("scheduleVisibleLocalStyling length=\(sourceLength)")
        deferredStyleTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  generation == styleGeneration,
                  sourceLength == textView.textStorage?.length,
                  let range = visibleBufferedCharacterRange()
            else {
                return
            }

            guard !MarkdownEditorDiagnostics.disableVisibleLocalStylingAfterPaste else {
                MarkdownEditorDiagnostics.log("visible local styling skipped by flag")
                return
            }

            MarkdownEditorDiagnostics.log(
                "visible local styling range=\(range.location)..\(NSMaxRange(range))"
            )
            applyStyles(in: range, spans: localStyleSpans(in: range))
        }
    }

    private func applyVisibleStyles(
        spans: [ResolvedMarkdownStyleSpan],
        leadingBuffer: Int = MarkdownEditorView.visibleStyleBuffer,
        trailingBuffer: Int = MarkdownEditorView.visibleStyleBuffer
    ) {
        guard let range = visibleBufferedCharacterRange(
            leadingBuffer: leadingBuffer,
            trailingBuffer: trailingBuffer
        ) else {
            return
        }

        applyStyles(
            in: range,
            spans: MarkdownStylingEngine.spansForRange(range, from: spans)
        )
    }

    private func visibleBufferedCharacterRange(
        leadingBuffer: Int = MarkdownEditorView.visibleStyleBuffer,
        trailingBuffer: Int = MarkdownEditorView.visibleStyleBuffer
    ) -> NSRange? {
        guard let textStorage = textView.textStorage,
              textStorage.length > 0
        else {
            return nil
        }

        let visibleRect = textView.visibleRect
        guard visibleRect.height > 0 else {
            let length = min(textStorage.length, Self.immediateStyleThreshold)
            return (textStorage.string as NSString).lineRange(
                for: NSRange(location: 0, length: length)
            )
        }

        let x = textView.textContainerInset.width + paragraphGutter + 1
        let start = textView.characterIndexForInsertion(at: NSPoint(
            x: x,
            y: max(0, visibleRect.minY)
        ))
        let end = textView.characterIndexForInsertion(at: NSPoint(
            x: x,
            y: max(visibleRect.minY + lineHeight, visibleRect.maxY)
        ))
        let lowerBound = max(0, min(start, end) - leadingBuffer)
        let upperBound = min(
            textStorage.length,
            max(start, end) + trailingBuffer
        )
        guard upperBound > lowerBound else {
            return nil
        }

        return (textStorage.string as NSString).lineRange(
            for: NSRange(location: lowerBound, length: upperBound - lowerBound)
        )
    }

    private func applyStyles(
        in targetRange: NSRange,
        spans: [ResolvedMarkdownStyleSpan]
    ) {
        guard let textStorage = textView.textStorage,
              let targetRange = boundedRange(targetRange)
        else {
            return
        }

        isApplyingStyles = true
        textView.undoManager?.disableUndoRegistration()
        let startTime = Date().timeIntervalSince1970
        let heightBefore = textView.frame.height
        let clipYBefore = clipView.bounds.origin.y
        textStorage.beginEditing()
        textStorage.setAttributes(baseAttributes(), range: targetRange)

        for span in spans {
            let range = NSIntersectionRange(span.range, targetRange)
            guard range.length > 0 else {
                continue
            }

            applyStyle(span.kind, range: range)
        }

        applyNonbreakingSpaceStyle(range: targetRange)
        applySearchHighlights(intersecting: [targetRange])
        applyFocusDimming(in: targetRange)

        textStorage.endEditing()
        textView.undoManager?.enableUndoRegistration()
        // Not while normalizing a just-processed edit: setTypingAttributes
        // triggers AppKit's font-panel update, which enumerates attributes
        // over the not-yet-updated selection. When typing replaced a selection
        // with shorter text, that stale range lies beyond the new length — the
        // NSRangeException unwinds through processEditing and permanently
        // wedges the text view (dead input, IMK mach port errors). The
        // selection-change hook restores typing attributes right after.
        if !isNormalizingEditedText {
            textView.typingAttributes = baseAttributes()
        }
        isApplyingStyles = false
        let duration = Self.milliseconds(since: startTime)
        let rangeDescription = "\(targetRange.location)..\(NSMaxRange(targetRange))"
        let heightDescription = "\(heightBefore)->\(textView.frame.height)"
        let clipDescription = "\(clipYBefore)->\(clipView.bounds.origin.y)"
        MarkdownEditorDiagnostics.log(
            "applyStyles range=\(rangeDescription) length=\(targetRange.length) "
                + "spans=\(spans.count) durationMs=\(duration) "
                + "height \(heightDescription) clipY \(clipDescription)"
        )
    }

    private func localStyleSpans(in range: NSRange) -> [ResolvedMarkdownStyleSpan] {
        let source = textView.string
        var spans: [ResolvedMarkdownStyleSpan] = []
        let string = source as NSString
        var lineStart = range.location
        let upperBound = min(NSMaxRange(range), string.length)
        let frontmatterRange = MarkdownFrontmatter.range(in: string)

        while lineStart < upperBound {
            let lineRange = string.lineRange(for: NSRange(location: lineStart, length: 0))
            defer { lineStart = max(NSMaxRange(lineRange), lineStart + 1) }

            // Frontmatter is re-scanned per call (cheap: O(1) unless the
            // document opens with "---") rather than cached like code blocks,
            // so typing the delimiter lines opens/closes the block with no
            // staleness. Suppresses the analyzer's thematic-break match on
            // "---" and all markdown styling inside the block.
            if let frontmatterRange,
               NSIntersectionRange(frontmatterRange, lineRange).length > 0
            {
                spans.append(ResolvedMarkdownStyleSpan(
                    range: frontmatterRange,
                    kind: .frontmatter
                ))
                continue
            }

            // Inside a known (parser-derived) code block: style as code and
            // skip the inline scanner. Markdown-looking tokens inside code
            // must stay plain — styling them locally and letting the parse
            // strip them a few ms later reads as flicker. This also avoids
            // the analyzer's whole-document fence scan, which is far too slow
            // to run on every keystroke in a large document.
            if let block = codeBlockDrawRanges.first(where: {
                NSIntersectionRange($0, lineRange).length > 0
            }) {
                spans.append(ResolvedMarkdownStyleSpan(range: block, kind: .codeBlock))
                continue
            }

            if let blockSpan = MarkdownBlockPrefixAnalyzer.prefixBlockSpan(
                for: lineRange,
                source: source
            ) {
                spans.append(blockSpan)
            }
            spans.append(contentsOf: MarkdownInlineStyleScanner.inlineSpans(
                in: lineRange,
                source: source
            ))
        }

        // Resolve link/image spans into punctuation/destination sub-spans the
        // same way the parse pipeline does, so the locally styled line looks
        // identical to the parsed one and nothing repaints when the parse
        // arrives.
        return MarkdownLinkStyleResolver.resolve(spans: spans, in: source)
    }

    private func applyStyle(_ kind: MarkdownStyleKind, range: NSRange) {
        guard let textStorage = textView.textStorage,
              let range = boundedRange(range),
              range.length > 0
        else {
            return
        }

        switch kind {
        case .heading:
            applyHeadingStyle(range: range)
        case .strong:
            addFontTraits(.boldFontMask, range: range)
        case .emphasis:
            addFontTraits(.italicFontMask, range: range)
        case .strikethrough:
            // Drawn by MarkdownLayoutManager centered on the x-height.
            textStorage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        case .inlineCode, .codeBlock:
            // Code backgrounds are drawn as rounded decorations in
            // MarkdownTextView (see updateCodeBackgroundRanges); the plain
            // .backgroundColor attribute is intentionally not applied here.
            textStorage.addAttributes([
                .font: baseFont,
                .foregroundColor: colors.foreground,
            ], range: range)
        case .linkDestination:
            textStorage.addAttributes([
                .foregroundColor: colors.punctuation,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: colors.underline,
            ], range: range)
        case .linkSyntaxPunctuation:
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.punctuation,
                range: range
            )
        case .link, .image:
            break
        case .blockQuote:
            applyLineMarkerStyle(
                Self.blockQuoteMarkerRegex,
                range: range,
                markerCaptureGroup: 1
            )
        case .orderedList, .unorderedList:
            applyLineMarkerStyle(Self.listMarkerRegex, range: range)
        case .thematicBreak:
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.thematicBreak,
                range: range
            )
        case .frontmatter:
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.frontmatter,
                range: range
            )
        }
    }

    private static let headingMarkerRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(#{1,6}[ \t]+)"#,
        options: [.anchorsMatchLines]
    )
    private static let blockQuoteMarkerRegex = try! NSRegularExpression(
        pattern: "^\\s*(>)",
        options: [.anchorsMatchLines]
    )
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: "^\\s*(?:[-+*]|\\d+[.)])\\s+",
        options: [.anchorsMatchLines]
    )
    private func applyHeadingStyle(range: NSRange) {
        guard let textStorage = textView.textStorage else {
            return
        }

        let source = textStorage.string
        let headingSearchRange = (source as NSString).lineRange(for: range)
        Self.headingMarkerRegex
            .enumerateMatches(
                in: source,
                range: headingSearchRange
            ) { [self] match, _, _ in
                guard let match,
                      match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound
                else {
                    return
                }

                let lineRange = (source as NSString).lineRange(for: match.range)
                guard let lineRange = boundedRange(lineRange) else {
                    return
                }

                addFontTraits(.boldFontMask, range: lineRange)

                let markerRange = match.range(at: 1)
                let marker = (source as NSString).substring(with: markerRange)
                let markerWidth = headingMarkerWidth(marker)
                let paragraphStyle = baseParagraphStyle()
                if !MarkdownEditorDiagnostics.disableHeadingOutdent,
                   !MarkdownEditorDiagnostics.disableParagraphStyle
                {
                    paragraphStyle.firstLineHeadIndent = paragraphGutter - markerWidth
                    paragraphStyle.headIndent = paragraphGutter
                    // The whole line including the trailing newline: TextKit
                    // conforms paragraph styles to paragraph boundaries, so a
                    // partial-line style would be re-expanded nondeterministically.
                    // The caret on the FOLLOWING empty line is protected by the
                    // extended restyle range in didProcessEditing instead.
                    textStorage.addAttribute(
                        .paragraphStyle,
                        value: paragraphStyle,
                        range: lineRange
                    )
                }
            }
    }

    private var headingMarkerWidthCache: [String: CGFloat] = [:]
    private var headingMarkerWidthCachePointSize: CGFloat = 0

    private func headingMarkerWidth(_ marker: String) -> CGFloat {
        if headingMarkerWidthCachePointSize != basePointSize {
            headingMarkerWidthCache.removeAll(keepingCapacity: true)
            headingMarkerWidthCachePointSize = basePointSize
        }

        if let cached = headingMarkerWidthCache[marker] {
            return cached
        }

        let width = (marker as NSString).size(withAttributes: [
            .font: boldFont,
            .kern: baseLetterSpacing,
        ]).width
        headingMarkerWidthCache[marker] = width
        return width
    }

    private func addFontTraits(_ traits: NSFontTraitMask, range: NSRange) {
        guard let textStorage = textView.textStorage else {
            return
        }

        guard !MarkdownEditorDiagnostics.disableFontTraits else {
            MarkdownEditorDiagnostics.log(
                "font traits skipped range=\(range.location)..\(NSMaxRange(range))"
            )
            return
        }

        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let currentFont = value as? NSFont ?? baseFont
            let existingTraits = NSFontManager.shared.traits(of: currentFont)
            textStorage.addAttribute(
                .font,
                value: LilexFontProvider.font(
                    size: currentFont.pointSize,
                    traits: existingTraits.union(traits)
                ),
                range: subrange
            )
        }
    }

    private func applyLineMarkerStyle(
        _ expression: NSRegularExpression,
        range: NSRange,
        markerCaptureGroup: Int? = nil
    ) {
        guard let textStorage = textView.textStorage else {
            return
        }

        let source = textStorage.string
        expression.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match else {
                return
            }

            let markerRange: NSRange
            if let markerCaptureGroup {
                guard markerCaptureGroup < match.numberOfRanges else {
                    return
                }
                markerRange = match.range(at: markerCaptureGroup)
            } else {
                markerRange = match.range
            }

            guard markerRange.location != NSNotFound,
                  NSMaxRange(markerRange) <= (source as NSString).length
            else {
                return
            }

            textStorage.addAttribute(
                .foregroundColor,
                value: colors.listMarker,
                range: markerRange
            )
        }
    }

    private func applyNonbreakingSpaceStyle(range: NSRange) {
        guard let textStorage = textView.textStorage,
              let range = boundedRange(range),
              range.length > 0
        else {
            return
        }

        let string = textStorage.string as NSString
        var searchRange = range
        let upperBound = NSMaxRange(range)
        while searchRange.length > 0 {
            let foundRange = string.range(of: "\u{00A0}", options: [], range: searchRange)
            guard foundRange.location != NSNotFound else {
                return
            }

            textStorage.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: colors.underline,
            ], range: foundRange)

            let nextLocation = NSMaxRange(foundRange)
            searchRange = NSRange(
                location: nextLocation,
                length: upperBound - nextLocation
            )
        }
    }

    private func applySearchHighlights(intersecting ranges: [NSRange]) {
        guard let textStorage = textView.textStorage,
              !searchMatchRanges.isEmpty
        else {
            return
        }

        for (index, matchRange) in searchMatchRanges.enumerated() {
            for range in ranges {
                let intersection = NSIntersectionRange(matchRange, range)
                guard intersection.length > 0,
                      boundedRange(intersection) != nil
                else {
                    continue
                }

                if !MarkdownEditorDiagnostics.disableBackgroundColor {
                    textStorage.addAttribute(
                        .backgroundColor,
                        value: searchHighlightColor(isSelected: index ==
                            selectedSearchMatchIndex),
                        range: intersection
                    )
                }
            }
        }
    }

    private func applyFocusDimming(in range: NSRange) {
        guard let textStorage = textView.textStorage,
              isFocusModeEnabled,
              !isFocusTemporarilySuppressed,
              focusMode == .focus,
              let activeRange = activeFocusParagraphRange
        else {
            return
        }

        for dimmedRange in MarkdownStylingEngine.subtract(activeRange, from: range) {
            guard dimmedRange.length > 0 else {
                continue
            }

            textStorage.addAttribute(
                .foregroundColor,
                value: colors.foreground
                    .withAlphaComponent(colors.foreground.alphaComponent * 0.5),
                range: dimmedRange
            )
        }
    }

    private func searchHighlightColor(isSelected: Bool) -> NSColor {
        let match = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if isSelected {
            return match == .darkAqua
                ? NSColor.systemOrange.withAlphaComponent(0.52)
                : NSColor.systemOrange.withAlphaComponent(0.38)
        }

        return match == .darkAqua
            ? NSColor.systemYellow.withAlphaComponent(0.34)
            : NSColor.systemYellow.withAlphaComponent(0.28)
    }

    private func replaceSelectedText(with string: String) {
        replaceText(in: textView.selectedRange(), with: string, selectedRange: NSRange(
            location: textView.selectedRange().location + (string as NSString).length,
            length: 0
        ))
    }

    @discardableResult
    private func replaceText(
        in range: NSRange,
        with string: String,
        selectedRange: NSRange
    ) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: string) else {
            return false
        }

        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        textView.setSelectedRange(selectedRange)
        return true
    }

    @discardableResult
    private func wrapSelection(opening: String, closing: String) -> Bool {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else {
            return false
        }

        let selectedText = (textView.string as NSString).substring(with: selectedRange)
        let replacement = opening + selectedText + closing
        let openingLength = (opening as NSString).length
        return replaceText(
            in: selectedRange,
            with: replacement,
            selectedRange: NSRange(
                location: selectedRange.location + openingLength,
                length: (selectedText as NSString).length
            )
        )
    }

    private func pasteboardURLString() -> String? {
        let pasteboard = NSPasteboard.general
        if let url = NSURL(from: pasteboard) as URL? {
            return url.absoluteString
        }

        guard let string = pasteboard.string(forType: .string)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
            let url = URL(string: string),
            url.scheme != nil
        else {
            return nil
        }

        return url.absoluteString
    }

    /// File URLs on the pasteboard that the editor can open as documents:
    /// Markdown and plain-text files (Markdown conforms to `public.plain-text`).
    private func openableFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL]
        else {
            return []
        }

        return urls.filter { url in
            guard url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension)
            else {
                return false
            }

            return type.conforms(to: .plainText)
        }
    }

    private func imageFileURL(from pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL]
        else {
            return nil
        }

        return urls.first { url in
            guard url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension)
            else {
                return false
            }

            return type.conforms(to: .image)
        }
    }

    private func insertMarkdownImage(for url: URL, at point: NSPoint) {
        let characterIndex = textView.characterIndexForInsertion(at: point)
        textView.setSelectedRange(NSRange(location: characterIndex, length: 0))

        let path = markdownRelativePath(for: url)
        let name = url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? "image"
        replaceSelectedText(with: "![\(escapeLinkText(name))](\(path))")
    }

    private func markdownRelativePath(for url: URL) -> String {
        guard let documentURL else {
            return url.lastPathComponent
        }

        return relativePath(from: documentURL.deletingLastPathComponent(), to: url)
    }

    private func relativePath(from baseDirectory: URL, to targetURL: URL) -> String {
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        var sharedPrefixCount = 0

        while sharedPrefixCount < baseComponents.count,
              sharedPrefixCount < targetComponents.count,
              baseComponents[sharedPrefixCount] == targetComponents[sharedPrefixCount]
        {
            sharedPrefixCount += 1
        }

        guard sharedPrefixCount > 0 else {
            return targetURL.lastPathComponent
        }

        let upComponents = Array(
            repeating: "..",
            count: baseComponents.count - sharedPrefixCount
        )
        let downComponents = targetComponents.dropFirst(sharedPrefixCount)
        return (upComponents + downComponents).joined(separator: "/")
    }

    private func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "]", with: "\\]")
    }

    private func applyEditorColors() {
        scrollView.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        textView.insertionPointColor = colors.caret
        textView.selectedTextAttributes = [.backgroundColor: colors.selection]
    }

    private var baseFont: NSFont {
        LilexFontProvider.regular(size: basePointSize)
    }

    private var boldFont: NSFont {
        LilexFontProvider.bold(size: basePointSize)
    }

    private var basePointSize: CGFloat {
        settings.basePointSize * windowWidthFontScale
    }

    private var baseLetterSpacing: CGFloat {
        basePointSize * 0.0305
    }

    private var lineHeight: CGFloat {
        basePointSize * 1.8
    }

    private var colors: EditorThemeColors.Variant {
        themeColors.variant(for: effectiveAppearance)
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: colors.foreground,
        ]
        if !MarkdownEditorDiagnostics.disableKern {
            attributes[.kern] = baseLetterSpacing
        }
        if !MarkdownEditorDiagnostics.disableParagraphStyle {
            attributes[.paragraphStyle] = baseParagraphStyle()
        }
        return attributes
    }

    private func baseParagraphStyle() -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.firstLineHeadIndent = paragraphGutter
        paragraphStyle.headIndent = paragraphGutter
        paragraphStyle.tailIndent = -paragraphGutter
        return paragraphStyle
    }

    private func characterWidth() -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: baseFont]).width
        return width > 0 ? width : basePointSize * 0.6
    }

    private static func windowWidthFontScale(for windowWidth: CGFloat) -> CGFloat {
        if windowWidth > 1250 {
            return 1.2
        }

        if windowWidth < 440 {
            return 0.9
        }

        return 1
    }

    private static func minimumHorizontalPaddingCharacters(for width: CGFloat)
        -> CGFloat
    {
        if width > 980 {
            return 6
        }

        if width > 770 {
            return 5
        }

        if width > 510 {
            return 4
        }

        if width > 440 {
            return 3
        }

        return 2
    }

    private static func milliseconds(since startTime: TimeInterval) -> String {
        String(format: "%.2f", (Date().timeIntervalSince1970 - startTime) * 1000)
    }

    private func boundedRange(_ range: NSRange) -> NSRange? {
        guard let textStorage = textView.textStorage,
              range.location >= 0,
              range.length >= 0,
              range.location <= textStorage.length,
              NSMaxRange(range) <= textStorage.length
        else {
            return nil
        }

        return range
    }

    private func edgeInsets(_ lhs: NSEdgeInsets, equalTo rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }

    private func setScrollerTopInset(_ top: CGFloat) {
        let scrollerInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        guard !edgeInsets(scrollView.scrollerInsets, equalTo: scrollerInsets) else {
            return
        }

        scrollView.scrollerInsets = scrollerInsets
    }

    private func invalidateEditorCursorRects() {
        window?.invalidateCursorRects(for: textView)
    }

    private func topChromeRectInContentView(window: NSWindow) -> NSRect? {
        TopChromeGeometry.revealRectInContentView(
            window: window,
            revealHeight: protectedTopPadding
        )
    }

    private func windowPointIsInTopChrome(
        _ pointInWindow: NSPoint,
        window: NSWindow
    ) -> Bool {
        guard let contentView = window.contentView,
              let chromeRect = topChromeRectInContentView(window: window)
        else {
            return false
        }

        let pointInContentView = contentView.convert(pointInWindow, from: nil)
        return chromeRect.contains(pointInContentView)
    }

    private func activeParagraphRangeAtSelection() -> NSRange? {
        guard let textStorage = textView.textStorage,
              textStorage.length > 0
        else {
            return nil
        }

        let string = textStorage.string as NSString
        let location = min(textView.selectedRange().location, string.length)
        return string.paragraphRange(for: NSRange(location: location, length: 0))
    }

    private func updateFocusForSelection() {
        guard isFocusModeEnabled else {
            return
        }

        let previousRange = activeFocusParagraphRange
        activeFocusParagraphRange = activeParagraphRangeAtSelection()
        // Dimming only differs in the paragraph that lost the caret and the
        // one that gained it; everything else keeps its state. Restyling the
        // whole document here would rewrite all attributes on every Enter
        // press and cross-paragraph caret move.
        if focusMode == .focus,
           !isFocusTemporarilySuppressed,
           previousRange?.location != activeFocusParagraphRange?.location
        {
            restyleFocusDelta(from: previousRange, to: activeFocusParagraphRange)
        }

        if !isFocusTemporarilySuppressed {
            centerCaretLineInVisibleArea(animated: true)
        }
    }

    private func restyleFocusDelta(
        from previousRange: NSRange?,
        to activeRange: NSRange?
    ) {
        var deltaRanges: [NSRange] = []
        if let previousRange {
            deltaRanges.append(previousRange)
        }
        if let activeRange, activeRange != previousRange {
            deltaRanges.append(activeRange)
        }

        let string = (textView.textStorage?.string ?? "") as NSString
        for deltaRange in deltaRanges {
            guard let range = boundedRange(
                MarkdownStylingEngine.lineNormalized(deltaRange, in: string)
            ), range.length > 0 else {
                continue
            }

            applyStyles(
                in: range,
                spans: MarkdownStylingEngine.spansForRange(
                    range,
                    from: currentStyleSpans
                )
            )
        }
    }

    /// Keeps the caret line vertically centered in focus/typewriter mode.
    /// Animated so that line transitions (Enter, arrow keys) glide instead of
    /// jumping. Driven by the same retargetable display-link animator as
    /// keyboard caret scrolling — the system animated scroll stacks a new
    /// animation per key repeat and the overlap visibly bounces.
    private func centerCaretLineInVisibleArea(animated: Bool) {
        // Centering takes over from any in-flight keyboard caret scroll.
        textView.cancelKeyboardCaretScroll()
        guard let lineRect = caretLineRectAtSelection() else {
            return
        }

        let clipHeight = clipView.bounds.height
        guard clipHeight > 0 else {
            return
        }

        let insets = scrollView.contentInsets
        let lineMidY = textView.textContainerOrigin.y + lineRect.midY
        let minimumOffsetY = -insets.top
        let maximumOffsetY = max(
            minimumOffsetY,
            textView.frame.height - clipHeight + insets.bottom
        )
        let targetOffsetY = min(
            max(minimumOffsetY, lineMidY - clipHeight / 2),
            maximumOffsetY
        )
        let currentOffsetY = focusScrollAnimator.isAnimating
            ? focusScrollAnimator.targetOffsetY
            : clipView.bounds.origin.y
        guard abs(currentOffsetY - targetOffsetY) > 0.5 else {
            return
        }

        guard animated else {
            focusScrollAnimator.cancel()
            focusScrollAdjustmentCount += 1
            clipView.setBoundsOrigin(
                NSPoint(x: clipView.bounds.origin.x, y: targetOffsetY)
            )
            scrollView.reflectScrolledClipView(clipView)
            focusScrollAdjustmentCount -= 1
            return
        }

        focusScrollAnimator.scroll(scrollView, toOffsetY: targetOffsetY)
    }

    private func caretLineRectAtSelection() -> NSRect? {
        guard let textStorage = textView.textStorage else {
            return nil
        }

        editorLayoutManager.ensureLayout(for: textContainer)

        guard textStorage.length > 0 else {
            return emptyCaretLineRect()
        }

        let location = min(textView.selectedRange().location, textStorage.length)
        if location == textStorage.length,
           editorLayoutManager.extraLineFragmentTextContainer === textContainer
        {
            return editorLayoutManager.extraLineFragmentRect
        }

        let characterIndex = min(location, textStorage.length - 1)
        let glyphIndex = editorLayoutManager.glyphIndexForCharacter(at: characterIndex)
        guard glyphIndex < editorLayoutManager.numberOfGlyphs else {
            return emptyCaretLineRect()
        }

        return editorLayoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil,
            withoutAdditionalLayout: true
        )
    }

    private func emptyCaretLineRect() -> NSRect {
        let extraLineRect = editorLayoutManager.extraLineFragmentRect
        guard extraLineRect.height > 0 else {
            return NSRect(
                x: 0,
                y: 0,
                width: textContainer.size.width,
                height: lineHeight
            )
        }

        return extraLineRect
    }

    private func restoreFocusAfterEditorInteraction() {
        guard isFocusModeEnabled else {
            return
        }

        guard isFocusTemporarilySuppressed else {
            updateFocusForSelection()
            return
        }

        isFocusTemporarilySuppressed = false
        activeFocusParagraphRange = activeParagraphRangeAtSelection()
        updateCaretScrollOwnership()
        // Lifting the scroll suppression must re-dim the whole document —
        // the paragraph-delta restyle in updateFocusForSelection cannot know
        // how much of it the suppression undimmed.
        if focusMode == .focus {
            restyleAllText()
        }
        centerCaretLineInVisibleArea(animated: true)
    }

    private func temporarilySuppressFocusForUserScroll(event: NSEvent) {
        MarkdownEditorDiagnostics.log(
            "scrollWheel deltaY=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) "
                + "phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) "
                + "clipY=\(clipView.bounds.origin.y) height=\(textView.frame.height)"
        )

        guard isFocusModeEnabled, !isFocusTemporarilySuppressed else {
            return
        }

        // The manual scroll takes over from an in-flight centering glide.
        focusScrollAnimator.cancel()
        isFocusTemporarilySuppressed = true
        updateCaretScrollOwnership()
        // Only focus mode dims text; typewriter mode has nothing to undim.
        if focusMode == .focus {
            restyleAllText()
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
