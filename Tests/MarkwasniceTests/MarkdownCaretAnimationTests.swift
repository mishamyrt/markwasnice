import AppKit
import Carbon.HIToolbox
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownCaretAnimationTests {
    @Test(arguments: [NSEvent.ModifierFlags(), .option, .command])
    func horizontalNavigationTypingAndDeletionAnimate(
        modifiers: NSEvent.ModifierFlags
    ) throws {
        let (editor, window) = makeEditor()
        defer { window.close() }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 10, length: 0))
        let start = NSRect(x: 140, y: 10, width: 2, height: 20)
        textView.updateInsertionIndicator(in: start, color: .red)
        let indicator = try #require(textView.subviews.flatMap(\.subviews).compactMap {
            $0 as? NSTextInsertionIndicator
        }.first)
        let container = try #require(indicator.superview)
        #expect(!textView.isInsertionPointAnimating)

        try pressArrow(
            .leftArrow,
            keyCode: kVK_LeftArrow,
            modifiers: modifiers,
            in: textView
        )
        #expect(textView.selectedRange().location < 10)
        let target = start.offsetBy(dx: -48, dy: 0)
        textView.updateInsertionIndicator(in: target, color: .red)
        expectAnimation(in: textView)
        #expect(container.frame == (textView.isInsertionPointAnimating ? start : target))
        #expect(indicator.frame == container.bounds)
        #expect(indicator.layer?.animation(forKey: "caretMovement") == nil)
        textView.updateInsertionIndicator(in: target, color: .red)
        expectAnimation(in: textView)
        textView.advanceInsertionPointAnimation(at: CACurrentMediaTime() + 1)
        #expect(container.frame == target)

        try pressArrow(
            .rightArrow,
            keyCode: kVK_RightArrow,
            modifiers: modifiers,
            in: textView
        )
        textView.updateInsertionIndicator(in: start, color: .red)
        expectAnimation(in: textView)

        textView.insertText("x", replacementRange: textView.selectedRange())
        textView.updateInsertionIndicator(in: start.offsetBy(dx: 12, dy: 0), color: .red)
        expectAnimation(in: textView)
        textView.deleteBackward(nil)
        textView.updateInsertionIndicator(in: start, color: .red)
        expectAnimation(in: textView)
        textView.insertText("\n", replacementRange: textView.selectedRange())
        textView.updateInsertionIndicator(
            in: start.offsetBy(dx: -60, dy: 24),
            color: .red
        )
        expectAnimation(in: textView)

        // Markdown commands place the final caret after didChangeText().
        editor.markdownTextViewInsertTab(textView)
        textView.updateInsertionIndicator(
            in: start.offsetBy(dx: -12, dy: 24),
            color: .red
        )
        expectAnimation(in: textView)
    }

    @Test func verticalNavigationAndSelectionAnimateButProgrammaticMovesDoNot() throws {
        let (editor, window) = makeEditor()
        defer { window.close() }
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let start = NSRect(x: 44, y: 10, width: 2, height: 20)
        textView.updateInsertionIndicator(in: start, color: .black)

        try pressArrow(.downArrow, keyCode: kVK_DownArrow, in: textView)
        #expect(textView.selectedRange().location > 10)
        let nextLine = start.offsetBy(dx: 0, dy: 24)
        textView.updateInsertionIndicator(in: nextLine, color: .black)
        expectAnimation(in: textView)

        try pressArrow(.upArrow, keyCode: kVK_UpArrow, in: textView)
        textView.updateInsertionIndicator(in: start, color: .black)
        expectAnimation(in: textView)

        try pressArrow(
            .rightArrow,
            keyCode: kVK_RightArrow,
            modifiers: .shift,
            in: textView
        )
        #expect(textView.selectedRange().length > 0)
        textView.updateInsertionIndicator(
            in: start.offsetBy(dx: 12, dy: 0),
            color: .black
        )
        expectAnimation(in: textView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.updateInsertionIndicator(in: start, color: .black)

        try pressArrow(.leftArrow, keyCode: kVK_LeftArrow, in: textView)
        // A later selection change must not inherit the pending arrow animation.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateInsertionIndicator(
            in: start.offsetBy(dx: -24, dy: 0),
            color: .black
        )
        #expect(!textView.isInsertionPointAnimating)
    }

    @Test func selectionKeepsTheCaretAtItsActiveEnd() async throws {
        let (editor, window) = makeEditor()
        defer { window.close() }
        let textView = editor.textView
        editor.layoutSubtreeIfNeeded()
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        func updateCaret() async throws {
            _ = try renderText(textView)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        func expectCaret(at location: Int) throws {
            let indicator = try #require(textView.subviews.flatMap(\.subviews)
                .compactMap { $0 as? NSTextInsertionIndicator }.first)
            #expect(indicator.displayMode == .automatic)
            #expect(indicator.automaticModeOptions.contains(.showWhileTracking))
            let screenRect = textView.firstRect(
                forCharacterRange: NSRange(location: location, length: 0),
                actualRange: nil
            )
            var expected = textView.convert(
                window.convertFromScreen(screenRect),
                from: nil
            )
            expected.size.width = 2
            textView.advanceInsertionPointAnimation(at: CACurrentMediaTime() + 1)
            #expect(indicator.superview?.frame == expected)
        }
        try await updateCaret()
        try expectCaret(at: 5)

        // Extend, shrink, and cross the anchor with Shift+arrows.
        var previousLocation = 5
        for location in [4, 3, 4, 5, 6] {
            let movesLeft = location < previousLocation
            try pressArrow(
                movesLeft ? .leftArrow : .rightArrow,
                keyCode: movesLeft ? kVK_LeftArrow : kVK_RightArrow,
                modifiers: .shift,
                in: textView
            )
            try await updateCaret()
            try expectCaret(at: location)
            previousLocation = location
        }

        // Drag across lines and past the anchor without collapsing the selection.
        for (selection, location) in [
            (NSRange(location: 5, length: 10), 15),
            (NSRange(location: 2, length: 3), 2),
            (NSRange(location: 5, length: 10), 15),
        ] {
            textView.setSelectedRanges(
                [NSValue(range: selection)], affinity: .downstream, stillSelecting: true
            )
            try await updateCaret()
            try expectCaret(at: location)
        }
        textView.setSelectedRanges(
            textView.selectedRanges, affinity: .upstream, stillSelecting: false
        )
        try await updateCaret()
        try expectCaret(at: 5)
        window.makeFirstResponder(nil)
        let indicator = try #require(textView.subviews.flatMap(\.subviews)
            .compactMap { $0 as? NSTextInsertionIndicator }.first)
        #expect(indicator.displayMode == .hidden)
    }

    @Test(arguments: ["insert", "deleteBackward", "deleteWordBackward"])
    func editsRenderImmediatelyWhileOnlyTheCaretMoves(edit: String) throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let (editor, window) = makeEditor()
        defer { window.close() }
        editor.setString("ab дфдXYZ", clearsUndo: true)
        editor.layoutSubtreeIfNeeded()
        let textView = editor.textView
        let layoutManager = try #require(textView.layoutManager)
        try layoutManager.ensureLayout(for: #require(textView.textContainer))
        textView.setSelectedRange(NSRange(location: 6, length: 0))

        func caretRect() -> NSRect {
            let screenRect = textView.firstRect(
                forCharacterRange: textView.selectedRange(),
                actualRange: nil
            )
            var rect = textView.convert(window.convertFromScreen(screenRect), from: nil)
            rect.size.width = 2
            return rect
        }
        textView.updateInsertionIndicator(in: caretRect(), color: .black)
        let container = try #require(textView.subviews
            .first { $0.subviews.contains { $0 is NSTextInsertionIndicator } })
        var immediateText = try renderText(textView)

        // A second edit retargets the moving caret without animating the text.
        for _ in 0 ..< 2 {
            let previousFrame = container.frame
            let previousText = try renderText(textView)
            switch edit {
            case "insert":
                textView.insertText("д", replacementRange: textView.selectedRange())
            case "deleteBackward":
                textView.deleteBackward(nil)
            default:
                textView.deleteWordBackward(nil)
            }
            let target = caretRect()
            textView.updateInsertionIndicator(in: target, color: .black)
            #expect(textView.isInsertionPointAnimating)
            #expect(container.frame == previousFrame)
            immediateText = try renderText(textView)
            #expect(immediateText != previousText)

            textView.advanceInsertionPointAnimation(at: CACurrentMediaTime() + 0.01)
            #expect(container.frame.minX > min(previousFrame.minX, target.minX))
            #expect(container.frame.minX < max(previousFrame.minX, target.minX))
            #expect(try renderText(textView) == immediateText)

            let intermediateFrame = container.frame
            textView.updateInsertionIndicator(in: target, color: .black)
            #expect(container.frame == intermediateFrame)
        }
        // Compare against the fully settled rendering, including the suffix.
        textView.advanceInsertionPointAnimation(at: CACurrentMediaTime() + 1)
        #expect(!textView.isInsertionPointAnimating)
        #expect(container.frame == caretRect())
        #expect(try renderText(textView) == immediateText)
    }

    private func renderText(_ textView: MarkdownTextView) throws -> [UInt8] {
        let context = try #require(CGContext(
            data: nil, width: 800, height: 100, bitsPerComponent: 8, bytesPerRow: 800 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: 100)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        textView.draw(NSRect(x: 0, y: 0, width: 800, height: 100))
        let data = try #require(context.data)
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: UInt8.self),
            count: 800 * 100 * 4
        ))
    }

    private func makeEditor() -> (MarkdownEditorView, NSWindow) {
        let editor = MarkdownEditorView(
            settings: EditorSettings(
                textSizeScale: 1,
                maxTextColumns: 64,
                tabInsertionMode: .spaces,
                tabWidth: 4
            ),
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = CaretTestWindow(
            contentRect: editor.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.makeFirstResponder(editor.textView)
        editor.setString("alpha beta\nsecond line", clearsUndo: true)
        return (editor, window)
    }

    private func pressArrow(
        _ key: NSEvent.SpecialKey,
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags = [],
        in textView: MarkdownTextView
    ) throws {
        let characters = String(key.unicodeScalar)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: modifiers.union([.numericPad, .function]),
            timestamp: 0, windowNumber: textView.window?.windowNumber ?? 0,
            context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
        textView.keyDown(with: event)
    }

    private func expectAnimation(in textView: MarkdownTextView) {
        #expect(
            textView.isInsertionPointAnimating
                == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

@MainActor
private final class CaretTestWindow: NSWindow {
    override var isKeyWindow: Bool {
        true
    }
}
