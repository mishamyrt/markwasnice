import AppKit
import UniformTypeIdentifiers

@MainActor
final class EditorDocumentSession: ObservableObject, Identifiable,
    MarkdownEditorViewDelegate
{
    static let editorTopInset: CGFloat = 0
    static let editorBottomInset: CGFloat = 72

    let id = UUID()
    let editorView: MarkdownEditorView
    let shellState: EditorShellState

    private let stylingController: MarkdownStylingController
    private let onAutosaveNeeded: () -> Void
    private var wordCountTask: Task<Void, Never>?
    private var isCloseApproved = false
    private var isPromptVisible = false
    private var isPointerInChromeRevealZone = false
    private var text: String

    private(set) var fileURL: URL? {
        didSet {
            updateTitle()
        }
    }

    private var hasUnsavedFileChanges: Bool {
        didSet {
            updateTitle()
        }
    }

    init(
        text: String,
        fileURL: URL?,
        isEdited: Bool,
        settings: EditorSettings,
        onAutosaveNeeded: @escaping () -> Void
    ) {
        self.text = text
        self.fileURL = fileURL
        hasUnsavedFileChanges = isEdited
        self.onAutosaveNeeded = onAutosaveNeeded
        editorView = MarkdownEditorView(settings: settings)
        shellState = EditorShellState()
        stylingController = MarkdownStylingController(editorView: editorView)

        shellState.onTopHoverChanged = { [weak self] isHovering in
            self?.handleTopHoverChanged(isHovering)
        }
        shellState.onUndo = { [weak self] in
            self?.editorView.window?.firstResponder?.tryToPerform(
                Selector(("undo:")), with: nil
            )
        }
        shellState.onRedo = { [weak self] in
            self?.editorView.window?.firstResponder?.tryToPerform(
                Selector(("redo:")), with: nil
            )
        }

        editorView.delegate = self
        editorView.documentURL = fileURL
        editorView.setString(text, clearsUndo: true)
        applyChromeInsets(isFullScreen: false)
        stylingController.scheduleParse(text: text)
        updateTitle()
        scheduleWordCount()
    }

    func markdownEditorViewDidChangeText(_ editorView: MarkdownEditorView) {
        guard editorView.string != text else {
            return
        }

        text = editorView.string
        hasUnsavedFileChanges = true
        onAutosaveNeeded()
        stylingController.scheduleParse(text: editorView.string)
        scheduleWordCount()
        hideChrome()
    }

    func markdownEditorViewDidScroll(_: MarkdownEditorView) {
        hideChrome()
    }

    func updateWindowWidth(_ width: CGFloat) {
        stylingController.updateWindowWidthFontScale(for: width)
    }

    func setFullScreen(_ isFullScreen: Bool) {
        guard shellState.isFullScreen != isFullScreen else {
            return
        }

        shellState.isFullScreen = isFullScreen
        applyChromeInsets(isFullScreen: isFullScreen)
    }

    func applySettings(_ settings: EditorSettings) {
        stylingController.applySettings(settings)
    }

    func pasteAsLink() {
        editorView.pasteAsLink()
    }

    func applyMarkup(_ command: MarkdownMarkupCommand) {
        editorView.applyMarkup(command)
    }

    func save() {
        guard let fileURL else {
            saveAs()
            return
        }

        _ = save(to: fileURL)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        _ = save(to: url)
    }

    func windowShouldClose(_ window: NSWindow, onApprovedClose: @escaping () -> Void)
        -> Bool
    {
        guard !isCloseApproved,
              !isPromptVisible,
              hasUnsavedFileChanges
        else {
            return true
        }

        promptToSaveBeforeClosing(window, onApprovedClose: onApprovedClose)
        return false
    }

    var autosavedDraft: AutosavedDraft {
        AutosavedDraft(text: text, fileURL: fileURL)
    }

    var title: String {
        fileURL?.lastPathComponent ?? "Untitled"
    }

    @discardableResult
    private func save(to url: URL) -> Bool {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            fileURL = url
            editorView.documentURL = url
            hasUnsavedFileChanges = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            onAutosaveNeeded()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private func promptToSaveBeforeClosing(
        _ window: NSWindow,
        onApprovedClose: @escaping () -> Void
    ) {
        isPromptVisible = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes you made to \"\(title)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                return
            }

            switch response {
            case .alertFirstButtonReturn:
                self.saveBeforeClosing(window, onApprovedClose: onApprovedClose)
            case .alertSecondButtonReturn:
                self.closeAfterUserApproval(onApprovedClose)
            default:
                self.isPromptVisible = false
            }
        }
    }

    private func saveBeforeClosing(
        _ window: NSWindow,
        onApprovedClose: @escaping () -> Void
    ) {
        if let fileURL {
            if save(to: fileURL) {
                closeAfterUserApproval(onApprovedClose)
            } else {
                isPromptVisible = false
            }
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = "Untitled.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                return
            }

            guard response == .OK, let url = panel.url else {
                self.isPromptVisible = false
                return
            }

            if self.save(to: url) {
                self.closeAfterUserApproval(onApprovedClose)
            } else {
                self.isPromptVisible = false
            }
        }
    }

    private func closeAfterUserApproval(_ onApprovedClose: () -> Void) {
        isCloseApproved = true
        isPromptVisible = false
        onApprovedClose()
    }

    private func updateTitle() {
        shellState.updateTitle(title, isEdited: hasUnsavedFileChanges)
    }

    private func scheduleWordCount() {
        wordCountTask?.cancel()
        let text = editorView.string
        wordCountTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }

            let count = Self.wordCount(in: text)
            await MainActor.run {
                guard !Task.isCancelled else {
                    return
                }

                self?.shellState.wordCount = count
            }
        }
    }

    private func applyChromeInsets(isFullScreen: Bool) {
        let toolbarHeight = isFullScreen ? 0 : EditorShellState.toolbarRevealHeight
        editorView.setChromeInsets(
            top: toolbarHeight + Self.editorTopInset,
            bottom: Self.editorBottomInset,
            protectedTop: toolbarHeight
        )
    }

    nonisolated private static func wordCount(in text: String) -> Int {
        text.split { character in
            character.isWhitespace || character.isPunctuation
        }.count
    }

    private func showChrome() {
        shellState.isToolbarVisible = true
        shellState.isStatusBarVisible = true
    }

    private func hideChrome() {
        guard !isPointerInChromeRevealZone else {
            return
        }

        hideChromeNow()
    }

    private func hideChromeNow() {
        shellState.isToolbarVisible = false
        shellState.isStatusBarVisible = false
    }

    private func handleTopHoverChanged(_ isHovering: Bool) {
        isPointerInChromeRevealZone = isHovering
        if isHovering {
            showChrome()
        }
    }
}
