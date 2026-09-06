import Foundation

@MainActor
final class MarkdownStylingController {
    private let editorView: MarkdownEditorView
    private let parseService = MarkdownParseService()
    private let proofreadingService = ProofreadingService()
    private var resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = []
    private var isProofreadingEnabled = false

    /// Bumped synchronously on every editor text change. Parsing may be
    /// debounced, but an older result becomes invalid before that delay.
    private var textVersion = 0
    private var proofreadScheduledTextVersion = 0
    private var resolvedStyleSpansVersion = 0

    /// The resolved spans when they still describe the text the editor holds,
    /// and nil once an edit has landed ahead of the next parse. Callers that
    /// derive protected ranges from them — typography — must not work from a
    /// stale set: a code span sitting at a moved offset would let the pass
    /// rewrite inside code it is supposed to leave alone.
    var freshStyleSpans: [ResolvedMarkdownStyleSpan]? {
        guard resolvedStyleSpansVersion == textVersion,
              resolvedSpansSourceLength == editorTextLength
        else {
            return nil
        }

        return resolvedStyleSpans
    }

    private var resolvedSpansSourceLength = 0

    init(editorView: MarkdownEditorView) {
        self.editorView = editorView
        parseService.onParse = { [weak self] result in
            self?.applyParseResult(result)
        }
        proofreadingService.onCheck = { [weak self] issues, source in
            // The service only delivers its latest scheduled check; if no
            // edit bumped textVersion since that check was scheduled, the
            // editor still holds the checked text.
            guard let self, isProofreadingEnabled,
                  proofreadScheduledTextVersion == textVersion,
                  source.utf16.count == editorTextLength
            else {
                return
            }

            editorView.setProofreadingIssues(issues)
        }
    }

    func scheduleParse(text: String) {
        let version = invalidateText()
        scheduleParse(text: text, version: version)
    }

    /// Invalidates parsed and proofreading state in the synchronous edit
    /// callback. The returned version belongs to that exact text generation
    /// and may be scheduled after the session-level debounce.
    @discardableResult
    func invalidateText() -> Int {
        textVersion &+= 1
        parseService.cancel()
        return textVersion
    }

    func scheduleParse(text: String, version: Int) {
        guard version == textVersion else {
            return
        }

        parseService.scheduleParse(text: text, version: version)
    }

    func applySettings(_ settings: EditorSettings) {
        editorView.applySettings(settings)
    }

    func updateWindowWidthFontScale(for width: CGFloat) {
        editorView.updateWindowWidthFontScale(for: width)
    }

    func setProofreadingEnabled(_ enabled: Bool) {
        guard enabled != isProofreadingEnabled else {
            return
        }

        isProofreadingEnabled = enabled
        if enabled {
            guard let spans = freshStyleSpans else {
                // The next accepted parse starts the check with ranges that
                // belong to the current text generation.
                return
            }
            proofreadScheduledTextVersion = textVersion
            proofreadingService.scheduleCheck(
                text: editorView.string,
                protectedRanges: ProofreadingService.protectedRanges(
                    from: spans
                ),
                debounceMilliseconds: 0
            )
        } else {
            proofreadingService.cancel()
            editorView.setProofreadingIssues([])
        }
    }

    private func applyParseResult(_ result: MarkdownParseResult) {
        guard result.textVersion == textVersion,
              result.sourceLength == editorTextLength
        else {
            return
        }

        resolvedStyleSpans = result.spans
        resolvedStyleSpansVersion = result.textVersion
        resolvedSpansSourceLength = result.sourceLength
        editorView.applyParsedStyles(
            resolvedStyleSpans,
            dirtyRanges: result.dirtyRanges
        )
        if isProofreadingEnabled {
            proofreadScheduledTextVersion = textVersion
            proofreadingService.scheduleCheck(
                text: result.source,
                protectedRanges: ProofreadingService.protectedRanges(
                    from: result.spans
                )
            )
        }
    }

    /// O(1), unlike `editorView.string`, which bridges the whole backing
    /// store into a fresh String on every access.
    private var editorTextLength: Int {
        editorView.textView.textStorage?.length ?? 0
    }
}
