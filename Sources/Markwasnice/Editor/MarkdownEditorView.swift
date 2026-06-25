import AppKit
import UniformTypeIdentifiers

@MainActor
protocol MarkdownEditorViewDelegate: AnyObject {
    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView)
    func markdownEditorViewDidScroll(_ editorView: MarkdownEditorView)
}

@MainActor
final class MarkdownEditorView: NSView, NSTextViewDelegate,
    MarkdownTextViewCommandDelegate
{
    weak var delegate: MarkdownEditorViewDelegate?

    private let scrollView = NSScrollView()
    private let textStorage = NSTextStorage()
    private let layoutManager = MarkdownCodeBackgroundLayoutManager()
    private let textContainer = NSTextContainer(
        containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private let textView: MarkdownTextView
    private var isApplyingStyles = false
    private var settings: EditorSettings
    private var windowWidthFontScale: CGFloat = 1
    private var hangsHeadingMarkers = true
    private var themeColors = EditorThemeColors.default
    private var currentStyleSpans: [ResolvedMarkdownStyleSpan] = []
    private var paragraphGutter: CGFloat = 0
    private var textTopPadding: CGFloat = 0
    private var textBottomPadding: CGFloat = 160
    private var visibleScrollerTopInset: CGFloat = 0
    private var isChromeVisible = true
    private var lastScrollOffsetY: CGFloat?

    var documentURL: URL?

    var string: String {
        get { textView.string }
        set { setString(newValue, clearsUndo: false) }
    }

    init(settings: EditorSettings, frame frameRect: NSRect = .zero) {
        self.settings = settings

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0

        textView = MarkdownTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: frameRect)

        configureTextView()
        configureScrollView()
        registerForDraggedTypes([.fileURL])

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        let didChangeParagraphGutter = applyChromeInsets()
        if didChangeParagraphGutter {
            applyStyles(currentStyleSpans)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyEditorColors()
        applyStyles(currentStyleSpans)
    }

    func setString(_ string: String, clearsUndo: Bool) {
        let selectedRange = textView.selectedRange()
        textView.string = string
        applyBaseStyleToText()

        if clearsUndo {
            textView.undoManager?.removeAllActions()
        }

        updateTextDocumentSize()
        let boundedLocation = min(selectedRange.location, (string as NSString).length)
        textView.setSelectedRange(NSRange(location: boundedLocation, length: 0))
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func applyStyles(_ spans: [ResolvedMarkdownStyleSpan]) {
        guard !textView.hasMarkedText() else {
            return
        }

        currentStyleSpans = spans
        let orderedSpans = orderedForVisibleRange(spans)

        isApplyingStyles = true
        textView.undoManager?.disableUndoRegistration()
        textStorage.beginEditing()
        applyBaseStyleToText()

        for span in orderedSpans {
            applyStyle(span.kind, range: span.range)
        }
        applyNonbreakingSpaceStyle()

        textStorage.endEditing()
        textView.undoManager?.enableUndoRegistration()
        isApplyingStyles = false
        updateTextDocumentSize()

        updateTypingAttributesAtSelection(spans: spans)
    }

    func applySettings(_ settings: EditorSettings, spans: [ResolvedMarkdownStyleSpan]) {
        self.settings = settings
        updateTextContainerInset()
        applyStyles(spans)
    }

    func updateWindowWidthFontScale(
        for windowWidth: CGFloat,
        spans: [ResolvedMarkdownStyleSpan]
    ) {
        let newScale = Self.windowWidthFontScale(for: windowWidth)
        let newHangsHeadingMarkers = Self.hangsHeadingMarkers(for: windowWidth)
        let didChangeFontScale = newScale != windowWidthFontScale
        let didChangeHeadingHang = newHangsHeadingMarkers != hangsHeadingMarkers

        windowWidthFontScale = newScale
        hangsHeadingMarkers = newHangsHeadingMarkers

        let didChangeParagraphGutter = updateTextContainerInset()
        if didChangeFontScale || didChangeHeadingHang || didChangeParagraphGutter {
            applyStyles(spans)
        }
    }

    func setChromeInsets(
        top: CGFloat,
        bottom: CGFloat,
        protectedTop _: CGFloat = 0
    ) {
        textTopPadding = top
        textBottomPadding = bottom
        visibleScrollerTopInset = top
        applyChromeInsets()
        setScrollerTopInset(isChromeVisible ? visibleScrollerTopInset : 0)
    }

    func setChromeVisible(_ isVisible: Bool) {
        isChromeVisible = isVisible
        setScrollerTopInset(isVisible ? visibleScrollerTopInset : 0)
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
            in: textView.string, selectedRange: textView.selectedRange()
        ),
            textView.shouldChangeText(
                in: edit.replacementRange,
                replacementString: edit.replacementString
            )
        else {
            return
        }

        textView.textStorage?.replaceCharacters(
            in: edit.replacementRange, with: edit.replacementString
        )
        textView.didChangeText()
        textView.setSelectedRange(edit.selectedRange)
    }

    func wrapSelectionWithQuotes(opening: String, closing: String) {
        _ = wrapSelection(opening: opening, closing: closing)
    }

    func markdownTextViewInsertTab(_: NSTextView) {
        let insertedText: String
        switch settings.tabInsertionMode {
        case .spaces:
            insertedText = String(repeating: " ", count: settings.tabWidth)
        case .tab:
            insertedText = "\t"
        }

        replaceSelectedText(with: insertedText)
    }

    func markdownTextViewContinueMarkdownPrefix(_ textView: NSTextView) -> Bool {
        guard textView.selectedRange().length == 0 else {
            return false
        }

        if exitEmptyMarkdownPrefixAtSelection() {
            return true
        }

        guard let continuation = listContinuationAtSelection() ??
            quoteContinuationAtSelection()
        else {
            return false
        }

        replaceSelectedText(with: continuation)
        return true
    }

    func markdownTextView(
        _: NSTextView, wrapSelectionWith opening: String, closing: String
    ) -> Bool {
        wrapSelection(opening: opening, closing: closing)
    }

    func markdownTextViewDraggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageFileURL(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    func markdownTextViewPerformDragOperation(
        _ sender: NSDraggingInfo,
        in textView: NSTextView
    )
        -> Bool
    {
        guard let url = imageFileURL(from: sender.draggingPasteboard) else {
            return false
        }

        let point = textView.convert(sender.draggingLocation, from: nil)
        insertMarkdownImage(for: url, at: point)
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        markdownTextViewDraggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = imageFileURL(from: sender.draggingPasteboard) else {
            return false
        }

        let point = convert(sender.draggingLocation, from: nil)
        let textPoint = textView.convert(point, from: self)
        insertMarkdownImage(for: url, at: textPoint)
        return true
    }

    func textDidChange(_: Notification) {
        guard !isApplyingStyles else {
            return
        }

        updateTextDocumentSize()
        delegate?.markdownEditorViewDidChangeText(self)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureScrollView() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.backgroundColor = colors.background
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsets(
            top: visibleScrollerTopInset, left: 0, bottom: 0, right: 0
        )
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @discardableResult
    private func applyChromeInsets() -> Bool {
        let textInsets = NSEdgeInsets(
            top: textTopPadding,
            left: 0,
            bottom: textBottomPadding,
            right: 0
        )

        if !edgeInsets(scrollView.contentInsets, equalTo: NSEdgeInsetsZero) {
            scrollView.contentInsets = NSEdgeInsetsZero
        }
        if !edgeInsets(textView.textContentInsets, equalTo: textInsets) {
            textView.textContentInsets = textInsets
        }

        let didChangeParagraphGutter = updateTextContainerInset()
        updateTextDocumentSize()
        return didChangeParagraphGutter
    }

    private func edgeInsets(_ lhs: NSEdgeInsets, equalTo rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }

    @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else {
            return
        }

        let offsetY = clipView.bounds.origin.y
        defer { lastScrollOffsetY = offsetY }

        guard let lastScrollOffsetY,
              abs(offsetY - lastScrollOffsetY) > 0.5
        else {
            return
        }

        delegate?.markdownEditorViewDidScroll(self)
    }

    private func configureTextView() {
        textView.delegate = self
        textView.commandDelegate = self
        textView.registerForDraggedTypes([.fileURL])
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        updateTextContainerInset()

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.enabledTextCheckingTypes = 0

        applyEditorColors()
        applyBaseStyleToText()
    }

    private func replaceSelectedText(with string: String) {
        let selectedRange = textView.selectedRange()
        guard textView.shouldChangeText(in: selectedRange, replacementString: string)
        else {
            return
        }

        textView.textStorage?.replaceCharacters(in: selectedRange, with: string)
        textView.didChangeText()
        textView.setSelectedRange(
            NSRange(
                location: selectedRange.location + (string as NSString).length,
                length: 0
            )
        )
    }

    private func replaceText(
        in range: NSRange,
        with string: String,
        selectedLocation: Int
    ) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: string) else {
            return false
        }

        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: selectedLocation, length: 0))
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
        guard textView
            .shouldChangeText(in: selectedRange, replacementString: replacement)
        else {
            return false
        }

        textView.textStorage?.replaceCharacters(in: selectedRange, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(
            NSRange(
                location: selectedRange.location + (opening as NSString).length,
                length: (selectedText as NSString).length
            )
        )
        return true
    }

    private func listContinuationAtSelection() -> String? {
        let nsString = textView.string as NSString
        let location = textView.selectedRange().location
        let lineLocation = location > 0 ? location - 1 : 0
        let lineRange = nsString.lineRange(for: NSRange(
            location: lineLocation,
            length: 0
        ))
        let cursorRange = NSRange(
            location: lineRange.location, length: max(0, location - lineRange.location)
        )
        let linePrefix = nsString.substring(with: cursorRange)
        guard let expression = try? NSRegularExpression(
            pattern: "^([ \\t]*)([-+*]|\\d+[.)])\\s+(.+)$"
        ),
            let match = expression.firstMatch(
                in: linePrefix, range: NSRange(
                    location: 0,
                    length: (linePrefix as NSString).length
                )
            ),
            match.numberOfRanges == 4
        else {
            return nil
        }

        let prefix = linePrefix as NSString
        let indentation = prefix.substring(with: match.range(at: 1))
        let marker = prefix.substring(with: match.range(at: 2))
        return "\n\(indentation)\(nextListMarker(after: marker)) "
    }

    private func exitEmptyMarkdownPrefixAtSelection() -> Bool {
        let nsString = textView.string as NSString
        let location = textView.selectedRange().location
        let lineLocation = location > 0 ? location - 1 : 0
        let lineRange = nsString.lineRange(for: NSRange(
            location: lineLocation,
            length: 0
        ))
        let cursorRange = NSRange(
            location: lineRange.location, length: max(0, location - lineRange.location)
        )
        let lineText = nsString.substring(with: lineRange)
            .trimmingCharacters(in: .newlines)
        guard lineMatchesEmptyMarkdownPrefix(lineText) else {
            return false
        }

        let replacementRange = NSRange(
            location: lineRange.location,
            length: lineRange.location + lineRange.length > location
                ? lineRange.length : cursorRange.length
        )
        return replaceText(
            in: replacementRange, with: "\n",
            selectedLocation: replacementRange.location + 1
        )
    }

    private func lineMatchesEmptyMarkdownPrefix(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        let patterns = [
            "^[ \\t]*(?:[-+*]|\\d+[.)])\\s*$",
            "^[ \\t]*>\\s*$",
        ]

        return patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                return false
            }

            return expression.firstMatch(in: line, range: range) != nil
        }
    }

    private func quoteContinuationAtSelection() -> String? {
        let nsString = textView.string as NSString
        let location = textView.selectedRange().location
        let lineLocation = location > 0 ? location - 1 : 0
        let lineRange = nsString.lineRange(for: NSRange(
            location: lineLocation,
            length: 0
        ))
        let cursorRange = NSRange(
            location: lineRange.location, length: max(0, location - lineRange.location)
        )
        let linePrefix = nsString.substring(with: cursorRange)
        guard let expression = try? NSRegularExpression(pattern: "^([ \\t]*)>"),
              let match = expression.firstMatch(
                  in: linePrefix, range: NSRange(
                      location: 0,
                      length: (linePrefix as NSString).length
                  )
              ),
              match.numberOfRanges == 2
        else {
            return nil
        }

        let prefix = linePrefix as NSString
        let indentation = prefix.substring(with: match.range(at: 1))
        return "\n\(indentation)> "
    }

    private func nextListMarker(after marker: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "^(\\d+)([.)])$"),
              let match = expression.firstMatch(
                  in: marker, range: NSRange(
                      location: 0,
                      length: (marker as NSString).length
                  )
              ),
              match.numberOfRanges == 3,
              let number = Int((marker as NSString).substring(with: match.range(at: 1)))
        else {
            return marker
        }

        let suffix = (marker as NSString).substring(with: match.range(at: 2))
        return "\(number + 1)\(suffix)"
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

    private func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "]", with: "\\]")
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

    private func markdownRelativePath(for url: URL) -> String {
        guard let documentURL else {
            return url.lastPathComponent
        }

        let baseDirectory = documentURL.deletingLastPathComponent()
        return relativePath(from: baseDirectory, to: url)
    }

    private func insertMarkdownImage(for url: URL, at point: NSPoint) {
        let characterIndex = textView.characterIndexForInsertion(at: point)
        textView.setSelectedRange(NSRange(location: characterIndex, length: 0))

        let path = markdownRelativePath(for: url)
        let name = url.deletingPathExtension().lastPathComponent.nilIfEmpty ?? "image"
        replaceSelectedText(with: "![\(escapeLinkText(name))](\(path))")
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

    private func applyEditorColors() {
        scrollView.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        textView.insertionPointColor = colors.caret
        textView.selectedTextAttributes = [.backgroundColor: colors.selection]
    }

    private func applyBaseStyleToText() {
        let attributes = baseAttributes()
        textView.font = baseFont
        textView.typingAttributes = attributes

        guard textStorage.length > 0 else {
            return
        }

        textStorage.setAttributes(
            attributes, range: NSRange(location: 0, length: textStorage.length)
        )
    }

    private var baseFont: NSFont {
        LilexFontProvider.regular(size: basePointSize)
    }

    private var basePointSize: CGFloat {
        settings.basePointSize * windowWidthFontScale
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont,
            .foregroundColor: colors.foreground,
            .kern: baseLetterSpacing,
            .paragraphStyle: baseParagraphStyle(),
        ]
    }

    private var baseLetterSpacing: CGFloat {
        basePointSize * 0.0305
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

    private var colors: EditorThemeColors.Variant {
        themeColors.variant(for: effectiveAppearance)
    }

    private var lineHeight: CGFloat {
        basePointSize * 1.8
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

    private static func hangsHeadingMarkers(for width: CGFloat) -> Bool {
        width > 440
    }

    private func updateTypingAttributesAtSelection(spans: [ResolvedMarkdownStyleSpan]) {
        let location = textView.selectedRange().location
        var attributes = baseAttributes()

        for span in spans where span.affectsTyping(at: location) {
            applyTypingStyle(span.kind, attributes: &attributes)
        }

        textView.typingAttributes = attributes
    }

    private func applyTypingStyle(
        _ kind: MarkdownStyleKind, attributes: inout [NSAttributedString.Key: Any]
    ) {
        switch kind {
        case .heading:
            attributes[.font] = font(
                from: attributes, adding: .boldFontMask
            )
        case .strong:
            attributes[.font] = font(from: attributes, adding: .boldFontMask)
        case .emphasis:
            attributes[.font] = font(from: attributes, adding: .italicFontMask)
            attributes[.foregroundColor] = colors.foreground
        case .inlineCode:
            attributes[.font] = LilexFontProvider
                .regular(size: currentPointSize(from: attributes))
            attributes[.markdownCodeBackgroundColor] = colors.codeBackground
            attributes[.foregroundColor] = colors.foreground
        case .codeBlock:
            attributes[.font] = LilexFontProvider
                .regular(size: currentPointSize(from: attributes))
            attributes[.markdownCodeBlockBackgroundColor] = colors.codeBackground
            attributes[.foregroundColor] = colors.foreground
        case .linkDestination:
            attributes[.foregroundColor] = colors.punctuation
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = colors.underline
        case .linkSyntaxPunctuation:
            attributes[.foregroundColor] = colors.punctuation
        case .link, .image:
            break
        case .blockQuote:
            break
        case .thematicBreak:
            attributes[.foregroundColor] = colors.thematicBreak
        case .orderedList, .unorderedList:
            break
        }
    }

    private func font(
        from attributes: [NSAttributedString.Key: Any], adding traits: NSFontTraitMask,
        size: CGFloat? = nil
    ) -> NSFont {
        let currentFont = attributes[.font] as? NSFont ?? baseFont
        let targetSize = size ?? currentFont.pointSize
        let existingTraits = NSFontManager.shared.traits(of: currentFont)
        return LilexFontProvider.font(
            size: targetSize,
            traits: existingTraits.union(traits)
        )
    }

    private func currentPointSize(from attributes: [NSAttributedString.Key: Any])
        -> CGFloat
    {
        (attributes[.font] as? NSFont)?.pointSize ?? baseFont.pointSize
    }

    private func applyStyle(_ kind: MarkdownStyleKind, range: NSRange) {
        guard let range = boundedRange(range), range.length > 0 else {
            return
        }

        switch kind {
        case .heading:
            addFontTraits(.boldFontMask, range: range)
            applyHeadingHang(range: range)
        case .strong:
            addFontTraits(.boldFontMask, range: range)
        case .emphasis:
            addFontTraits(.italicFontMask, range: range)
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.foreground,
                range: range
            )
        case .inlineCode:
            setMonospaceFont(range: range)
            textStorage.addAttributes(
                [
                    .markdownCodeBackgroundColor: colors.codeBackground,
                    .foregroundColor: colors.foreground,
                ], range: range
            )
        case .codeBlock:
            setMonospaceFont(range: range)
            textStorage.addAttributes(
                [
                    .markdownCodeBlockBackgroundColor: colors.codeBackground,
                    .foregroundColor: colors.foreground,
                ], range: range
            )
        case .linkDestination:
            textStorage.addAttributes(
                [
                    .foregroundColor: colors.punctuation,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: colors.underline,
                ], range: range
            )
        case .linkSyntaxPunctuation:
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.punctuation,
                range: range
            )
        case .link, .image:
            break
        case .blockQuote:
            applyLineMarkerStyle(pattern: "^\\s*(>)", range: range, markerCaptureGroup: 1)
        case .orderedList, .unorderedList:
            applyLineMarkerStyle(pattern: "^\\s*(?:[-+*]|\\d+[.)])\\s+", range: range)
        case .thematicBreak:
            textStorage.addAttribute(
                .foregroundColor, value: colors.thematicBreak, range: range
            )
        }
    }

    private func orderedForVisibleRange(_ spans: [ResolvedMarkdownStyleSpan])
        -> [ResolvedMarkdownStyleSpan]
    {
        guard let visibleRange = visibleCharacterRange() else {
            return spans
        }

        var visible: [ResolvedMarkdownStyleSpan] = []
        var deferred: [ResolvedMarkdownStyleSpan] = []

        for span in spans {
            if NSIntersectionRange(span.range, visibleRange).length > 0 {
                visible.append(span)
            } else {
                deferred.append(span)
            }
        }

        return visible + deferred
    }

    private func visibleCharacterRange() -> NSRange? {
        guard textStorage.length > 0 else {
            return nil
        }

        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleTextContainerRect(), in: textContainer
        )
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil
        )
        return characterRange.length > 0 ? characterRange : nil
    }

    private func visibleTextContainerRect() -> NSRect {
        var visibleRect = textView.visibleRect
        visibleRect.origin.x -= textView.textContainerOrigin.x
        visibleRect.origin.y -= textView.textContainerOrigin.y
        return visibleRect
    }

    private func boundedRange(_ range: NSRange) -> NSRange? {
        guard range.location >= 0,
              range.length >= 0,
              range.location <= textStorage.length,
              range.location + range.length <= textStorage.length
        else {
            return nil
        }

        return range
    }

    private func addFontTraits(
        _ traits: NSFontTraitMask,
        size: CGFloat? = nil,
        range: NSRange
    ) {
        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let currentFont = value as? NSFont ?? baseFont
            let existingTraits = NSFontManager.shared.traits(of: currentFont)
            let convertedFont = LilexFontProvider.font(
                size: size ?? currentFont.pointSize, traits: existingTraits.union(traits)
            )
            textStorage.addAttribute(.font, value: convertedFont, range: subrange)
        }
    }

    private func setMonospaceFont(range: NSRange) {
        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let currentFont = value as? NSFont ?? baseFont
            let font = LilexFontProvider.regular(size: currentFont.pointSize)
            textStorage.addAttribute(.font, value: font, range: subrange)
        }
    }

    private func applyHeadingHang(range: NSRange) {
        guard hangsHeadingMarkers else {
            return
        }

        guard let expression = try? NSRegularExpression(
            pattern: "^[ \t]*#{1,6}[ \t]+", options: [.anchorsMatchLines]
        )
        else {
            return
        }

        let string = textStorage.string as NSString
        let lineRange = string.lineRange(for: range)
        expression
            .enumerateMatches(
                in: textStorage.string,
                range: lineRange
            ) { match, _, stop in
                guard let markerRange = match?.range,
                      markerRange.location != NSNotFound,
                      markerRange.location + markerRange.length <= string.length
                else {
                    return
                }

                let marker = string.substring(with: markerRange) as NSString
                let markerWidth = marker.size(withAttributes: baseAttributes()).width
                let paragraphStyle = baseParagraphStyle()
                paragraphStyle.firstLineHeadIndent =
                    paragraphGutter - markerWidth
                textStorage.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle,
                    range: lineRange
                )
                stop.pointee = true
            }
    }

    @discardableResult
    private func updateTextContainerInset() -> Bool {
        let availableWidth =
            scrollView.contentView.bounds.width > 0
                ? scrollView.contentView.bounds.width : bounds.width
        let minimumHorizontalInset =
            (characterWidth() * Self
                .minimumHorizontalPaddingCharacters(for: availableWidth))
        let targetWidth = characterWidth() * CGFloat(settings.maxTextColumns)
        let horizontalInset = max(
            minimumHorizontalInset,
            floor((availableWidth - targetWidth) / 2)
        )
        let markerGutter = characterWidth() * 7
        let containerInset = max(6, horizontalInset - markerGutter)
        let newParagraphGutter = max(0, horizontalInset - containerInset)
        let didChangeParagraphGutter = newParagraphGutter != paragraphGutter
        let containerInsetSize = NSSize(width: containerInset, height: 0)

        paragraphGutter = newParagraphGutter
        if textView.textContainerInset != containerInsetSize {
            textView.textContainerInset = containerInsetSize
        }
        return didChangeParagraphGutter
    }

    private func updateTextDocumentSize() {
        let clipSize = scrollView.contentView.bounds.size
        let targetWidth = clipSize.width > 0 ? clipSize.width : bounds.width
        guard targetWidth > 0 else {
            return
        }

        if textView.frame.width != targetWidth {
            textView.setFrameSize(NSSize(
                width: targetWidth,
                height: textView.frame.height
            ))
        }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let textMaxY = max(usedRect.maxY, extraLineFragmentMaxY())
        let targetHeight = max(
            clipSize.height,
            ceil(textTopPadding + textMaxY + textBottomPadding)
        )

        guard textView.frame.height != targetHeight else {
            return
        }

        textView.setFrameSize(NSSize(width: targetWidth, height: targetHeight))
    }

    private func extraLineFragmentMaxY() -> CGFloat {
        guard layoutManager.extraLineFragmentTextContainer === textContainer else {
            return 0
        }

        return layoutManager.extraLineFragmentRect.maxY
    }

    private func setScrollerTopInset(_ top: CGFloat) {
        let scrollerInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        guard !edgeInsets(scrollView.scrollerInsets, equalTo: scrollerInsets) else {
            return
        }

        scrollView.scrollerInsets = scrollerInsets
    }

    private func characterWidth() -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: baseFont]).width
        return width > 0 ? width : basePointSize * 0.6
    }

    private func applyLineMarkerStyle(
        pattern: String, range: NSRange, markerCaptureGroup: Int? = nil
    ) {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.anchorsMatchLines]
        )
        else {
            return
        }

        let string = textStorage.string as NSString
        expression.enumerateMatches(in: textStorage.string, range: range) { match, _, _ in
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
                  markerRange.location + markerRange.length <= string.length
            else {
                return
            }

            textStorage.addAttribute(
                .foregroundColor, value: colors.listMarker, range: markerRange
            )
        }
    }

    private func applyNonbreakingSpaceStyle() {
        let string = textStorage.string as NSString
        var searchRange = NSRange(location: 0, length: string.length)

        while searchRange.length > 0 {
            let range = string.range(of: "\u{00A0}", options: [], range: searchRange)
            guard range.location != NSNotFound else {
                return
            }

            textStorage.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: colors.underline,
                ], range: range
            )

            let nextLocation = range.location + range.length
            searchRange = NSRange(
                location: nextLocation,
                length: string.length - nextLocation
            )
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
