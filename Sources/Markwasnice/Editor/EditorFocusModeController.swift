@preconcurrency import AppKit

/// Owns the focus/typewriter-mode cluster for the editor: the enabled/mode
/// state, the active focus paragraph, the scroll-induced suppression episode
/// (including the suppressed-viewport restyle memo), and the caret-centering
/// scroll. Attribute application stays in MarkdownEditorView — the controller
/// supplies ranges and decisions and drives restyles through the callbacks
/// below, so focus state has a single owner instead of being scattered
/// through the editor class.
@MainActor
final class EditorFocusModeController {
    private let textView: MarkdownTextView
    private let scrollView: NSScrollView
    private let clipView: NSClipView
    private let scrollAnimator = CaretScrollAnimator()

    private(set) var isEnabled = false
    private(set) var mode: EditorFocusMode = .focus
    private(set) var isTemporarilySuppressed = false
    private(set) var activeParagraphRange: NSRange?
    /// The character range already undimmed during the current focus
    /// suppression episode. Momentum scrolling delivers a bounds change per
    /// frame; without this memo every one of them re-styled the same
    /// viewport-plus-buffer for a few-pixel delta. Reset when suppression
    /// begins/ends and on any text change (the offsets shift).
    private var suppressedRestyledRange: NSRange?
    private var scrollAdjustmentCount = 0

    // MARK: Editor callbacks

    /// Full-document restyle, used when the dimming state flips wholesale.
    var restyleAllText: () -> Void = {}
    /// Restyles one range, widened to whole lines and bounds-checked by the
    /// editor; empty or out-of-bounds ranges are skipped there.
    var restyleLineRange: (NSRange) -> Void = { _ in }
    /// The viewport-plus-buffer character range from the editor's styling
    /// geometry.
    var visibleBufferedRange: () -> NSRange? = { nil }
    /// Re-applies the text container inset — the editor's focus overscroll
    /// padding depends on `isEnabled`.
    var updateContainerInset: () -> Void = {}

    init(
        textView: MarkdownTextView,
        scrollView: NSScrollView,
        clipView: NSClipView
    ) {
        self.textView = textView
        self.scrollView = scrollView
        self.clipView = clipView
    }

    var isAdjustingScroll: Bool {
        scrollAdjustmentCount > 0 || scrollAnimator.isAnimating
    }

    func setEnabled(_ isEnabled: Bool) {
        guard self.isEnabled != isEnabled else {
            return
        }

        self.isEnabled = isEnabled
        isTemporarilySuppressed = false
        suppressedRestyledRange = nil
        activeParagraphRange = isEnabled ? activeParagraphRangeAtSelection() : nil
        updateCaretScrollOwnership()
        updateContainerInset()
        restyleAllText()
        if isEnabled {
            centerCaretLineInVisibleArea(animated: true)
        }
    }

    func setMode(_ mode: EditorFocusMode) {
        guard self.mode != mode else {
            return
        }

        self.mode = mode
        isTemporarilySuppressed = false
        suppressedRestyledRange = nil
        activeParagraphRange = activeParagraphRangeAtSelection()
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
        textView.skipsKeyboardCaretScrolling = isEnabled && !isTemporarilySuppressed
    }

    func cancelScrollAnimation() {
        scrollAnimator.cancel()
    }

    /// The ranges within `range` to dim — everything outside the active
    /// focus paragraph; empty while dimming is off or suppressed.
    func dimmedRanges(in range: NSRange) -> [NSRange] {
        guard isEnabled,
              !isTemporarilySuppressed,
              mode == .focus,
              let activeRange = activeParagraphRange
        else {
            return []
        }

        return MarkdownStylingEngine.subtract(activeRange, from: range)
            .filter { $0.length > 0 }
    }

    func updateForSelection() {
        guard isEnabled else {
            return
        }

        let previousRange = activeParagraphRange
        activeParagraphRange = activeParagraphRangeAtSelection()
        // Dimming only differs in the paragraph that lost the caret and the
        // one that gained it; everything else keeps its state. Restyling the
        // whole document here would rewrite all attributes on every Enter
        // press and cross-paragraph caret move.
        if mode == .focus,
           !isTemporarilySuppressed,
           previousRange?.location != activeParagraphRange?.location
        {
            restyleDelta(from: previousRange, to: activeParagraphRange)
        }

        if !isTemporarilySuppressed {
            centerCaretLineInVisibleArea(animated: true)
        }
    }

    /// Keeps the suppression memo and the active focus paragraph glued to
    /// the text across an edit. The edit shifts character offsets; the memo
    /// would otherwise claim shifted lines were already undimmed, and the
    /// dimming (plus the paragraph-delta restyle on the next selection
    /// change) subtracts the active range — a stale one would dim part of
    /// the paragraph being typed in.
    func handleTextEdit(
        editedRange: NSRange,
        changeInLength: Int,
        sourceLength: Int
    ) {
        suppressedRestyledRange = nil
        if let activeRange = activeParagraphRange {
            activeParagraphRange = MarkdownStylingEngine.editAdjustedRange(
                activeRange,
                editLocation: editedRange.location,
                changeInLength: changeInLength,
                editedLength: editedRange.length,
                sourceLength: sourceLength
            )
        }
    }

    /// Undims the viewport during a scroll-induced focus suppression, but
    /// only the part not already covered in this suppression episode — the
    /// common per-frame case (a small delta inside the covered range) costs
    /// one range check and no attribute work.
    func restyleSuppressedViewportIfNeeded() {
        guard let neededRange = visibleBufferedRange() else {
            return
        }

        var rangesToStyle = [neededRange]
        var extendsCoveredRange = false
        if let coveredRange = suppressedRestyledRange {
            // Overlapping or touching ranges extend the memo; a far jump
            // (scroll-bar drag) restarts it at the viewport instead — a
            // union across the gap would mark never-restyled lines covered.
            if NSMaxRange(coveredRange) >= neededRange.location,
               NSMaxRange(neededRange) >= coveredRange.location
            {
                rangesToStyle = MarkdownStylingEngine.subtract(
                    coveredRange,
                    from: neededRange
                )
                extendsCoveredRange = true
                guard !rangesToStyle.isEmpty else {
                    return
                }
            }
        }

        for styleRange in rangesToStyle {
            restyleLineRange(styleRange)
        }

        suppressedRestyledRange = extendsCoveredRange
            ? NSUnionRange(suppressedRestyledRange ?? neededRange, neededRange)
            : neededRange
    }

    func restoreAfterEditorInteraction() {
        guard isEnabled else {
            return
        }

        guard isTemporarilySuppressed else {
            updateForSelection()
            return
        }

        isTemporarilySuppressed = false
        suppressedRestyledRange = nil
        activeParagraphRange = activeParagraphRangeAtSelection()
        updateCaretScrollOwnership()
        // Lifting the scroll suppression must re-dim the whole document —
        // the paragraph-delta restyle in updateForSelection cannot know
        // how much of it the suppression undimmed.
        if mode == .focus {
            restyleAllText()
        }
        centerCaretLineInVisibleArea(animated: true)
    }

    func suppressForUserScroll() {
        guard isEnabled, !isTemporarilySuppressed else {
            return
        }

        // The manual scroll takes over from an in-flight centering glide.
        scrollAnimator.cancel()
        isTemporarilySuppressed = true
        suppressedRestyledRange = nil
        updateCaretScrollOwnership()
        // Only focus mode dims text; typewriter mode has nothing to undim.
        if mode == .focus {
            restyleAllText()
        }
    }

    private func restyleDelta(
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
            restyleLineRange(deltaRange)
        }
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

    /// Keeps the caret line vertically centered in focus/typewriter mode.
    /// Animated so that line transitions (Enter, arrow keys) glide instead of
    /// jumping. Driven by the same retargetable display-link animator as
    /// keyboard caret scrolling — the system animated scroll stacks a new
    /// animation per key repeat and the overlap visibly bounces.
    private func centerCaretLineInVisibleArea(animated: Bool) {
        // Centering takes over from any in-flight keyboard caret scroll.
        textView.cancelKeyboardCaretScroll()
        // The rect is in view coordinates (container origin included), so
        // its midY feeds the offset math directly.
        guard let lineRect = textView.caretLineRect(
            for: textView.selectedRange(),
            affinity: textView.selectionAffinity
        ) else {
            return
        }

        let clipHeight = clipView.bounds.height
        guard clipHeight > 0 else {
            return
        }

        let targetOffsetY = clampedScrollOffsetY(lineRect.midY - clipHeight / 2)
        let currentOffsetY = scrollAnimator.isAnimating
            ? scrollAnimator.targetOffsetY
            : clipView.bounds.origin.y
        guard abs(currentOffsetY - targetOffsetY) > 0.5 else {
            return
        }

        guard animated else {
            performSuppressedScroll(toOffsetY: targetOffsetY)
            return
        }

        scrollAnimator.scroll(scrollView, toOffsetY: targetOffsetY)
    }

    /// The given offset clamped to the legal scroll range — by the clip view
    /// itself rather than by scroll-view inset math: the clip view is the
    /// authority on legal resting offsets (AppKit layout re-asserts them),
    /// and a target outside that range would leave any animator fighting
    /// layout forever.
    func clampedScrollOffsetY(_ offsetY: CGFloat) -> CGFloat {
        clipView.constrainBoundsRect(
            NSRect(
                origin: NSPoint(x: clipView.bounds.origin.x, y: offsetY),
                size: clipView.bounds.size
            )
        ).origin.y
    }

    /// Jumps the clip origin without the change reading as user scrolling —
    /// that would hide the chrome and suppress focus mode.
    func performSuppressedScroll(toOffsetY targetOffsetY: CGFloat) {
        scrollAnimator.cancel()
        scrollAdjustmentCount += 1
        clipView.setBoundsOrigin(
            NSPoint(x: clipView.bounds.origin.x, y: targetOffsetY)
        )
        scrollView.reflectScrolledClipView(clipView)
        scrollAdjustmentCount -= 1
    }
}
