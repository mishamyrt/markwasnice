import Foundation

/// Owns the invariant that a canonical file URL belongs to at most one
/// document session, including while the file is being opened or saved as.
struct DocumentRegistry {
    struct SaveClaim: Equatable {
        fileprivate let id = UUID()
        /// Canonical destination reserved when the save started. FileIO uses
        /// the same value so a queued Save As cannot follow a retargeted link
        /// into a URL owned by another session.
        let documentURL: URL
        fileprivate let sessionID: UUID

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum ClaimError: LocalizedError, Equatable {
        case alreadyOpen(URL)
        case opening(URL)

        var errorDescription: String? {
            switch self {
            case let .alreadyOpen(url):
                "\(url.lastPathComponent) is already open in another window."
            case let .opening(url):
                "\(url.lastPathComponent) is currently being opened."
            }
        }
    }

    private var sessionIDsByURL: [URL: UUID] = [:]
    private var openingURLs: Set<URL> = []
    private var saveClaimsByURL: [URL: SaveClaim] = [:]

    func sessionID(for documentURL: URL) -> UUID? {
        sessionIDsByURL[documentURL]
    }

    mutating func beginOpening(_ documentURL: URL) -> Bool {
        guard sessionIDsByURL[documentURL] == nil,
              saveClaimsByURL[documentURL] == nil
        else {
            return false
        }

        return openingURLs.insert(documentURL).inserted
    }

    mutating func finishOpening(_ documentURL: URL) {
        openingURLs.remove(documentURL)
    }

    mutating func register(_ documentURL: URL, to sessionID: UUID) -> Bool {
        guard sessionIDsByURL[documentURL].map({ $0 == sessionID }) ?? true,
              saveClaimsByURL[documentURL].map({ $0.sessionID == sessionID }) ?? true
        else {
            return false
        }

        sessionIDsByURL[documentURL] = sessionID
        return true
    }

    mutating func reserveSave(
        to documentURL: URL,
        for sessionID: UUID
    ) throws -> SaveClaim {
        if let owner = sessionIDsByURL[documentURL], owner != sessionID {
            throw ClaimError.alreadyOpen(documentURL)
        }
        if openingURLs.contains(documentURL) {
            throw ClaimError.opening(documentURL)
        }
        if let claim = saveClaimsByURL[documentURL], claim.sessionID != sessionID {
            throw ClaimError.alreadyOpen(documentURL)
        }

        let claim = SaveClaim(documentURL: documentURL, sessionID: sessionID)
        saveClaimsByURL[documentURL] = claim
        return claim
    }

    mutating func finishSave(
        _ claim: SaveClaim,
        previousDocumentURL: URL?,
        succeeded: Bool
    ) {
        guard saveClaimsByURL[claim.documentURL] == claim else {
            return
        }

        saveClaimsByURL[claim.documentURL] = nil
        guard succeeded else {
            return
        }

        if let previousDocumentURL,
           previousDocumentURL != claim.documentURL,
           sessionIDsByURL[previousDocumentURL] == claim.sessionID
        {
            sessionIDsByURL[previousDocumentURL] = nil
        }
        sessionIDsByURL[claim.documentURL] = claim.sessionID
    }

    mutating func removeSession(_ sessionID: UUID) {
        sessionIDsByURL = sessionIDsByURL.filter { $0.value != sessionID }
        // An already-started write can outlive its window/session. Keep its
        // destination reserved until the task reports through finishSave, so
        // a newly opened session cannot race that write to the same file.
    }
}
