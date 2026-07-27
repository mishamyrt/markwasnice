import AppKit
import Testing
@testable import Markwasnice

/// The code-block band is derived from the block's first and last line
/// fragments rather than by enumerating every fragment it covers — a scroll
/// frame inside a thousand-line block would otherwise pay for all of them.
/// These pin the AppKit assumption that makes the shortcut equivalent: the
/// enclosing rects of a glyph range never reach past the line fragments of its
/// end glyphs.
@MainActor
struct CodeBlockBandGeometryTests {
    private struct Layout {
        /// Held on to: a layout manager's reference back to its storage does
        /// not keep it alive.
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        let text: NSString
    }

    /// A narrow container so the long lines wrap and the block spans more
    /// fragments than it has lines.
    private func makeLayout(_ string: String) -> Layout {
        let storage = NSTextStorage(string: string)
        storage.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: 14),
            range: NSRange(location: 0, length: storage.length)
        )
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(
                width: 80,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return Layout(
            storage: storage,
            layoutManager: layoutManager,
            container: container,
            text: string as NSString
        )
    }

    private func enclosingBand(_ layout: Layout, _ glyphRange: NSRange) -> NSRect? {
        var union: NSRect?
        layout.layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: layout.container
        ) { rect, _ in
            guard !rect.isEmpty else {
                return
            }

            union = union.map { $0.union(rect) } ?? rect
        }
        return union
    }

    private func endFragmentBand(_ layout: Layout, _ glyphRange: NSRange) -> NSRect {
        let first = layout.layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        let last = layout.layoutManager.lineFragmentRect(
            forGlyphAt: NSMaxRange(glyphRange) - 1,
            effectiveRange: nil
        )
        return first.union(last)
    }

    private func expectSameVerticalExtent(
        _ layout: Layout,
        characterRange: NSRange,
        _ comment: Comment
    ) throws {
        let glyphRange = layout.layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        let enclosing = try #require(enclosingBand(layout, glyphRange), comment)
        let ends = endFragmentBand(layout, glyphRange)

        #expect(abs(ends.minY - enclosing.minY) < 0.5, comment)
        #expect(abs(ends.maxY - enclosing.maxY) < 0.5, comment)
    }

    @Test func wrappedBlockSpansTheSameBandEitherWay() throws {
        let layout = makeLayout(
            """
            ```
            a fenced block whose lines are long enough to wrap several times
            and a second line that also wraps around the narrow container
            ```
            after
            """
        )
        let block = layout.text.range(of: "```\na fenced")
        let end = layout.text.range(of: "container\n```")
        try expectSameVerticalExtent(
            layout,
            characterRange: NSRange(
                location: block.location,
                length: NSMaxRange(end) - block.location
            ),
            "wrapped fenced block"
        )
    }

    /// The band still has to reach the full height of its end fragments when
    /// the range starts and stops in the middle of a wrapped line.
    @Test func blockStartingMidLineSpansTheSameBandEitherWay() throws {
        let layout = makeLayout(
            "a long first line that wraps, then more text, then a final line"
        )
        try expectSameVerticalExtent(
            layout,
            characterRange: NSRange(location: 8, length: 30),
            "range starting mid-fragment"
        )
    }

    @Test func singleFragmentBlockSpansTheSameBandEitherWay() throws {
        let layout = makeLayout("short\nlines\nonly")
        try expectSameVerticalExtent(
            layout,
            characterRange: NSRange(location: 0, length: 5),
            "single fragment"
        )
    }
}
