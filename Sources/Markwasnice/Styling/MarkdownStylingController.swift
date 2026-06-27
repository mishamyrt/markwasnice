import Foundation

@MainActor
final class MarkdownStylingController {
    private let editorView: MarkdownEditorView
    private let parseService = MarkdownParseService()
    private var resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = []

    init(editorView: MarkdownEditorView) {
        self.editorView = editorView
        parseService.onParse = { [weak self] result in
            self?.applyParseResult(result)
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

    private func applyParseResult(_ result: MarkdownParseResult) {
        guard result.source == editorView.string else {
            return
        }

        resolvedStyleSpans = result.spans
        editorView.applyParsedStyles(
            resolvedStyleSpans,
            dirtyRanges: result.dirtyRanges
        )
    }
}
