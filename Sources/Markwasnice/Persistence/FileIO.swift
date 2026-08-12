import CryptoKit
import Foundation

enum FileIO {
    /// Identifies the resolved file target and its exact byte contents.
    struct Revision: Equatable, Sendable {
        fileprivate let resolvedURL: URL
        fileprivate let contentDigest: Data
    }

    struct UTF8Snapshot: Sendable {
        let text: String
        let revision: Revision
    }

    enum ConditionalWriteError: Error, Equatable, LocalizedError, Sendable {
        case modifiedExternally(URL)
        case revisionUnavailable(URL)

        var errorDescription: String? {
            switch self {
            case let .modifiedExternally(url):
                "The file at \(url.path) was modified outside Markwasnice."
            case let .revisionUnavailable(url):
                "The current version of \(url.path) could not be verified. "
                    + "Use Save As to preserve both versions."
            }
        }
    }

    static func readUTF8Snapshot(from url: URL) async throws -> UTF8Snapshot {
        try await Task.detached(priority: .userInitiated) {
            let resolvedURL = canonicalDocumentURL(for: url)
            return try snapshot(at: resolvedURL)
        }.value
    }

    /// Reads the exact target claimed by the document registry. If the
    /// requested symlink moves while Open is queued, no session is created
    /// with bytes and a revision belonging to a different URL.
    static func readUTF8Snapshot(
        from url: URL,
        resolvingTo expectedResolvedURL: URL
    ) async throws -> UTF8Snapshot {
        try await Task.detached(priority: .userInitiated) {
            guard canonicalDocumentURL(for: url) == expectedResolvedURL else {
                throw ConditionalWriteError.modifiedExternally(url)
            }
            let result = try snapshot(at: expectedResolvedURL)
            guard canonicalDocumentURL(for: url) == expectedResolvedURL else {
                throw ConditionalWriteError.modifiedExternally(url)
            }
            return result
        }.value
    }

    @discardableResult
    static func writeUTF8(_ text: String, to url: URL) async throws -> Revision {
        try await Task.detached(priority: .utility) {
            let resolvedURL = canonicalDocumentURL(for: url)
            let data = Data(text.utf8)
            return try coordinatedWrite(
                data,
                to: resolvedURL,
                reportedURL: url,
                expectedRevision: nil
            )
        }.value
    }

    /// Writes to the destination resolved when the app-level save claim was
    /// acquired. A symlink changed while the save was queued is a conflict,
    /// not permission to follow it into another open document.
    @discardableResult
    static func writeUTF8(
        _ text: String,
        to url: URL,
        resolvingTo expectedResolvedURL: URL
    ) async throws -> Revision {
        try await Task.detached(priority: .utility) {
            guard canonicalDocumentURL(for: url) == expectedResolvedURL else {
                throw ConditionalWriteError.modifiedExternally(url)
            }

            let data = Data(text.utf8)
            let savedRevision = try coordinatedWrite(
                data,
                to: expectedResolvedURL,
                reportedURL: url,
                expectedRevision: nil
            )
            // Catch a cooperative retarget that happened while the target was
            // being written before the session adopts the original link URL.
            guard canonicalDocumentURL(for: url) == expectedResolvedURL else {
                throw ConditionalWriteError.modifiedExternally(url)
            }
            return savedRevision
        }.value
    }

    @discardableResult
    static func writeUTF8(
        _ text: String,
        to url: URL,
        ifUnmodifiedSince expectedRevision: Revision
    ) async throws -> Revision {
        try await Task.detached(priority: .utility) {
            let resolvedURL = canonicalDocumentURL(for: url)
            guard resolvedURL == expectedRevision.resolvedURL else {
                throw ConditionalWriteError.modifiedExternally(url)
            }

            let data = Data(text.utf8)
            return try coordinatedWrite(
                data,
                to: resolvedURL,
                reportedURL: url,
                expectedRevision: expectedRevision
            )
        }.value
    }

    static func canonicalDocumentURL(for url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var visitedPaths: Set<String> = []
        for _ in 0 ..< 32 {
            guard visitedPaths.insert(candidate.path).inserted,
                  let destination = try? FileManager.default
                  .destinationOfSymbolicLink(atPath: candidate.path)
            else {
                return candidate.resolvingSymlinksInPath().standardizedFileURL
            }

            if (destination as NSString).isAbsolutePath {
                candidate = URL(fileURLWithPath: destination)
            } else {
                candidate = candidate.deletingLastPathComponent()
                    .appendingPathComponent(destination)
            }
            candidate = candidate.standardizedFileURL
        }
        return candidate.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func coordinatedWrite(
        _ data: Data,
        to resolvedURL: URL,
        reportedURL: URL,
        expectedRevision: Revision?
    ) throws -> Revision {
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            if expectedRevision != nil {
                throw ConditionalWriteError.modifiedExternally(reportedURL)
            }
            try data.write(to: resolvedURL, options: .atomic)
            return revision(for: data, at: resolvedURL)
        }

        var coordinationError: NSError?
        var writeResult: Result<Revision, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: resolvedURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            writeResult = Result {
                if let expectedRevision {
                    let currentData = try Data(contentsOf: coordinatedURL)
                    guard revision(for: currentData, at: resolvedURL)
                        == expectedRevision
                    else {
                        throw ConditionalWriteError.modifiedExternally(reportedURL)
                    }
                }

                try data.write(to: coordinatedURL, options: .atomic)
                return revision(for: data, at: resolvedURL)
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        guard let writeResult else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSURLErrorKey: resolvedURL]
            )
        }
        return try writeResult.get()
    }

    private static func revision(for data: Data, at resolvedURL: URL) -> Revision {
        Revision(
            resolvedURL: resolvedURL,
            contentDigest: Data(SHA256.hash(data: data))
        )
    }

    private static func snapshot(at resolvedURL: URL) throws -> UTF8Snapshot {
        let data = try Data(contentsOf: resolvedURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(
                .fileReadInapplicableStringEncoding,
                userInfo: [NSURLErrorKey: resolvedURL]
            )
        }
        return UTF8Snapshot(
            text: text,
            revision: revision(for: data, at: resolvedURL)
        )
    }
}
