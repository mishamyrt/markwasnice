import Foundation

struct AutosavedDraft: Codable, Sendable {
    /// Recovery payload. Clean file-backed documents omit it and are read
    /// from their file on launch; untitled and edited documents always keep
    /// a value, including an explicitly empty string.
    var text: String?
    var fileURL: URL?
    /// Drafts sharing a window identifier were tabs of one window; the value
    /// itself is regenerated on every save and only the grouping matters.
    var windowID: UUID?
    /// NSStringFromRect descriptor of the window frame at save time, so the
    /// window reopens with the same size and position. Tabs of one window
    /// share the frame of the group's selected window. Absent for
    /// fullscreen windows.
    var windowFrame: String?

    var hasRestorableContent: Bool {
        text != nil || fileURL != nil
    }
}

struct AutosavedSession: Codable, Sendable {
    var drafts: [AutosavedDraft]
}

actor AutosaveStore {
    enum LoadResult: Sendable {
        case missing
        case loaded(AutosavedSession)
        case corruptFileQuarantined(backupURL: URL)
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private var latestAcceptedGeneration: UInt64?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Markwasnice", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("AutosavedDraft.json")
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func loadSession() throws -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            guard Self.isFileNotFound(error) else {
                throw error
            }

            return .missing
        }

        let decoder = JSONDecoder()
        if let session = try? decoder.decode(AutosavedSession.self, from: data),
           session.drafts.allSatisfy(\.hasRestorableContent)
        {
            return .loaded(session)
        }

        if let draft = try? decoder.decode(AutosavedDraft.self, from: data),
           draft.hasRestorableContent
        {
            return .loaded(AutosavedSession(drafts: [draft]))
        }

        // The file exists but is undecodable; move it aside so the next
        // autosave cannot overwrite the only copy of whatever it contains.
        return try .corruptFileQuarantined(backupURL: quarantineCorruptFile())
    }

    func saveSession(_ session: AutosavedSession, generation: UInt64) throws {
        // Actor isolation serializes writes but does not order the detached
        // tasks that arrive here. Claim the generation before doing I/O so an
        // older task can never write after a newer one, even if the newer write
        // itself fails. The same generation remains retryable.
        if let latestAcceptedGeneration, generation < latestAcceptedGeneration {
            return
        }
        latestAcceptedGeneration = generation

        let data = try JSONEncoder().encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    private func quarantineCorruptFile() throws -> URL {
        var backupURL = fileURL.appendingPathExtension("corrupt")
        if fileManager.fileExists(atPath: backupURL.path) {
            // Never clobber an earlier quarantined copy; a timestamped name
            // is unique enough for a once-per-launch failure path.
            backupURL = fileURL.appendingPathExtension(
                "corrupt-\(UInt64(Date().timeIntervalSince1970))"
            )
        }
        try fileManager.moveItem(at: fileURL, to: backupURL)
        return backupURL
    }

    nonisolated private static func isFileNotFound(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileReadNoSuchFileError
        {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(POSIXErrorCode.ENOENT.rawValue)
        {
            return true
        }

        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isFileNotFound(underlying)
    }
}
