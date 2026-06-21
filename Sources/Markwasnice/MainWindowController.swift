import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainWindowController: NSWindowController, MarkdownEditorViewDelegate, NSWindowDelegate {
    private let editorView: MarkdownEditorView
    private let parseService = MarkdownParseService()
    private var latestParseResult: MarkdownParseResult?
    private var resolvedStyleSpans: [ResolvedMarkdownStyleSpan] = []
    private var currentFileURL: URL?
    private var documentEdited = false {
        didSet {
            window?.isDocumentEdited = documentEdited
        }
    }

    init(settings: EditorSettings) {
        editorView = MarkdownEditorView(settings: settings)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Untitled"
        window.center()
        window.contentView = editorView

        super.init(window: window)

        editorView.delegate = self
        parseService.onParse = { [weak self] result in
            guard let self else {
                return
            }

            self.latestParseResult = result
            guard result.sourceLength == self.editorView.string.utf16.count else {
                return
            }

            let sourceMap = SourceMap(text: self.editorView.string)
            self.resolvedStyleSpans = result.spans.compactMap { span in
                guard let range = sourceMap.nsRange(for: span.range) else {
                    return nil
                }

                return ResolvedMarkdownStyleSpan(range: range, kind: span.kind)
            }
            self.editorView.applyStyles(self.resolvedStyleSpans)
        }
        window.delegate = self
        parseService.scheduleParse(text: editorView.string)
    }

    func applySettings(_ settings: EditorSettings) {
        editorView.applySettings(settings, spans: resolvedStyleSpans)
    }

    func newDocument() -> Bool {
        guard confirmDiscardingUnsavedChanges() else {
            return false
        }

        currentFileURL = nil
        editorView.setString("", clearsUndo: true)
        documentEdited = false
        latestParseResult = nil
        resolvedStyleSpans = []
        parseService.scheduleParse(text: editorView.string)
        updateWindowTitle()
        editorView.focus()
        return true
    }

    func displayMarkdown(_ text: String, from url: URL) {
        currentFileURL = url
        editorView.setString(text, clearsUndo: true)
        documentEdited = false
        latestParseResult = nil
        resolvedStyleSpans = []
        parseService.scheduleParse(text: text)
        updateWindowTitle()
        editorView.focus()
    }

    func saveDocument(_ sender: Any?) {
        if let url = currentFileURL {
            save(to: url)
        } else {
            saveDocumentAs(sender)
        }
    }

    func saveDocumentAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Untitled.md"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        save(to: url)
    }

    func confirmDiscardingUnsavedChanges() -> Bool {
        guard documentEdited else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Do you want to save changes?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocument(nil)
            return !documentEdited
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }

    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView) {
        documentEdited = true
        parseService.scheduleParse(text: editorView.string)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardingUnsavedChanges()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func save(to url: URL) {
        do {
            try editorView.string.write(to: url, atomically: true, encoding: .utf8)
            currentFileURL = url
            documentEdited = false
            updateWindowTitle()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func updateWindowTitle() {
        window?.title = currentFileURL?.lastPathComponent ?? "Untitled"
    }
}
