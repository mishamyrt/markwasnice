import Foundation

struct AutosavedDraft: Codable {
    var text: String
    var fileURL: URL?
}

struct AutosavedSession: Codable {
    var drafts: [AutosavedDraft]
}

final class AutosaveStore {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Markwasnice", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("AutosavedDraft.json")
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
