import AppKit

extension NSAttributedString.Key {
    static let markdownCodeBackgroundColor = NSAttributedString.Key(
        "MarkwasniceMarkdownCodeBackgroundColor")
    static let markdownCodeBlockBackgroundColor = NSAttributedString.Key(
        "MarkwasniceMarkdownCodeBlockBackgroundColor")
}

final class MarkdownCodeBackgroundLayoutManager: NSLayoutManager {
    var codeBackgroundCornerRadius: CGFloat = 3

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let textStorage else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        let characterRange = self.characterRange(
            forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        textStorage.enumerateAttribute(
            .markdownCodeBackgroundColor, in: characterRange, options: []
        ) { value, range, _ in
            guard let color = value as? NSColor else {
                return
            }

            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let visibleGlyphRange = NSIntersectionRange(glyphRange, glyphsToShow)
            guard visibleGlyphRange.length > 0 else {
                return
            }

            self.drawCodeBackground(color: color, glyphRange: visibleGlyphRange, at: origin)
        }

        textStorage.enumerateAttribute(
            .markdownCodeBlockBackgroundColor, in: characterRange, options: []
        ) { value, range, _ in
            guard let color = value as? NSColor else {
                return
            }

            var effectiveRange = NSRange()
            _ = textStorage.attribute(
                .markdownCodeBlockBackgroundColor,
                at: range.location,
                longestEffectiveRange: &effectiveRange,
                in: NSRange(location: 0, length: textStorage.length)
            )

            let glyphRange = self.glyphRange(
                forCharacterRange: effectiveRange, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else {
                return
            }

            self.drawCodeBlockBackground(color: color, glyphRange: glyphRange, at: origin)
        }

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawCodeBackground(color: NSColor, glyphRange: NSRange, at origin: NSPoint) {
        guard
            let textContainer = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil)
        else {
            return
        }

        var glyphIndex = glyphRange.location
        let endGlyphIndex = NSMaxRange(glyphRange)

        while glyphIndex < endGlyphIndex {
            var lineGlyphRange = NSRange()
            lineFragmentRect(
                forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true)
            let drawingGlyphRange = NSIntersectionRange(glyphRange, lineGlyphRange)

            if let textGlyphRange = visibleTextGlyphRange(from: drawingGlyphRange),
                let rect = codeBackgroundRect(
                    forGlyphRange: textGlyphRange, in: textContainer, at: origin)
            {
                color.setFill()
                NSBezierPath(
                    roundedRect: rect,
                    xRadius: codeBackgroundCornerRadius,
                    yRadius: codeBackgroundCornerRadius
                ).fill()
            }

            glyphIndex = max(NSMaxRange(lineGlyphRange), glyphIndex + 1)
        }
    }

    private func drawCodeBlockBackground(color: NSColor, glyphRange: NSRange, at origin: NSPoint) {
        var glyphIndex = glyphRange.location
        let endGlyphIndex = NSMaxRange(glyphRange)
        var blockRect: NSRect?

        while glyphIndex < endGlyphIndex {
            var lineGlyphRange = NSRange()
            lineFragmentRect(
                forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange,
                withoutAdditionalLayout: true)

            if let lineRect = codeBlockLineRect(forGlyphAt: glyphIndex, at: origin) {
                blockRect = blockRect.map { $0.union(lineRect) } ?? lineRect
            }

            glyphIndex = max(NSMaxRange(lineGlyphRange), glyphIndex + 1)
        }

        guard let blockRect else {
            return
        }

        color.setFill()
        NSBezierPath(
            roundedRect: blockRect.integral,
            xRadius: codeBackgroundCornerRadius,
            yRadius: codeBackgroundCornerRadius
        ).fill()
    }

    private func codeBlockLineRect(forGlyphAt glyphIndex: Int, at origin: NSPoint) -> NSRect? {
        guard let textContainer = textContainer(forGlyphAt: glyphIndex, effectiveRange: nil) else {
            return nil
        }

        var rect = lineFragmentRect(
            forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)
        guard rect.width > 0, rect.height > 0 else {
            return nil
        }

        if let paragraphStyle = paragraphStyle(forGlyphAt: glyphIndex) {
            let trailingInset = paragraphStyle.tailIndent < 0 ? abs(paragraphStyle.tailIndent) : 0
            rect.origin.x += paragraphStyle.headIndent
            rect.size.width -= paragraphStyle.headIndent + trailingInset
        }

        rect.size.width = min(rect.size.width, textContainer.size.width - rect.origin.x)
        rect.size.height -= rect.size.height * 0.161
        rect.origin.x += origin.x
        rect.origin.y += origin.y + (rect.size.height * 0.258)
        return rect
    }

    private func paragraphStyle(forGlyphAt glyphIndex: Int) -> NSParagraphStyle? {
        guard let textStorage else {
            return nil
        }

        let characterIndex = characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length else {
            return nil
        }

        return textStorage.attribute(.paragraphStyle, at: characterIndex, effectiveRange: nil)
            as? NSParagraphStyle
    }

    private func visibleTextGlyphRange(from glyphRange: NSRange) -> NSRange? {
        guard let string = textStorage?.string as NSString? else {
            return nil
        }

        var lowerBound = glyphRange.location
        var upperBound = NSMaxRange(glyphRange)

        while lowerBound < upperBound, isLineBreakGlyph(at: lowerBound, in: string) {
            lowerBound += 1
        }

        while upperBound > lowerBound, isLineBreakGlyph(at: upperBound - 1, in: string) {
            upperBound -= 1
        }

        let length = upperBound - lowerBound
        return length > 0 ? NSRange(location: lowerBound, length: length) : nil
    }

    private func isLineBreakGlyph(at glyphIndex: Int, in string: NSString) -> Bool {
        let characterIndex = characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < string.length else {
            return true
        }

        switch string.character(at: characterIndex) {
        case 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    private func codeBackgroundRect(
        forGlyphRange glyphRange: NSRange, in textContainer: NSTextContainer, at origin: NSPoint
    ) -> NSRect? {
        var rect = boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard rect.width > 0, rect.height > 0 else {
            return nil
        }

        rect.size.height -= rect.size.height * 0.161
        rect.size.width += rect.size.height * 0.066
        rect.origin.x += origin.x - 2
        rect.origin.y += origin.y + (rect.size.height * 0.258)
        return rect.integral
    }
}
