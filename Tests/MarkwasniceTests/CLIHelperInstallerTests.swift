import Foundation
import Testing
@testable import Markwasnice

struct CLIHelperInstallerTests {
    private struct Fixture {
        let root: URL
        let helper: URL
        let installDirectory: URL

        var link: URL {
            installDirectory.appending(path: CLIHelperInstaller.linkName)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CLIHelperInstallerTests-\(UUID().uuidString)")
        let bundle = root.appending(path: "Markwasnice.app/Contents/Resources")
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        let helper = bundle.appending(path: CLIHelperInstaller.linkName)
        try Data("#!/bin/sh\n".utf8).write(to: helper)

        return Fixture(
            root: root,
            helper: helper,
            // Deliberately not created: installing has to make it.
            installDirectory: root.appending(path: "bin")
        )
    }

    private func makeInstaller(
        _ fixture: Fixture,
        helperURL: URL?? = nil,
        otherLinkDirectories: [URL] = []
    ) -> CLIHelperInstaller {
        CLIHelperInstaller(
            helperURL: helperURL ?? fixture.helper,
            installDirectory: fixture.installDirectory,
            otherLinkDirectories: otherLinkDirectories
        )
    }

    @Test
    func reportsUnavailableWhenTheBuildHasNoHelper() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let installer = makeInstaller(fixture, helperURL: .some(nil))

        #expect(installer.state == .unavailable)
        #expect(throws: CLIHelperInstaller.Failure.unavailable) {
            try installer.install()
        }
    }

    @Test
    func installsTheLinkAndReportsIt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = makeInstaller(fixture)

        #expect(installer.state == .notInstalled)
        let link = try installer.install()

        #expect(link == fixture.link)
        #expect(installer.state == .installed(fixture.link))
        let destination = try FileManager.default
            .destinationOfSymbolicLink(atPath: link.path)
        #expect(destination == fixture.helper.path)
    }

    /// A link left behind by a bundle that is gone: it occupies the path but
    /// resolves to nothing, so it reads as not installed and gets replaced.
    @Test
    func replacesALinkLeftByAMissingBundle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = makeInstaller(fixture)
        try FileManager.default.createDirectory(
            at: fixture.installDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.link,
            withDestinationURL: fixture.root.appending(path: "gone/markwasnice")
        )

        #expect(installer.state == .notInstalled)
        try installer.install()

        #expect(installer.state == .installed(fixture.link))
    }

    @Test
    func refusesToReplaceARegularFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = makeInstaller(fixture)
        try FileManager.default.createDirectory(
            at: fixture.installDirectory,
            withIntermediateDirectories: true
        )
        try Data("mine".utf8).write(to: fixture.link)

        #expect(throws: CLIHelperInstaller.Failure.destinationOccupied(fixture.link)) {
            try installer.install()
        }
        #expect(try String(contentsOf: fixture.link, encoding: .utf8) == "mine")
    }

    /// A manually created link in /usr/local/bin counts as installed so the
    /// button does not offer a second one next to it.
    @Test
    func countsALinkInAnotherDirectoryAsInstalled() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherDirectory = fixture.root.appending(path: "usr-local-bin")
        try FileManager.default.createDirectory(
            at: otherDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: otherDirectory.appending(path: CLIHelperInstaller.linkName),
            withDestinationURL: fixture.helper
        )

        let installer = makeInstaller(fixture, otherLinkDirectories: [otherDirectory])

        #expect(
            installer.state
                == .installed(otherDirectory.appending(path: CLIHelperInstaller.linkName))
        )
    }
}
