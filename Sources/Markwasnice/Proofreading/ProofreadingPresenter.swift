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

    private static let hoverDwellSeconds: TimeInterval = 0.15
    private static let lightHighlightAlpha: CGFloat = 0.16
    private static let darkHighlightAlpha: CGFloat = 0.26
    private static let highlightFadeSeconds: TimeInterval = 0.14
    private static let fadeFrameInterval: TimeInterval = 1.0 / 60.0

    private let textView: MarkdownTextView
    private let severityColor: (ProofreadingSeverity) -> NSColor

    private(set) var issues: [ProofreadingIssue] = []
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

    // No deinit invalidation needed: both timers hold self weakly (the dwell
    // timer fires once, the fade timer stops itself once every fade settles),
    // and the presenter lives as long as the editor view anyway.

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

        // Where issues overlap (a word-level issue inside a sentence-level
        // one), only the most specific issue draws its wave in the overlap;
        // broader underlines are clipped around it instead of stacking.
        var underlines: [MarkdownTextView.ProofreadingDrawItem] = []
        var highlights: [MarkdownTextView.ProofreadingDrawItem] = []
        var claimedRanges: [NSRange] = []
        for index in issues.indices.sorted(by: issueSpecificityOrder) {
            let issue = issues[index]
            let color = severityColor(issue.severity)
            let fade = easedFade(for: issue.ruleID)
            if fade > 0 {
                highlights.append(.init(
                    range: issue.range,
                    color: color.withAlphaComponent(highlightAlpha * fade)
                ))
            }
            if fade >= 1 {
                claimedRanges.append(issue.range)
                continue
            }

            // Subtract only actually overlapping claims: overlaps are rare,
            // and unconditional subtraction would allocate O(n²) arrays here
            // on every push with many issues.
            var visibleSegments = [issue.range]
            for claimed in claimedRanges
                where NSIntersectionRange(claimed, issue.range).length > 0
            {
                visibleSegments = visibleSegments.flatMap {
                    MarkdownStylingEngine.subtract(claimed, from: $0)
                }
            }
            let underlineColor = fade > 0
                ? color.withAlphaComponent(color.alphaComponent * (1 - fade))
                : color
            underlines += visibleSegments.map {
                .init(range: $0, color: underlineColor)
            }
            claimedRanges.append(issue.range)
        }
        textView.setProofreadingDecorations(
            underlines: underlines,
            highlights: highlights
        )
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
