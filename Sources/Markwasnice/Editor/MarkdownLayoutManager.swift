import AppKit

/// TextKit 1 layout manager that redraws strikethrough centered on the
/// x-height. AppKit places the standard strikethrough at a font-defined
/// position that sits noticeably below the visual middle of lowercase text.
final class MarkdownLayoutManager: NSLayoutManager {
    override func drawStrikethrough(
        forGlyphRange glyphRange: NSRange,
        strikethroughType: NSUnderlineStyle,
        baselineOffset: CGFloat,
        lineFragmentRect lineRect: CGRect,
        lineFragmentGlyphRange lineGlyphRange: NSRange,
        containerOrigin: CGPoint
    ) {
        guard glyphRange.length > 0,
              let textStorage,
              let textContainer = textContainer(
                  forGlyphAt: glyphRange.location,
                  effectiveRange: nil
              )
        else {
            super.drawStrikethrough(
                forGlyphRange: glyphRange,
                strikethroughType: strikethroughType,
                baselineOffset: baselineOffset,
                lineFragmentRect: lineRect,
                lineFragmentGlyphRange: lineGlyphRange,
                containerOrigin: containerOrigin
            )
            return
        }

        let characterIndex = characterIndexForGlyph(at: glyphRange.location)
        let attributes = textStorage.attributes(
            at: characterIndex,
            effectiveRange: nil
        )
        let font = attributes[.font] as? NSFont
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color = attributes[.strikethroughColor] as? NSColor
            ?? attributes[.foregroundColor] as? NSColor
            ?? .textColor

        let bounding = boundingRect(forGlyphRange: glyphRange, in: textContainer)
        // location(forGlyphAt:) is measured from the line fragment's top edge
        // to the baseline (flipped coordinates), so subtracting half the
        // x-height lands the line in the visual middle of lowercase glyphs.
        let baselineY = lineRect.minY + location(forGlyphAt: glyphRange.location).y
        let thickness = max(font.underlineThickness, 1)
        let lineRect = NSRect(
            x: containerOrigin.x + bounding.minX,
            y: containerOrigin.y + baselineY - font.xHeight / 2 - thickness / 2,
            width: bounding.width,
            height: thickness
        )

        color.setFill()
        lineRect.fill()
    }
}
