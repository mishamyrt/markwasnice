import AppKit

@MainActor
protocol MarkdownEditorViewDelegate: AnyObject {
    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView)
}

@MainActor
final class MarkdownEditorView: NSView, NSTextViewDelegate {
    weak var delegate: MarkdownEditorViewDelegate?

    private let scrollView = NSScrollView()
    private let textStorage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(
        containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private let textView: NSTextView
    private var isApplyingStyles = false
    private var settings: EditorSettings
    private var themeColors = EditorThemeColors.default
    private var currentStyleSpans: [ResolvedMarkdownStyleSpan] = []

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

        textView = NSTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: frameRect)

        configureTextView()
        configureScrollView()

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
        updateTextContainerInset()
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
        let selectedRanges = textView.selectedRanges
        let visibleOrigin = scrollView.contentView.bounds.origin
        let orderedSpans = orderedForVisibleRange(spans)

        isApplyingStyles = true
        textView.undoManager?.disableUndoRegistration()
        textStorage.beginEditing()
        applyBaseStyleToText()

        for span in orderedSpans {
            applyStyle(span.kind, range: span.range)
        }

        textStorage.endEditing()
        textView.undoManager?.enableUndoRegistration()
        isApplyingStyles = false

        restoreSelectionAndScroll(selectedRanges: selectedRanges, visibleOrigin: visibleOrigin)
        updateTypingAttributesAtSelection(spans: spans)
    }

    func applySettings(_ settings: EditorSettings, spans: [ResolvedMarkdownStyleSpan]) {
        self.settings = settings
        updateTextContainerInset()
        applyStyles(spans)
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingStyles else {
            return
        }

        delegate?.markdownEditorViewDidChangeText(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureScrollView() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = colors.background
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 160, right: 0)
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureTextView() {
        textView.delegate = self
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
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
            attributes, range: NSRange(location: 0, length: textStorage.length))
    }

    private var baseFont: NSFont {
        LilexFontProvider.regular(size: settings.basePointSize)
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = settings.lineHeight
        paragraphStyle.maximumLineHeight = settings.lineHeight

        return [
            .font: baseFont,
            .foregroundColor: colors.foreground,
            .paragraphStyle: paragraphStyle,
        ]
    }

    private var colors: EditorThemeColors.Variant {
        themeColors.variant(for: effectiveAppearance)
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
        case .heading(_):
            attributes[.font] = font(
                from: attributes, adding: .boldFontMask)
        case .strong:
            attributes[.font] = font(from: attributes, adding: .boldFontMask)
        case .emphasis:
            attributes[.font] = font(from: attributes, adding: .italicFontMask)
            attributes[.foregroundColor] = colors.emphasis
        case .inlineCode:
            attributes[.font] = LilexFontProvider.regular(size: currentPointSize(from: attributes))
            attributes[.backgroundColor] = colors.codeBackground
            attributes[.foregroundColor] = colors.codeForeground
        case .codeBlock:
            attributes[.font] = LilexFontProvider.regular(size: currentPointSize(from: attributes))
            attributes[.backgroundColor] = colors.codeBackground
            attributes[.foregroundColor] = colors.codeForeground
        case .link:
            attributes[.foregroundColor] = colors.linkText
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        case .image:
            attributes[.foregroundColor] = colors.image
        case .blockQuote:
            attributes[.foregroundColor] = colors.quote
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
        return LilexFontProvider.font(size: targetSize, traits: existingTraits.union(traits))
    }

    private func currentPointSize(from attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        (attributes[.font] as? NSFont)?.pointSize ?? baseFont.pointSize
    }

    private func applyStyle(_ kind: MarkdownStyleKind, range: NSRange) {
        guard let range = boundedRange(range), range.length > 0 else {
            return
        }

        switch kind {
        case .heading(_):
            addFontTraits(.boldFontMask, range: range)
        case .strong:
            addFontTraits(.boldFontMask, range: range)
        case .emphasis:
            addFontTraits(.italicFontMask, range: range)
            textStorage.addAttribute(.foregroundColor, value: colors.emphasis, range: range)
        case .inlineCode:
            setMonospaceFont(range: range)
            textStorage.addAttributes(
                [
                    .backgroundColor: colors.codeBackground,
                    .foregroundColor: colors.codeForeground,
                ], range: range)
        case .codeBlock:
            setMonospaceFont(range: range)
            textStorage.addAttributes(
                [
                    .backgroundColor: colors.codeBackground,
                    .foregroundColor: colors.codeForeground,
                ], range: range)
        case .link:
            textStorage.addAttributes(
                [
                    .foregroundColor: colors.linkText,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: range)
        case .image:
            textStorage.addAttribute(.foregroundColor, value: colors.image, range: range)
        case .blockQuote:
            textStorage.addAttribute(
                .foregroundColor, value: colors.quote, range: range)
            applyLineMarkerStyle(pattern: "^\\s*>", range: range)
        case .orderedList, .unorderedList:
            applyLineMarkerStyle(pattern: "^\\s*(?:[-+*]|\\d+[.)])\\s+", range: range)
        case .thematicBreak:
            textStorage.addAttribute(
                .foregroundColor, value: colors.thematicBreak, range: range)
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
            forBoundingRect: textView.visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil)
        return characterRange.length > 0 ? characterRange : nil
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

    private func addFontTraits(_ traits: NSFontTraitMask, size: CGFloat? = nil, range: NSRange) {
        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let currentFont = value as? NSFont ?? baseFont
            let existingTraits = NSFontManager.shared.traits(of: currentFont)
            let convertedFont = LilexFontProvider.font(
                size: size ?? currentFont.pointSize, traits: existingTraits.union(traits))
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

    private func updateTextContainerInset() {
        let minimumHorizontalInset: CGFloat = 28
        let availableWidth =
            scrollView.contentView.bounds.width > 0
            ? scrollView.contentView.bounds.width : bounds.width
        let targetWidth = characterWidth() * CGFloat(settings.maxTextColumns)
        let horizontalInset = max(minimumHorizontalInset, floor((availableWidth - targetWidth) / 2))
        textView.textContainerInset = NSSize(width: horizontalInset, height: 24)
    }

    private func restoreSelectionAndScroll(selectedRanges: [NSValue], visibleOrigin: NSPoint) {
        textView.selectedRanges = selectedRanges
        layoutManager.ensureLayout(for: textContainer)

        let clipView = scrollView.contentView
        let documentBounds = scrollView.documentView?.bounds ?? .zero
        let maxOriginX = max(0, documentBounds.maxX - clipView.bounds.width)
        let maxOriginY = max(0, documentBounds.maxY - clipView.bounds.height)
        let clampedOrigin = NSPoint(
            x: min(max(visibleOrigin.x, 0), maxOriginX),
            y: min(max(visibleOrigin.y, 0), maxOriginY)
        )

        clipView.scroll(to: clampedOrigin)
        scrollView.reflectScrolledClipView(clipView)
    }

    private func characterWidth() -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: baseFont]).width
        return width > 0 ? width : settings.basePointSize * 0.6
    }

    private func applyLineMarkerStyle(pattern: String, range: NSRange) {
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern, options: [.anchorsMatchLines])
        else {
            return
        }

        let string = textStorage.string as NSString
        expression.enumerateMatches(in: textStorage.string, range: range) { match, _, _ in
            guard let markerRange = match?.range,
                markerRange.location != NSNotFound,
                markerRange.location + markerRange.length <= string.length
            else {
                return
            }

            textStorage.addAttribute(
                .foregroundColor, value: colors.listMarker, range: markerRange)
        }
    }
}
