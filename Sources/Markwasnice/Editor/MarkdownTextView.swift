@preconcurrency import AppKit

protocol MarkdownTextViewCommandDelegate: AnyObject {
    func markdownTextViewShowFind(_ textView: NSTextView)
    func markdownTextViewInsertTab(_ textView: NSTextView)
    func markdownTextViewContinueMarkdownPrefix(_ textView: NSTextView) -> Bool
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

    private static let blockCornerRadius: CGFloat = 6
    private static let inlineCornerRadiusScale: CGFloat = 0.3
    private static let inlineHorizontalPadding: CGFloat = 3

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
        let didChange = inline != inlineCodeRanges
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
            xRadius: Self.blockCornerRadius,
            yRadius: Self.blockCornerRadius
        ).fill()
    }

    private func drawInlineCodeBackground(
        range: NSRange,
        origin: NSPoint,
        dirtyRect: NSRect
    ) {
        for segment in segmentRects(for: range, origin: origin)
            where segment.intersects(dirtyRect)
        {
            let padded = segment.insetBy(dx: -Self.inlineHorizontalPadding, dy: 0)
            let radius = min(
                padded.height * Self.inlineCornerRadiusScale,
                padded.height / 2
            )
            NSBezierPath(roundedRect: padded, xRadius: radius, yRadius: radius).fill()
        }
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
            commandDelegate?.markdownTextViewInsertTab(self)
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

    // AppKit disables responsive (asynchronous, pre-rendered) scrolling for
    // any view that overrides scrollWheel(with:). Our override only observes
    // the event and always calls super, so it is safe to opt back in — losing
    // responsive scrolling makes every frame draw synchronously and visibly
    // drops scroll FPS on large documents.
    override static var isCompatibleWithResponsiveScrolling: Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?(event)
        super.scrollWheel(with: event)
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
            rects.append(NSRect(
                x: visible.minX,
                y: visible.minY,
                width: visible.width,
                height: blocked.minY - visible.minY
            ))
        }
        if blocked.maxY < visible.maxY {
            rects.append(NSRect(
                x: visible.minX,
                y: blocked.maxY,
                width: visible.width,
                height: visible.maxY - blocked.maxY
            ))
        }
        if blocked.minX > visible.minX {
            rects.append(NSRect(
                x: visible.minX,
                y: blocked.minY,
                width: blocked.minX - visible.minX,
                height: blocked.height
            ))
        }
        if blocked.maxX < visible.maxX {
            rects.append(NSRect(
                x: blocked.maxX,
                y: blocked.minY,
                width: visible.maxX - blocked.maxX,
                height: blocked.height
            ))
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
