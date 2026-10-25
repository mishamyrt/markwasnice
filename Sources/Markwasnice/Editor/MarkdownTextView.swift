@preconcurrency import AppKit

protocol MarkdownTextViewCommandDelegate: AnyObject {
    func markdownTextViewShowFind(_ textView: NSTextView)
    func markdownTextViewInsertTab(_ textView: NSTextView)
    func markdownTextViewInsertBacktab(_ textView: NSTextView)
    func markdownTextView(
        _ textView: NSTextView,
        moveLines command: MarkdownLineMoveCommand
    )
    func markdownTextViewContinueMarkdownPrefix(
        _ textView: NSTextView,
        continuingItem: Bool
    ) -> Bool
    func markdownTextView(
        _ textView: NSTextView, applyMarkup command: MarkdownMarkupCommand
    )
    func markdownTextViewRequestInsertTable(_ textView: NSTextView)
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
    private(set) var keyDownModifiers: NSEvent.ModifierFlags = []
    var isWindowPointInTopChrome: ((NSPoint, NSWindow) -> Bool)?
    var topChromeRectProvider: (() -> NSRect?)?
    var onMouseDown: (() -> Void)?
    var onSelectionAutoscroll: (() -> Void)?
    var onScrollWheel: ((NSEvent) -> Void)?
    var pasteboardForPaste: () -> NSPasteboard = { .general }
    var convertDeferredPaste: @Sendable (
        RichTextMarkdownConverter.DeferredPaste
    ) async -> String? = { paste in
        let task = Task.detached(priority: .userInitiated) {
            RichTextMarkdownConverter.convertDeferredPaste(paste)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private var deferredPasteTask: Task<Void, Never>?
    private var pasteRequestGeneration = 0
    private var contentRevision = 0
    private var selectionRevision = 0
    private var selectionHeadAtStart = false

    private var pendingAnimatedSelectionRevision: Int?
    private var insertionPointContentRevision = 0
    private var insertionPointRect: NSRect?
    private var insertionPointUpdatePending = false
    private static let insertionPointAnimationDuration: TimeInterval = 0.03
    private var insertionPointDisplayLink: CADisplayLink?
    private var insertionPointAnimation: (from: NSRect, startTime: TimeInterval)?

    var isInsertionPointAnimating: Bool {
        insertionPointAnimation != nil
    }

    private lazy var insertionIndicatorContainer: NSView = {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        addSubview(view)
        return view
    }()

    private lazy var insertionIndicator: NSTextInsertionIndicator = {
        let indicator = NSTextInsertionIndicator(frame: .zero)
        indicator.displayMode = .hidden
        indicator.automaticModeOptions.insert(.showWhileTracking)
        insertionIndicatorContainer.addSubview(indicator)
        return indicator
    }()

    override var shouldDrawInsertionPoint: Bool {
        false
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Caret geometry and view updates must happen outside the render pass.
        guard !insertionPointUpdatePending else {
            return
        }
        insertionPointUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            insertionPointUpdatePending = false
            updateInsertionPoint()
        }
    }

    private func updateInsertionPoint() {
        guard let window, window.isKeyWindow,
              window.firstResponder === self, isEditable,
              selectedRanges.count == 1
        else {
            resetInsertionPointAnimation()
            return
        }

        // The legacy drawInsertionPoint hook is not called on recent macOS.
        // Ask text input for the laid-out caret rect, including bidi and IME.
        updateInsertionIndicator(
            in: currentInsertionPointRect(in: window),
            color: insertionPointColor
        )
    }

    private func currentInsertionPointRect(in window: NSWindow) -> NSRect {
        let selection = selectedRange()
        let location = selectionHeadAtStart
            ? selection.location : NSMaxRange(selection)
        let screenRect = firstRect(
            forCharacterRange: NSRange(location: location, length: 0),
            actualRange: nil
        )
        var rect = convert(window.convertFromScreen(screenRect), from: nil)
        rect.size.width = 2
        return rect
    }

    func updateInsertionIndicator(
        in rect: NSRect,
        color: NSColor
    ) {
        let previousRect = insertionPointRect
        let shouldAnimate = pendingAnimatedSelectionRevision == selectionRevision
            || insertionPointContentRevision != contentRevision
        insertionPointContentRevision = contentRevision
        pendingAnimatedSelectionRevision = nil
        insertionPointRect = rect
        let indicator = insertionIndicator
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.color = color
        if indicator.displayMode != .automatic {
            indicator.displayMode = .automatic
        }
        CATransaction.commit()

        guard previousRect != rect else { return }

        if shouldAnimate,
           previousRect != nil,
           !hasMarkedText(),
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
            insertionPointAnimation = (
                insertionIndicatorContainer.frame,
                CACurrentMediaTime()
            )
            if insertionPointDisplayLink == nil {
                let link = displayLink(
                    target: self,
                    selector: #selector(updateInsertionPointAnimation(_:))
                )
                link.add(to: .main, forMode: .common)
                insertionPointDisplayLink = link
            }
        } else {
            stopInsertionPointAnimation()
            applyInsertionPointFrame(rect)
        }
    }

    private func stopInsertionPointAnimation() {
        insertionPointDisplayLink?.invalidate()
        insertionPointDisplayLink = nil
        insertionPointAnimation = nil
    }

    private func resetInsertionPointAnimation() {
        stopInsertionPointAnimation()
        pendingAnimatedSelectionRevision = nil
        insertionPointRect = nil
        insertionIndicator.displayMode = .hidden
    }

    @objc private func updateInsertionPointAnimation(_ link: CADisplayLink) {
        guard window?.isKeyWindow == true, window?.firstResponder === self else {
            resetInsertionPointAnimation()
            return
        }
        if insertionPointContentRevision != contentRevision {
            updateInsertionPoint()
        }
        advanceInsertionPointAnimation(at: link.targetTimestamp)
    }

    func advanceInsertionPointAnimation(at timestamp: TimeInterval) {
        guard let animation = insertionPointAnimation,
              let target = insertionPointRect else { return }
        let elapsed = timestamp - animation.startTime
        var progress = min(1, max(0, elapsed / Self.insertionPointAnimationDuration))
        if hasMarkedText() || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            progress = 1
        }
        let start = animation.from.origin
        var rect = target
        rect.origin.x = start.x + (target.minX - start.x) * progress
        rect.origin.y = start.y + (target.minY - start.y) * progress
        if progress == 1 {
            stopInsertionPointAnimation()
        }
        applyInsertionPointFrame(rect)
    }

    private func applyInsertionPointFrame(_ rect: NSRect) {
        // Move only the indicator; AppKit owns its blinking and text rendering.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insertionIndicatorContainer.frame = rect
        insertionIndicator.frame = insertionIndicatorContainer.bounds
        CATransaction.commit()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            resetInsertionPointAnimation()
        }
        return resigned
    }

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

    // Repainting only the ranges that changed looks tempting here and is
    // wrong: it assumes an unchanged range still covers the same pixels. Any
    // edit can reflow the layout, so a decoration that kept its range can
    // still have moved, and the rect it was painted at is unrecoverable once
    // layout has run — the old paint stays on screen as a ghost. Making it
    // correct means diffing painted *rects* against the previous frame's,
    // not ranges.

    private var searchBorderRanges: [NSRange] = []
    private var searchSelectedMatchRange: NSRange?
    private var searchMatchBorderColor: NSColor = .clear
    private var searchMatchFillColor: NSColor = .clear

    func setSearchMatchDecorations(
        borderRanges: [NSRange],
        selectedRange: NSRange?,
        borderColor: NSColor,
        fillColor: NSColor
    ) {
        let didChange =
            borderRanges != searchBorderRanges
                || selectedRange != searchSelectedMatchRange
                || borderColor != searchMatchBorderColor
                || fillColor != searchMatchFillColor
        searchBorderRanges = borderRanges
        searchSelectedMatchRange = selectedRange
        searchMatchBorderColor = borderColor
        searchMatchFillColor = fillColor
        if didChange {
            needsDisplay = true
        }
    }

    struct ProofreadingDrawItem: Equatable {
        let range: NSRange
        let color: NSColor
    }

    private var proofreadingUnderlines: [ProofreadingDrawItem] = []
    private var proofreadingHighlights: [ProofreadingDrawItem] = []

    func setProofreadingDecorations(
        underlines: [ProofreadingDrawItem],
        highlights: [ProofreadingDrawItem]
    ) {
        let didChange = underlines != proofreadingUnderlines
            || highlights != proofreadingHighlights
        proofreadingUnderlines = underlines
        proofreadingHighlights = highlights
        if didChange {
            needsDisplay = true
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodeBackgrounds(in: rect)
        drawProofreadingDecorations(in: rect)
        drawSearchMatchDecorations(in: rect)
    }

    private static let searchMatchCornerRadius: CGFloat = 2
    private static let searchMatchHorizontalPadding: CGFloat = 1.5
    private static let searchMatchVerticalPadding: CGFloat = 5

    private func drawSearchMatchDecorations(in rect: NSRect) {
        guard searchSelectedMatchRange != nil || !searchBorderRanges.isEmpty
        else {
            return
        }

        let origin = textContainerOrigin
        // Decorations reach beyond their glyphs; when a scroll exposes just
        // that overhang, the dirty rect alone would miss the match's glyphs
        // and leave the border edge unpainted until the next full redraw.
        let reach = Self.searchMatchVerticalPadding + 1
        let queryRect = rect.insetBy(
            dx: -(Self.searchMatchHorizontalPadding + 1),
            dy: -reach
        )
        let visibleRange = characterRange(forViewRect: queryRect, origin: origin)

        searchMatchBorderColor.setStroke()
        for range in searchBorderRanges
            where Self.range(range, mayBeVisibleIn: visibleRange)
        {
            for segment in inlineLineRects(for: range, origin: origin) {
                let padded = segment.insetBy(
                    dx: -Self.searchMatchHorizontalPadding,
                    dy: -Self.searchMatchVerticalPadding
                )
                guard padded.intersects(rect) else {
                    continue
                }

                // The half-point inset keeps the 1pt stroke on pixel
                // boundaries instead of blurring across two rows.
                let path = NSBezierPath(
                    roundedRect: padded.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: Self.searchMatchCornerRadius,
                    yRadius: Self.searchMatchCornerRadius
                )
                path.lineWidth = 1
                path.stroke()
            }
        }

        if let selectedRange = searchSelectedMatchRange,
           Self.range(selectedRange, mayBeVisibleIn: visibleRange)
        {
            searchMatchFillColor.setFill()
            for segment in inlineLineRects(for: selectedRange, origin: origin) {
                let padded = segment.insetBy(
                    dx: -Self.searchMatchHorizontalPadding,
                    dy: -Self.searchMatchVerticalPadding
                )
                guard padded.intersects(rect) else {
                    continue
                }

                NSBezierPath(
                    roundedRect: padded,
                    xRadius: Self.searchMatchCornerRadius,
                    yRadius: Self.searchMatchCornerRadius
                ).fill()
            }
        }
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
            where Self.range(range, mayBeVisibleIn: visibleRange)
        {
            drawCodeBlockBackground(range: range, origin: origin, dirtyRect: rect)
        }

        for range in inlineCodeRanges
            where Self.range(range, mayBeVisibleIn: visibleRange)
        {
            drawInlineCodeBackground(range: range, origin: origin, dirtyRect: rect)
        }
    }

    /// Whether a decoration range can reach the character range a dirty rect
    /// maps to. A nil `visibleRange` means the mapping failed (no layout
    /// manager, or an empty glyph range) and nothing may be culled.
    private static func range(
        _ range: NSRange,
        mayBeVisibleIn visibleRange: NSRange?
    ) -> Bool {
        guard let visibleRange else {
            return true
        }

        return NSIntersectionRange(range, visibleRange).length > 0
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
        // Tested against the band, not against the glyph rects it is derived
        // from: the band reaches out to the gutter on both sides, and a dirty
        // rect covering only that margin still has to be filled.
        guard let blockRect = codeBlockRect(for: range, origin: origin),
              blockRect.intersects(dirtyRect)
        else {
            return
        }

        NSBezierPath(
            roundedRect: blockRect,
            xRadius: Self.codeCornerRadius,
            yRadius: Self.codeCornerRadius
        ).fill()
    }

    /// The filled band of a code block: the block's vertical extent stretched
    /// to the container width minus the gutter. Shared with the invalidation
    /// path so a repaint is asked for exactly what gets drawn.
    private func codeBlockRect(for range: NSRange, origin: NSPoint) -> NSRect? {
        guard let layoutManager,
              let storageLength = textStorage?.length,
              range.location >= 0,
              NSMaxRange(range) <= storageLength
        else {
            return nil
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
            return nil
        }

        // Only the top and bottom of the band are read from layout — the
        // width comes from the container below — so the first and last line
        // fragments answer the question on their own. Enumerating every
        // fragment of a thousand-line block would cost the same rect once per
        // scroll frame.
        let first = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        let last = layoutManager.lineFragmentRect(
            forGlyphAt: NSMaxRange(glyphRange) - 1,
            effectiveRange: nil
        )
        let union = first.union(last).offsetBy(dx: origin.x, dy: origin.y)

        let containerWidth = textContainer?.size.width ?? bounds.width
        let left = origin.x + codeBackgroundGutter
        let right = origin.x + containerWidth - codeBackgroundGutter
        let width = right > left ? right - left : union.width
        return NSRect(
            x: right > left ? left : union.minX,
            y: union.minY,
            width: width,
            height: union.height
        )
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

    /// One rect per visual line, hugging the glyphs vertically. The layout
    /// manager's own enclosing rects are unsuitable for inline code: they span
    /// the full fragment height (the fixed 1.8x line height leaves large gaps
    /// above and below the text) and merge the middle lines of a wrapped range
    /// into a single full-width block.
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

    private static let proofreadingWaveAmplitude: CGFloat = 1.25
    private static let proofreadingWaveLength: CGFloat = 12
    private static let proofreadingWaveOffset: CGFloat = 7
    private static let proofreadingWaveLineWidth: CGFloat = 1.5
    private static let proofreadingHighlightCornerRadius: CGFloat = 3

    /// The wave metrics above were tuned for the default body font. The line
    /// thickness and its baseline offset scale with the current font size so
    /// the squiggle keeps the same visual weight at any text size.
    private static let proofreadingReferenceFontSize: CGFloat = 20

    private var proofreadingScale: CGFloat {
        (font?.pointSize ?? Self.proofreadingReferenceFontSize)
            / Self.proofreadingReferenceFontSize
    }

    private func drawProofreadingDecorations(in rect: NSRect) {
        guard !(proofreadingUnderlines.isEmpty && proofreadingHighlights.isEmpty)
        else {
            return
        }

        let origin = textContainerOrigin
        let waveReach = Self.proofreadingWaveOffset * proofreadingScale
            + Self.proofreadingWaveAmplitude + 2
        let queryRect = NSRect(
            x: rect.minX,
            y: rect.minY - waveReach,
            width: rect.width,
            height: rect.height + waveReach
        )
        let visibleRange = characterRange(forViewRect: queryRect, origin: origin)

        for item in proofreadingHighlights
            where Self.range(item.range, mayBeVisibleIn: visibleRange)
        {
            item.color.setFill()
            for segment in inlineLineRects(for: item.range, origin: origin)
                where segment.intersects(rect)
            {
                let padding = segment.height * Self.codeHorizontalPaddingRatio
                NSBezierPath(
                    roundedRect: segment.insetBy(dx: -padding, dy: 0),
                    xRadius: Self.proofreadingHighlightCornerRadius,
                    yRadius: Self.proofreadingHighlightCornerRadius
                ).fill()
            }
        }

        for item in proofreadingUnderlines
            where Self.range(item.range, mayBeVisibleIn: visibleRange)
        {
            drawProofreadingUnderline(
                range: item.range,
                color: item.color,
                origin: origin,
                dirtyRect: rect
            )
        }
    }

    private func drawProofreadingUnderline(
        range: NSRange,
        color: NSColor,
        origin: NSPoint,
        dirtyRect: NSRect
    ) {
        guard let layoutManager, let textContainer,
              let storageLength = textStorage?.length,
              range.location >= 0,
              NSMaxRange(range) <= storageLength
        else {
            return
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
            return
        }

        color.setStroke()
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

            let baseline = fragmentRect.minY
                + layoutManager.location(forGlyphAt: lineRange.location).y
            let waveY = baseline
                + Self.proofreadingWaveOffset * self.proofreadingScale + origin.y
            let minX = bounds.minX + origin.x
            let maxX = bounds.maxX + origin.x
            guard maxX > minX,
                  dirtyRect.intersects(NSRect(
                      x: minX,
                      y: waveY - Self.proofreadingWaveAmplitude - 1,
                      width: maxX - minX,
                      height: 2 * Self.proofreadingWaveAmplitude + 2
                  ))
            else {
                return
            }

            self.strokeWave(from: minX, to: maxX, y: waveY)
        }
    }

    /// One sine-like period per `proofreadingWaveLength` points, built from a
    /// quadratic curve per half-wave (two path elements per period instead of
    /// a per-point polyline), phase anchored to the segment start so the
    /// squiggle is stable across repaints.
    private func strokeWave(from minX: CGFloat, to maxX: CGFloat, y: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = Self.proofreadingWaveLineWidth * proofreadingScale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // A quadratic curve's apex sits at half the control-point offset, so
        // the control point goes twice the amplitude out. The trailing
        // partial half-wave scales its apex with its width, so short tails
        // flatten out instead of ending in a full-height kink.
        let halfWaveLength = Self.proofreadingWaveLength / 2
        let controlOffset = 2 * Self.proofreadingWaveAmplitude
        var x = minX
        var direction: CGFloat = 1
        path.move(to: NSPoint(x: x, y: y))
        while x < maxX {
            let nextX = min(x + halfWaveLength, maxX)
            let apexScale = (nextX - x) / halfWaveLength
            path.curve(
                to: NSPoint(x: nextX, y: y),
                controlPoint: NSPoint(
                    x: (x + nextX) / 2,
                    y: y + direction * controlOffset * apexScale
                )
            )
            direction = -direction
            x = nextX
        }
        path.stroke()
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

    /// Point in view coordinates while the pointer moves over the text,
    /// nil when it leaves. Only fires while proofreading tracking is on.
    var onProofreadingHover: ((NSPoint?) -> Void)?

    var isProofreadingTrackingEnabled = false {
        didSet {
            guard isProofreadingTrackingEnabled != oldValue else {
                return
            }

            if !isProofreadingTrackingEnabled {
                onProofreadingHover?(nil)
            }
            updateTrackingAreas()
        }
    }

    private var proofreadingTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let area = proofreadingTrackingArea {
            removeTrackingArea(area)
            proofreadingTrackingArea = nil
        }
        guard isProofreadingTrackingEnabled else {
            return
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        proofreadingTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if eventIsInTopChrome(event) {
            NSCursor.arrow.set()
            if isProofreadingTrackingEnabled {
                onProofreadingHover?(nil)
            }
            return
        }

        if isProofreadingTrackingEnabled {
            onProofreadingHover?(convert(event.locationInWindow, from: nil))
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if isProofreadingTrackingEnabled,
           event.trackingArea === proofreadingTrackingArea
        {
            onProofreadingHover?(nil)
        }
        super.mouseExited(with: event)
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

    /// Cmd-F and line movement shortcuts are handled at the raw-event level.
    /// Return/Tab/Backtab are intercepted by the editor view's
    /// textView(_:doCommandBy:) instead: the event must reach the input
    /// context first, so IME composition keeps Return/Tab for itself and
    /// keypad Enter (a different character, the same insertNewline command)
    /// gets markdown continuation too.
    override func keyDown(with event: NSEvent) {
        let previousModifiers = keyDownModifiers
        keyDownModifiers = event.modifierFlags
        defer { keyDownModifiers = previousModifiers }
        pendingAnimatedSelectionRevision = nil
        if isFindShortcut(event) {
            commandDelegate?.markdownTextViewShowFind(self)
            return
        }

        if let command = lineMoveCommand(for: event) {
            commandDelegate?.markdownTextView(self, moveLines: command)
            return
        }

        let previousSelectionRevision = selectionRevision
        let previousContentRevision = contentRevision
        super.keyDown(with: event)
        switch event.specialKey {
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            if selectionRevision != previousSelectionRevision,
               contentRevision == previousContentRevision,
               selectedRanges.count == 1,
               !hasMarkedText()
            {
                // Drawing is deferred, so retain the exact navigation selection.
                pendingAnimatedSelectionRevision = selectionRevision
            }
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        caretScrollAnimator.cancel()
        stopInsertionPointAnimation()
        insertionPointRect = nil
        pendingAnimatedSelectionRevision = nil
        isTrackingMouseSelection = true
        defer {
            isTrackingMouseSelection = false
            stopSelectionAutoscroll()
        }
        super.mouseDown(with: event)
        // An autoscrolled selection keeps its viewport until the next caret move.
        if selectionScrollDisplayLink == nil {
            onMouseDown?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else {
            return nil
        }

        if let copyItem = menu.items.first(where: { $0.action == #selector(copy(_:)) }) {
            copyItem.title = "Copy As"
            copyItem.action = nil
            copyItem.keyEquivalent = ""
            copyItem.submenu = copyAsMenu()
        }

        var index = 0
        if selectedRange().length > 0 {
            menu.insertItem(
                submenuItem(title: "Style", menu: styleMenu()), at: index
            )
            index += 1
        }

        let insertTable = NSMenuItem(
            title: "Insert Table...",
            action: #selector(insertTableMenuItem(_:)),
            keyEquivalent: ""
        )
        insertTable.target = self
        menu.insertItem(insertTable, at: index)
        menu.insertItem(NSMenuItem.separator(), at: index + 1)
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

    private func submenuItem(title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func copyAsMenu() -> NSMenu {
        let menu = NSMenu(title: "Copy As")
        menu.autoenablesItems = false
        let commands: [(String, Selector)] = [
            ("Plain Text", #selector(copySelectionAsPlainText)),
            ("Telegram", #selector(copySelectionAsTelegram)),
            ("Markdown", #selector(copy(_:))),
        ]
        for (title, action) in commands {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = selectedRange().length > 0
            menu.addItem(item)
        }
        return menu
    }

    @objc private func insertTableMenuItem(_: NSMenuItem) {
        commandDelegate?.markdownTextViewRequestInsertTable(self)
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

    func copySelection(as format: MarkdownCopyFormat) {
        let range = selectedRange()
        guard range.length > 0 else {
            return
        }

        let markdown = (string as NSString).substring(with: range)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(format.convert(markdown), forType: .string)
    }

    override func paste(_ sender: Any?) {
        invalidateDeferredPaste()
        guard let plan = RichTextMarkdownConverter.pastePlan(
            from: pasteboardForPaste()
        ) else {
            super.paste(sender)
            return
        }

        switch plan {
        case let .immediate(text):
            commitPaste(text, replacementRange: selectedRange())
        case let .deferred(paste):
            startDeferredPaste(paste, replacementRange: selectedRange())
        }
    }

    override func didChangeText() {
        contentRevision &+= 1
        if deferredPasteTask != nil {
            invalidateDeferredPaste()
        }
        super.didChangeText()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        let previousRanges = selectedRanges
        let previousSelection = selectedRange()
        let previousAffinity = selectionAffinity
        super.setSelectedRanges(
            ranges,
            affinity: affinity,
            stillSelecting: stillSelectingFlag
        )
        guard selectedRanges != previousRanges || selectionAffinity != previousAffinity
        else {
            return
        }

        selectionRevision &+= 1
        let selection = selectedRange()
        // AppKit's affinity describes line-wrap placement, not the active edge.
        // The unchanged endpoint anchors selection; it can switch sides when crossed.
        if selection != previousSelection,
           selection.location == previousSelection.location
           || selection.location == NSMaxRange(previousSelection)
        {
            selectionHeadAtStart = false
        } else if selection != previousSelection,
                  NSMaxRange(selection) == NSMaxRange(previousSelection)
                  || NSMaxRange(selection) == previousSelection.location
        {
            selectionHeadAtStart = true
        } else {
            selectionHeadAtStart = selectionAffinity == .upstream
        }
        if selectedRanges.count != 1 {
            resetInsertionPointAnimation()
        }
        needsDisplay = true
        if deferredPasteTask != nil {
            invalidateDeferredPaste()
        }
    }

    private func startDeferredPaste(
        _ paste: RichTextMarkdownConverter.DeferredPaste,
        replacementRange: NSRange
    ) {
        let requestGeneration = pasteRequestGeneration
        let expectedRevision = contentRevision
        let expectedSelectionRevision = selectionRevision
        let converter = convertDeferredPaste
        deferredPasteTask = Task { @MainActor [weak self] in
            let text = await converter(paste)
            guard let self,
                  !Task.isCancelled,
                  pasteRequestGeneration == requestGeneration,
                  contentRevision == expectedRevision,
                  selectionRevision == expectedSelectionRevision,
                  selectedRange() == replacementRange
            else {
                return
            }

            deferredPasteTask = nil
            pasteRequestGeneration &+= 1
            guard let text else {
                NSSound.beep()
                return
            }
            commitPaste(text, replacementRange: replacementRange)
        }
    }

    private func invalidateDeferredPaste() {
        deferredPasteTask?.cancel()
        deferredPasteTask = nil
        pasteRequestGeneration &+= 1
    }

    private func commitPaste(_ text: String, replacementRange: NSRange) {
        super.insertText(text, replacementRange: replacementRange)
    }

    isolated deinit {
        deferredPasteTask?.cancel()
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

    private var isTrackingMouseSelection = false
    private var selectionScrollDisplayLink: CADisplayLink?
    private var selectionScrollTimestamp: TimeInterval?

    override func autoscroll(with event: NSEvent) -> Bool {
        guard isTrackingMouseSelection,
              event.type == .leftMouseDragged,
              selectedRanges.count == 1,
              let scrollView = enclosingScrollView,
              window != nil
        else {
            stopSelectionAutoscroll()
            return super.autoscroll(with: event)
        }

        let clipView = scrollView.contentView
        let bounds = clipView.bounds
        let point = clipView.convert(event.locationInWindow, from: nil)
        let distance: CGFloat
        if point.y < bounds.minY {
            distance = point.y - bounds.minY
        } else if point.y > bounds.maxY {
            distance = point.y - bounds.maxY
        } else {
            selectionScrollTimestamp = nil
            return false
        }

        if selectionScrollDisplayLink == nil {
            onSelectionAutoscroll?()
            let link = displayLink(
                target: self, selector: #selector(pulseSelectionAutoscroll(_:))
            )
            link.add(to: .main, forMode: .common)
            selectionScrollDisplayLink = link
        }

        advanceSelectionAutoscroll(distance: distance, at: CACurrentMediaTime())
        return true
    }

    func advanceSelectionAutoscroll(distance: CGFloat, at timestamp: TimeInterval) {
        guard let scrollView = enclosingScrollView, let window else { return }
        let clipView = scrollView.contentView
        let bounds = clipView.bounds
        let elapsed = selectionScrollTimestamp.map { min(timestamp - $0, 1 / 30) } ?? 0
        selectionScrollTimestamp = timestamp
        let speed = min(1800, max(180, abs(distance) * 12))
        let delta = (distance < 0 ? -speed : speed) * elapsed
        var offset = clipView.constrainBoundsRect(bounds.offsetBy(dx: 0, dy: delta))
            .origin
        // Match AppKit's pixel alignment before layout can snap the viewport back.
        let scale = window.backingScaleFactor
        offset.y = (offset.y * scale).rounded() / scale
        clipView.setBoundsOrigin(offset)
        scrollView.reflectScrolledClipView(clipView)
    }

    @objc private func pulseSelectionAutoscroll(_ link: CADisplayLink) {
        guard isTrackingMouseSelection, let window else {
            stopSelectionAutoscroll()
            return
        }

        // Wake AppKit's tracking loop each frame so it extends the native selection
        // using the latest drag event, including word/paragraph and Shift anchors.
        guard let event = NSEvent.otherEvent(
            with: .periodic, location: .zero, modifierFlags: [],
            timestamp: link.targetTimestamp, windowNumber: window.windowNumber,
            context: nil, subtype: 0, data1: 0, data2: 0
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func stopSelectionAutoscroll() {
        selectionScrollDisplayLink?.invalidate()
        selectionScrollDisplayLink = nil
        selectionScrollTimestamp = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            caretScrollAnimator.cancel()
            stopSelectionAutoscroll()
            resetInsertionPointAnimation()
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

        // Clamped by the clip view itself rather than by scroll-view inset
        // math: the clip view is the authority on legal resting offsets
        // (AppKit layout re-asserts them), and a target outside that range
        // would leave the animator fighting layout forever.
        offsetY = clipView.constrainBoundsRect(
            NSRect(
                origin: NSPoint(x: clipBounds.origin.x, y: offsetY),
                size: clipBounds.size
            )
        ).origin.y
        guard abs(offsetY - currentOffsetY) > 0.5 else {
            return true
        }

        caretScrollAnimator.scroll(scrollView, toOffsetY: offsetY)
        return true
    }

    /// The line-fragment rect (in view coordinates, container origin
    /// included) of the caret end of the given range — the upstream or
    /// downstream end per `affinity`, matching where the caret sits during
    /// keyboard navigation. Shared by the keyboard caret scroll here and by
    /// the editor view's focus-mode centering.
    func caretLineRect(
        for range: NSRange,
        affinity: NSSelectionAffinity
    ) -> NSRect? {
        guard let layoutManager, let textContainer, let textStorage else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let length = textStorage.length
        let location = min(
            affinity == .upstream ? range.location : NSMaxRange(range),
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

        let origin = textContainerOrigin
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The caret line rect prepared for the minimal keyboard scroll.
    private func caretLineScrollRect(for range: NSRange) -> NSRect? {
        guard var rect = caretLineRect(for: range, affinity: selectionAffinity)
        else {
            return nil
        }

        // Only vertical visibility matters for the caret line; pinning x to
        // the current viewport avoids any horizontal jump.
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

    private func lineMoveCommand(for event: NSEvent) -> MarkdownLineMoveCommand? {
        let modifiers = event.modifierFlags.intersection([
            .shift,
            .control,
            .option,
            .command,
        ])
        guard modifiers == .option else {
            return nil
        }

        switch event.specialKey {
        case .upArrow:
            return .up
        case .downArrow:
            return .down
        default:
            return nil
        }
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
