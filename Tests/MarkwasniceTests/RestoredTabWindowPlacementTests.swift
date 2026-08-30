import Foundation
import Testing
@testable import Markwasnice

@MainActor
struct RestoredTabWindowPlacementTests {
    @Test
    func followerKeepsItsLeadUntilTheLeadIsReady() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoredTabWindowPlacementTests-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let windowID = UUID()
        let autosaved = AutosavedSession(drafts: [
            AutosavedDraft(
                text: "lead",
                fileURL: nil,
                windowID: windowID,
                windowFrame: nil
            ),
            AutosavedDraft(
                text: "follower",
                fileURL: nil,
                windowID: windowID,
                windowFrame: nil
            ),
        ])
        let autosaveURL = directory.appendingPathComponent("AutosavedDraft.json")
        try JSONEncoder().encode(autosaved).write(to: autosaveURL)

        let appState = MarkwasniceAppState(
            autosaveStore: AutosaveStore(fileURL: autosaveURL)
        )
        let leadID = try #require(await appState.initialSessionID())
        let followerID = try #require(appState.takePendingWindowIDs().first)

        #expect(appState.takeRestoreTabLead(for: followerID) { _ in false } == nil)
        #expect(appState.hasPendingRestoreTabLead(for: followerID))
        #expect(
            appState.takeRestoreTabLead(for: followerID) { $0 == leadID } == leadID
        )
        #expect(!appState.hasPendingRestoreTabLead(for: followerID))
    }
}
