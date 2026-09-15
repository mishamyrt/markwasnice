import AppKit
import Testing
@testable import Markwasnice

@MainActor
@Suite
struct MarkdownPreviewRendererTests {
    private let baseFontSize: CGFloat = 20

    private func render(_ source: String) -> NSAttributedString {
        BundledFontFamily.plexSans.registerFonts()
        BundledFontFamily.lilex.registerFonts()
        let renderer = MarkdownPreviewRenderer(theme: .init(
            baseFontSize: baseFontSize,
            colors: EditorThemeColors.default.light
        ))
        return renderer.render(source)
    }

    private func font(
        in rendered: NSAttributedString,
        at location: Int
    ) -> NSFont? {
        rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    @Test
    func stripsMarkupPunctuation() {
        let rendered = render("# Title\n\nSome **bold** and *italic* and `code`.")
        let text = rendered.string
        #expect(!text.contains("#"))
        #expect(!text.contains("*"))
        #expect(!text.contains("`"))
        #expect(text.contains("Title"))
        #expect(text.contains("bold"))
        #expect(text.contains("italic"))
        #expect(text.contains("code"))
    }

    @Test
    func headingSizeDependsOnLevel() {
        let rendered = render("# One\n\n## Two\n\nBody")
        let plain = rendered.string as NSString
        let h1Font = font(in: rendered, at: plain.range(of: "One").location)
        let h2Font = font(in: rendered, at: plain.range(of: "Two").location)
        let bodyFont = font(in: rendered, at: plain.range(of: "Body").location)

        #expect(h1Font != nil && h2Font != nil && bodyFont != nil)
        #expect(h1Font!.pointSize > h2Font!.pointSize)
        #expect(h2Font!.pointSize > bodyFont!.pointSize)
        #expect(bodyFont!.pointSize == baseFontSize)
    }

    @Test
    func bodyKeepsEditorLineHeightWithoutKerning() {
        let rendered = render("Plain paragraph")
        let style = rendered.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(style?.minimumLineHeight == baseFontSize * 1.8)
        #expect(style?.maximumLineHeight == baseFontSize * 1.8)
        #expect(rendered.attribute(.kern, at: 0, effectiveRange: nil) == nil)
    }

    @Test
    func strongTextGetsBoldTrait() {
        let rendered = render("Some **bold** words")
        let location = (rendered.string as NSString).range(of: "bold").location
        let boldFont = font(in: rendered, at: location)
        #expect(boldFont != nil)
        #expect(NSFontManager.shared.traits(of: boldFont!).contains(.boldFontMask))
    }

    @Test
    func linkKeepsTextAndHidesDestination() {
        let rendered = render("See [the docs](https://example.com)")
        let text = rendered.string
        #expect(text.contains("the docs"))
        #expect(!text.contains("https://example.com"))
        #expect(!text.contains("["))

        let location = (text as NSString).range(of: "the docs").location
        let link = rendered.attribute(.link, at: location, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "https://example.com")
    }

    @Test
    func listMarkersAreRendered() {
        let rendered = render("- first\n- second\n\n1. one\n2. two")
        let text = rendered.string
        #expect(text.contains("•\tfirst"))
        #expect(text.contains("•\tsecond"))
        #expect(text.contains("1.\tone"))
        #expect(text.contains("2.\ttwo"))
        #expect(!text.contains("- "))
    }

    @Test
    func inlineCodeUsesMonospaceWithBackground() {
        let rendered = render("Run `make` now")
        let location = (rendered.string as NSString).range(of: "make").location
        let codeFont = font(in: rendered, at: location)
        #expect(codeFont?.isFixedPitch == true)
        let background = rendered.attribute(
            .backgroundColor,
            at: location,
            effectiveRange: nil
        ) as? NSColor
        #expect(background != nil)
    }

    @Test
    func tableCellsAreRenderedInsideTextTable() {
        let rendered = render("""
        | Name | Role |
        | --- | --- |
        | Ann | Dev |
        | Bob | Ops |
        """)
        let text = rendered.string
        #expect(text.contains("Name"))
        #expect(text.contains("Role"))
        #expect(text.contains("Ann"))
        #expect(text.contains("Ops"))
        // Pipe/dash markup is consumed by the table layout.
        #expect(!text.contains("|"))
        #expect(!text.contains("---"))

        let location = (text as NSString).range(of: "Name").location
        let style = rendered.attribute(
            .paragraphStyle,
            at: location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let block = style?.textBlocks.first as? NSTextTableBlock
        #expect(block != nil)
        #expect(block?.table.numberOfColumns == 2)
    }

    @Test
    func tableHeaderCellsAreBold() {
        let rendered = render("| Name | Role |\n| --- | --- |\n| Ann | Dev |")
        let headerLocation = (rendered.string as NSString).range(of: "Name").location
        let bodyLocation = (rendered.string as NSString).range(of: "Ann").location
        let headerFont = font(in: rendered, at: headerLocation)
        let bodyFont = font(in: rendered, at: bodyLocation)
        #expect(headerFont != nil && bodyFont != nil)
        #expect(NSFontManager.shared.traits(of: headerFont!).contains(.boldFontMask))
        #expect(!NSFontManager.shared.traits(of: bodyFont!).contains(.boldFontMask))
    }

    @Test
    func tableColumnAlignmentIsApplied() {
        let rendered = render("| L | R |\n| :--- | ---: |\n| a | b |")
        let leftLocation = (rendered.string as NSString).range(of: "a").location
        let rightLocation = (rendered.string as NSString).range(of: "b").location
        let leftStyle = rendered.attribute(
            .paragraphStyle,
            at: leftLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let rightStyle = rendered.attribute(
            .paragraphStyle,
            at: rightLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(leftStyle?.alignment == .left)
        #expect(rightStyle?.alignment == .right)
    }

    @Test
    func blockQuoteAndThematicBreakAreStripped() {
        let rendered = render("> quoted line\n\n---\n\nafter")
        let text = rendered.string
        #expect(text.contains("quoted line"))
        #expect(!text.contains(">"))
        #expect(!text.contains("---"))
        #expect(text.contains("after"))
    }

    @Test
    func hidesFrontmatter() {
        let rendered = render("---\ntitle: Secret\n---\n# Visible\n\nBody")
        let text = rendered.string
        #expect(!text.contains("Secret"))
        #expect(!text.contains("title"))
        #expect(text.contains("Visible"))
        #expect(text.contains("Body"))
    }

    @Test
    func rendersUnclosedLeadingDashesAsBefore() {
        // No closing delimiter → not frontmatter; the body must survive.
        let rendered = render("---\n\nText")
        #expect(rendered.string.contains("Text"))
    }
}
