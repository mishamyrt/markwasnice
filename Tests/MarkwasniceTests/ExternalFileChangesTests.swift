import Foundation
import Testing
@testable import Markwasnice

@MainActor
struct ExternalFileChangesTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeSession(
        text: String = "opened",
        in directory: URL
    ) async throws -> (EditorDocumentSession, URL) {
        let fileURL = directory.appending(path: "document.md")
        try Data(text.utf8).write(to: fileURL)
        let snapshot = try await FileIO.readUTF8Snapshot(from: fileURL)
        return (
            EditorDocumentSession(
                text: snapshot.text,
                fileURL: fileURL,
                isEdited: false,
                settings: Self.settings,
                fileRevision: snapshot.revision
            ) {},
            fileURL
        )
    }

    @Test
    func cleanDocumentAutomaticallyReloadsAnExternalChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ExternalReloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, fileURL) = try await makeSession(in: directory)

        try Data("changed outside".utf8).write(to: fileURL, options: .atomic)

        for _ in 0 ..< 200 where session.editorView.string != "changed outside" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.editorView.string == "changed outside")
        #expect(!session.shellState.isEdited)

        try Data("changed in place".utf8).write(to: fileURL)
        for _ in 0 ..< 200 where session.editorView.string != "changed in place" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.editorView.string == "changed in place")
        #expect(!session.shellState.isEdited)
    }

    @Test
    func dirtyDocumentDoesNotReloadAnExternalChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ExternalDirtyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, fileURL) = try await makeSession(in: directory)
        session.editorView.setString("local changes", clearsUndo: false)
        session.markdownEditorViewDidChangeText(session.editorView)

        try Data("changed outside".utf8).write(to: fileURL, options: .atomic)
        await session.reloadFromDiskIfClean()

        #expect(session.editorView.string == "local changes")
        #expect(session.shellState.isEdited)
    }

    @Test
    func conflictCanDiscardLocalChangesAndReloadDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ExternalDiscardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, fileURL) = try await makeSession(in: directory)
        session.resolveFileConflict = { _ in .discardLocalChanges }
        session.editorView.setString("local changes", clearsUndo: false)
        session.markdownEditorViewDidChangeText(session.editorView)
        try Data("changed outside".utf8).write(to: fileURL, options: .atomic)

        session.save()

        for _ in 0 ..< 200 where session.editorView.string != "changed outside" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.editorView.string == "changed outside")
        #expect(!session.shellState.isEdited)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "changed outside")
    }

    @Test
    func cleanSaveRaceReloadsWithoutAskingForConflictResolution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ExternalCleanSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, fileURL) = try await makeSession(in: directory)
        session.resolveFileConflict = { _ in
            Issue.record("a clean document must not ask how to resolve a conflict")
            return .cancel
        }
        try Data("changed outside".utf8).write(to: fileURL, options: .atomic)

        session.save()

        for _ in 0 ..< 200 where session.editorView.string != "changed outside" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.editorView.string == "changed outside")
        #expect(!session.shellState.isEdited)
    }

    @Test
    func conflictCanOverwriteDiskWithLocalChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ExternalOverwriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let (session, fileURL) = try await makeSession(in: directory)
        session.resolveFileConflict = { _ in .overwriteFile }
        session.editorView.setString("local changes", clearsUndo: false)
        session.markdownEditorViewDidChangeText(session.editorView)
        try Data("changed outside".utf8).write(to: fileURL, options: .atomic)

        session.save()

        for _ in 0 ..< 200
            where try String(contentsOf: fileURL, encoding: .utf8) != "local changes"
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "local changes")
        #expect(!session.shellState.isEdited)
    }
}
