import Darwin
import Foundation

/// Bridges coordinated changes and raw file-system events into the document
/// session. A new presenter is created when Save As changes the backing URL,
/// which keeps the URL properties immutable and therefore safe for Foundation
/// to read from any queue.
final class DocumentFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    nonisolated let presentedItemURL: URL?
    nonisolated let presentedItemOperationQueue = OperationQueue.main

    private let onChange: @MainActor @Sendable () -> Void
    private let monitorQueue = DispatchQueue(
        label: "com.mishamyrt.Markwasnice.document-file-monitor",
        qos: .utility
    )
    private let registrationLock = NSLock()
    private var isRegistered = false
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
        super.init()
        isRegistered = true
        fileSource = makeSource(for: url, eventMask: [
            .write, .delete, .rename, .revoke, .attrib, .extend,
        ])
        directorySource = makeSource(
            for: url.deletingLastPathComponent(),
            eventMask: [.write, .delete, .rename, .revoke]
        )
        NSFileCoordinator.addFilePresenter(self)
    }

    func presentedItemDidChange() {
        rearmFileSource()
        Task { @MainActor [onChange] in
            onChange()
        }
    }

    func invalidate() {
        registrationLock.lock()
        let shouldRemove = isRegistered
        isRegistered = false
        let fileSource = fileSource
        self.fileSource = nil
        let directorySource = directorySource
        self.directorySource = nil
        registrationLock.unlock()

        if shouldRemove {
            fileSource?.cancel()
            directorySource?.cancel()
            NSFileCoordinator.removeFilePresenter(self)
        }
    }

    private func makeSource(
        for url: URL,
        eventMask: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: eventMask,
            queue: monitorQueue
        )
        source.setEventHandler { [weak self] in
            self?.fileSystemItemDidChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    private func fileSystemItemDidChange() {
        rearmFileSource()

        registrationLock.lock()
        let shouldNotify = isRegistered
        registrationLock.unlock()
        guard shouldNotify else {
            return
        }

        Task { @MainActor [onChange] in
            onChange()
        }
    }

    /// Atomic saves replace the inode behind the path. The directory source
    /// notices that replacement; reopening here moves the file source onto
    /// the new inode so later in-place writes remain observable.
    private func rearmFileSource() {
        guard let url = presentedItemURL else {
            return
        }
        let replacement = makeSource(for: url, eventMask: [
            .write, .delete, .rename, .revoke, .attrib, .extend,
        ])

        registrationLock.lock()
        guard isRegistered else {
            registrationLock.unlock()
            replacement?.cancel()
            return
        }
        let previous = fileSource
        fileSource = replacement
        registrationLock.unlock()
        previous?.cancel()
    }

    deinit {
        invalidate()
    }
}
