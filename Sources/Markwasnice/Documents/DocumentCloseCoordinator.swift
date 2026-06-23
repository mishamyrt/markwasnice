import AppKit
import UniformTypeIdentifiers

@MainActor
final class DocumentCloseCoordinator {
    private let isAppTerminating: () -> Bool
    private var isCloseApproved = false
    private var isPromptVisible = false

    init(isAppTerminating: @escaping () -> Bool) {
        self.isAppTerminating = isAppTerminating
    }

    func windowShouldClose(
        _ window: NSWindow,
        document: MarkdownDocument?,
        title: String,
        onApprovedClose: @escaping () -> Void
    ) -> Bool {
        guard !isCloseApproved,
              !isPromptVisible,
              !isAppTerminating(),
              let document,
              document.hasUnsavedChangesForDisplay else {
            return true
        }

        promptToSaveBeforeClosing(
            window,
            document: document,
            title: title,
            onApprovedClose: onApprovedClose
        )
        return false
    }

    private func promptToSaveBeforeClosing(
        _ window: NSWindow,
        document: MarkdownDocument,
        title: String,
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

        alert.beginSheetModal(for: window) { [weak self, weak document] response in
            guard let self, let document else {
                return
            }

            switch response {
            case .alertFirstButtonReturn:
                self.saveBeforeClosing(document, window: window, onApprovedClose: onApprovedClose)
            case .alertSecondButtonReturn:
                self.closeAfterUserApproval(onApprovedClose)
            default:
                self.isPromptVisible = false
            }
        }
    }

    private func saveBeforeClosing(
        _ document: MarkdownDocument,
        window: NSWindow,
        onApprovedClose: @escaping () -> Void
    ) {
        if let url = document.fileURL {
            save(
                document,
                to: url,
                operation: .saveOperation,
                window: window,
                onApprovedClose: onApprovedClose
            )
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md") ?? .plainText,
            .plainText,
        ]
        panel.nameFieldStringValue = "Untitled.md"
        panel.beginSheetModal(for: window) { [weak self, weak document] response in
            guard let self, let document else {
                return
            }

            guard response == .OK, let url = panel.url else {
                self.isPromptVisible = false
                return
            }

            self.save(
                document,
                to: url,
                operation: .saveAsOperation,
                window: window,
                onApprovedClose: onApprovedClose
            )
        }
    }

    private func save(
        _ document: MarkdownDocument,
        to url: URL,
        operation: NSDocument.SaveOperationType,
        window: NSWindow,
        onApprovedClose: @escaping () -> Void
    ) {
        document.save(to: url, ofType: MarkdownDocument.fileType, for: operation) { [weak self] error in
            guard let self else {
                return
            }

            if let error {
                self.isPromptVisible = false
                NSAlert(error: error).beginSheetModal(for: window)
                return
            }

            self.closeAfterUserApproval(onApprovedClose)
        }
    }

    private func closeAfterUserApproval(_ onApprovedClose: () -> Void) {
        isCloseApproved = true
        isPromptVisible = false
        onApprovedClose()
    }
}
