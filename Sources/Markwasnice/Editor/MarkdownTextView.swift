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
