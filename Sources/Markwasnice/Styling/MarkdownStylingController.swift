import Foundation

@MainActor
final class MarkdownStylingController {
    private let editorView: MarkdownEditorView
    private let parseService = MarkdownParseService()
    private let proofreadingService = ProofreadingService()
    private var resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = []
    private var isProofreadingEnabled = false

    /// Bumped on every scheduled parse — i.e. on every editor text change,
    /// since all edit paths re-schedule. Async results carry the version
    /// their text was scheduled at, so freshness checks compare two integers
    /// (plus an O(1) length sanity check) instead of walking the whole
    /// document per delivery on the main thread.
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
        textVersion += 1
        parseService.scheduleParse(text: text, version: textVersion)
    }

    func applySettings(_ settings: EditorSettings) {
        editorView.applySettings(settings, spans: resolvedStyleSpans)
    }

    func updateWindowWidthFontScale(for width: CGFloat) {
        editorView.updateWindowWidthFontScale(for: width, spans: resolvedStyleSpans)
    }

    func setProofreadingEnabled(_ enabled: Bool) {
        guard enabled != isProofreadingEnabled else {
            return
        }

        isProofreadingEnabled = enabled
        if enabled {
            proofreadScheduledTextVersion = textVersion
            proofreadingService.scheduleCheck(
                text: editorView.string,
                protectedRanges: ProofreadingService.protectedRanges(
                    from: resolvedStyleSpans
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
