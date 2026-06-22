import Foundation

struct AutosavedDraft: Codable {
    var text: String
    var fileURL: URL?
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

    func save(_ draft: AutosavedDraft) {
        guard let data = try? JSONEncoder().encode(draft) else {
            return
        }

        try? data.write(to: fileURL, options: .atomic)
    }
}
