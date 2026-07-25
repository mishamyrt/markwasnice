import Foundation

struct AutosavedDraft: Codable {
    var text: String
    var fileURL: URL?
    /// Drafts sharing a window identifier were tabs of one window; the value
    /// itself is regenerated on every save and only the grouping matters.
    var windowID: UUID?
    /// NSStringFromRect descriptor of the window frame at save time, so the
    /// window reopens with the same size and position. Tabs of one window
    /// share the frame of the group's selected window. Absent for
    /// fullscreen windows.
    var windowFrame: String?
}

struct AutosavedSession: Codable {
    var drafts: [AutosavedDraft]
}

actor AutosaveStore {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("Markwasnice", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("AutosavedDraft.json")
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func loadSession() -> AutosavedSession? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        if let session = try? decoder.decode(AutosavedSession.self, from: data) {
            return session
        }

        if let draft = try? decoder.decode(AutosavedDraft.self, from: data) {
            return AutosavedSession(drafts: [draft])
        }

        // The file exists but is undecodable; move it aside so the next
        // autosave cannot overwrite the only copy of whatever it contains.
        quarantineCorruptFile()
        return nil
    }

    func saveSession(_ session: AutosavedSession) throws {
        let data = try JSONEncoder().encode(session)
        try data.write(to: fileURL, options: .atomic)
    }

    private func quarantineCorruptFile() {
        let fileManager = FileManager.default
        var backupURL = fileURL.appendingPathExtension("corrupt")
        if fileManager.fileExists(atPath: backupURL.path) {
            // Never clobber an earlier quarantined copy; a timestamped name
            // is unique enough for a once-per-launch failure path.
            backupURL = fileURL.appendingPathExtension(
                "corrupt-\(UInt64(Date().timeIntervalSince1970))"
            )
        }
        try? fileManager.moveItem(at: fileURL, to: backupURL)
    }
}
