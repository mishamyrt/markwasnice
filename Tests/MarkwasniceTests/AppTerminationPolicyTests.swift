import Foundation
import Testing
@testable import Markwasnice

/// The app quits when its last editor window closes, but not while windows
/// are still on their way: SwiftUI restores its scene windows at launch with
/// no session value and the editor host dismisses them again, so quitting on
/// every last-window closure would kill the app mid-launch.
@MainActor
struct AppTerminationPolicyTests {
    private func makeAppState() throws -> (state: MarkwasniceAppState, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppTerminationPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = AutosaveStore(
            fileURL: directory.appendingPathComponent("AutosavedDraft.json")
        )
        return (MarkwasniceAppState(autosaveStore: store), directory)
    }

    @Test
    func doesNotQuitWhileASessionIsOpen() async throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = await state.initialSessionID()

        #expect(id != nil)
        #expect(!state.canTerminateAfterLastWindowClosed)
    }

    @Test
    func continuousEditsAndLayoutChangesStillAutosave() async throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = await state.initialSessionID()
        let session = try #require(state.session(for: id))
        #expect(await state.flushAutosaveAndWait(force: true))
        let recoveryURL = directory.appendingPathComponent("AutosavedDraft.json")

        var previousText = ""
        for _ in 0 ..< 2 {
            let until = ContinuousClock.now + .milliseconds(2300)
            repeat {
                session.editorView.textView.insertText(
                    "x",
                    replacementRange: NSRange(location: 0, length: 0)
                )
                state.noteWindowLayoutChanged()
                state.noteSelectedTabChanged()
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < until

            let saved = try JSONDecoder().decode(
                AutosavedSession.self,
                from: Data(contentsOf: recoveryURL)
            )
            let text = try #require(saved.drafts.first?.text)
            #expect(text.count > previousText.count)
            previousText = text
        }
        #expect(await state.flushAutosaveAndWait(force: true))
    }

    @Test
    func quitsOnceTheLastSessionIsGone() async throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = await state.initialSessionID()
        let session = try #require(state.session(for: id))
        state.remove(session)

        #expect(state.canTerminateAfterLastWindowClosed)
    }

    /// Before any session exists the app is quittable — a stray window
    /// closure must not leave a windowless app running.
    @Test
    func quitsWhenNoSessionWasEverCreated() throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(state.canTerminateAfterLastWindowClosed)
    }

    /// Restoring a file-backed draft whose text is empty is the "deleted the
    /// whole file's contents and relaunched" case. It has to come back
    /// edited: an unedited session closes without a save prompt, which would
    /// silently revert the deletion.
    @Test
    func restoresEmptiedFileBackedDraftAsEdited() async throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("note.md")
        try "still on disk".write(to: fileURL, atomically: true, encoding: .utf8)
        let autosaved = AutosavedSession(drafts: [
            AutosavedDraft(
                text: "", fileURL: fileURL, windowID: nil, windowFrame: nil
            ),
        ])
        try JSONEncoder().encode(autosaved).write(
            to: directory.appendingPathComponent("AutosavedDraft.json")
        )

        let id = await state.initialSessionID()
        let session = try #require(state.session(for: id))

        // The restored flag starts provisional and is refined by an
        // asynchronous comparison against the file.
        var attempts = 0
        while !session.shellState.isEdited, attempts < 200 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }

        #expect(session.shellState.isEdited)
    }

    @Test
    func restoresPayloadlessFileBackedDraftFromCurrentFileContents() async throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("note.md")
        try "when autosaved".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        let autosaved = AutosavedSession(drafts: [
            AutosavedDraft(
                text: nil,
                fileURL: fileURL,
                windowID: nil,
                windowFrame: nil
            ),
        ])
        try JSONEncoder().encode(autosaved).write(
            to: directory.appendingPathComponent("AutosavedDraft.json")
        )
        try "changed outside the app".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )

        let id = await state.initialSessionID()
        let session = try #require(state.session(for: id))

        #expect(session.editorView.string == "changed outside the app")
        #expect(!session.shellState.isEdited)
    }

    @Test
    func skipsPayloadlessDraftWhenBackingFileIsMissing() async throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingURL = directory.appendingPathComponent("missing.md")
        let autosaved = AutosavedSession(drafts: [
            AutosavedDraft(
                text: nil,
                fileURL: missingURL,
                windowID: nil,
                windowFrame: nil
            ),
        ])
        try JSONEncoder().encode(autosaved).write(
            to: directory.appendingPathComponent("AutosavedDraft.json")
        )

        let id = await state.initialSessionID()
        let session = try #require(state.session(for: id))

        #expect(state.sessions.count == 1)
        #expect(session.fileURL == nil)
        #expect(session.editorView.string.isEmpty)
        #expect(!session.shellState.isEdited)

        #expect(await state.flushAutosaveAndWait(force: true))
        let store = AutosaveStore(
            fileURL: directory.appendingPathComponent("AutosavedDraft.json")
        )
        let loaded = try await store.loadSession()
        guard case let .loaded(savedSession) = loaded else {
            Issue.record("expected the unresolved manifest to be preserved")
            return
        }
        #expect(savedSession.drafts.contains { draft in
            draft.fileURL == missingURL && draft.text == nil
        })
    }

    @Test
    func forcedAutosaveWaitsUntilInitialRecoveryFinishes() async throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("note.md")
        try Data("on disk".utf8).write(to: fileURL)
        let autosaveURL = directory.appendingPathComponent("AutosavedDraft.json")
        let original = AutosavedSession(drafts: [
            AutosavedDraft(
                text: nil,
                fileURL: fileURL,
                windowID: nil,
                windowFrame: nil
            ),
        ])
        try JSONEncoder().encode(original).write(to: autosaveURL)

        let initialID = Task { await state.initialSessionID() }
        await Task.yield()
        #expect(await state.flushAutosaveAndWait(force: true))
        _ = await initialID.value

        let loaded = try await AutosaveStore(fileURL: autosaveURL).loadSession()
        guard case let .loaded(savedSession) = loaded else {
            Issue.record("expected the recovery manifest to remain readable")
            return
        }
        #expect(savedSession.drafts.count == 1)
        #expect(savedSession.drafts[0].fileURL == fileURL)
    }

    @Test
    func windowQueuedBeforeStartupDoesNotBypassRecovery() async throws {
        let (state, directory) = try makeAppState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let autosaveURL = directory.appendingPathComponent("AutosavedDraft.json")
        let recoveredText = "text that must survive launch"
        try JSONEncoder().encode(AutosavedSession(drafts: [
            AutosavedDraft(
                text: recoveredText,
                fileURL: nil,
                windowID: nil,
                windowFrame: nil
            ),
        ])).write(to: autosaveURL)

        state.requestNewWindow()
        let queuedID = try #require(state.pendingWindowIDs.first)
        let initialID = try #require(await state.initialSessionID())

        #expect(initialID != queuedID)
        #expect(state.sessions.count == 2)
        #expect(state.session(for: initialID)?.editorView.string == recoveredText)
        #expect(state.pendingWindowIDs == [queuedID])

        #expect(await state.flushAutosaveAndWait(force: true))
        let loaded = try await AutosaveStore(fileURL: autosaveURL).loadSession()
        guard case let .loaded(savedSession) = loaded else {
            Issue.record("expected the recovery manifest to remain readable")
            return
        }
        #expect(savedSession.drafts.contains { $0.text == recoveredText })
    }
}
