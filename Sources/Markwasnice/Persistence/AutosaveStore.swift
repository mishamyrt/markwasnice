import Foundation

struct AutosavedDraft: Codable {
    var text: String
    var fileURL: URL?
    /// Drafts sharing a window identifier were tabs of one window; the value
    /// itself is regenerated on every save and only the grouping matters.
    var windowID: UUID?
    /// NSStringFromRect descriptor of the window frame at save time, so the
    /// window reopens with the same size and position. Absent for fullscreen
    /// windows and drafts saved before a window existed.
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

    func load() -> AutosavedDraft? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        return try? JSONDecoder().decode(AutosavedDraft.self, from: data)
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

        return nil
    }

    func save(_ draft: AutosavedDraft) {
        guard let data = try? JSONEncoder().encode(draft) else {
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }

    func saveSession(_ session: AutosavedSession) {
        guard let data = try? JSONEncoder().encode(session) else {
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }
}
