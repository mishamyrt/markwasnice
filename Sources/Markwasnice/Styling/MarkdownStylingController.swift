import Foundation

@MainActor
final class MarkdownStylingController {
    private let editorView: MarkdownEditorView
    private let parseService = MarkdownParseService()
    private let proofreadingService = ProofreadingService()
    private var resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = []
    private var isProofreadingEnabled = false

    init(editorView: MarkdownEditorView) {
        self.editorView = editorView
        parseService.onParse = { [weak self] result in
            self?.applyParseResult(result)
        }
        proofreadingService.onCheck = { [weak self] issues, source in
            guard let self, isProofreadingEnabled,
                  source == editorView.string
            else {
                return
            }

            editorView.setProofreadingIssues(issues)
        }
    }

    func scheduleParse(text: String) {
        parseService.scheduleParse(text: text)
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
        guard result.source == editorView.string else {
            return
        }

        resolvedStyleSpans = result.spans
        editorView.applyParsedStyles(
            resolvedStyleSpans,
            dirtyRanges: result.dirtyRanges
        )
        if isProofreadingEnabled {
            proofreadingService.scheduleCheck(
                text: result.source,
                protectedRanges: ProofreadingService.protectedRanges(
                    from: result.spans
                )
            )
        }
    }
}
