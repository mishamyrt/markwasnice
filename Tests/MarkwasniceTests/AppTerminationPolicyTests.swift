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
}
