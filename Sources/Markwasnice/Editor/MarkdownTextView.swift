@preconcurrency import AppKit

protocol MarkdownTextViewCommandDelegate: AnyObject {
    func markdownTextViewShowFind(_ textView: NSTextView)
    func markdownTextViewInsertTab(_ textView: NSTextView)
    func markdownTextViewInsertBacktab(_ textView: NSTextView)
    func markdownTextViewContinueMarkdownPrefix(_ textView: NSTextView) -> Bool
    func markdownTextView(
        _ textView: NSTextView, applyMarkup command: MarkdownMarkupCommand
    )
    func markdownTextView(
        _ textView: NSTextView, wrapSelectionWith opening: String, closing: String
    ) -> Bool
    func markdownTextViewDraggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation
    func markdownTextViewPerformDragOperation(
        _ sender: NSDraggingInfo,
        in textView: NSTextView
    ) -> Bool
}

final class MarkdownTextView: NSTextView {
    weak var commandDelegate: MarkdownTextViewCommandDelegate?
    var isWindowPointInTopChrome: ((NSPoint, NSWindow) -> Bool)?
    var topChromeRectProvider: (() -> NSRect?)?
    var onMouseDown: (() -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?

    private static let codeCornerRadius: CGFloat = 3
    private static let codeHorizontalPaddingRatio: CGFloat = 0.02
    private static let codeVerticalPaddingRatio: CGFloat = 0.02

    /// Vertical padding around the text, kept inside the text view (instead
    /// of scroll-view content insets) so the padded areas stay clickable and
    /// the overlay scroller can span the full window height (content insets
    /// offset the scroller and negative scroller insets are clamped).
    /// Implemented with a symmetric textContainerInset of the average value
    /// and a container-origin shift making it asymmetric.
    var topContentPadding: CGFloat = 0 {
        didSet {
            guard topContentPadding != oldValue else {
                return
            }

            needsLayout = true
            needsDisplay = true
        }
    }

    var bottomContentPadding: CGFloat = 0 {
        didSet {
            guard bottomContentPadding != oldValue else {
                return
            }

            needsLayout = true
            needsDisplay = true
        }
    }

    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        origin.y += (topContentPadding - bottomContentPadding) / 2
        return origin
    }

    private(set) var inlineCodeRanges: [NSRange] = []
    private(set) var codeBlockRanges: [NSRange] = []
    private var codeBackgroundGutter: CGFloat = 0
    private var codeBackgroundFillColor: NSColor = .clear

    func setCodeBackgroundRanges(
        inline: [NSRange],
        block: [NSRange],
        gutter: CGFloat,
        fillColor: NSColor
    ) {
        let didChange =
            inline != inlineCodeRanges
                || block != codeBlockRanges
                || gutter != codeBackgroundGutter
                || fillColor != codeBackgroundFillColor
        inlineCodeRanges = inline
        codeBlockRanges = block
        codeBackgroundGutter = gutter
        codeBackgroundFillColor = fillColor
        if didChange {
            needsDisplay = true
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodeBackgrounds(in: rect)
    }

    private func drawCodeBackgrounds(in rect: NSRect) {
        guard codeBackgroundFillColor.alphaComponent > 0,
              !(inlineCodeRanges.isEmpty && codeBlockRanges.isEmpty)
        else {
            return
        }

        let origin = textContainerOrigin
        // Only touch ranges that can intersect the dirty rect; asking the
        // layout manager for geometry of every code range in the document on
        // each repaint is wasted work.
        let visibleRange = characterRange(forViewRect: rect, origin: origin)
        codeBackgroundFillColor.setFill()

        for range in codeBlockRanges
            where visibleRange == nil
            || NSIntersectionRange(range, visibleRange ?? range).length > 0
        {
            drawCodeBlockBackground(range: range, origin: origin, dirtyRect: rect)
        }

        for range in inlineCodeRanges
            where visibleRange == nil
            || NSIntersectionRange(range, visibleRange ?? range).length > 0
        {
            drawInlineCodeBackground(range: range, origin: origin, dirtyRect: rect)
        }
    }

    private func characterRange(
        forViewRect rect: NSRect,
        origin: NSPoint
    ) -> NSRange? {
        guard let layoutManager, let textContainer else {
            return nil
        }

        let containerRect = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: containerRect,
            in: textContainer
        )
        guard glyphRange.location != NSNotFound else {
            return nil
        }

        return layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
    }

    private func drawCodeBlockBackground(
        range: NSRange,
        origin: NSPoint,
        dirtyRect: NSRect
    ) {
        let rects = segmentRects(for: range, origin: origin)
        guard var union = rects.first else {
            return
        }

        for segment in rects.dropFirst() {
            union = union.union(segment)
        }

        guard union.intersects(dirtyRect) else {
            return
        }

        let containerWidth = textContainer?.size.width ?? bounds.width
        let left = origin.x + codeBackgroundGutter
        let right = origin.x + containerWidth - codeBackgroundGutter
        let width = right > left ? right - left : union.width
        let blockRect = NSRect(
            x: right > left ? left : union.minX,
            y: union.minY,
            width: width,
            height: union.height
        )
        NSBezierPath(
            roundedRect: blockRect,
            xRadius: Self.codeCornerRadius,
            yRadius: Self.codeCornerRadius
        ).fill()
    }

    private func drawInlineCodeBackground(
        range: NSRange,
        origin: NSPoint,
        dirtyRect: NSRect
    ) {
        for segment in inlineLineRects(for: range, origin: origin)
            where segment.intersects(dirtyRect)
        {
            let horizontalPadding = segment.height * Self.codeHorizontalPaddingRatio
            let padded = segment.insetBy(dx: -horizontalPadding, dy: 0)
            NSBezierPath(
                roundedRect: padded, xRadius: Self.codeCornerRadius,
                yRadius: Self.codeCornerRadius
            )
            .fill()
        }
    }

    /// One rect per visual line, hugging the glyphs vertically. The enclosing
    /// rects from segmentRects(for:origin:) are unsuitable for inline code:
    /// they span the full fragment height (the fixed 1.8x line height leaves
    /// large gaps above and below the text) and merge the middle lines of a
    /// wrapped range into a single full-width block.
    private func inlineLineRects(for range: NSRange, origin: NSPoint) -> [NSRect] {
        guard let layoutManager, let textContainer, let textStorage,
              range.location >= 0,
              NSMaxRange(range) <= textStorage.length
        else {
            return []
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
            return []
        }

        var rects: [NSRect] = []
        layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { fragmentRect, _, _, lineGlyphRange, _ in
            let lineRange = NSIntersectionRange(lineGlyphRange, glyphRange)
            guard lineRange.length > 0 else {
                return
            }

            let bounds = layoutManager.boundingRect(
                forGlyphRange: lineRange,
                in: textContainer
            )
            guard !bounds.isEmpty else {
                return
            }

            let characterIndex = layoutManager.characterIndexForGlyph(
                at: lineRange.location
            )
            let font =
                textStorage.attribute(
                    .font, at: characterIndex, effectiveRange: nil
                ) as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let baseline =
                fragmentRect.minY
                    + layoutManager.location(forGlyphAt: lineRange.location).y
            let verticalPadding = font.ascender * Self.codeVerticalPaddingRatio
            rects.append(
                NSRect(
                    x: bounds.minX,
                    y: baseline - font.ascender - verticalPadding,
                    width: bounds.width,
                    height: font.ascender - font.descender
                        + 2 * verticalPadding
                ).offsetBy(dx: origin.x, dy: origin.y)
            )
        }
        return rects
    }

    private func segmentRects(for range: NSRange, origin: NSPoint) -> [NSRect] {
        guard let layoutManager, let textContainer,
              let storageLength = textStorage?.length,
              range.location >= 0,
              NSMaxRange(range) <= storageLength
        else {
            return []
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
            return []
        }

        var rects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            if !rect.isEmpty {
                rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        return rects
    }

    override func resetCursorRects() {
        guard let window,
              let contentView = window.contentView,
              let chromeRectInContentView = topChromeRectProvider?()
        else {
            addCursorRect(visibleRect, cursor: .iBeam)
            return
        }

        let blocked = visibleRect.intersection(
            convert(chromeRectInContentView, from: contentView)
        )
        guard !blocked.isNull, !blocked.isEmpty else {
            addCursorRect(visibleRect, cursor: .iBeam)
            return
        }

        for rect in cursorRects(visible: visibleRect, excluding: blocked)
            where !rect.isEmpty
        {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        if eventIsInTopChrome(event) {
            NSCursor.arrow.set()
            return
        }

        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if eventIsInTopChrome(event) {
            NSCursor.arrow.set()
            return
        }

        super.mouseEntered(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if eventIsInTopChrome(event) {
            NSCursor.arrow.set()
            return
        }

        super.cursorUpdate(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isFindShortcut(event) {
            commandDelegate?.markdownTextViewShowFind(self)
            return
        }

        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else {
            super.keyDown(with: event)
            return
        }

        switch event.charactersIgnoringModifiers {
        case "\t":
            if event.modifierFlags.contains(.shift) {
                commandDelegate?.markdownTextViewInsertBacktab(self)
            } else {
                commandDelegate?.markdownTextViewInsertTab(self)
            }
        case "\u{19}": // Shift+Tab arrives as a backtab character.
            commandDelegate?.markdownTextViewInsertBacktab(self)
        case "\r", "\n":
            if commandDelegate?.markdownTextViewContinueMarkdownPrefix(self) != true {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseDown?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, selectedRange().length > 0 else {
            return menu
        }

        menu.insertItem(submenuItem(title: "Style", menu: styleMenu()), at: 0)
        menu.insertItem(submenuItem(title: "Copy as", menu: copyAsMenu()), at: 1)
        menu.insertItem(NSMenuItem.separator(), at: 2)
        return menu
    }

    private func styleMenu() -> NSMenu {
        let menu = NSMenu(title: "Style")
        let commands: [(String, MarkdownMarkupCommand)] = [
            ("Bold", .bold),
            ("Italic", .italic),
            ("Code", .code),
        ]
        for (title, command) in commands {
            let item = NSMenuItem(
                title: title,
                action: #selector(applyStyleMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = command.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func copyAsMenu() -> NSMenu {
        let menu = NSMenu(title: "Copy as")

        let plainText = NSMenuItem(
            title: "Plain Text",
            action: #selector(copySelectionAsPlainText),
            keyEquivalent: ""
        )
        plainText.target = self
        menu.addItem(plainText)

        let telegram = NSMenuItem(
            title: "Telegram",
            action: #selector(copySelectionAsTelegram),
            keyEquivalent: ""
        )
        telegram.target = self
        menu.addItem(telegram)

        return menu
    }

    private func submenuItem(title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @objc private func applyStyleMenuItem(_ sender: NSMenuItem) {
        guard let command = MarkdownMarkupCommand(rawValue: sender.tag) else {
            return
        }

        commandDelegate?.markdownTextView(self, applyMarkup: command)
    }

    @objc private func copySelectionAsPlainText() {
        copySelection(as: .plainText)
    }

    @objc private func copySelectionAsTelegram() {
        copySelection(as: .telegram)
    }

    private func copySelection(as format: MarkdownCopyFormat) {
        let range = selectedRange()
        guard range.length > 0 else {
            return
        }

        let markdown = (string as NSString).substring(with: range)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(format.convert(markdown), forType: .string)
    }

    /// AppKit disables responsive (asynchronous, pre-rendered) scrolling for
    /// any view that overrides scrollWheel(with:). Our override only observes
    /// the event and always calls super, so it is safe to opt back in — losing
    /// responsive scrolling makes every frame draw synchronously and visibly
    /// drops scroll FPS on large documents.
    override static var isCompatibleWithResponsiveScrolling: Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        // A manual scroll takes over from any in-flight caret scroll.
        caretScrollAnimator.cancel()
        onScrollWheel?(event)
        super.scrollWheel(with: event)
    }

    /// Keyboard-driven caret scrolls go through the system smooth-scroll
    /// animation (NSScrollAnimationHelper). Under key auto-repeat a new
    /// animation starts on every repeat while the previous one is still
    /// running, and the overlapping animations fight over the clip origin —
    /// the scroll visibly bounces backwards each frame. Those scrolls are
    /// handled here instead, bypassing the system pass entirely, with a
    /// retargetable display-link animator (see CaretScrollAnimator).
    override func scrollRangeToVisible(_ range: NSRange) {
        if NSApp.currentEvent?.type == .keyDown {
            // In focus/typewriter mode the editor's caret centering owns the
            // scroll position; the minimal-visibility scroll would only fight
            // with it.
            guard !skipsKeyboardCaretScrolling else {
                return
            }

            if let rect = caretLineScrollRect(for: range),
               scrollCaretLineRectIntoView(rect)
            {
                return
            }
        }

        super.scrollRangeToVisible(range)
    }

    /// Set while the editor's focus-mode centering drives the scroll
    /// position on every caret move.
    var skipsKeyboardCaretScrolling = false

    private let caretScrollAnimator = CaretScrollAnimator()

    func cancelKeyboardCaretScroll() {
        caretScrollAnimator.cancel()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            caretScrollAnimator.cancel()
        }
    }

    /// Minimal scroll that puts the caret line inside the viewport with a
    /// one-line margin. Returns false when the scroll could not be handled
    /// and the caller must fall back to the system path.
    private func scrollCaretLineRectIntoView(_ rect: NSRect) -> Bool {
        guard let scrollView = enclosingScrollView else {
            return false
        }

        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        let margin = scrollView.lineScroll
        let target = rect.insetBy(dx: 0, dy: -margin)

        // While an animated scroll is in flight the clip origin lags behind
        // the target; computing from the final target keeps successive key
        // repeats from re-deriving (and jittering around) the same goal.
        let currentOffsetY = caretScrollAnimator.isAnimating
            ? caretScrollAnimator.targetOffsetY
            : clipBounds.origin.y

        var offsetY = currentOffsetY
        if target.minY < offsetY {
            offsetY = target.minY
        } else if target.maxY > offsetY + clipBounds.height {
            offsetY = target.maxY - clipBounds.height
        }

        let insets = scrollView.contentInsets
        let minimumOffsetY = -insets.top
        let maximumOffsetY = max(
            minimumOffsetY,
            frame.height - clipBounds.height + insets.bottom
        )
        offsetY = min(max(offsetY, minimumOffsetY), maximumOffsetY)
        guard abs(offsetY - currentOffsetY) > 0.5 else {
            return true
        }

        caretScrollAnimator.scroll(scrollView, toOffsetY: offsetY)
        return true
    }

    /// The line-fragment rect (in view coordinates) of the moving end of the
    /// given range — the end the caret is at during keyboard navigation.
    private func caretLineScrollRect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer, let textStorage else {
            return nil
        }

        let origin = textContainerOrigin
        let length = textStorage.length
        let location = min(
            selectionAffinity == .upstream ? range.location : NSMaxRange(range),
            length
        )

        var rect: NSRect
        if location == length,
           length == 0 || layoutManager.extraLineFragmentTextContainer === textContainer,
           layoutManager.extraLineFragmentRect.height > 0
        {
            rect = layoutManager.extraLineFragmentRect
        } else if length > 0 {
            let glyphIndex = layoutManager
                .glyphIndexForCharacter(at: min(location, length - 1))
            guard glyphIndex < layoutManager.numberOfGlyphs else {
                return nil
            }

            rect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
        } else {
            return nil
        }

        // Only vertical visibility matters for the caret line; pinning x to
        // the current viewport avoids any horizontal jump.
        rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        rect.origin.x = visibleRect.origin.x
        rect.size.width = 1
        return rect
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if selectedRange().length > 0,
           let string = plainString(from: insertString),
           let pair = pairSymbol(for: string),
           commandDelegate?.markdownTextView(
               self, wrapSelectionWith: pair.opening, closing: pair.closing
           ) == true
        {
            return
        }

        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        commandDelegate?.markdownTextViewDraggingEntered(sender) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        commandDelegate?.markdownTextViewPerformDragOperation(sender, in: self) ?? false
    }

    private func plainString(from insertString: Any) -> String? {
        if let string = insertString as? String {
            return string
        }

        return (insertString as? NSAttributedString)?.string
    }

    private func isFindShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == .command && event.charactersIgnoringModifiers == "f"
    }

    private func eventIsInTopChrome(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? window else {
            return false
        }

        return isWindowPointInTopChrome?(event.locationInWindow, window) == true
    }

    private func cursorRects(visible: NSRect, excluding blocked: NSRect) -> [NSRect] {
        let blocked = visible.intersection(blocked)
        guard !blocked.isNull, !blocked.isEmpty else {
            return [visible]
        }

        var rects: [NSRect] = []
        if blocked.minY > visible.minY {
            rects.append(
                NSRect(
                    x: visible.minX,
                    y: visible.minY,
                    width: visible.width,
                    height: blocked.minY - visible.minY
                )
            )
        }
        if blocked.maxY < visible.maxY {
            rects.append(
                NSRect(
                    x: visible.minX,
                    y: blocked.maxY,
                    width: visible.width,
                    height: visible.maxY - blocked.maxY
                )
            )
        }
        if blocked.minX > visible.minX {
            rects.append(
                NSRect(
                    x: visible.minX,
                    y: blocked.minY,
                    width: blocked.minX - visible.minX,
                    height: blocked.height
                )
            )
        }
        if blocked.maxX < visible.maxX {
            rects.append(
                NSRect(
                    x: blocked.maxX,
                    y: blocked.minY,
                    width: visible.maxX - blocked.maxX,
                    height: blocked.height
                )
            )
        }
        return rects
    }

    private func pairSymbol(for string: String) -> (opening: String, closing: String)? {
        switch string {
        case "\"":
            return ("\"", "\"")
        case "'":
            return ("'", "'")
        case "`":
            return ("`", "`")
        case "*":
            return ("*", "*")
        case "(":
            return ("(", ")")
        case "[":
            return ("[", "]")
        case "{":
            return ("{", "}")
        case "~":
            return ("~", "~")
        case "«":
            return ("«", "»")
        case "“":
            return ("“", "”")
        case "„":
            return ("„", "“")
        default:
            return nil
        }
    }
}
