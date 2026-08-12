import AppKit
import Testing
@testable import Markwasnice

/// The attribute half of the styling pipeline, driven against a bare
/// NSTextStorage — no text view, no layout manager, no window. Every case
/// mirrors what MarkdownEditorView.applyStyles does around it: base
/// attributes over the target range first, then the per-span work.
@MainActor
struct MarkdownStyleApplierTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )
    private static let colors = EditorThemeColors.default.light
    private static let paragraphGutter: CGFloat = 40

    private func makeApplier(
        text: String
    ) -> (applier: MarkdownStyleApplier, storage: NSTextStorage) {
        let storage = NSTextStorage(string: text)
        let applier = MarkdownStyleApplier(
            textStorage: storage,
            colors: { Self.colors },
            settings: Self.settings,
            windowWidthFontScale: 1
        )
        applier.paragraphGutter = Self.paragraphGutter
        storage.setAttributes(
            applier.baseAttributes(),
            range: NSRange(location: 0, length: storage.length)
        )
        return (applier, storage)
    }

    private func paragraphStyle(
        in storage: NSTextStorage,
        at location: Int
    ) -> NSParagraphStyle? {
        storage.attribute(
            .paragraphStyle,
            at: location,
            effectiveRange: nil
        ) as? NSParagraphStyle
    }

    private func font(in storage: NSTextStorage, at location: Int) -> NSFont? {
        storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func foregroundColor(
        in storage: NSTextStorage,
        at location: Int
    ) -> NSColor? {
        storage.attribute(
            .foregroundColor,
            at: location,
            effectiveRange: nil
        ) as? NSColor
    }

    /// How far the heading's first line is pulled left of the paragraph text,
    /// i.e. the measured width of its marker.
    private func headingMarkerOutdent(
        in storage: NSTextStorage,
        at location: Int
    ) -> CGFloat? {
        guard let style = paragraphStyle(in: storage, at: location) else {
            return nil
        }

        return style.headIndent - style.firstLineHeadIndent
    }

    // MARK: - Heading markers

    @Test func headingOutdentsItsMarkerIntoTheGutter() throws {
        let text = "# Title\n\nBody"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .heading,
            range: NSRange(location: 0, length: 7),
            string: storage.mutableString
        )

        let headingStyle = try #require(paragraphStyle(in: storage, at: 0))
        // The body keeps the gutter; only the heading's first line reaches
        // left of it, by exactly the width of "# ".
        #expect(headingStyle.headIndent == Self.paragraphGutter)
        #expect(headingStyle.firstLineHeadIndent < Self.paragraphGutter)
        #expect(try #require(headingMarkerOutdent(in: storage, at: 0)) > 0)

        let bodyStyle = try #require(paragraphStyle(in: storage, at: 9))
        #expect(bodyStyle.firstLineHeadIndent == Self.paragraphGutter)
        #expect(bodyStyle.headIndent == Self.paragraphGutter)
    }

    @Test func headingStylesTheWholeLineBoldAndNothingBeyondIt() throws {
        let text = "# Title\n\nBody"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .heading,
            range: NSRange(location: 0, length: 7),
            string: storage.mutableString
        )

        let markerFont = try #require(font(in: storage, at: 0))
        let titleFont = try #require(font(in: storage, at: 2))
        let bodyFont = try #require(font(in: storage, at: 9))
        #expect(NSFontManager.shared.traits(of: markerFont).contains(.boldFontMask))
        #expect(NSFontManager.shared.traits(of: titleFont).contains(.boldFontMask))
        #expect(!NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
    }

    @Test func widerHeadingMarkerOutdentsFurther() throws {
        let (shallowApplier, shallowStorage) = makeApplier(text: "# Title")
        let (deepApplier, deepStorage) = makeApplier(text: "###### Title")

        shallowApplier.applyStyle(
            .heading,
            range: NSRange(location: 0, length: shallowStorage.length),
            string: shallowStorage.mutableString
        )
        deepApplier.applyStyle(
            .heading,
            range: NSRange(location: 0, length: deepStorage.length),
            string: deepStorage.mutableString
        )

        let shallowOutdent = try #require(headingMarkerOutdent(
            in: shallowStorage,
            at: 0
        ))
        let deepOutdent = try #require(headingMarkerOutdent(in: deepStorage, at: 0))
        #expect(deepOutdent > shallowOutdent)
    }

    /// The marker width is cached, keyed on the point size — a text-size or
    /// window-width change has to invalidate it, or headings keep the indent
    /// measured for the old font.
    @Test func headingMarkerWidthFollowsAPointSizeChange() throws {
        let text = "## Title"
        let (applier, storage) = makeApplier(text: text)
        let fullRange = NSRange(location: 0, length: storage.length)

        applier.applyStyle(.heading, range: fullRange, string: storage.mutableString)
        let outdentAtBaseSize = try #require(headingMarkerOutdent(in: storage, at: 0))

        applier.updateMetrics(
            settings: Self.settings,
            windowWidthFontScale: 2
        )
        storage.setAttributes(applier.baseAttributes(), range: fullRange)
        applier.applyStyle(.heading, range: fullRange, string: storage.mutableString)
        let outdentAtDoubleSize = try #require(headingMarkerOutdent(in: storage, at: 0))

        #expect(outdentAtDoubleSize > outdentAtBaseSize * 1.5)
    }

    // MARK: - Line markers

    @Test func unorderedListMarkerIsColoredAndTheItemTextIsNot() {
        let text = "- item"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .unorderedList,
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        #expect(foregroundColor(in: storage, at: 0) == Self.colors.listMarker)
        #expect(foregroundColor(in: storage, at: 1) == Self.colors.listMarker)
        #expect(foregroundColor(in: storage, at: 2) == Self.colors.foreground)
    }

    @Test func orderedListMarkerIsColoredThroughItsTrailingSpace() {
        let text = "12. item"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .orderedList,
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        for location in 0 ..< 4 {
            #expect(foregroundColor(in: storage, at: location) == Self.colors.listMarker)
        }
        #expect(foregroundColor(in: storage, at: 4) == Self.colors.foreground)
    }

    /// The checkbox is part of the marker, so "- [x] " colors as a whole.
    @Test func taskCheckboxIsPartOfTheListMarker() {
        let text = "- [x] done"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .unorderedList,
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        for location in 0 ..< 6 {
            #expect(foregroundColor(in: storage, at: location) == Self.colors.listMarker)
        }
        #expect(foregroundColor(in: storage, at: 6) == Self.colors.foreground)
    }

    @Test func blockQuoteColorsOnlyTheAngleBracket() {
        let text = "> quoted"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .blockQuote,
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        #expect(foregroundColor(in: storage, at: 0) == Self.colors.listMarker)
        #expect(foregroundColor(in: storage, at: 1) == Self.colors.foreground)
        #expect(foregroundColor(in: storage, at: 2) == Self.colors.foreground)
    }

    /// The markers are matched line by line inside the span, not once at its
    /// start: a multi-line quote colors every one of its brackets.
    @Test func everyLineOfABlockQuoteSpanIsMarked() {
        let text = "> one\n> two"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .blockQuote,
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        #expect(foregroundColor(in: storage, at: 0) == Self.colors.listMarker)
        #expect(foregroundColor(in: storage, at: 6) == Self.colors.listMarker)
    }

    @Test func listMarkerGivesWrappedLinesATwoCharacterHangingIndent() throws {
        let text = "- a long item\n- another long item"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .unorderedList,
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        let expectedIndent = Self.paragraphGutter
            + 2 * (applier.characterWidth() + applier.baseLetterSpacing)
        for location in [0, 14] {
            let style = try #require(paragraphStyle(in: storage, at: location))
            #expect(style.firstLineHeadIndent == Self.paragraphGutter)
            #expect(style.headIndent == expectedIndent)
        }
        #expect(storage.string == text)
    }

    @Test func orderedListMarkerUsesThreeCharacterHangingIndent() throws {
        let text = "1. a long item"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .orderedList,
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        let style = try #require(paragraphStyle(in: storage, at: 0))
        let expectedIndent = Self.paragraphGutter
            + 3 * (applier.characterWidth() + applier.baseLetterSpacing)
        #expect(style.firstLineHeadIndent == Self.paragraphGutter)
        #expect(style.headIndent == expectedIndent)
        #expect(storage.string == text)
    }

    @Test func quoteMarkerGivesWrappedLinesATwoCharacterHangingIndent() throws {
        let text = "> a long quote\n> another long quote"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .blockQuote,
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        let expectedIndent = Self.paragraphGutter
            + 2 * (applier.characterWidth() + applier.baseLetterSpacing)
        for location in [0, 15] {
            let style = try #require(paragraphStyle(in: storage, at: location))
            #expect(style.firstLineHeadIndent == Self.paragraphGutter)
            #expect(style.headIndent == expectedIndent)
        }
        #expect(storage.string == text)
    }

    /// The marker offsets come back from a regex run over the extracted span
    /// text, so a span that does not start at zero has to be offset back onto
    /// the document.
    @Test func markerOffsetsAreMappedBackOntoTheDocument() {
        let text = "Intro\n\n- item"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .unorderedList,
            range: NSRange(location: 7, length: 6),
            string: storage.mutableString
        )

        #expect(foregroundColor(in: storage, at: 0) == Self.colors.foreground)
        #expect(foregroundColor(in: storage, at: 7) == Self.colors.listMarker)
        #expect(foregroundColor(in: storage, at: 8) == Self.colors.listMarker)
        #expect(foregroundColor(in: storage, at: 9) == Self.colors.foreground)
    }

    // MARK: - Font traits

    @Test func addFontTraitsKeepsTheTraitsAlreadyOnTheRun() throws {
        let text = "bold italic"
        let (applier, storage) = makeApplier(text: text)
        let fullRange = NSRange(location: 0, length: storage.length)

        applier.addFontTraits(.boldFontMask, range: fullRange)
        applier.addFontTraits(.italicFontMask, range: fullRange)

        let styledFont = try #require(font(in: storage, at: 0))
        let traits = NSFontManager.shared.traits(of: styledFont)
        #expect(traits.contains(.boldFontMask))
        #expect(traits.contains(.italicFontMask))
    }

    @Test func overlappingStrongAndEmphasisSpansCombineTheirTraits() throws {
        let text = "plain strong both emphasis"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .strong,
            range: NSRange(location: 6, length: 11),
            string: storage.mutableString
        )
        applier.applyStyle(
            .emphasis,
            range: NSRange(location: 13, length: 13),
            string: storage.mutableString
        )

        let plainTraits = try NSFontManager.shared
            .traits(of: #require(font(in: storage, at: 0)))
        let strongTraits = try NSFontManager.shared
            .traits(of: #require(font(in: storage, at: 6)))
        let bothTraits = try NSFontManager.shared
            .traits(of: #require(font(in: storage, at: 13)))
        let emphasisTraits = try NSFontManager.shared
            .traits(of: #require(font(in: storage, at: 18)))

        #expect(!plainTraits.contains(.boldFontMask))
        #expect(!plainTraits.contains(.italicFontMask))
        #expect(strongTraits.contains(.boldFontMask))
        #expect(!strongTraits.contains(.italicFontMask))
        #expect(bothTraits.contains(.boldFontMask))
        #expect(bothTraits.contains(.italicFontMask))
        #expect(!emphasisTraits.contains(.boldFontMask))
        #expect(emphasisTraits.contains(.italicFontMask))
    }

    @Test func fontTraitsKeepTheSizeOfTheRunTheyAreAddedTo() throws {
        let text = "bold"
        let (applier, storage) = makeApplier(text: text)

        applier.addFontTraits(
            .boldFontMask,
            range: NSRange(location: 0, length: storage.length)
        )

        let styledFont = try #require(font(in: storage, at: 0))
        #expect(styledFont.pointSize == applier.basePointSize)
    }

    // MARK: - Non-breaking spaces

    @Test func everyNonbreakingSpaceInTheRangeIsUnderlined() {
        let text = "a\u{00A0}b\u{00A0}c"
        let (applier, storage) = makeApplier(text: text)

        applier.applyNonbreakingSpaceStyle(
            range: NSRange(location: 0, length: storage.length),
            string: storage.mutableString
        )

        for location in [1, 3] {
            #expect(
                storage.attribute(.underlineStyle, at: location, effectiveRange: nil)
                    as? Int == NSUnderlineStyle.single.rawValue
            )
            #expect(
                storage.attribute(.underlineColor, at: location, effectiveRange: nil)
                    as? NSColor == Self.colors.underline
            )
        }
        for location in [0, 2, 4] {
            #expect(
                storage.attribute(.underlineStyle, at: location, effectiveRange: nil)
                    == nil
            )
        }
    }

    @Test func nonbreakingSpacesOutsideTheRangeAreLeftAlone() {
        let text = "a\u{00A0}b\u{00A0}c"
        let (applier, storage) = makeApplier(text: text)

        applier.applyNonbreakingSpaceStyle(
            range: NSRange(location: 0, length: 2),
            string: storage.mutableString
        )

        #expect(
            storage.attribute(.underlineStyle, at: 1, effectiveRange: nil) != nil
        )
        #expect(
            storage.attribute(.underlineStyle, at: 3, effectiveRange: nil) == nil
        )
    }

    // MARK: - Bounds

    @Test func rangesPastTheEndOfTheStorageAreIgnored() {
        let text = "short"
        let (applier, storage) = makeApplier(text: text)

        applier.applyStyle(
            .thematicBreak,
            range: NSRange(location: 3, length: 40),
            string: storage.mutableString
        )
        applier.applyNonbreakingSpaceStyle(
            range: NSRange(location: 3, length: 40),
            string: storage.mutableString
        )

        #expect(foregroundColor(in: storage, at: 3) == Self.colors.foreground)
    }

    // MARK: - Metrics

    @Test func metricsFollowSettingsAndWindowWidthTogether() {
        let (applier, _) = makeApplier(text: "text")
        let basePointSize = applier.basePointSize

        applier.updateMetrics(
            settings: EditorSettings(
                textSizeScale: 2,
                maxTextColumns: 64,
                tabInsertionMode: .spaces,
                tabWidth: 4
            ),
            windowWidthFontScale: 1.2
        )

        #expect(applier.basePointSize == basePointSize * 2 * 1.2)
        #expect(applier.baseFont.pointSize == applier.basePointSize)
        #expect(applier.lineHeight == applier.basePointSize * 1.8)
        #expect(applier.characterWidth() > 0)
    }

    @Test func baseAttributesCarryTheGutterAndTheThemeForeground() throws {
        let (applier, _) = makeApplier(text: "text")

        let attributes = applier.baseAttributes()

        #expect(attributes[.foregroundColor] as? NSColor == Self.colors.foreground)
        #expect(attributes[.font] as? NSFont == applier.baseFont)
        #expect(attributes[.kern] as? CGFloat == applier.baseLetterSpacing)
        let style = try #require(attributes[.paragraphStyle] as? NSParagraphStyle)
        #expect(style.firstLineHeadIndent == Self.paragraphGutter)
        #expect(style.headIndent == Self.paragraphGutter)
        #expect(style.tailIndent == -Self.paragraphGutter)
        #expect(style.minimumLineHeight == applier.lineHeight)
        #expect(style.maximumLineHeight == applier.lineHeight)
    }

    /// The theme variant is pulled on every read, not cached: a restyle that
    /// runs without anyone having pushed the new variant first must still
    /// paint in the current theme, otherwise the app stays stuck in whatever
    /// appearance it launched with.
    @Test func baseAttributesFollowTheCurrentThemeWithoutAPush() {
        final class ThemeSource {
            var variant = EditorThemeColors.default.light
        }
        let theme = ThemeSource()
        let applier = MarkdownStyleApplier(
            textStorage: NSTextStorage(string: "text"),
            colors: { theme.variant },
            settings: Self.settings,
            windowWidthFontScale: 1
        )

        theme.variant = EditorThemeColors.default.dark

        #expect(
            applier.baseAttributes()[.foregroundColor] as? NSColor
                == EditorThemeColors.default.dark.foreground
        )
    }
}
