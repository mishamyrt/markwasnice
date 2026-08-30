import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct AppCommandRoutingTests {
    @Test
    func typographyTargetsTheWindowThatReceivedTheShortcut() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCommandRoutingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = MarkwasniceAppState(autosaveStore: AutosaveStore(
            fileURL: directory.appendingPathComponent("AutosavedDraft.json")
        ))
        let first = state.newSession()
        let focused = state.newSession()
        first.editorView.setString("\"первый\"", clearsUndo: true)
        focused.editorView.setString("\"второй\"", clearsUndo: true)

        let firstWindow = makeWindow(hosting: first.editorView)
        let focusedWindow = makeWindow(hosting: focused.editorView)
        state.activate(first)

        state.fixTypography(in: focusedWindow)

        #expect(first.editorView.string == "\"первый\"")
        #expect(focused.editorView.string == "«второй»")
        _ = firstWindow
    }

    private func makeWindow(hosting editor: MarkdownEditorView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        return window
    }
}
