import Foundation
import Testing
@testable import Markwasnice

struct DocumentRegistryTests {
    private let fileURL = URL(fileURLWithPath: "/tmp/document.md")

    @Test
    func onlyOneOpenCanOwnAnUnregisteredURL() {
        var registry = DocumentRegistry()

        let firstClaim = registry.beginOpening(fileURL)
        let duplicateClaim = registry.beginOpening(fileURL)
        #expect(firstClaim)
        #expect(!duplicateClaim)

        registry.finishOpening(fileURL)
        let claimAfterFinish = registry.beginOpening(fileURL)
        #expect(claimAfterFinish)
    }

    @Test
    func registeredDocumentRoutesBackToItsSession() {
        var registry = DocumentRegistry()
        let sessionID = UUID()

        let didRegister = registry.register(fileURL, to: sessionID)
        #expect(didRegister)
        #expect(registry.sessionID(for: fileURL) == sessionID)
        let didBeginDuplicateOpen = registry.beginOpening(fileURL)
        #expect(!didBeginDuplicateOpen)
    }

    @Test
    func saveAsCannotClaimAURLOwnedByAnotherSession() throws {
        var registry = DocumentRegistry()
        let ownerID = UUID()
        let didRegister = registry.register(fileURL, to: ownerID)
        #expect(didRegister)

        #expect(throws: DocumentRegistry.ClaimError.alreadyOpen(fileURL)) {
            try registry.reserveSave(to: fileURL, for: UUID())
        }
    }

    @Test
    func onlyLatestSaveClaimCanChangeOwnership() throws {
        var registry = DocumentRegistry()
        let oldURL = URL(fileURLWithPath: "/tmp/old.md")
        let sessionID = UUID()
        let didRegister = registry.register(oldURL, to: sessionID)
        #expect(didRegister)

        let superseded = try registry.reserveSave(to: fileURL, for: sessionID)
        let latest = try registry.reserveSave(to: fileURL, for: sessionID)
        registry.finishSave(
            superseded,
            previousDocumentURL: oldURL,
            succeeded: true
        )
        #expect(registry.sessionID(for: oldURL) == sessionID)
        #expect(registry.sessionID(for: fileURL) == nil)

        registry.finishSave(latest, previousDocumentURL: oldURL, succeeded: true)
        #expect(registry.sessionID(for: oldURL) == nil)
        #expect(registry.sessionID(for: fileURL) == sessionID)
    }

    @Test
    func removingSessionKeepsItsInFlightWriteReservedUntilCompletion() throws {
        var registry = DocumentRegistry()
        let sessionID = UUID()
        let claim = try registry.reserveSave(to: fileURL, for: sessionID)

        registry.removeSession(sessionID)
        #expect(throws: DocumentRegistry.ClaimError.alreadyOpen(fileURL)) {
            try registry.reserveSave(to: fileURL, for: UUID())
        }

        registry.finishSave(claim, previousDocumentURL: nil, succeeded: false)
        let nextClaim = try registry.reserveSave(to: fileURL, for: UUID())
        #expect(nextClaim != claim)
    }
}

@MainActor
struct DocumentOpenRegistryTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    @Test
    func simultaneousCanonicalAndSymlinkOpenCreateOneSession() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentOpenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("document.md")
        let linkURL = directory.appendingPathComponent("alias.md")
        try Data("hello".utf8).write(to: fileURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: fileURL
        )
        let autosaveStore = AutosaveStore(
            fileURL: directory.appendingPathComponent("AutosavedDraft.json")
        )
        let state = MarkwasniceAppState(autosaveStore: autosaveStore)

        async let canonical: Void = state.openDocument(fileURL)
        async let symlink: Void = state.openDocument(linkURL)
        _ = await (canonical, symlink)

        #expect(state.sessions.count == 1)
        #expect(state.sessions.values.first?.fileURL != nil)
    }

    @Test
    func appStateWiresSaveAsCollisionGateAndReleasesItOnClose() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AutosaveStore(
            fileURL: directory.appendingPathComponent("AutosavedDraft.json")
        )
        let state = MarkwasniceAppState(autosaveStore: store)
        let owner = state.newSession()
        let contender = state.newSession()
        let destination = directory.appendingPathComponent("document.md")
        let reservedClaim = try owner.reserveSaveDestination?(destination)
        let claim = try #require(reservedClaim)
        owner.finishSaveDestination?(claim, nil, true)

        #expect(throws: DocumentRegistry.ClaimError.self) {
            try contender.reserveSaveDestination?(destination)
        }

        state.remove(owner)
        let releasedClaim = try contender.reserveSaveDestination?(destination)
        #expect(releasedClaim != nil)
    }

    @Test
    func duplicateLegacyRecoveryKeepsBothTextsButOnlyOneFileOwner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("document.md")
        let aliasURL = directory.appendingPathComponent("alias.md")
        try Data("on disk".utf8).write(to: documentURL)
        try FileManager.default.createSymbolicLink(
            at: aliasURL,
            withDestinationURL: documentURL
        )
        let store = AutosaveStore(
            fileURL: directory.appendingPathComponent("AutosavedDraft.json")
        )
        try await store.saveSession(
            AutosavedSession(drafts: [
                AutosavedDraft(
                    text: "first recovered text",
                    fileURL: documentURL,
                    windowID: nil,
                    windowFrame: nil
                ),
                AutosavedDraft(
                    text: "second recovered text",
                    fileURL: aliasURL,
                    windowID: nil,
                    windowFrame: nil
                ),
            ]),
            generation: 1
        )
        let state = MarkwasniceAppState(autosaveStore: store)

        _ = await state.initialSessionID()

        #expect(state.sessions.count == 2)
        #expect(state.sessions.values.compactMap(\.fileURL).count == 1)
        #expect(
            Set(state.sessions.values.map(\.editorView.string))
                == ["first recovered text", "second recovered text"]
        )
    }

    @Test
    func rapidConsecutiveSavesUseTheRevisionProducedByThePreviousSave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConsecutiveSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("document.md")
        try Data("opened".utf8).write(to: fileURL)
        let snapshot = try await FileIO.readUTF8Snapshot(from: fileURL)
        let session = EditorDocumentSession(
            text: snapshot.text,
            fileURL: fileURL,
            isEdited: false,
            settings: Self.settings,
            fileRevision: snapshot.revision
        ) {}

        session.editorView.setString("first save", clearsUndo: false)
        session.markdownEditorViewDidChangeText(session.editorView)
        session.save()
        session.editorView.setString("second save", clearsUndo: false)
        session.markdownEditorViewDidChangeText(session.editorView)
        session.save()

        for _ in 0 ..< 200 {
            if try String(contentsOf: fileURL, encoding: .utf8) == "second save" {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the latest save did not reach the file")
    }
}
