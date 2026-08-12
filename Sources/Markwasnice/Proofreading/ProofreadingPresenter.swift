import AppKit

/// Owns the interactive side of proofreading: the issue list, the wavy
/// underline / tinted highlight decoration state pushed into the text view,
/// hover-dwell and caret activation, and the single issue popup.
@MainActor
final class ProofreadingPresenter {
    private enum ActivationTrigger {
        case hover
        case caret
    }

    private struct ActiveState {
        let anchorIndex: Int
        let ruleID: Int
        let trigger: ActivationTrigger
    }

    /// Draw order plus, per entry, the parts of that issue's range no more
    /// specific issue already claimed. Both derive from the issue ranges
    /// alone, so a crossfade frame — which only moves alphas — can reuse
    /// them instead of re-sorting and re-intersecting every issue at 60 Hz.
    private struct DecorationLayout {
        /// Issue indices, most specific first.
        let order: [Int]
        /// Parallel to `order`: the underline segments of `order[i]`.
        let underlineSegments: [[NSRange]]
    }

    private struct RangeBoundary {
        let location: Int
        let rangeIndex: Int
        let startsRange: Bool
    }

    private static let hoverDwellSeconds: TimeInterval = 0.15
    private static let lightHighlightAlpha: CGFloat = 0.16
    private static let darkHighlightAlpha: CGFloat = 0.26
    private static let highlightFadeSeconds: TimeInterval = 0.14
    private static let fadeFrameInterval: TimeInterval = 1.0 / 60.0

    private let textView: MarkdownTextView
    private let severityColor: (ProofreadingSeverity) -> NSColor

    /// Every mutation drops the cached layout, so no caller has to remember
    /// to invalidate it.
    private(set) var issues: [ProofreadingIssue] = [] {
        didSet { decorationLayout = nil }
    }

    private var decorationLayout: DecorationLayout?
    private var isEnabled = false
    private var activeState: ActiveState?
    private var dwellTimer: Timer?
    private var dwellCandidateIndex: Int?
    private var popover: NSPopover?

    /// Underline-to-highlight crossfade per rule: 0 draws only the wavy
    /// underline, 1 only the tinted highlight. Entries animate toward 1 for
    /// the active rule and 0 for everything else, then settled zeros drop out.
    private var fadeProgress: [Int: CGFloat] = [:]
    private var fadeTimer: Timer?
    private var lastFadeTick: CFTimeInterval = 0

    init(
        textView: MarkdownTextView,
        severityColor: @escaping (ProofreadingSeverity) -> NSColor
    ) {
        self.textView = textView
        self.severityColor = severityColor
        textView.onProofreadingHover = { [weak self] point in
            self?.handleHover(point: point)
        }
    }

    isolated deinit {
        // RunLoop retains scheduled timers. Their weak callbacks do not keep
        // the presenter alive, but without explicit invalidation an orphaned
        // repeating fade timer would continue waking the main run loop.
        dwellTimer?.invalidate()
        fadeTimer?.invalidate()
    }

    /// Internal lifecycle seam for verifying that teardown invalidates the
    /// RunLoop-owned animation timer without opening a UI popover.
    func startFadeTimerForTesting() -> Timer? {
        startFadeTimer()
        return fadeTimer
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            return
        }

        isEnabled = enabled
        textView.isProofreadingTrackingEnabled = enabled
        if !enabled {
            issues = []
            deactivate()
        }
        pushDecorations()
    }

    func setIssues(_ newIssues: [ProofreadingIssue]) {
        guard isEnabled else {
            return
        }

        let previousAnchor = activeState.map { issues[$0.anchorIndex] }
        issues = newIssues
        if let state = activeState {
            // Keep the popup only if the exact anchor issue survived the
            // re-check; otherwise the text under it changed.
            if let previousAnchor,
               let newIndex = issues.firstIndex(of: previousAnchor)
            {
                activeState = ActiveState(
                    anchorIndex: newIndex,
                    ruleID: state.ruleID,
                    trigger: state.trigger
                )
            } else {
                deactivate()
            }
        }
        cancelDwell()
        pushDecorations()
    }

    func clearIssues() {
        guard isEnabled, !issues.isEmpty || activeState != nil else {
            return
        }

        issues = []
        deactivate()
        pushDecorations()
    }

    /// Keeps issue ranges glued to the text between checks. Issues whose text
    /// was edited are dropped; the next check repopulates them.
    func handleTextEdit(
        editedRange: NSRange,
        changeInLength: Int,
        sourceLength: Int
    ) {
        guard isEnabled, !issues.isEmpty else {
            return
        }

        issues = issues.compactMap { issue in
            guard let adjusted = MarkdownStylingEngine.editAdjustedRange(
                issue.range,
                editLocation: editedRange.location,
                changeInLength: changeInLength,
                editedLength: editedRange.length,
                sourceLength: sourceLength
            ), NSIntersectionRange(adjusted, editedRange).length == 0,
            // A deletion's editedRange has length 0 and intersects nothing,
            // but a deletion point strictly inside the issue still changed
            // its text — drop it like an insertion would be.
            !(changeInLength < 0
                && editedRange.location > adjusted.location
                && editedRange.location < NSMaxRange(adjusted))
            else {
                return nil
            }

            var moved = issue
            moved.range = adjusted
            return moved
        }
        deactivate()
        pushDecorations()
    }

    func handleHover(point: NSPoint?) {
        guard isEnabled else {
            return
        }

        guard let point, let index = issueIndex(at: point) else {
            cancelDwell()
            if let state = activeState, state.trigger == .hover {
                fallBackToCaretOrDeactivate()
                pushDecorations()
            }
            return
        }

        if let state = activeState, state.anchorIndex == index {
            cancelDwell()
            return
        }
        guard dwellCandidateIndex != index else {
            return
        }

        cancelDwell()
        dwellCandidateIndex = index
        dwellTimer = Timer.scheduledTimer(
            withTimeInterval: Self.hoverDwellSeconds,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }

                self.dwellCandidateIndex = nil
                self.activate(index, trigger: .hover)
            }
        }
        dwellTimer?.tolerance = 0.1
    }

    func handleSelectionChange(_ selectedRange: NSRange) {
        guard isEnabled else {
            return
        }

        guard selectedRange.length == 0,
              let index = issueIndex(containing: selectedRange.location)
        else {
            if let state = activeState, state.trigger == .caret {
                deactivate()
                pushDecorations()
            }
            return
        }

        guard activeState?.anchorIndex != index else {
            return
        }
        activate(index, trigger: .caret)
    }

    func dismissPopup() {
        guard activeState != nil else {
            return
        }

        deactivate()
        pushDecorations()
    }

    func refreshColors() {
        pushDecorations()
    }

    // MARK: - Activation

    private func activate(_ index: Int, trigger: ActivationTrigger) {
        guard isEnabled, issues.indices.contains(index) else {
            return
        }

        closePopover()
        let issue = issues[index]
        activeState = ActiveState(
            anchorIndex: index,
            ruleID: issue.ruleID,
            trigger: trigger
        )
        pushDecorations()
        showPopover(for: issue)
    }

    private func deactivate() {
        cancelDwell()
        closePopover()
        activeState = nil
    }

    /// A hover that ends while the caret still sits inside the anchor issue
    /// keeps the activation alive as a caret one instead of dropping it.
    private func fallBackToCaretOrDeactivate() {
        guard let state = activeState else {
            return
        }

        let caret = textView.selectedRange()
        if caret.length == 0, issues.indices.contains(state.anchorIndex),
           NSLocationInRange(caret.location, issues[state.anchorIndex].range)
        {
            activeState = ActiveState(
                anchorIndex: state.anchorIndex,
                ruleID: state.ruleID,
                trigger: .caret
            )
            return
        }

        deactivate()
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwellCandidateIndex = nil
    }

    // MARK: - Decorations

    private func pushDecorations() {
        guard isEnabled, !issues.isEmpty else {
            fadeProgress = [:]
            stopFadeTimer()
            textView.setProofreadingDecorations(underlines: [], highlights: [])
            return
        }

        retargetFade()

        let isDark = textView.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highlightAlpha = isDark
            ? Self.darkHighlightAlpha : Self.lightHighlightAlpha

        let layout = decorationLayout ?? rebuiltDecorationLayout()
        var underlines: [MarkdownTextView.ProofreadingDrawItem] = []
        var highlights: [MarkdownTextView.ProofreadingDrawItem] = []
        for (position, index) in layout.order.enumerated() {
            let issue = issues[index]
            let color = severityColor(issue.severity)
            let fade = easedFade(for: issue.ruleID)
            if fade > 0 {
                highlights.append(.init(
                    range: issue.range,
                    color: color.withAlphaComponent(highlightAlpha * fade)
                ))
            }
            // A fully faded-in issue shows only its highlight; its claim on
            // the overlap is already baked into the cached segments.
            if fade >= 1 {
                continue
            }

            let underlineColor = fade > 0
                ? color.withAlphaComponent(color.alphaComponent * (1 - fade))
                : color
            underlines += layout.underlineSegments[position].map {
                .init(range: $0, color: underlineColor)
            }
        }
        textView.setProofreadingDecorations(
            underlines: underlines,
            highlights: highlights
        )
    }

    private func rebuiltDecorationLayout() -> DecorationLayout {
        let order = issues.indices.sorted(by: issueSpecificityOrder)
        let layout = DecorationLayout(
            order: order,
            underlineSegments: Self.underlineSegments(
                forDrawOrderedRanges: order.map { issues[$0].range }
            )
        )
        decorationLayout = layout
        return layout
    }

    /// Where issues overlap (a word-level issue inside a sentence-level
    /// one), only the most specific issue draws its wave in the overlap;
    /// broader underlines are clipped around it instead of stacking. Every
    /// range claims its overlap whatever its fade is, so the result depends
    /// on the draw-ordered ranges alone and survives a crossfade.
    static func underlineSegments(
        forDrawOrderedRanges ranges: [NSRange]
    ) -> [[NSRange]] {
        var segments = Array(repeating: [NSRange](), count: ranges.count)
        var boundaries: [RangeBoundary] = []
        boundaries.reserveCapacity(ranges.count * 2)
        for (index, range) in ranges.enumerated() {
            guard range.location >= 0,
                  range.location != NSNotFound,
                  range.length > 0,
                  range.location <= Int.max - range.length
            else {
                continue
            }

            boundaries.append(.init(
                location: range.location,
                rangeIndex: index,
                startsRange: true
            ))
            boundaries.append(.init(
                location: range.location + range.length,
                rangeIndex: index,
                startsRange: false
            ))
        }
        boundaries.sort { lhs, rhs in
            lhs.location < rhs.location
        }

        // Sweep all endpoints once. The minimum active draw-order index owns
        // each interval; a lazy min-heap makes overlap resolution O(n log n)
        // instead of testing every issue against every earlier issue.
        var active = Array(repeating: false, count: ranges.count)
        var activeHeap: [Int] = []
        var boundaryIndex = 0
        var previousLocation = boundaries.first?.location
        while boundaryIndex < boundaries.count {
            let location = boundaries[boundaryIndex].location
            removeInactiveRanges(from: &activeHeap, active: active)
            if let previousLocation,
               previousLocation < location,
               let owner = activeHeap.first
            {
                appendUnderlineSegment(
                    NSRange(
                        location: previousLocation,
                        length: location - previousLocation
                    ),
                    to: &segments[owner]
                )
            }

            while boundaryIndex < boundaries.count,
                  boundaries[boundaryIndex].location == location
            {
                let boundary = boundaries[boundaryIndex]
                active[boundary.rangeIndex] = boundary.startsRange
                if boundary.startsRange {
                    heapInsert(boundary.rangeIndex, into: &activeHeap)
                }
                boundaryIndex += 1
            }
            previousLocation = location
        }

        return segments
    }

    private static func appendUnderlineSegment(
        _ segment: NSRange,
        to segments: inout [NSRange]
    ) {
        if let last = segments.last, NSMaxRange(last) == segment.location {
            segments[segments.count - 1].length += segment.length
        } else {
            segments.append(segment)
        }
    }

    private static func heapInsert(_ value: Int, into heap: inout [Int]) {
        heap.append(value)
        var index = heap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard heap[index] < heap[parent] else {
                return
            }
            heap.swapAt(index, parent)
            index = parent
        }
    }

    private static func removeInactiveRanges(
        from heap: inout [Int],
        active: [Bool]
    ) {
        while let first = heap.first, !active[first] {
            let last = heap.removeLast()
            guard !heap.isEmpty else {
                continue
            }
            heap[0] = last
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < heap.count else {
                    break
                }
                let right = left + 1
                let child = right < heap.count && heap[right] < heap[left]
                    ? right : left
                guard heap[child] < heap[index] else {
                    break
                }
                heap.swapAt(index, child)
                index = child
            }
        }
    }

    // MARK: - Highlight crossfade

    /// Ensures the active rule has a fade entry, drops entries for rules that
    /// no longer exist, and runs the frame timer while anything is mid-fade.
    private func retargetFade() {
        let activeRuleID = activeState?.ruleID
        if let activeRuleID, fadeProgress[activeRuleID] == nil {
            fadeProgress[activeRuleID] = 0
        }
        if !fadeProgress.isEmpty {
            let liveRuleIDs = Set(issues.map(\.ruleID))
            fadeProgress = fadeProgress.filter { liveRuleIDs.contains($0.key) }
        }
        let needsAnimation = fadeProgress.contains { ruleID, progress in
            progress != (ruleID == activeRuleID ? 1 : 0)
        }
        if needsAnimation {
            startFadeTimer()
        }
    }

    private func easedFade(for ruleID: Int) -> CGFloat {
        guard let progress = fadeProgress[ruleID], progress > 0 else {
            return 0
        }

        // Smoothstep: gentle in and out of the crossfade.
        return progress * progress * (3 - 2 * progress)
    }

    private func startFadeTimer() {
        guard fadeTimer == nil else {
            return
        }

        lastFadeTick = CACurrentMediaTime()
        let timer = Timer(
            timeInterval: Self.fadeFrameInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stepFade()
            }
        }
        // Default-mode timers stall during scroll and event tracking; the
        // crossfade should keep moving there.
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func stopFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func stepFade() {
        let now = CACurrentMediaTime()
        // Clamp hitches so a stalled frame advances, not teleports, the fade.
        let delta = CGFloat(
            min(now - lastFadeTick, 4 * Self.fadeFrameInterval)
                / Self.highlightFadeSeconds
        )
        lastFadeTick = now

        let activeRuleID = activeState?.ruleID
        var settled = true
        var next: [Int: CGFloat] = [:]
        for (ruleID, progress) in fadeProgress {
            let target: CGFloat = ruleID == activeRuleID ? 1 : 0
            let value = progress < target
                ? min(target, progress + delta)
                : max(target, progress - delta)
            if value != target {
                settled = false
            }
            if value > 0 || ruleID == activeRuleID {
                next[ruleID] = value
            }
        }
        fadeProgress = next
        if settled {
            stopFadeTimer()
        }
        pushDecorations()
    }

    /// Smaller range first (more specific wins overlaps), then higher
    /// weight, then document order — used both for drawing precedence and
    /// for picking which of several overlapping issues hover/caret target.
    private func issueSpecificityOrder(_ lhs: Int, _ rhs: Int) -> Bool {
        let left = issues[lhs]
        let right = issues[rhs]
        if left.range.length != right.range.length {
            return left.range.length < right.range.length
        }
        if left.weight != right.weight {
            return left.weight > right.weight
        }
        return left.range.location < right.range.location
    }

    /// The most specific issue whose range contains the character index.
    private func issueIndex(containing characterIndex: Int) -> Int? {
        issues.indices
            .filter { NSLocationInRange(characterIndex, issues[$0].range) }
            .min(by: issueSpecificityOrder)
    }

    // MARK: - Hit testing

    private func issueIndex(at point: NSPoint) -> Int? {
        guard !issues.isEmpty,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else {
            return nil
        }

        let origin = textView.textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let characterIndex = layoutManager.characterIndex(
            for: containerPoint,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard characterIndex != NSNotFound else {
            return nil
        }

        // characterIndex clamps to the nearest glyph; require the pointer to
        // actually sit on it so trailing whitespace past line ends misses.
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: container
        )
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(containerPoint) else {
            return nil
        }

        return issueIndex(containing: characterIndex)
    }

    // MARK: - Popup

    private func showPopover(for issue: ProofreadingIssue) {
        guard let anchorRect = anchorRect(for: issue) else {
            return
        }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.hasFullSizeContent = true
        popover.contentViewController = ProofreadingPopoverController(
            title: issue.title,
            hint: issue.hint
        )
        popover.show(relativeTo: anchorRect, of: textView, preferredEdge: .minY)
        self.popover = popover
    }

    private func closePopover() {
        popover?.close()
        popover = nil
    }

    /// Bounding rect of the issue's first visual line, in text-view
    /// coordinates — the popup points at the start of the phrase.
    private func anchorRect(for issue: ProofreadingIssue) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else {
            return nil
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: issue.range,
            actualCharacterRange: nil
        )
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else {
            return nil
        }

        var fragmentGlyphRange = NSRange(location: NSNotFound, length: 0)
        layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: &fragmentGlyphRange
        )
        var lineRange = glyphRange
        if fragmentGlyphRange.location != NSNotFound {
            let intersection = NSIntersectionRange(fragmentGlyphRange, glyphRange)
            if intersection.length > 0 {
                lineRange = intersection
            }
        }

        let bounds = layoutManager.boundingRect(
            forGlyphRange: lineRange,
            in: container
        )
        guard !bounds.isEmpty else {
            return nil
        }

        let origin = textView.textContainerOrigin
        return bounds.offsetBy(dx: origin.x, dy: origin.y)
    }
}
