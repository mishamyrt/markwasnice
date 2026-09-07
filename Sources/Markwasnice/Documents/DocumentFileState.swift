import Foundation

/// Owns file identity, observation and serialized save transactions. The
/// session supplies text and presents decisions; this type owns disk state.
@MainActor
final class DocumentFileState {
    enum ConflictResolution {
        case discardLocalChanges
        case overwriteFile
        case cancel
    }

    private(set) var url: URL?
    var revision: FileIO.Revision?
    var reserveSaveDestination: ((URL) throws -> DocumentRegistry.SaveClaim)?
    var finishSaveDestination: ((DocumentRegistry.SaveClaim, URL?, Bool) -> Void)?
    var canReload: () -> Bool = { false }
    var isCurrentText: (String) -> Bool = { _ in false }
    var resolveConflict: (URL) -> ConflictResolution = { _ in .cancel }
    var onReload: ((FileIO.UTF8Snapshot) -> Void)?
    var onSave: ((URL, Bool) -> Void)?

    /// The two asynchronous boundaries can be held open by transaction tests.
    var readSnapshot: @Sendable (URL, URL) async throws -> FileIO.UTF8Snapshot = {
        try await FileIO.readUTF8Snapshot(from: $0, resolvingTo: $1)
    }

    var writeSnapshot: @Sendable (String, URL, URL, FileIO.Revision?) async throws
        -> FileIO.Revision = { text, url, resolvedURL, revision in
            if let revision {
                return try await FileIO.writeUTF8(
                    text, to: url, ifUnmodifiedSince: revision
                )
            }
            return try await FileIO.writeUTF8(text, to: url, resolvingTo: resolvedURL)
        }

    private var saveTask: Task<Bool, Error>?
    private var reloadTask: Task<Void, Never>?
    private var presenter: DocumentFilePresenter?
    private var identityGeneration = 0

    init(url: URL?, revision: FileIO.Revision?) {
        self.url = url
        self.revision = revision
        observeFileChanges()
    }

    deinit {
        reloadTask?.cancel()
        presenter?.invalidate()
    }

    func adopt(url: URL, revision: FileIO.Revision?) {
        identityGeneration &+= 1
        saveTask?.cancel()
        self.url = url
        self.revision = revision
        observeFileChanges()
    }

    /// Reserves identity and captures the snapshot synchronously, returning
    /// an awaitable outcome. A completed older write advances the revision
    /// even when superseded, before the next conditional write starts.
    func startSave(_ text: String, to destination: URL) throws -> Task<Bool, Error> {
        try Task.checkCancellation()
        let previousDocumentURL = url.map { FileIO.canonicalDocumentURL(for: $0) }
        let resolvedDestination = FileIO.canonicalDocumentURL(for: destination)
        let isCurrentDocument =
            url?.standardizedFileURL == destination.standardizedFileURL
                || previousDocumentURL == resolvedDestination
        if isCurrentDocument, revision == nil {
            throw FileIO.ConditionalWriteError.revisionUnavailable(destination)
        }
        let claim = try reserveSaveDestination?(destination)
        let finishClaim = finishSaveDestination
        let generation = identityGeneration
        let previousTask = saveTask
        previousTask?.cancel()

        let task = Task { [self] in
            var didFinishClaim = false
            defer {
                if let claim, !didFinishClaim {
                    finishClaim?(claim, previousDocumentURL, false)
                }
            }
            // Detached file writes cannot be interrupted. A queued save
            // waits for the in-flight write, but skips its own work if a
            // newer request has already replaced it.
            _ = await previousTask?.result
            try Task.checkCancellation()

            do {
                let savedRevision: FileIO.Revision
                do {
                    let expectedRevision = isCurrentDocument ? revision : nil
                    if isCurrentDocument, expectedRevision == nil {
                        throw FileIO.ConditionalWriteError
                            .revisionUnavailable(destination)
                    }
                    savedRevision = try await writeSnapshot(
                        text, destination, claim?.documentURL ?? resolvedDestination,
                        expectedRevision
                    )
                } catch FileIO.ConditionalWriteError.modifiedExternally
                    where isCurrentDocument
                {
                    try Task.checkCancellation()
                    let resolution = canReload() && isCurrentText(text)
                        ? .discardLocalChanges
                        : resolveConflict(destination)
                    switch resolution {
                    case .discardLocalChanges:
                        let snapshot = try await readSnapshot(
                            destination, previousDocumentURL ?? resolvedDestination
                        )
                        try Task.checkCancellation()
                        guard isCurrentText(text) else {
                            return false
                        }
                        revision = snapshot.revision
                        onReload?(snapshot)
                        return true
                    case .overwriteFile:
                        savedRevision = try await writeSnapshot(
                            text, destination, previousDocumentURL ?? resolvedDestination,
                            nil
                        )
                    case .cancel:
                        return false
                    }
                }

                if isCurrentDocument, generation == identityGeneration {
                    revision = savedRevision
                }
                try Task.checkCancellation()
                if let claim {
                    finishClaim?(claim, previousDocumentURL, true)
                    didFinishClaim = true
                }
                url = destination
                revision = savedRevision
                observeFileChanges()
                let didSaveCurrentText = isCurrentText(text)
                onSave?(destination, didSaveCurrentText)
                return didSaveCurrentText
            } catch {
                // A superseded transaction must not surface a stale alert.
                try Task.checkCancellation()
                throw error
            }
        }
        saveTask = task
        return task
    }

    /// User edits, identity changes and newer revisions all invalidate an
    /// external read that began while the document was clean.
    func reloadFromDiskIfClean() async {
        guard canReload(), let url, let revision,
              let documentURL = presenter?.presentedItemURL
        else {
            return
        }
        let generation = identityGeneration
        guard let snapshot = try? await readSnapshot(url, documentURL),
              !Task.isCancelled, canReload(), generation == identityGeneration,
              self.revision == revision, snapshot.revision != revision
        else {
            return
        }
        self.revision = snapshot.revision
        onReload?(snapshot)
    }

    private func observeFileChanges() {
        reloadTask?.cancel()
        presenter?.invalidate()
        presenter = url.map { url in
            DocumentFilePresenter(
                url: FileIO.canonicalDocumentURL(for: url)
            ) { [weak self] in
                self?.scheduleReload()
            }
        }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            // Atomic replacement emits both attribute and content changes.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else {
                return
            }
            await self?.reloadFromDiskIfClean()
        }
    }
}
