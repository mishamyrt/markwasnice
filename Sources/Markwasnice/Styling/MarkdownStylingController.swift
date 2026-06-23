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
        guard result.sourceLength == editorView.string.utf16.count else {
            return
        }

        let sourceMap = SourceMap(text: editorView.string)
        let resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = result.spans.compactMap { span in
            guard let range = sourceMap.nsRange(for: span.range) else {
                return nil
            }

            return ResolvedMarkdownStyleSpan(range: range, kind: span.kind)
        }
        self.resolvedStyleSpans = MarkdownLinkStyleResolver.resolve(
            spans: resolvedStyleSpans, in: editorView.string)
        editorView.applyStyles(self.resolvedStyleSpans)
    }
}
