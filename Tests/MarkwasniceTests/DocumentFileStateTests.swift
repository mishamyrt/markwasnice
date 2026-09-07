import Foundation
import Testing
@testable import Markwasnice

@MainActor
struct DocumentFileStateTests {
    private struct PendingWrite: Sendable {
        let text: String
        let revision: FileIO.Revision?
        let continuation: CheckedContinuation<Void, Never>
    }

    @Test
    func queuedSavesKeepOrderAndReleaseClaimsAfterTheSessionCloses() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "document.md")
        try Data("opened".utf8).write(to: url)
        let opened = try await FileIO.readUTF8Snapshot(from: url)
        let state = DocumentFileState(url: url, revision: opened.revision)
        let canonicalURL = FileIO.canonicalDocumentURL(for: url)
        let sessionID = UUID()
        var registry = DocumentRegistry()
        let registered = registry.register(canonicalURL, to: sessionID)
        #expect(registered)
        var isOpen = true
        var claimsFinished = 0
        state.reserveSaveDestination = { url in
            try registry.reserveSave(
                to: FileIO.canonicalDocumentURL(for: url), for: sessionID
            )
        }
        state.finishSaveDestination = { claim, previousURL, succeeded in
            claimsFinished += 1
            registry.finishSave(
                claim, previousDocumentURL: previousURL, succeeded: succeeded && isOpen
            )
        }
        var currentText = "first"
        var isEdited = true
        state.isCurrentText = { $0 == currentText }
        state.onSave = { _, isCurrent in isEdited = !isCurrent }
        let (writes, continuation) = AsyncStream<PendingWrite>.makeStream()
        let write = state.writeSnapshot
        state.writeSnapshot = { text, url, resolvedURL, revision in
            await withCheckedContinuation { resume in
                continuation.yield(PendingWrite(
                    text: text, revision: revision, continuation: resume
                ))
            }
            return try await write(text, url, resolvedURL, revision)
        }
        var pending = writes.makeAsyncIterator()

        let firstSave = try state.startSave(currentText, to: url)
        let firstWrite = try #require(await pending.next())
        #expect(firstWrite.text == "first")
        #expect(firstWrite.revision == opened.revision)
        let skippedSave = try state.startSave("skipped", to: url)
        currentText = "latest"
        let latestSave = try state.startSave(currentText, to: url)
        firstWrite.continuation.resume()

        let latestWrite = try #require(await pending.next())
        #expect(latestWrite.text == "latest")
        let intermediate = try await FileIO.readUTF8Snapshot(from: url)
        #expect(intermediate.text == "first")
        #expect(latestWrite.revision == intermediate.revision)
        #expect(state.revision == intermediate.revision)
        for save in [firstSave, skippedSave] {
            await #expect(throws: CancellationError.self) { try await save.value }
        }

        currentText = "edited after save began"
        isOpen = false
        registry.removeSession(sessionID)
        let openedWhileWriting = registry.beginOpening(canonicalURL)
        #expect(!openedWhileWriting)
        latestWrite.continuation.resume()
        #expect(try await latestSave.value == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == "latest")
        #expect(isEdited)
        #expect(claimsFinished == 3)
        #expect(registry.sessionID(for: canonicalURL) == nil)
        let openedAfterWriting = registry.beginOpening(canonicalURL)
        #expect(openedAfterWriting)
        continuation.finish()
    }

    @Test(arguments: [false, true])
    func aLateExternalReadCannotReplaceEditsOrAnAdoptedDocument(
        adoptsDocument: Bool
    ) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "document.md")
        try Data("opened".utf8).write(to: url)
        let opened = try await FileIO.readUTF8Snapshot(from: url)
        try Data("external".utf8).write(to: url)
        let state = DocumentFileState(url: url, revision: opened.revision)
        var isClean = true
        state.canReload = { isClean }
        state.onReload = { _ in Issue.record("a stale read replaced the document") }
        let (reads, continuation) = AsyncStream<CheckedContinuation<Void, Never>>
            .makeStream()
        let read = state.readSnapshot
        state.readSnapshot = { url, resolvedURL in
            let snapshot = try await read(url, resolvedURL)
            await withCheckedContinuation { continuation.yield($0) }
            return snapshot
        }
        var pending = reads.makeAsyncIterator()
        let reload = Task { await state.reloadFromDiskIfClean() }
        let resume = try #require(await pending.next())
        if adoptsDocument {
            // Even adopting the same URL/revision invalidates an older read.
            state.adopt(url: url, revision: opened.revision)
        } else {
            isClean = false
        }
        resume.resume()
        await reload.value
        #expect(state.revision == opened.revision)
        continuation.finish()
    }

    @Test
    func anOldWriteCannotChangeTheAdoptedFileIdentity() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldURL = directory.appending(path: "old.md")
        let newURL = directory.appending(path: "new.md")
        try Data("old".utf8).write(to: oldURL)
        try Data("new".utf8).write(to: newURL)
        let old = try await FileIO.readUTF8Snapshot(from: oldURL)
        let new = try await FileIO.readUTF8Snapshot(from: newURL)
        let state = DocumentFileState(url: oldURL, revision: old.revision)
        state.onSave = { _, _ in Issue.record("a stale save changed the session") }
        let (writes, continuation) = AsyncStream<CheckedContinuation<Void, Never>>
            .makeStream()
        let write = state.writeSnapshot
        state.writeSnapshot = { text, url, resolvedURL, revision in
            await withCheckedContinuation { continuation.yield($0) }
            return try await write(text, url, resolvedURL, revision)
        }
        var pending = writes.makeAsyncIterator()
        let save = try state.startSave("saved old", to: oldURL)
        let resume = try #require(await pending.next())
        state.adopt(url: newURL, revision: new.revision)
        resume.resume()
        await #expect(throws: CancellationError.self) { try await save.value }
        #expect(state.url == newURL)
        #expect(state.revision == new.revision)
        #expect(try String(contentsOf: oldURL, encoding: .utf8) == "saved old")
        #expect(try String(contentsOf: newURL, encoding: .utf8) == "new")
        continuation.finish()
    }

    @Test
    func aFailedSaveReleasesItsDestination() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "missing/document.md")
        let state = DocumentFileState(url: nil, revision: nil)
        let sessionID = UUID()
        var registry = DocumentRegistry()
        state
            .reserveSaveDestination = { try registry.reserveSave(to: $0, for: sessionID) }
        state.finishSaveDestination = { claim, previousURL, succeeded in
            registry.finishSave(
                claim,
                previousDocumentURL: previousURL,
                succeeded: succeeded
            )
        }
        let save = try state.startSave("draft", to: url)
        await #expect(throws: (any Error).self) { try await save.value }
        #expect(state.url == nil)
        #expect(state.revision == nil)
        let openedAfterFailure = registry.beginOpening(url)
        #expect(openedAfterFailure)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DocumentFileStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
