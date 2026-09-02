import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownEditorTextChangeTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    @Test func reportsStrictlyIncreasingTextChangeGenerations() {
        let editor = MarkdownEditorView(settings: Self.settings)
        let delegate = GenerationRecordingDelegate()
        editor.delegate = delegate

        editor.setString("seed", clearsUndo: true)
        editor.textView.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(delegate.generations.isEmpty)

        insertText("a", in: editor)
        insertText("b", in: editor)

        #expect(delegate.generations == [1, 2])
        #expect(delegate.changeCount == 0)
    }

    @Test func bridgesTextChangeToLegacyDelegates() {
        let editor = MarkdownEditorView(settings: Self.settings)
        let delegate = LegacyRecordingDelegate()
        editor.delegate = delegate

        insertText("a", in: editor)

        #expect(delegate.changeCount == 1)
    }

    @Test func reportsReplacementAsStructuredUTF16Edit() throws {
        let editor = MarkdownEditorView(settings: Self.settings)
        let delegate = DeltaRecordingDelegate()
        editor.delegate = delegate
        editor.setString("seed", clearsUndo: true)

        editor.textView.insertText(
            "X",
            replacementRange: NSRange(location: 1, length: 2)
        )

        #expect(delegate.notifications.count == 1)
        let notification = try #require(delegate.notifications.first)
        #expect(notification.generation == 1)
        #expect(notification.edits == [MarkdownTextEdit(
            replacedRange: NSRange(location: 1, length: 2),
            replacement: "X"
        )])
    }

    @Test func reportsDeletionThatEmptiesTheDocument() throws {
        let editor = MarkdownEditorView(settings: Self.settings)
        let delegate = DeltaRecordingDelegate()
        editor.delegate = delegate
        editor.setString("seed", clearsUndo: true)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 4))

        editor.textView.deleteBackward(nil)

        #expect(delegate.notifications.count == 1)
        let notification = try #require(delegate.notifications.first)
        #expect(notification.edits == [MarkdownTextEdit(
            replacedRange: NSRange(location: 0, length: 4),
            replacement: ""
        )])
    }

    @Test func programmaticTextSettingDoesNotAdvanceGeneration() {
        let editor = MarkdownEditorView(settings: Self.settings)
        let delegate = GenerationRecordingDelegate()
        editor.delegate = delegate

        editor.setString("programmatic", clearsUndo: true)

        #expect(delegate.generations.isEmpty)
        #expect(delegate.changeCount == 0)
    }

    private func insertText(_ text: String, in editor: MarkdownEditorView) {
        editor.textView.insertText(
            text,
            replacementRange: editor.textView.selectedRange()
        )
    }
}

@MainActor
private class RecordingDelegateBase {
    private(set) var changeCount = 0

    func markdownEditorViewDidChangeText(_: MarkdownEditorView) {
        changeCount += 1
    }

    func markdownEditorView(
        _: MarkdownEditorView,
        didChangeSelectionText _: String?
    ) {}

    func markdownEditorViewDidScroll(_: MarkdownEditorView) {}

    func markdownEditorView(
        _: MarkdownEditorView,
        didChangeScrolledFromTop _: Bool
    ) {}

    func markdownEditorViewShowSearch(_: MarkdownEditorView) {}

    func markdownEditorViewRequestInsertTable(_: MarkdownEditorView) {}

    func markdownEditorView(
        _: MarkdownEditorView,
        requestOpenFileURLs _: [URL]
    ) {}
}

@MainActor
private final class LegacyRecordingDelegate: RecordingDelegateBase,
    @preconcurrency MarkdownEditorViewDelegate
{}

@MainActor
private final class GenerationRecordingDelegate: RecordingDelegateBase,
    @preconcurrency MarkdownEditorViewDelegate
{
    private(set) var generations: [Int] = []

    func markdownEditorView(
        _: MarkdownEditorView,
        didChangeTextAt generation: Int
    ) {
        generations.append(generation)
    }
}

@MainActor
private final class DeltaRecordingDelegate: RecordingDelegateBase,
    @preconcurrency MarkdownEditorViewDelegate
{
    struct Notification: Equatable {
        let edits: [MarkdownTextEdit]
        let generation: Int
    }

    private(set) var notifications: [Notification] = []

    func markdownEditorView(
        _: MarkdownEditorView,
        didChangeTextBy edits: [MarkdownTextEdit],
        at generation: Int
    ) {
        notifications.append(Notification(edits: edits, generation: generation))
    }
}
