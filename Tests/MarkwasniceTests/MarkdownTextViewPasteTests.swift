import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownTextViewPasteTests {
    private actor ConversionGate {
        private var continuation: CheckedContinuation<String?, Never>?

        func convert() async -> String? {
            await withCheckedContinuation { continuation in
                precondition(self.continuation == nil)
                self.continuation = continuation
            }
        }

        func isRequested() -> Bool {
            continuation != nil
        }

        func finish(with text: String?) -> Bool {
            guard let continuation else {
                return false
            }
            self.continuation = nil
            continuation.resume(returning: text)
            return true
        }
    }

    @MainActor
    private struct Fixture {
        let editor: MarkdownEditorView
        let window: NSWindow

        var textView: MarkdownTextView {
            editor.textView
        }
    }

    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    @Test
    func deferredPasteCommitsOnceAndCanBeUndone() async throws {
        let selection = NSRange(location: 6, length: 4)
        let fixture = makeFixture(text: "alpha beta omega", selection: selection)
        let gate = ConversionGate()
        prepareDeferredPaste(in: fixture.textView, gate: gate)

        fixture.textView.paste(nil)
        #expect(await waitUntilRequested(gate))
        #expect(await gate.finish(with: "**rich**"))
        #expect(await waitUntil {
            fixture.textView.string == "alpha **rich** omega"
        })
        #expect(fixture.textView.selectedRange() == NSRange(location: 14, length: 0))

        let undoManager = try #require(fixture.textView.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()

        #expect(fixture.textView.string == "alpha beta omega")
        #expect(fixture.textView.selectedRange() == selection)
        _ = fixture.window
    }

    @Test
    func selectionMoveInvalidatesDeferredPasteEvenAfterMovingBack() async {
        let selection = NSRange(location: 6, length: 4)
        let fixture = makeFixture(text: "alpha beta omega", selection: selection)
        let gate = ConversionGate()
        prepareDeferredPaste(in: fixture.textView, gate: gate)

        fixture.textView.paste(nil)
        #expect(await waitUntilRequested(gate))
        fixture.textView.setSelectedRange(NSRange(location: 0, length: 0))
        fixture.textView.setSelectedRange(selection)
        #expect(await gate.finish(with: "**stale**"))
        await settleTasks()

        #expect(fixture.textView.string == "alpha beta omega")
        _ = fixture.window
    }

    @Test
    func programmaticTextReplacementInvalidatesDeferredPaste() async {
        let fixture = makeFixture(
            text: "original",
            selection: NSRange(location: 0, length: 0)
        )
        let gate = ConversionGate()
        prepareDeferredPaste(in: fixture.textView, gate: gate)

        fixture.textView.paste(nil)
        #expect(await waitUntilRequested(gate))
        fixture.textView.string = "replacement"
        #expect(await gate.finish(with: "stale "))
        await settleTasks()

        #expect(fixture.textView.string == "replacement")
        _ = fixture.window
    }

    @Test
    func newerDeferredPasteSupersedesOlderCompletion() async {
        let selection = NSRange(location: 6, length: 4)
        let fixture = makeFixture(text: "alpha beta omega", selection: selection)
        let firstGate = ConversionGate()
        prepareDeferredPaste(in: fixture.textView, gate: firstGate)

        fixture.textView.paste(nil)
        #expect(await waitUntilRequested(firstGate))

        let secondGate = ConversionGate()
        prepareDeferredPaste(in: fixture.textView, gate: secondGate)
        fixture.textView.paste(nil)
        #expect(await waitUntilRequested(secondGate))
        #expect(await secondGate.finish(with: "second"))
        #expect(await waitUntil {
            fixture.textView.string == "alpha second omega"
        })

        #expect(await firstGate.finish(with: "first"))
        await settleTasks()

        #expect(fixture.textView.string == "alpha second omega")
        _ = fixture.window
    }

    private func makeFixture(text: String, selection: NSRange) -> Fixture {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let editor = MarkdownEditorView(settings: Self.settings, frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = editor
        window.makeFirstResponder(editor.textView)
        editor.setString(text, clearsUndo: true)
        editor.textView.setSelectedRange(selection)
        editor.textView.undoManager?.removeAllActions()
        return Fixture(editor: editor, window: window)
    }

    private func prepareDeferredPaste(
        in textView: MarkdownTextView,
        gate: ConversionGate
    ) {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("MarkdownTextViewPasteTests-\(UUID())")
        )
        pasteboard.clearContents()
        pasteboard.setString("plain fallback", forType: .string)
        pasteboard.setData(
            Data(
                repeating: 0x20,
                count: RichTextMarkdownConverter.largePasteByteThreshold + 1
            ),
            forType: .rtf
        )
        textView.pasteboardForPaste = { pasteboard }
        textView.convertDeferredPaste = { _ in
            await gate.convert()
        }
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 10000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    private func waitUntilRequested(_ gate: ConversionGate) async -> Bool {
        for _ in 0 ..< 1000 {
            if await gate.isRequested() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await gate.isRequested()
    }

    private func settleTasks() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }
}
