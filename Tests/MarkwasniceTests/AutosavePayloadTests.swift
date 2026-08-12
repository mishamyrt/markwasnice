import Foundation
import Testing
@testable import Markwasnice

@MainActor
struct AutosavePayloadTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    @Test
    func verifiedCleanFileBackedDraftOmitsText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosavePayloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("clean.md")
        try Data("stored on disk".utf8).write(to: fileURL)
        let snapshot = try await FileIO.readUTF8Snapshot(from: fileURL)
        let session = EditorDocumentSession(
            text: snapshot.text,
            fileURL: fileURL,
            isEdited: false,
            settings: Self.settings,
            fileRevision: snapshot.revision
        ) {}

        let draft = session.autosavedDraft(windowID: nil, windowFrame: nil)

        #expect(draft.text == nil)
    }

    @Test
    func unverifiedFileBackedDraftKeepsRecoveryText() {
        let session = EditorDocumentSession(
            text: "only recovery copy",
            fileURL: URL(fileURLWithPath: "/tmp/unverified.md"),
            isEdited: false,
            settings: Self.settings
        ) {}

        let draft = session.autosavedDraft(windowID: nil, windowFrame: nil)

        #expect(draft.text == "only recovery copy")
    }

    @Test
    func dirtyEmptyFileBackedDraftKeepsExplicitEmptyText() {
        let session = EditorDocumentSession(
            text: "stored on disk",
            fileURL: URL(fileURLWithPath: "/tmp/dirty.md"),
            isEdited: false,
            settings: Self.settings
        ) {}
        session.editorView.setString("", clearsUndo: false)
        session.markdownEditorViewDidChangeText(session.editorView)

        let draft = session.autosavedDraft(windowID: nil, windowFrame: nil)

        #expect(draft.text != nil)
        #expect(draft.text?.isEmpty == true)
    }

    @Test
    func untitledEmptyDraftKeepsExplicitEmptyText() {
        let session = EditorDocumentSession(
            text: "",
            fileURL: nil,
            isEdited: false,
            settings: Self.settings
        ) {}

        let draft = session.autosavedDraft(windowID: nil, windowFrame: nil)

        #expect(draft.text != nil)
        #expect(draft.text?.isEmpty == true)
    }
}
