import AppKit

@MainActor
protocol MarkdownTextViewCommandDelegate: AnyObject {
    func markdownTextViewInsertTab(_ textView: NSTextView)
    func markdownTextViewContinueMarkdownPrefix(_ textView: NSTextView) -> Bool
    func markdownTextView(
        _ textView: NSTextView, wrapSelectionWith opening: String, closing: String
    ) -> Bool
    func markdownTextViewDraggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation
    func markdownTextViewPerformDragOperation(
        _ sender: NSDraggingInfo,
        in textView: NSTextView
    )
        -> Bool
}

@MainActor
final class MarkdownTextView: NSTextView {
    weak var commandDelegate: MarkdownTextViewCommandDelegate?
    var isWindowPointInTopChrome: ((NSPoint, NSWindow) -> Bool)?
    var topChromeRectProvider: (() -> NSRect?)?
    var onMouseDown: (() -> Void)?
    var onScrollWheel: (() -> Void)?

    var textContentInsets = NSEdgeInsetsZero {
        didSet {
            needsDisplay = true
        }
    }

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(
            x: origin.x + textContentInsets.left,
            y: origin.y + textContentInsets.top
        )
    }

    override func resetCursorRects() {
        guard let window,
              let contentView = window.contentView,
              let chromeRectInContentView = topChromeRectProvider?()
        else {
            addCursorRect(visibleRect, cursor: .iBeam)
            return
        }

        let visible = visibleRect
        let chromeRect = convert(chromeRectInContentView, from: contentView)
        let blocked = visible.intersection(chromeRect)

        guard !blocked.isNull, !blocked.isEmpty else {
            addCursorRect(visible, cursor: .iBeam)
            return
        }

        for rect in visible.subtracting(blocked) where !rect.isEmpty {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let isTopChrome = eventIsInTopChrome(event)

        if isTopChrome {
            NSCursor.arrow.set()
            return
        }

        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        let isTopChrome = eventIsInTopChrome(event)

        if isTopChrome {
            NSCursor.arrow.set()
            return
        }

        super.mouseEntered(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let isTopChrome = eventIsInTopChrome(event)

        if isTopChrome {
            NSCursor.arrow.set()
            return
        }

        super.cursorUpdate(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else {
            super.keyDown(with: event)
            return
        }

        switch event.charactersIgnoringModifiers {
        case "\t":
            commandDelegate?.markdownTextViewInsertTab(self)
        case "\r", "\n":
            if commandDelegate?.markdownTextViewContinueMarkdownPrefix(self) != true {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseDown?()
    }

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?()
        super.scrollWheel(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if selectedRange().length > 0,
           let string = plainString(from: insertString),
           let pair = pairSymbol(for: string),
           commandDelegate?.markdownTextView(
               self, wrapSelectionWith: pair.opening, closing: pair.closing
           ) == true
        {
            return
        }

        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        commandDelegate?.markdownTextViewDraggingEntered(sender) ?? []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        commandDelegate?.markdownTextViewPerformDragOperation(sender, in: self) ?? false
    }

    private func plainString(from insertString: Any) -> String? {
        if let string = insertString as? String {
            return string
        }

        return (insertString as? NSAttributedString)?.string
    }

    private func eventIsInTopChrome(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? window else {
            return false
        }

        return isWindowPointInTopChrome?(event.locationInWindow, window) == true
    }

    private func pairSymbol(for string: String) -> (opening: String, closing: String)? {
        switch string {
        case "\"":
            return ("\"", "\"")
        case "'":
            return ("'", "'")
        case "`":
            return ("`", "`")
        case "«":
            return ("«", "»")
        case "“":
            return ("“", "”")
        case "(":
            return ("(", ")")
        case "[":
            return ("[", "]")
        case "„":
            return ("„", "“")
        case "*":
            return ("*", "*")
        default:
            return nil
        }
    }
}

extension NSRect {
    func subtracting(_ cut: NSRect) -> [NSRect] {
        let cut = intersection(cut)
        guard !cut.isNull, !cut.isEmpty else {
            return [self]
        }

        var result: [NSRect] = []

        if cut.maxY < maxY {
            result.append(NSRect(
                x: minX,
                y: cut.maxY,
                width: width,
                height: maxY - cut.maxY
            ))
        }

        if cut.minY > minY {
            result.append(NSRect(
                x: minX,
                y: minY,
                width: width,
                height: cut.minY - minY
            ))
        }

        if cut.minX > minX {
            result.append(NSRect(
                x: minX,
                y: cut.minY,
                width: cut.minX - minX,
                height: cut.height
            ))
        }

        if cut.maxX < maxX {
            result.append(NSRect(
                x: cut.maxX,
                y: cut.minY,
                width: maxX - cut.maxX,
                height: cut.height
            ))
        }

        return result
    }
}
