import Foundation
import Testing
@testable import Markwasnice

struct AutosaveStoreTests {
    private struct LegacyAutosavedDraft: Codable {
        var text: String
        var fileURL: URL?
        var windowID: UUID?
        var windowFrame: String?
    }

    private struct LegacyAutosavedSession: Codable {
        var drafts: [LegacyAutosavedDraft]
    }

    private final class FailingMoveFileManager: FileManager, @unchecked Sendable {
        enum Failure: Error {
            case moveRejected
        }

        override func moveItem(at _: URL, to _: URL) throws {
            throw Failure.moveRejected
        }
    }

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
            AutosavedDraft(
                text: "hello",
                fileURL: nil,
                windowID: UUID(),
                windowFrame: nil
            ),
            AutosavedDraft(text: "world", fileURL: nil, windowID: nil, windowFrame: nil),
        ])
        try await store.saveSession(session, generation: 1)

        let loaded = try await store.loadSession()
        guard case let .loaded(loadedSession) = loaded else {
            Issue.record("expected an autosaved session")
            return
        }
        #expect(loadedSession.drafts.map(\.text) == ["hello", "world"])
    }

    @Test
    func loadsLegacySingleDraft() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let draft = LegacyAutosavedDraft(
            text: "legacy",
            fileURL: nil,
            windowID: nil,
            windowFrame: nil
        )
        try JSONEncoder().encode(draft).write(to: fileURL)

        let store = AutosaveStore(fileURL: fileURL)
        let loaded = try await store.loadSession()
        guard case let .loaded(loadedSession) = loaded else {
            Issue.record("expected a migrated legacy draft")
            return
        }
        #expect(loadedSession.drafts.map(\.text) == ["legacy"])
    }

    @Test
    func loadsLegacySessionWithRequiredTextPayloads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let session = LegacyAutosavedSession(drafts: [
            LegacyAutosavedDraft(
                text: "legacy session",
                fileURL: URL(fileURLWithPath: "/tmp/legacy.md"),
                windowID: nil,
                windowFrame: nil
            ),
        ])
        try JSONEncoder().encode(session).write(to: fileURL)

        let store = AutosaveStore(fileURL: fileURL)
        let loaded = try await store.loadSession()
        guard case let .loaded(loadedSession) = loaded else {
            Issue.record("expected a migrated legacy session")
            return
        }

        #expect(loadedSession.drafts.map(\.text) == ["legacy session"])
    }

    @Test
    func omitsAbsentRecoveryTextFromJSON() throws {
        let draft = AutosavedDraft(
            text: nil,
            fileURL: URL(fileURLWithPath: "/tmp/clean.md"),
            windowID: nil,
            windowFrame: nil
        )

        let data = try JSONEncoder().encode(draft)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["text"] == nil)
        #expect(object["fileURL"] != nil)
    }

    @Test
    func quarantinesDraftWithoutTextOrBackingFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let invalidSession = AutosavedSession(drafts: [
            AutosavedDraft(
                text: nil,
                fileURL: nil,
                windowID: nil,
                windowFrame: nil
            ),
        ])
        try JSONEncoder().encode(invalidSession).write(to: fileURL)

        let store = AutosaveStore(fileURL: fileURL)
        let loaded = try await store.loadSession()
        guard case let .corruptFileQuarantined(backupURL) = loaded else {
            Issue.record("expected an invalid draft to be quarantined")
            return
        }

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test
    func missingFileHasADistinctLoadResultWithoutQuarantine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")

        let store = AutosaveStore(fileURL: fileURL)
        let loaded = try await store.loadSession()
        guard case .missing = loaded else {
            Issue.record("expected a missing autosave result")
            return
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.isEmpty)
    }

    @Test
    func readFailureIsNotTreatedAsMissing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: false
        )
        let store = AutosaveStore(fileURL: fileURL)

        var didThrow = false
        do {
            _ = try await store.loadSession()
        } catch {
            didThrow = true
        }

        #expect(didThrow)
    }

    @Test
    func quarantinesUndecodableFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let corruptData = Data("not json at all".utf8)
        try corruptData.write(to: fileURL)

        let store = AutosaveStore(fileURL: fileURL)
        let loaded = try await store.loadSession()
        guard case let .corruptFileQuarantined(backupURL) = loaded else {
            Issue.record("expected a quarantined corrupt autosave")
            return
        }

        // The original file must be moved aside so the next autosave
        // cannot overwrite the only copy.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(backupURL == fileURL.appendingPathExtension("corrupt"))
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
        let loaded = try await store.loadSession()
        guard case let .corruptFileQuarantined(quarantinedURL) = loaded else {
            Issue.record("expected a quarantined corrupt autosave")
            return
        }

        #expect(try Data(contentsOf: backupURL) == earlierBackup)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(quarantinedURL != backupURL)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let fallbackBackups = contents.filter { $0.contains("corrupt-") }
        #expect(fallbackBackups.count == 1)
    }

    @Test
    func quarantineFailureIsPropagatedAndKeepsTheOriginal() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let corruptData = Data("not json at all".utf8)
        try corruptData.write(to: fileURL)
        let store = AutosaveStore(
            fileURL: fileURL,
            fileManager: FailingMoveFileManager()
        )

        do {
            _ = try await store.loadSession()
            Issue.record("expected the quarantine failure to be propagated")
        } catch FailingMoveFileManager.Failure.moveRejected {
            #expect(try Data(contentsOf: fileURL) == corruptData)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func staleGenerationCannotOverwriteNewerSession() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        let store = AutosaveStore(fileURL: fileURL)
        let stale = AutosavedSession(drafts: [
            AutosavedDraft(
                text: "stale", fileURL: nil, windowID: nil, windowFrame: nil
            ),
        ])
        let latest = AutosavedSession(drafts: [
            AutosavedDraft(
                text: "latest", fileURL: nil, windowID: nil, windowFrame: nil
            ),
        ])

        try await store.saveSession(latest, generation: 2)
        try await store.saveSession(stale, generation: 1)

        let loaded = try await store.loadSession()
        guard case let .loaded(session) = loaded else {
            Issue.record("expected the latest autosaved session")
            return
        }
        #expect(session.drafts.map(\.text) == ["latest"])
    }

    @Test
    func failedNewerGenerationStillRejectsStaleWrites() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("AutosavedDraft.json")
        try FileManager.default.createDirectory(
            at: fileURL,
            withIntermediateDirectories: false
        )
        let store = AutosaveStore(fileURL: fileURL)
        let stale = AutosavedSession(drafts: [
            AutosavedDraft(
                text: "stale", fileURL: nil, windowID: nil, windowFrame: nil
            ),
        ])
        let latest = AutosavedSession(drafts: [
            AutosavedDraft(
                text: "latest", fileURL: nil, windowID: nil, windowFrame: nil
            ),
        ])

        do {
            try await store.saveSession(latest, generation: 2)
            Issue.record("expected the first write to fail")
        } catch {
            try FileManager.default.removeItem(at: fileURL)
        }

        try await store.saveSession(stale, generation: 1)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        try await store.saveSession(latest, generation: 2)
        let loaded = try await store.loadSession()
        guard case let .loaded(session) = loaded else {
            Issue.record("expected the retried latest autosave")
            return
        }
        #expect(session.drafts.map(\.text) == ["latest"])
    }
}
