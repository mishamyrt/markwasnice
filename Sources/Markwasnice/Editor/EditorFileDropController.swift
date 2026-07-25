@preconcurrency import AppKit
import UniformTypeIdentifiers

/// Drag-and-drop file triage and Markdown link/image path helpers for the
/// editor: which dropped files open as documents, which insert as image
/// links, how image paths relativize against the document, and how link
/// URLs are read off the pasteboard.
@MainActor
final class EditorFileDropController {
    /// Mirrors the editor's document URL; dropped image paths relativize
    /// against its directory.
    var documentURL: URL?

    /// Hands markdown/text file URLs to the owning session to open as
    /// documents.
    var openFileURLs: ([URL]) -> Void = { _ in }
    /// Inserts markup at the current selection through the editor's
    /// undo-gated replace path.
    var insertMarkupAtSelection: (String) -> Void = { _ in }

    /// A drop of markdown/text files opens them as documents; a dropped image
    /// is inserted as a Markdown image link at the drop point. Opening takes
    /// precedence so dragging a `.md` file never pastes its path into the text.
    func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        guard openableFileURLs(from: pasteboard).isEmpty else {
            return .copy
        }

        return imageFileURL(from: pasteboard) == nil ? [] : .copy
    }

    func performFileDrop(
        _ sender: NSDraggingInfo,
        insertionView: NSTextView
    ) -> Bool {
        let pasteboard = sender.draggingPasteboard
        let openableURLs = openableFileURLs(from: pasteboard)
        guard openableURLs.isEmpty else {
            openFileURLs(openableURLs)
            return true
        }

        guard let url = imageFileURL(from: pasteboard) else {
            return false
        }

        let point = insertionView.convert(sender.draggingLocation, from: nil)
        insertMarkdownImage(for: url, at: point, in: insertionView)
        return true
    }

    func pasteboardURLString() -> String? {
        let pasteboard = NSPasteboard.general
        if let url = NSURL(from: pasteboard) as URL? {
            return url.absoluteString
        }

        guard let string = pasteboard.string(forType: .string)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ),
            let url = URL(string: string),
            url.scheme != nil
        else {
            return nil
        }

        return url.absoluteString
    }

    /// File URLs on the pasteboard that the editor can open as documents:
    /// Markdown and plain-text files (Markdown conforms to `public.plain-text`).
    private func openableFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL]
        else {
            return []
        }

        return urls.filter { url in
            guard url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension)
            else {
                return false
            }

            return type.conforms(to: .plainText)
        }
    }

    private func imageFileURL(from pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: nil
        ) as? [URL]
        else {
            return nil
        }

        return urls.first { url in
            guard url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension)
            else {
                return false
            }

            return type.conforms(to: .image)
        }
    }

    private func insertMarkdownImage(
        for url: URL,
        at point: NSPoint,
        in insertionView: NSTextView
    ) {
        let characterIndex = insertionView.characterIndexForInsertion(at: point)
        insertionView.setSelectedRange(
            NSRange(location: characterIndex, length: 0)
        )

        let path = markdownRelativePath(for: url)
        let name = url.deletingPathExtension().lastPathComponent.nilIfEmpty
            ?? "image"
        insertMarkupAtSelection("![\(Self.escapeLinkText(name))](\(path))")
    }

    func markdownRelativePath(for url: URL) -> String {
        guard let documentURL else {
            return url.lastPathComponent
        }

        return Self.relativePath(
            from: documentURL.deletingLastPathComponent(),
            to: url
        )
    }

    nonisolated static func relativePath(
        from baseDirectory: URL,
        to targetURL: URL
    ) -> String {
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        var sharedPrefixCount = 0

        while sharedPrefixCount < baseComponents.count,
              sharedPrefixCount < targetComponents.count,
              baseComponents[sharedPrefixCount] == targetComponents[sharedPrefixCount]
        {
            sharedPrefixCount += 1
        }

        guard sharedPrefixCount > 0 else {
            return targetURL.lastPathComponent
        }

        let upComponents = Array(
            repeating: "..",
            count: baseComponents.count - sharedPrefixCount
        )
        let downComponents = targetComponents.dropFirst(sharedPrefixCount)
        return (upComponents + downComponents).joined(separator: "/")
    }

    nonisolated static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "]", with: "\\]")
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
