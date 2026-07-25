import Foundation
import Testing
@testable import Markwasnice

@Suite
struct AutosaveStoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @Test
    func roundTripsSession() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let store = AutosaveStore(fileURL: fileURL)

        let session = AutosavedSession(drafts: [
            AutosavedDraft(text: "hello", fileURL: nil, windowID: UUID(), windowFrame: nil),
            AutosavedDraft(text: "world", fileURL: nil, windowID: nil, windowFrame: nil),
        ])
        try await store.saveSession(session)

        let loaded = await store.loadSession()
        #expect(loaded?.drafts.map(\.text) == ["hello", "world"])
    }

    @Test
    func loadsLegacySingleDraft() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let draft = AutosavedDraft(text: "legacy", fileURL: nil, windowID: nil, windowFrame: nil)
        try JSONEncoder().encode(draft).write(to: fileURL)

        let store = AutosaveStore(fileURL: fileURL)
        let loaded = await store.loadSession()
        #expect(loaded?.drafts.map(\.text) == ["legacy"])
    }

    @Test
    func missingFileLoadsNilWithoutQuarantine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")

        let store = AutosaveStore(fileURL: fileURL)
        let loaded = await store.loadSession()
        #expect(loaded == nil)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    @Test
    func quarantinesUndecodableFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let corruptData = Data("not json at all".utf8)
        try corruptData.write(to: fileURL)

        let store = AutosaveStore(fileURL: fileURL)
        let loaded = await store.loadSession()
        #expect(loaded == nil)

        // The original file must be moved aside so the next autosave
        // cannot overwrite the only copy.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let backupURL = fileURL.appendingPathExtension("corrupt")
        #expect(try Data(contentsOf: backupURL) == corruptData)
    }

    @Test
    func quarantineNeverOverwritesExistingBackup() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let backupURL = fileURL.appendingPathExtension("corrupt")
        let earlierBackup = Data("earlier corruption".utf8)
        try earlierBackup.write(to: backupURL)
        let corruptData = Data("later corruption".utf8)
        try corruptData.write(to: fileURL)

        let store = AutosaveStore(fileURL: fileURL)
        _ = await store.loadSession()

        #expect(try Data(contentsOf: backupURL) == earlierBackup)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let fallbackBackups = contents.filter { $0.contains("corrupt-") }
        #expect(fallbackBackups.count == 1)
    }
}
