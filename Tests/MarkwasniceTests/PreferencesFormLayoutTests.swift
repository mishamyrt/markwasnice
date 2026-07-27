import AppKit
import Testing
@testable import Markwasnice

/// The settings window takes its height from the form instead of a constant,
/// so the row that comes and goes — the CLI helper — is what changes it.
@MainActor
struct PreferencesFormLayoutTests {
    private struct Fixture {
        let root: URL
        let installer: CLIHelperInstaller
    }

    private func makeFixture(hasHelper: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "PreferencesFormLayoutTests-\(UUID().uuidString)")
        let bundle = root.appending(path: "Markwasnice.app/Contents/Resources")
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        let helper = bundle.appending(path: CLIHelperInstaller.linkName)
        try Data("#!/bin/sh\n".utf8).write(to: helper)

        return Fixture(
            root: root,
            installer: CLIHelperInstaller(
                helperURL: hasHelper ? helper : nil,
                installDirectory: root.appending(path: "bin")
            )
        )
    }

    private func makeController(
        _ fixture: Fixture
    ) -> PreferencesWindowController {
        PreferencesWindowController(
            settings: EditorSettings(
                textSizeScale: EditorSettings.defaultTextSizeScale,
                maxTextColumns: EditorSettings.defaultMaxTextColumns,
                tabInsertionMode: EditorSettings.defaultTabInsertionMode,
                tabWidth: EditorSettings.defaultTabWidth
            ),
            cliHelperInstaller: fixture.installer
        ) { _, _ in }
    }

    /// Everything the form asks for has to fit: a window sized from a stale
    /// constant would clip the last row instead.
    @Test func formFitsInsideTheWindowItSized() throws {
        let fixture = try makeFixture(hasHelper: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let contentView = try #require(makeController(fixture).window?.contentView)
        contentView.layoutSubtreeIfNeeded()

        let form = try #require(contentView.subviews.first as? NSGridView)
        #expect(form.numberOfRows == 6)
        #expect(form.frame.maxY <= contentView.bounds.height + 0.5)
        #expect(form.frame.minY >= -0.5)
        #expect(form.frame.width <= contentView.bounds.width)
    }

    /// The collapsing row is the only thing between the two heights — no
    /// second constant to keep in step with it.
    @Test func theWindowShrinksByExactlyTheHiddenRow() throws {
        let withHelper = try makeFixture(hasHelper: true)
        let withoutHelper = try makeFixture(hasHelper: false)
        defer {
            try? FileManager.default.removeItem(at: withHelper.root)
            try? FileManager.default.removeItem(at: withoutHelper.root)
        }

        let tall = try #require(makeController(withHelper).window?.contentView)
        let short = try #require(makeController(withoutHelper).window?.contentView)
        tall.layoutSubtreeIfNeeded()
        short.layoutSubtreeIfNeeded()

        let tallForm = try #require(tall.subviews.first as? NSGridView)
        let shortForm = try #require(short.subviews.first as? NSGridView)

        #expect(!tallForm.row(at: 5).isHidden)
        #expect(shortForm.row(at: 5).isHidden)
        #expect(short.bounds.height < tall.bounds.height)
        #expect(short.bounds.width == tall.bounds.width)
    }
}
