import Foundation
import Testing
@testable import Markwasnice

struct FileIOTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FileIOTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    @Test
    func atomicWriteThroughAbsoluteSymlinkPreservesLinkAndUpdatesTarget() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appending(path: "target.md")
        let linkURL = directory.appending(path: "link.md")
        try Data("old".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )

        try await FileIO.writeUTF8("new", to: linkURL)

        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "new")
        #expect(try String(contentsOf: linkURL, encoding: .utf8) == "new")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
                == targetURL.path
        )
    }

    @Test
    func atomicWriteThroughRelativeSymlinkPreservesLinkAndUpdatesTarget() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appending(path: "target.md")
        let linkURL = directory.appending(path: "link.md")
        try Data("old".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: targetURL.lastPathComponent
        )

        try await FileIO.writeUTF8("new", to: linkURL)

        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "new")
        #expect(try String(contentsOf: linkURL, encoding: .utf8) == "new")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
                == targetURL.lastPathComponent
        )
    }

    @Test
    func atomicWriteThroughBrokenSymlinkCreatesTargetAndPreservesLink() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appending(path: "target.md")
        let linkURL = directory.appending(path: "link.md")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: targetURL.lastPathComponent
        )

        try await FileIO.writeUTF8("new", to: linkURL)

        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "new")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
                == targetURL.lastPathComponent
        )
    }

    @Test
    func conditionalWriteRejectsExternalModificationWithoutOverwritingIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "document.md")
        try Data("opened".utf8).write(to: fileURL)
        let snapshot = try await FileIO.readUTF8Snapshot(from: fileURL)
        // Same byte count ensures the guard is based on contents, not file size.
        try Data("edited".utf8).write(to: fileURL)

        do {
            try await FileIO.writeUTF8(
                "editor edit",
                to: fileURL,
                ifUnmodifiedSince: snapshot.revision
            )
            Issue.record("expected an external-modification conflict")
        } catch let error as FileIO.ConditionalWriteError {
            #expect(error == .modifiedExternally(fileURL))
        }

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "edited")
    }

    @Test
    func conditionalWriteWithCurrentRevisionReturnsRevisionForNextWrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "document.md")
        try Data("opened".utf8).write(to: fileURL)
        let snapshot = try await FileIO.readUTF8Snapshot(from: fileURL)

        let savedRevision = try await FileIO.writeUTF8(
            "first save",
            to: fileURL,
            ifUnmodifiedSince: snapshot.revision
        )
        try await FileIO.writeUTF8(
            "second save",
            to: fileURL,
            ifUnmodifiedSince: savedRevision
        )

        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "second save")
    }

    @Test
    func conditionalWriteRejectsSymlinkRetargeting() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalTargetURL = directory.appending(path: "original.md")
        let newTargetURL = directory.appending(path: "new-target.md")
        let linkURL = directory.appending(path: "link.md")
        try Data("original".utf8).write(to: originalTargetURL)
        try Data("new target".utf8).write(to: newTargetURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: originalTargetURL
        )
        let snapshot = try await FileIO.readUTF8Snapshot(from: linkURL)
        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: newTargetURL
        )

        do {
            try await FileIO.writeUTF8(
                "editor edit",
                to: linkURL,
                ifUnmodifiedSince: snapshot.revision
            )
            Issue.record("expected a conflict after the symlink was retargeted")
        } catch let error as FileIO.ConditionalWriteError {
            #expect(error == .modifiedExternally(linkURL))
        }

        #expect(try String(contentsOf: originalTargetURL, encoding: .utf8) == "original")
        #expect(try String(contentsOf: newTargetURL, encoding: .utf8) == "new target")
    }

    @Test
    func claimedSaveAsDestinationRejectsSymlinkRetargeting() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalTargetURL = directory.appending(path: "original.md")
        let newTargetURL = directory.appending(path: "new-target.md")
        let linkURL = directory.appending(path: "link.md")
        try Data("original".utf8).write(to: originalTargetURL)
        try Data("new target".utf8).write(to: newTargetURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: originalTargetURL
        )
        let claimedDestination = FileIO.canonicalDocumentURL(for: linkURL)
        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: newTargetURL
        )

        do {
            try await FileIO.writeUTF8(
                "editor edit",
                to: linkURL,
                resolvingTo: claimedDestination
            )
            Issue.record("expected a conflict after the claimed link was retargeted")
        } catch let error as FileIO.ConditionalWriteError {
            #expect(error == .modifiedExternally(linkURL))
        }

        #expect(try String(contentsOf: originalTargetURL, encoding: .utf8) == "original")
        #expect(try String(contentsOf: newTargetURL, encoding: .utf8) == "new target")
    }

    @Test
    func claimedSaveAsDestinationPreservesTheUnchangedSymlink() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appending(path: "target.md")
        let linkURL = directory.appending(path: "link.md")
        try Data("old".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: targetURL
        )
        let claimedDestination = FileIO.canonicalDocumentURL(for: linkURL)

        try await FileIO.writeUTF8(
            "saved",
            to: linkURL,
            resolvingTo: claimedDestination
        )

        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "saved")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)
                == targetURL.path
        )
    }

    @Test
    func claimedOpenRejectsSymlinkRetargeting() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalTargetURL = directory.appending(path: "original.md")
        let newTargetURL = directory.appending(path: "new-target.md")
        let linkURL = directory.appending(path: "link.md")
        try Data("original".utf8).write(to: originalTargetURL)
        try Data("new target".utf8).write(to: newTargetURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: originalTargetURL
        )
        let claimedDestination = FileIO.canonicalDocumentURL(for: linkURL)
        let initial = try await FileIO.readUTF8Snapshot(
            from: linkURL,
            resolvingTo: claimedDestination
        )
        #expect(initial.text == "original")

        try FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: newTargetURL
        )
        do {
            _ = try await FileIO.readUTF8Snapshot(
                from: linkURL,
                resolvingTo: claimedDestination
            )
            Issue.record("expected Open to reject a retargeted claimed link")
        } catch let error as FileIO.ConditionalWriteError {
            #expect(error == .modifiedExternally(linkURL))
        }
    }
}
