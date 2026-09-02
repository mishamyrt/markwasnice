@preconcurrency import AppKit

/// One character edit in UTF-16 coordinates. `replacedRange` addresses the
/// text before this edit; edits in one callback batch are applied in order.
struct MarkdownTextEdit: Equatable {
    let replacedRange: NSRange
    let replacement: String
}

protocol MarkdownEditorViewDelegate: AnyObject {
    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView)
    /// A confirmed editor text change. The generation is strictly increasing
    /// for the lifetime of the view, so consumers can trust the notification
    /// without comparing two full-document String snapshots.
    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        didChangeTextAt generation: Int
    )
    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        didChangeTextBy edits: [MarkdownTextEdit],
        at generation: Int
    )
    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        didChangeSelectionText selectedText: String?
    )
    func markdownEditorViewDidScroll(_ editorView: MarkdownEditorView)
    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        didChangeScrolledFromTop isScrolled: Bool
    )
    func markdownEditorViewShowSearch(_ editorView: MarkdownEditorView)
    func markdownEditorViewRequestInsertTable(_ editorView: MarkdownEditorView)
    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        requestOpenFileURLs urls: [URL]
    )
}

extension MarkdownEditorViewDelegate {
    /// Compatibility bridge for delegates that have not adopted generations.
    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        didChangeTextAt _: Int
    ) {
        markdownEditorViewDidChangeText(editorView)
    }

    /// Compatibility bridge for delegates that do not need edit deltas.
    /// MarkdownEditorView calls only this most specific entry point.
    func markdownEditorView(
        _ editorView: MarkdownEditorView,
        didChangeTextBy _: [MarkdownTextEdit],
        at generation: Int
    ) {
        markdownEditorView(editorView, didChangeTextAt: generation)
    }
}

/// Environment-driven kill switches for the styling pipeline, used to bisect
/// a misbehaving document down to the attribute that causes it. Shared with
/// MarkdownStyleApplier, which owns the attribute application the last four
/// flags disable.
enum MarkdownEditorDiagnostics {
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
    /// Base for relativizing dropped image paths; the file-drop controller
    /// is the consumer, so the value lives there.
    var documentURL: URL? {
        get { fileDropController.documentURL }
        set { fileDropController.documentURL = newValue }
    }

    /// Fired when the preview asks to leave (Escape); the owning session
    /// flips the shell state, which calls back into setPreviewActive(false).
    var onPreviewExitRequested: (() -> Void)?

    private let scrollView = OverlayScrollView()
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
    private var textTopPadding: CGFloat = 0
    private var textBottomPadding: CGFloat = 160
    private var protectedTopPadding: CGFloat = 0
    private var scrollerBottomInset: CGFloat = 0
    private var isToolbarVisible = true
    private var isStatusBarVisible = true
    private var lastScrollOffsetY: CGFloat?
    private var lastScrollClipSize: NSSize?
    private var isScrolledFromTop = false

    private var currentStyleSpans: [ResolvedMarkdownStyleSpan] = []
    private var codeInlineDrawRanges: [NSRange] = []
    private var codeBlockDrawRanges: [NSRange] = []
    private var searchMatchRanges: [NSRange] = []
    private var selectedSearchMatchIndex: Int?
    private var previousSelectionRange = NSRange(location: 0, length: 0)

    // MARK: Styling/edit reentrancy flags

    //
    // The three flags below mark self-inflicted text-storage mutations so
    // the storage and selection hooks can tell them from user edits. Each is
    // only ever set around a contiguous block through its with…() scoped
    // helper (withStyleApplication, withProgrammaticTextSetting,
    // withEditedTextNormalization), so a flag can never leak set.
    private var isApplyingStyles = false
    private var isSettingTextProgrammatically = false
    private var isNormalizingEditedText = false
    private var textChangeGeneration = 0
    private var pendingTextEdits: [MarkdownTextEdit] = []
    // Asymmetric set-here-consume-there protocol, deliberately not scoped:
    // hasRecentLargeEdit is raised by the large-edit path in
    // textStorage(_:didProcessEditing:…) and consumed by the next
    // applyParsedStyles, which answers with a full restyle instead of a
    // dirty-range delta and lowers it.
    private var hasRecentLargeEdit = false

    private var deferredStyleTask: Task<Void, Never>?
    private var styleGeneration = 0
    private var pendingFullStyleRanges: [NSRange] = []
    /// Owns attribute application and the font/layout metrics behind it. The
    /// metrics are read back through it (base attributes, point size, letter
    /// spacing, character width, paragraph gutter) rather than recomputed
    /// here, so the applier cannot disagree with the view about them.
    private lazy var styleApplier = MarkdownStyleApplier(
        textStorage: editorTextStorage,
        // Read back through the view on every use rather than handed over
        // once: the variant follows the effective appearance, and only the
        // view can resolve that. The fallback is unreachable while the view
        // that owns the applier is alive, which is the applier's whole life.
        colors: { [weak self] in
            self?.colors
                ?? EditorThemeColors.default.variant(for: .currentDrawing())
        },
        settings: settings,
        windowWidthFontScale: windowWidthFontScale
    )
    private lazy var focusModeController = makeFocusModeController()
    private let fileDropController = EditorFileDropController()
    private lazy var previewPresenter = makePreviewPresenter()
    private lazy var proofreadingPresenter = ProofreadingPresenter(
        textView: textView
    ) { [weak self] severity in
        self?.colors.proofreadingColor(for: severity) ?? .systemOrange
    }

    private var previewHorizontalInset: CGFloat = 6

    private static let immediateStyleThreshold = 20000
    private static let visibleStyleBuffer = 6000
    private static let backgroundStyleIdleDelayMilliseconds = 160

    var string: String {
        get { textView.string }
        set { setString(newValue, clearsUndo: false) }
    }

    var selectedTextForSearch: String? {
        selectedText(in: textView.selectedRange())
    }

    var selectedRange: NSRange {
        textView.selectedRange()
    }

    /// The text storage's backing string. Reading `textView.string` bridges
    /// the whole document into a fresh Swift String on every access (Swift
    /// copies a mutable NSString to keep value semantics), while this is a
    /// proxy over the same storage — so the UTF-16 range math the styling and
    /// command paths do costs nothing to set up. Only ever read from here.
    private var sourceCharacters: NSString {
        textView.textStorage?.mutableString ?? ""
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
        configureFileDropController()
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
            focusModeController.cancelScrollAnimation()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyEditorColors()
        updateSearchMatchDecorations()
        restyleAllText()
        previewPresenter.refreshIfActive()
        proofreadingPresenter.refreshColors()
    }

    func setString(_ string: String, clearsUndo: Bool) {
        proofreadingPresenter.clearIssues()
        pendingTextEdits = []
        let selectedRange = textView.selectedRange()
        withProgrammaticTextSetting {
            textView.string = string
        }

        if clearsUndo {
            textView.undoManager?.removeAllActions()
        }

        let boundedLocation = min(selectedRange.location, (string as NSString).length)
        textView.setSelectedRange(NSRange(location: boundedLocation, length: 0))
        restyleAllText()
        previewPresenter.refreshIfActive()
    }

    func restoreSelectedRange(_ range: NSRange?) {
        guard let range,
              range.location != NSNotFound,
              range.location >= 0,
              range.length >= 0
        else {
            return
        }

        let textLength = sourceCharacters.length
        let location = min(range.location, textLength)
        textView.setSelectedRange(NSRange(
            location: location,
            length: min(range.length, textLength - location)
        ))
    }

    func setPreviewActive(_ isActive: Bool) {
        if isActive {
            proofreadingPresenter.dismissPopup()
        }
        previewPresenter.setActive(isActive)
        updateScrolledFromTop()
    }

    func setProofreadingEnabled(_ isEnabled: Bool) {
        proofreadingPresenter.setEnabled(isEnabled)
    }

    func setProofreadingIssues(_ issues: [ProofreadingIssue]) {
        proofreadingPresenter.setIssues(issues)
    }

    func focus() {
        guard window?.makeFirstResponder(textView) == true else {
            return
        }

        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func applyParsedStyles(
        _ spans: [ResolvedMarkdownStyleSpan],
        dirtyRanges: [NSRange]?
    ) {
        MarkdownEditorDiagnostics.log(
            "applyParsedStyles spans=\(spans.count) textLength=\(textView.textStorage?.length ?? 0) "
                + "dirty=\(dirtyRanges.map { "\($0.count)" } ?? "nil") "
                + "recentLargeEdit=\(hasRecentLargeEdit)"
        )
        guard !(MarkdownEditorDiagnostics
            .disableParsedStylingAfterPaste && hasRecentLargeEdit)
        else {
            MarkdownEditorDiagnostics.log("applyParsedStyles skipped by flag")
            return
        }

        setStyleSpans(spans)
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

        applyDirtyStyles(dirtyRanges, spans: currentStyleSpans)
    }

    /// The single place fresh spans are stored: MarkdownStylingEngine's
    /// range slicing relies on document order, which the parse pipeline does
    /// not guarantee (see documentOrdered).
    private func setStyleSpans(_ spans: [ResolvedMarkdownStyleSpan]) {
        currentStyleSpans = MarkdownStylingEngine.documentOrdered(spans)
    }

    private func applyDirtyStyles(
        _ dirtyRanges: [NSRange],
        spans: [ResolvedMarkdownStyleSpan]
    ) {
        let string = sourceCharacters
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
        // Before the inset pass below: it measures the gutter with the new
        // font metrics.
        syncStyleApplierMetrics()
        setStyleSpans(spans)
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
        syncStyleApplierMetrics()

        let didChangeGutter = updateTextContainerInset()
        if didChangeScale || didChangeGutter {
            setStyleSpans(spans)
            restyleAllText()
        }
        if didChangeScale {
            previewPresenter.refreshIfActive()
        }
    }

    func setChromeInsets(
        top: CGFloat,
        bottom: CGFloat,
        protectedTop: CGFloat = 0,
        scrollerBottomInset: CGFloat = 0
    ) {
        textTopPadding = top
        textBottomPadding = bottom
        protectedTopPadding = protectedTop
        self.scrollerBottomInset = scrollerBottomInset
        applyChromeInsets()
        updateScrollerInsets()
        invalidateEditorCursorRects()
    }

    func setChromeVisibility(
        toolbarVisible: Bool,
        statusBarVisible: Bool
    ) {
        isToolbarVisible = toolbarVisible
        isStatusBarVisible = statusBarVisible
        updateScrollerInsets()
    }

    /// Content insets are zero (padding lives inside the text view), so the
    /// scroller spans the full window height by default; when the chrome is
    /// visible it is inset independently by the top and bottom bars' heights.
    private func updateScrollerInsets() {
        let topInset = isToolbarVisible ? textTopPadding : 0
        let bottomInset = isStatusBarVisible ? scrollerBottomInset : 0
        setScrollerInsets(top: topInset, bottom: bottomInset)
        previewPresenter.setScrollerInsets(top: topInset, bottom: bottomInset)
    }

    func setFocusModeEnabled(_ isEnabled: Bool) {
        focusModeController.setEnabled(isEnabled)
    }

    func setFocusMode(_ mode: EditorFocusMode) {
        focusModeController.setMode(mode)
    }

    private func makeFocusModeController() -> EditorFocusModeController {
        let controller = EditorFocusModeController(
            textView: textView,
            scrollView: scrollView,
            clipView: clipView
        )
        controller.restyleAllText = { [weak self] in
            self?.restyleAllText()
        }
        controller.restyleLineRange = { [weak self] range in
            self?.restyleLineNormalizedRange(range)
        }
        controller.visibleBufferedRange = { [weak self] in
            self?.visibleBufferedCharacterRange()
        }
        controller.updateContainerInset = { [weak self] in
            _ = self?.updateTextContainerInset()
        }
        return controller
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
        presenter.onScrollOffsetChanged = { [weak self] in
            self?.updateScrolledFromTop()
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
            baseFontSize: styleApplier.basePointSize,
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

        let previousSelectedRange = selectedSearchMatchRange
        searchMatchRanges = ranges
        selectedSearchMatchIndex = selectedIndex
        updateSearchMatchDecorations()
        // Only the selected match carries an attribute change (the dark
        // foreground over the yellow fill — see applySearchHighlights); the
        // fill and the borders are drawn decorations. Restyling just the
        // lines that lost and gained that color keeps find-field keystrokes
        // and next/previous steps from rewriting the whole document's
        // attributes. The old line is restyled even when the match no longer
        // exists in the new set — that is what clears the stale color,
        // including on the search-closed transition.
        restyleSelectedSearchMatchDelta(
            from: previousSelectedRange,
            to: selectedSearchMatchRange
        )
    }

    private var selectedSearchMatchRange: NSRange? {
        guard let selectedSearchMatchIndex,
              searchMatchRanges.indices.contains(selectedSearchMatchIndex)
        else {
            return nil
        }

        return searchMatchRanges[selectedSearchMatchIndex]
    }

    /// Same shape as the focus controller's paragraph delta: only the line
    /// ranges whose selected-match membership changed are restyled. An
    /// out-of-bounds previous range (the match set was recomputed for shorter
    /// text) collapses to empty in lineNormalized and is skipped — the text
    /// it colored is gone.
    private func restyleSelectedSearchMatchDelta(
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

        for deltaRange in deltaRanges {
            restyleLineNormalizedRange(deltaRange)
        }
    }

    /// Restyles one range widened to whole lines with the current spans;
    /// out-of-bounds or empty ranges are skipped. Shared by the search-match
    /// delta above and the focus controller's restyle callback.
    private func restyleLineNormalizedRange(_ range: NSRange) {
        let string = sourceCharacters
        guard let range = boundedRange(
            MarkdownStylingEngine.lineNormalized(range, in: string)
        ), range.length > 0 else {
            return
        }

        applyStyles(
            in: range,
            spans: MarkdownStylingEngine.spansForRange(
                range,
                from: currentStyleSpans
            )
        )
    }

    func selectSearchMatch(_ range: NSRange) {
        guard boundedRange(range) != nil else {
            return
        }

        // A caret, not a range selection: selecting the match makes AppKit
        // draw the inactive-selection gray over the yellow match fill while
        // the search field owns focus. The caret still lands the editor at
        // the match when the search closes. Do not use showFindIndicator:
        // its transient overlay can stay fixed to the viewport while scrolling.
        textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        scrollSearchMatchToCenter(range)
    }

    /// Centers the match in the area below the chrome band (the search bar
    /// is always visible while searching); near the document edges the
    /// offset clamps, landing the match as close to center as the scroll
    /// range allows.
    private func scrollSearchMatchToCenter(_ range: NSRange) {
        editorLayoutManager.ensureLayout(for: textContainer)
        let glyphRange = editorLayoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        let matchRect = editorLayoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )

        let clipHeight = clipView.bounds.height
        guard clipHeight > 0 else {
            textView.scrollRangeToVisible(range)
            return
        }

        let matchMidY = textView.textContainerOrigin.y + matchRect.midY
        let visibleCenterY = (textTopPadding + clipHeight) / 2
        let targetOffsetY = focusModeController.clampedScrollOffsetY(
            matchMidY - visibleCenterY
        )
        guard abs(clipView.bounds.origin.y - targetOffsetY) > 0.5 else {
            return
        }

        // Any in-flight caret centering would fight the new offset.
        textView.cancelKeyboardCaretScroll()
        focusModeController.performSuppressedScroll(toOffsetY: targetOffsetY)
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
        performBatchReplacements(validRanges.map { ($0, replacement) })
    }

    /// One undo-coalesced text change for several non-overlapping ranges:
    /// a single shouldChangeText gate over all of them, then the edits
    /// applied back-to-front inside one begin/endEditing so earlier ranges
    /// keep their offsets. Returns false when the change was refused (or
    /// there was nothing to do).
    @discardableResult
    private func performBatchReplacements(
        _ replacements: [(range: NSRange, replacement: String)]
    ) -> Bool {
        guard !replacements.isEmpty,
              let textStorage = textView.textStorage,
              textView.shouldChangeText(
                  inRanges: replacements.map { NSValue(range: $0.range) },
                  replacementStrings: replacements.map(\.replacement)
              )
        else {
            return false
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
        return true
    }

    func pasteAsLink() {
        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0,
              let selectedText = sourceCharacters
              .substring(with: selectedRange)
              .nilIfEmpty,
              let urlString = fileDropController.pasteboardURLString()
        else {
            return
        }

        let linkText = EditorFileDropController.escapeLinkText(selectedText)
        replaceSelectedText(with: "[\(linkText)](\(urlString))")
    }

    func applyMarkup(_ command: MarkdownMarkupCommand) {
        guard let edit = command.edit(
            in: sourceCharacters,
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

    func applyBlockCommand(_ command: MarkdownBlockCommand) {
        guard let edit = command.edit(
            in: sourceCharacters,
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

    func moveLines(_ command: MarkdownLineMoveCommand) {
        guard let edit = command.edit(
            in: sourceCharacters,
            selectedRange: textView.selectedRange()
        ) else {
            return
        }

        guard edit.replacementString != sourceCharacters.substring(
            with: edit.replacementRange
        ) else {
            textView.setSelectedRange(edit.selectedRange)
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
            in: sourceCharacters,
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

    func fixTypography(spans: [ResolvedMarkdownStyleSpan]?) {
        let selectedRange = textView.selectedRange()
        let replacements = MarkdownTypographyCommand.replacements(
            in: textView.string,
            selectedRange: selectedRange,
            locales: settings.typographyLocales,
            spans: spans
        )
        guard performBatchReplacements(
            replacements.map { ($0.range, $0.replacement) }
        ) else {
            return
        }

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

    func markdownTextView(
        _: NSTextView,
        moveLines command: MarkdownLineMoveCommand
    ) {
        moveLines(command)
    }

    func applyIndent(_ command: MarkdownIndentCommand) {
        let indentUnit: String
        switch settings.tabInsertionMode {
        case .spaces:
            indentUnit = String(repeating: " ", count: settings.tabWidth)
        case .tab:
            indentUnit = "\t"
        }

        guard let edit = command.edit(
            in: sourceCharacters,
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
            in: textView.textStorage?.mutableString ?? "",
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
        fileDropController.dragOperation(for: sender)
    }

    func markdownTextViewPerformDragOperation(
        _ sender: NSDraggingInfo,
        in textView: NSTextView
    ) -> Bool {
        fileDropController.performFileDrop(sender, insertionView: textView)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropController.dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropController.performFileDrop(sender, insertionView: textView)
    }

    private func configureFileDropController() {
        fileDropController.openFileURLs = { [weak self] urls in
            guard let self else {
                return
            }

            delegate?.markdownEditorView(self, requestOpenFileURLs: urls)
        }
        fileDropController.insertMarkupAtSelection = { [weak self] markup in
            self?.replaceSelectedText(with: markup)
        }
    }

    /// Return/Tab/Shift-Tab are intercepted here, on the input-context
    /// command path, rather than in keyDown: raw character dispatch stole
    /// these keys from IME composition and missed keypad Enter (which
    /// arrives as a different character but the same insertNewline command).
    /// Returning false hands the command back to AppKit's default handling.
    func textView(
        _ textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            return markdownTextViewContinueMarkdownPrefix(textView)
        case #selector(NSResponder.insertTab(_:)):
            markdownTextViewInsertTab(textView)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            markdownTextViewInsertBacktab(textView)
            return true
        default:
            return false
        }
    }

    func textDidChange(_: Notification) {
        guard !isApplyingStyles, !isSettingTextProgrammatically else {
            return
        }

        focusModeController.updateForSelection()
        textChangeGeneration += 1
        let edits = pendingTextEdits
        pendingTextEdits = []
        delegate?.markdownEditorView(
            self,
            didChangeTextBy: edits,
            at: textChangeGeneration
        )
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
              !isNormalizingEditedText
        else {
            return
        }

        let replacedLength = max(0, editedRange.length - changeInLength)
        if editedRange.location != NSNotFound,
           editedRange.location >= 0,
           editedRange.length >= 0,
           NSMaxRange(editedRange) <= textStorage.length
        {
            pendingTextEdits.append(MarkdownTextEdit(
                replacedRange: NSRange(
                    location: editedRange.location,
                    length: replacedLength
                ),
                replacement: textStorage.mutableString.substring(with: editedRange)
            ))
        }

        guard !textView.hasMarkedText() else {
            return
        }
        guard textStorage.length > 0 else {
            currentStyleSpans = []
            codeInlineDrawRanges = []
            codeBlockDrawRanges = []
            proofreadingPresenter.clearIssues()
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
        // The edit shifts character offsets; the focus controller resets its
        // suppression-episode memo (which would otherwise claim shifted lines
        // were already undimmed) and keeps the active focus paragraph glued
        // to the text — the dimming applied below (and the paragraph-delta
        // restyle on the next selection change) subtract that range, and a
        // stale one would dim part of the paragraph being typed in.
        focusModeController.handleTextEdit(
            editedRange: editedRange,
            changeInLength: changeInLength,
            sourceLength: textStorage.length
        )

        // Keep span positions valid across the edit so that any restyle
        // running before the next parse result (search updates, appearance or
        // gutter changes, …) applies attributes at the right offsets. Spans
        // overlapping the edit are dropped; the local styling below re-derives
        // the edited line. The translation moves every start monotonically, so
        // the document order setStyleSpans established survives it — no
        // re-sorting per keystroke.
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

        proofreadingPresenter.handleTextEdit(
            editedRange: editedRange,
            changeInLength: changeInLength,
            sourceLength: textStorage.length
        )

        // Share one mutable-string view of the backing storage across the
        // local styling pass instead of making each helper fetch it again.
        let characters = textStorage.mutableString
        let dirtyRange = MarkdownStylingEngine.editDirtyRange(
            editedRange: editedRange,
            in: characters
        )
        guard let range = boundedRange(dirtyRange), range.length > 0 else {
            return
        }

        guard !isLargeEdit else {
            currentStyleSpans = []
            proofreadingPresenter.clearIssues()
            updateCodeBackgroundRanges()
            pendingFullStyleRanges = []
            hasRecentLargeEdit = true
            withEditedTextNormalization {
                textStorage.setAttributes(styleApplier.baseAttributes(), range: range)
            }
            scheduleVisibleLocalStyling()
            return
        }

        withEditedTextNormalization {
            let localSpans = localStyleSpans(in: range, string: characters)
            reconcileInlineCodeDrawRanges(
                in: range,
                with: localSpans,
                string: characters
            )
            applyStyles(in: range, spans: localSpans)
        }
    }

    func textViewDidChangeSelection(_: Notification) {
        let selectedRange = textView.selectedRange()
        let didClearSelection = previousSelectionRange.length > 0
            && selectedRange.length == 0
        previousSelectionRange = selectedRange
        delegate?.markdownEditorView(
            self,
            didChangeSelectionText: selectedText(in: selectedRange)
        )

        guard !isApplyingStyles else {
            return
        }

        textView.typingAttributes = styleApplier.baseAttributes()
        // A caret move from the keyboard (arrow keys, typing) ends a
        // scroll-induced focus suppression the same way a mouse click does;
        // updateForSelection alone would leave the suppression in place.
        if focusModeController.isTemporarilySuppressed,
           NSApp.currentEvent?.type == .keyDown
        {
            focusModeController.restoreAfterEditorInteraction()
        } else {
            focusModeController.updateForSelection()
        }
        proofreadingPresenter.handleSelectionChange(selectedRange)
        if didClearSelection {
            // AppKit invalidates using the selection's current glyph geometry.
            // If styling changed that geometry while it was selected, pixels
            // just outside the new bounds otherwise remain in the backing store.
            textView.setNeedsDisplay(textView.visibleRect)
        }
    }

    private func selectedText(in range: NSRange) -> String? {
        guard range.length > 0,
              range.location != NSNotFound,
              NSMaxRange(range) <= sourceCharacters.length
        else {
            return nil
        }

        return sourceCharacters.substring(with: range)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureTextView() {
        textView.delegate = self
        textView.commandDelegate = self
        textView.onMouseDown = { [weak self] in
            self?.focusModeController.restoreAfterEditorInteraction()
        }
        textView.onScrollWheel = { [weak self] event in
            guard let self else {
                return
            }

            MarkdownEditorDiagnostics.log(
                "scrollWheel deltaY=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) "
                    + "phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) "
                    + "clipY=\(clipView.bounds.origin.y) height=\(textView.frame.height)"
            )
            focusModeController.suppressForUserScroll()
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
        textView.font = styleApplier.baseFont
        textView.typingAttributes = styleApplier.baseAttributes()
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
        guard focusModeController.isEnabled else {
            return 0
        }

        return max(0, (clipView.bounds.height - styleApplier.lineHeight) / 2)
    }

    private func updateTextContainerInset() -> Bool {
        let availableWidth = scrollView.contentView.bounds.width > 0
            ? scrollView.contentView.bounds.width
            : bounds.width
        let characterWidth = styleApplier.characterWidth()
        let minimumHorizontalInset = characterWidth
            * Self.minimumHorizontalPaddingCharacters(for: availableWidth)
        let targetWidth = characterWidth * CGFloat(settings.maxTextColumns)
        let horizontalInset = max(
            minimumHorizontalInset,
            floor((availableWidth - targetWidth) / 2)
        )
        // Sized for the widest heading marker, "###### " — 7 glyphs each
        // advanced by the letter-spacing kern, matching how markerWidth is
        // measured in MarkdownStyleApplier.applyHeadingStyle. Without the kern
        // term the H6 marker overflows the gutter and its text is pushed right.
        let markerGutter = (characterWidth + styleApplier.baseLetterSpacing) * 7
        let containerInset = max(6, horizontalInset - markerGutter)
        let newParagraphGutter = max(0, horizontalInset - containerInset)
        let didChangeParagraphGutter = newParagraphGutter != styleApplier.paragraphGutter
        // The average of the two paddings on both sides; MarkdownTextView
        // shifts the container origin to make the padding asymmetric while
        // remaining part of the (clickable) text view.
        let topPadding = max(textTopPadding, focusOverscrollPadding)
        let bottomPadding = max(textBottomPadding, focusOverscrollPadding)
        let insetSize = NSSize(
            width: containerInset,
            height: (topPadding + bottomPadding) / 2
        )

        styleApplier.paragraphGutter = newParagraphGutter
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
        // Ahead of every guard below: focus-mode centering and window
        // resizes genuinely move the content, so the chrome separator has to
        // follow them even though they do not count as user scrolling.
        updateScrolledFromTop()
        MarkdownEditorDiagnostics.log(
            "boundsChanged y=\(offsetY) last=\(lastScrollOffsetY.map(String.init(describing:)) ?? "nil") "
                + "height=\(textView.frame.height) visible=\(textView.visibleRect) "
                + "isApplying=\(isApplyingStyles)"
        )
        // Bounds changes produced by our own centering animation must not
        // count as user scrolling (they would hide the chrome and suppress
        // focus mode).
        guard !focusModeController.isAdjustingScroll else {
            return
        }

        if let lastScrollOffsetY, lastScrollOffsetY != offsetY {
            proofreadingPresenter.dismissPopup()
        }

        // While focus dimming is suppressed for a user scroll, newly revealed
        // content may still carry dimming on long documents — the undim pass
        // at suppression start runs chunked in the background there. Restyle
        // just the viewport; short documents were already fully restyled
        // synchronously when the suppression began.
        if focusModeController.isEnabled,
           focusModeController.isTemporarilySuppressed,
           focusModeController.mode == .focus,
           let textStorage = textView.textStorage,
           textStorage.length > Self.immediateStyleThreshold
        {
            focusModeController.restyleSuppressedViewportIfNeeded()
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

    /// Whether the visible surface — the preview while it is up, the editor
    /// otherwise — sits away from its resting top position.
    private func updateScrolledFromTop() {
        let isScrolled = previewPresenter.isActive
            ? previewPresenter.isScrolledFromTop
            : clipView.bounds.origin.y > 0.5
        guard isScrolled != isScrolledFromTop else {
            return
        }

        isScrolledFromTop = isScrolled
        delegate?.markdownEditorView(self, didChangeScrolledFromTop: isScrolled)
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
            gutter: styleApplier.paragraphGutter,
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
        with localSpans: [ResolvedMarkdownStyleSpan],
        string: NSString
    ) {
        guard let targetRange = boundedRange(targetRange) else {
            return
        }

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
            textView.font = styleApplier.baseFont
            textView.typingAttributes = styleApplier.baseAttributes()
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
            in: textStorage.mutableString,
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

            // Every exit hands the property back, not just the drained one:
            // resumeFullStylingIfNeeded reads `deferredStyleTask == nil` as
            // "nothing in flight", and a finished task left in place stranded
            // the remaining chunks behind it. The generation guard keeps a
            // superseded task from clearing the successor that replaced it.
            defer {
                if generation == styleGeneration {
                    deferredStyleTask = nil
                }
            }

            // Acquired once for the whole pass rather than per chunk: this is
            // the live backing string, so it stays correct across the yields
            // below, and the guards above already abandon the pass whenever
            // the document changed underneath it.
            let string = sourceCharacters
            while !pendingFullStyleRanges.isEmpty {
                guard !Task.isCancelled,
                      generation == styleGeneration,
                      sourceLength == textView.textStorage?.length
                else {
                    return
                }

                let chunk = pendingFullStyleRanges.removeFirst()
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
        }
    }

    private func scheduleVisibleLocalStyling() {
        guard let textStorage = textView.textStorage,
              textStorage.length > 0
        else {
            return
        }

        // Owns the cancellation itself instead of trusting the caller to have
        // cancelled: this overwrites deferredStyleTask, and an in-flight
        // chunk pass left running would keep styling against stale spans.
        cancelDeferredStyling()
        let generation = styleGeneration
        let sourceLength = textStorage.length
        MarkdownEditorDiagnostics
            .log("scheduleVisibleLocalStyling length=\(sourceLength)")
        deferredStyleTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else {
                return
            }

            defer {
                if generation == styleGeneration {
                    deferredStyleTask = nil
                }
            }

            guard !Task.isCancelled,
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
            applyStyles(
                in: range,
                spans: localStyleSpans(in: range, string: sourceCharacters)
            )
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
            return textStorage.mutableString.lineRange(
                for: NSRange(location: 0, length: length)
            )
        }

        let x = textView.textContainerInset.width + styleApplier.paragraphGutter + 1
        let start = textView.characterIndexForInsertion(at: NSPoint(
            x: x,
            y: max(0, visibleRect.minY)
        ))
        let end = textView.characterIndexForInsertion(at: NSPoint(
            x: x,
            y: max(visibleRect.minY + styleApplier.lineHeight, visibleRect.maxY)
        ))
        let lowerBound = max(0, min(start, end) - leadingBuffer)
        let upperBound = min(
            textStorage.length,
            max(start, end) + trailingBuffer
        )
        guard upperBound > lowerBound else {
            return nil
        }

        return textStorage.mutableString.lineRange(
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

        // Acquired once and threaded through the helpers below; each of them
        // used to take the document's string itself, which copies the whole
        // backing store per heading, per list and per pass.
        let string = textStorage.mutableString
        withStyleApplication {
            textView.undoManager?.disableUndoRegistration()
            // This runs on every keystroke; the disabled-diagnostics path must
            // pay nothing for timestamps, geometry reads, or log formatting.
            let diagnosticsEnabled = MarkdownEditorDiagnostics.isEnabled
            let startTime = diagnosticsEnabled ? Date().timeIntervalSince1970 : 0
            let heightBefore = diagnosticsEnabled ? textView.frame.height : 0
            let clipYBefore = diagnosticsEnabled ? clipView.bounds.origin.y : 0
            textStorage.beginEditing()
            textStorage.setAttributes(styleApplier.baseAttributes(), range: targetRange)

            for span in spans {
                let range = NSIntersectionRange(span.range, targetRange)
                guard range.length > 0 else {
                    continue
                }

                styleApplier.applyStyle(span.kind, range: range, string: string)
            }

            styleApplier.applyNonbreakingSpaceStyle(
                range: targetRange,
                string: string
            )
            // `setAttributes` above restores Lilex over the whole dirty line,
            // including emoji that it cannot draw. Outside a text-storage
            // edit AppKit fixes that fallback automatically; the local pass
            // runs inside didProcessEditing, so without doing it here the
            // emoji disappears until the parser's later styling pass.
            textStorage.fixFontAttribute(in: targetRange)
            // Dimming first: the selected match's dark text must survive focus
            // mode's foreground override.
            applyFocusDimming(in: targetRange)
            applySearchHighlights(intersecting: [targetRange])

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
                textView.typingAttributes = styleApplier.baseAttributes()
            }
            if diagnosticsEnabled {
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
        }
    }

    // MARK: Scoped flag helpers

    /// Marks a contiguous attribute-application block so the text-storage
    /// and selection hooks ignore the self-inflicted mutations.
    private func withStyleApplication(_ body: () -> Void) {
        isApplyingStyles = true
        defer { isApplyingStyles = false }
        body()
    }

    /// Marks a programmatic full-text replacement (setString) so it does not
    /// read as a user edit.
    private func withProgrammaticTextSetting(_ body: () -> Void) {
        isSettingTextProgrammatically = true
        defer { isSettingTextProgrammatically = false }
        body()
    }

    /// Marks the local re-normalization pass that runs inside
    /// textStorage(_:didProcessEditing:…) — applyStyles reads this to skip
    /// setTypingAttributes while the selection is stale (see the comment
    /// there), and the storage hook uses it to avoid recursing.
    private func withEditedTextNormalization(_ body: () -> Void) {
        isNormalizingEditedText = true
        defer { isNormalizingEditedText = false }
        body()
    }

    private func localStyleSpans(
        in range: NSRange,
        string: NSString
    ) -> [ResolvedMarkdownStyleSpan] {
        let boundedRange = NSIntersectionRange(
            range,
            NSRange(location: 0, length: string.length)
        )
        guard boundedRange.length > 0 else {
            return []
        }

        // The scanners require a Swift String. Materialize only the dirty
        // lines, then translate their spans back to document coordinates.
        let sourceRange = string.lineRange(for: boundedRange)
        let source = string.substring(with: sourceRange)
        let localString = source as NSString
        var localSpans: [ResolvedMarkdownStyleSpan] = []
        var absoluteSpans: [ResolvedMarkdownStyleSpan] = []
        var lineStart = 0
        let upperBound = localString.length
        let frontmatterRange = MarkdownFrontmatter.range(in: string)

        while lineStart < upperBound {
            let localLineRange = localString.lineRange(
                for: NSRange(location: lineStart, length: 0)
            )
            let absoluteLineRange = NSRange(
                location: sourceRange.location + localLineRange.location,
                length: localLineRange.length
            )
            defer {
                lineStart = max(NSMaxRange(localLineRange), lineStart + 1)
            }

            // Frontmatter is re-scanned per call (cheap: O(1) unless the
            // document opens with "---") rather than cached like code blocks,
            // so typing the delimiter lines opens/closes the block with no
            // staleness. Suppresses the analyzer's thematic-break match on
            // "---" and all markdown styling inside the block.
            if let frontmatterRange,
               NSIntersectionRange(frontmatterRange, absoluteLineRange).length > 0
            {
                absoluteSpans.append(ResolvedMarkdownStyleSpan(
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
                NSIntersectionRange($0, absoluteLineRange).length > 0
            }) {
                absoluteSpans.append(ResolvedMarkdownStyleSpan(
                    range: block,
                    kind: .codeBlock
                ))
                continue
            }

            if let blockSpan = MarkdownBlockPrefixAnalyzer.prefixBlockSpan(
                for: localLineRange,
                source: source
            ) {
                localSpans.append(blockSpan)
            }
            localSpans.append(contentsOf: MarkdownInlineStyleScanner.inlineSpans(
                in: localLineRange,
                source: source
            ))
            // The inline scanner cannot produce this one: cmark reads a
            // list-less checkbox as ordinary text (see
            // MarkdownTaskCheckboxScanner).
            if let checkboxRange = MarkdownTaskCheckboxScanner.checkboxRange(
                for: localLineRange,
                source: source
            ) {
                localSpans.append(ResolvedMarkdownStyleSpan(
                    range: checkboxRange,
                    kind: .taskCheckbox
                ))
            }
        }

        // Resolve link/image spans into punctuation/destination sub-spans the
        // same way the parse pipeline does, so the locally styled line looks
        // identical to the parsed one and nothing repaints when the parse
        // arrives.
        let resolvedLocalSpans = MarkdownLinkStyleResolver.resolve(
            spans: localSpans,
            in: source
        )
        absoluteSpans.append(contentsOf: resolvedLocalSpans.map { span in
            ResolvedMarkdownStyleSpan(
                range: NSRange(
                    location: sourceRange.location + span.range.location,
                    length: span.range.length
                ),
                kind: span.kind
            )
        })
        return absoluteSpans
    }

    /// The selected match sits on the opaque yellow fill drawn in the text
    /// view's background pass; the theme foreground has no contrast there,
    /// so its text flips to a dark color. The fill and the borders around
    /// the other matches are drawn in MarkdownTextView, not applied as
    /// attributes — see updateSearchMatchDecorations().
    private func applySearchHighlights(intersecting ranges: [NSRange]) {
        guard let textStorage = textView.textStorage,
              let selectedIndex = selectedSearchMatchIndex,
              searchMatchRanges.indices.contains(selectedIndex)
        else {
            return
        }

        let matchRange = searchMatchRanges[selectedIndex]
        for range in ranges {
            let intersection = NSIntersectionRange(matchRange, range)
            guard intersection.length > 0,
                  boundedRange(intersection) != nil
            else {
                continue
            }

            textStorage.addAttribute(
                .foregroundColor,
                value: Self.searchSelectedMatchTextColor,
                range: intersection
            )
        }
    }

    private func applyFocusDimming(in range: NSRange) {
        guard let textStorage = textView.textStorage else {
            return
        }

        for dimmedRange in focusModeController.dimmedRanges(in: range) {
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.foreground
                    .withAlphaComponent(colors.foreground.alphaComponent * 0.5),
                range: dimmedRange
            )
        }
    }

    private static let searchSelectedMatchFillColor = NSColor.systemYellow
    private static let searchSelectedMatchTextColor = NSColor.black
        .withAlphaComponent(0.88)

    private static let searchMatchBorderColor = NSColor.textColor

    private func updateSearchMatchDecorations() {
        let selectedRange: NSRange? =
            if let selectedSearchMatchIndex,
            searchMatchRanges.indices.contains(selectedSearchMatchIndex) {
                searchMatchRanges[selectedSearchMatchIndex]
            } else {
                nil
            }
        let borderRanges = searchMatchRanges.enumerated()
            .filter { $0.offset != selectedSearchMatchIndex }
            .map(\.element)
        textView.setSearchMatchDecorations(
            borderRanges: borderRanges,
            selectedRange: selectedRange,
            borderColor: Self.searchMatchBorderColor,
            fillColor: Self.searchSelectedMatchFillColor
        )
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

        let selectedText = sourceCharacters.substring(with: selectedRange)
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

    /// Refreshes what AppKit will not re-read on its own. Text attributes are
    /// deliberately not among them: the applier resolves the variant per read,
    /// so a restyle repaints in the current theme even when this never ran.
    private func applyEditorColors() {
        scrollView.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        textView.insertionPointColor = colors.caret
        textView.selectedTextAttributes = [.backgroundColor: colors.selection]
    }

    /// Only the view can resolve the theme variant — it is the one holding an
    /// NSAppearance — so this stays here and the applier reads it through the
    /// closure it was built with.
    private var colors: EditorThemeColors.Variant {
        themeColors.variant(for: effectiveAppearance)
    }

    /// Both font-metric inputs are pushed together from the view's own values,
    /// so a settings change and a window-width change cannot leave the applier
    /// half updated.
    private func syncStyleApplierMetrics() {
        styleApplier.updateMetrics(
            settings: settings,
            windowWidthFontScale: windowWidthFontScale
        )
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
        guard let textStorage = textView.textStorage else {
            return nil
        }

        return MarkdownStylingEngine.bounded(range, length: textStorage.length)
    }

    private func edgeInsets(_ lhs: NSEdgeInsets, equalTo rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }

    private func setScrollerInsets(top: CGFloat, bottom: CGFloat) {
        let scrollerInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
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
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
