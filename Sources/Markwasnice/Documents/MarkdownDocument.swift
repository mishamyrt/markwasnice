import AppKit

@MainActor
final class MarkdownDocument: NSDocument {
    static let fileType = "Markdown"

    var onAutosaveNeeded: (() -> Void)?
    var onAutosaveNow: (() -> Void)?

    private var settings: EditorSettings
    private var hasUnsavedFileChanges = false {
        didSet {
            refreshWindowState()
        }
    }
    nonisolated(unsafe) private var text = ""

    override class var autosavesInPlace: Bool {
        false
    }

    override var isDocumentEdited: Bool {
        false
    }

    init(settings: EditorSettings) {
        self.settings = settings
        super.init()
    }

    override init() {
        settings = EditorSettingsStore().load()
        super.init()
    }

    override func makeWindowControllers() {
        let controller = MainWindowController(document: self, settings: settings)
        addWindowController(controller)
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(text.utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let string = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadInapplicableStringEncodingError
            )
        }

        text = string
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        if change == .changeCleared {
            hasUnsavedFileChanges = false
        }

        refreshWindowState()
    }

    override func canClose(
        withDelegate delegate: Any,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        flushAutosave()
        super.canClose(
            withDelegate: delegate,
            shouldClose: shouldCloseSelector,
            contextInfo: contextInfo
        )
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil {
                self?.hasUnsavedFileChanges = false
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                self?.refreshWindowState()
                self?.requestAutosave()
            }

            completionHandler(error)
        }
    }

    func loadText(_ text: String, from url: URL) {
        self.text = text
        fileURL = url
        hasUnsavedFileChanges = false
        refreshWindowState()
    }

    func restore(_ draft: AutosavedDraft) {
        text = draft.text
        fileURL = draft.fileURL
        hasUnsavedFileChanges = isDraftEdited(draft)
        refreshWindowState()
    }

    func editorTextDidChange(_ text: String) {
        guard text != self.text else {
            return
        }

        self.text = text
        hasUnsavedFileChanges = true
        requestAutosave()
    }

    func applySettings(_ settings: EditorSettings) {
        self.settings = settings
        for controller in windowControllers {
            (controller as? MainWindowController)?.applySettings(settings)
        }
    }

    func refreshWindowState() {
        for controller in windowControllers {
            (controller as? MainWindowController)?.refreshDocumentState()
        }
    }

    func requestAutosave() {
        onAutosaveNeeded?()
    }

    func flushAutosave() {
        onAutosaveNow?()
    }

    var editorText: String {
        text
    }

    var autosavedDraft: AutosavedDraft {
        AutosavedDraft(text: text, fileURL: fileURL)
    }

    var hasUnsavedChangesForDisplay: Bool {
        hasUnsavedFileChanges
    }

    private func isDraftEdited(_ draft: AutosavedDraft) -> Bool {
        guard !draft.text.isEmpty else {
            return false
        }

        guard let fileURL = draft.fileURL else {
            return true
        }

        return (try? String(contentsOf: fileURL, encoding: .utf8)) != draft.text
    }
}
