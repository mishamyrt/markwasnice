import Foundation

/// Links the `markwasnice` launcher that ships inside the app bundle into a
/// directory on the user's PATH.
///
/// The link goes to `~/.local/bin`, which needs no administrator rights and is
/// on the default PATH of a login shell. A link already sitting in
/// `/usr/local/bin` — left by a manual install — also counts as installed, so
/// the button never offers a second link next to a working one.
struct CLIHelperInstaller {
    static let linkName = "markwasnice"

    enum State: Equatable {
        case installed(URL)
        case notInstalled
        /// This build has no launcher to link — a bare `swift run` is not a
        /// bundle, so there is nothing the row could offer.
        case unavailable
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable
        case destinationOccupied(URL)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "This build of Markwasnice does not contain the command line launcher."
            case let .destinationOccupied(url):
                "\(url.path) already exists and is not a link."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .unavailable:
                "Install Markwasnice.app and try again."
            case .destinationOccupied:
                "Remove or rename that file, then install the helper again."
            }
        }
    }

    /// The launcher inside the app bundle, or nil when this build has none.
    let helperURL: URL?
    /// Where a new link is created.
    let installDirectory: URL
    /// Other places a link may already live in.
    let otherLinkDirectories: [URL]
    private let fileManager: FileManager

    init(
        helperURL: URL?,
        installDirectory: URL,
        otherLinkDirectories: [URL] = [],
        fileManager: FileManager = .default
    ) {
        self.helperURL = helperURL
        self.installDirectory = installDirectory
        self.otherLinkDirectories = otherLinkDirectories
        self.fileManager = fileManager
    }

    /// The installer for the running app.
    static var bundled: Self {
        let fileManager = FileManager.default
        let helper = Bundle.main.resourceURL?.appending(path: linkName)
        return Self(
            helperURL: helper.flatMap {
                fileManager.isExecutableFile(atPath: $0.path) ? $0 : nil
            },
            installDirectory: fileManager.homeDirectoryForCurrentUser
                .appending(path: ".local/bin"),
            otherLinkDirectories: [URL(filePath: "/usr/local/bin")],
            fileManager: fileManager
        )
    }

    var state: State {
        guard helperURL != nil else {
            return .unavailable
        }

        // fileExists resolves symlinks, so a link left behind by a deleted
        // bundle reads as not installed — which is what it is, and installing
        // again replaces it.
        for directory in [installDirectory] + otherLinkDirectories {
            let link = directory.appending(path: Self.linkName)
            if fileManager.fileExists(atPath: link.path) {
                return .installed(link)
            }
        }

        return .notInstalled
    }

    @discardableResult
    func install() throws -> URL {
        guard let helperURL else {
            throw Failure.unavailable
        }

        let link = installDirectory.appending(path: Self.linkName)
        try fileManager.createDirectory(
            at: installDirectory,
            withIntermediateDirectories: true
        )

        // Only a symlink is ever replaced — a regular file under that name
        // belongs to someone else. The symlink check comes first because a
        // dangling link exists as a path while fileExists denies it.
        if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try fileManager.removeItem(at: link)
        } else if fileManager.fileExists(atPath: link.path) {
            throw Failure.destinationOccupied(link)
        }

        try fileManager.createSymbolicLink(at: link, withDestinationURL: helperURL)
        return link
    }
}
