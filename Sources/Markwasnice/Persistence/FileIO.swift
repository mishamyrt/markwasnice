import Foundation

enum FileIO {
    static func readUTF8(from url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    static func writeUTF8(_ text: String, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try Data(text.utf8).write(to: url, options: .atomic)
        }.value
    }

    static func hasDifferentUTF8Contents(at url: URL, from text: String) async -> Bool {
        await Task.detached(priority: .utility) {
            (try? String(contentsOf: url, encoding: .utf8)) != text
        }.value
    }
}
