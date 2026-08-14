import AppKit

/// The attribute-application half of the editor's styling pipeline: it turns
/// resolved style spans into text-storage attributes, and owns the font and
/// layout metrics every one of those attributes is built from. The editor view
/// keeps the pipeline around it — the deferred-task lifecycle, the reentrancy
/// guards, focus dimming and search decoration — and reads its own geometry
/// (text container inset, preview font size, code-background gutter) off the
/// metrics here, so each of those formulas keeps a single home.
///
/// Everything it needs is pushed in rather than read from a live view, so it
/// can be exercised against a bare NSTextStorage.
@MainActor
final class MarkdownStyleApplier {
    private let textStorage: NSTextStorage
    private var settings: EditorSettings
    private var windowWidthFontScale: CGFloat

    /// The theme variant is resolved on every read rather than stored: only
    /// the owner can resolve it (it is the one holding an NSAppearance), and a
    /// stored copy goes stale the moment a restyle runs without an appearance
    /// notification having refreshed it first — which the user sees as the app
    /// being stuck in whatever theme it launched with.
    private let resolveColors: () -> EditorThemeColors.Variant

    var colors: EditorThemeColors.Variant {
        resolveColors()
    }

    /// The indent the paragraph text starts at, measured from the text
    /// container's edge. Block markers are outdented into it, so it is both a
    /// paragraph-style input here and the width of the gutter the view has the
    /// text view fill behind code. Recomputed by the view's container-inset
    /// pass, which is the only place that can measure the available width.
    var paragraphGutter: CGFloat = 0

    init(
        textStorage: NSTextStorage,
        colors: @escaping () -> EditorThemeColors.Variant,
        settings: EditorSettings,
        windowWidthFontScale: CGFloat
    ) {
        self.textStorage = textStorage
        resolveColors = colors
        self.settings = settings
        self.windowWidthFontScale = windowWidthFontScale
    }

    /// Both metric inputs are pushed together, even when only one of them
    /// moved: a settings change and a window-width change go through the same
    /// call, so neither path can leave the other input behind.
    func updateMetrics(settings: EditorSettings, windowWidthFontScale: CGFloat) {
        self.settings = settings
        self.windowWidthFontScale = windowWidthFontScale
    }

    // MARK: Metrics

    var baseFont: NSFont {
        LilexFontProvider.regular(size: basePointSize)
    }

    private var boldFont: NSFont {
        LilexFontProvider.bold(size: basePointSize)
    }

    var basePointSize: CGFloat {
        settings.basePointSize * windowWidthFontScale
    }

    var baseLetterSpacing: CGFloat {
        basePointSize * 0.0305
    }

    var lineHeight: CGFloat {
        basePointSize * 1.8
    }

    func baseAttributes() -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: colors.foreground,
        ]
        if !MarkdownEditorDiagnostics.disableKern {
            attributes[.kern] = baseLetterSpacing
        }
        if !MarkdownEditorDiagnostics.disableParagraphStyle {
            attributes[.paragraphStyle] = baseParagraphStyle()
        }
        return attributes
    }

    private func baseParagraphStyle() -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.firstLineHeadIndent = paragraphGutter
        paragraphStyle.headIndent = paragraphGutter
        paragraphStyle.tailIndent = -paragraphGutter
        return paragraphStyle
    }

    func characterWidth() -> CGFloat {
        let width = ("0" as NSString).size(withAttributes: [.font: baseFont]).width
        return width > 0 ? width : basePointSize * 0.6
    }

    /// A source prefix expressed in the same character-cell metric used for
    /// the editor gutter, including the spacing applied to every glyph.
    private func markerPrefixWidth(characterCount: Int) -> CGFloat {
        CGFloat(characterCount) * (characterWidth() + baseLetterSpacing)
    }

    // MARK: Attribute application

    func applyStyle(
        _ kind: MarkdownStyleKind,
        range: NSRange,
        string: NSString
    ) {
        guard let range = boundedRange(range), range.length > 0 else {
            return
        }

        switch kind {
        case .heading:
            applyHeadingStyle(range: range, string: string)
        case .strong:
            addFontTraits(.boldFontMask, range: range)
        case .emphasis:
            addFontTraits(.italicFontMask, range: range)
        case .strikethrough:
            // Drawn by MarkdownLayoutManager centered on the x-height.
            textStorage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        case .inlineCode, .codeBlock:
            // Code backgrounds are drawn as rounded decorations in
            // MarkdownTextView (see updateCodeBackgroundRanges); the plain
            // .backgroundColor attribute is intentionally not applied here.
            textStorage.addAttributes([
                .font: baseFont,
                .foregroundColor: colors.foreground,
            ], range: range)
        case .linkDestination:
            textStorage.addAttributes([
                .foregroundColor: colors.punctuation,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: colors.underline,
            ], range: range)
        case .linkSyntaxPunctuation:
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.punctuation,
                range: range
            )
        case .link, .image:
            break
        case .blockQuote:
            applyLineMarkerStyle(
                Self.blockQuoteMarkerRegex,
                range: range,
                string: string,
                markerCaptureGroup: 1
            )
        case .orderedList:
            applyLineMarkerStyle(
                Self.listMarkerRegex,
                range: range,
                string: string,
                hangingIndentCharacterCount: 3,
                checkboxCaptureGroup: 1
            )
        case .unorderedList:
            applyLineMarkerStyle(
                Self.listMarkerRegex,
                range: range,
                string: string,
                checkboxCaptureGroup: 1
            )
        case .taskCheckbox:
            // Same colour a list marker gets, so "[ ] a" and "- [ ] a" read
            // alike; the span already covers just the brackets.
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.listMarker,
                range: range
            )
        case .thematicBreak:
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.thematicBreak,
                range: range
            )
        case .frontmatter:
            textStorage.addAttribute(
                .foregroundColor,
                value: colors.frontmatter,
                range: range
            )
        }
    }

    private static let headingMarkerRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(#{1,6}[ \t]+)"#,
        options: [.anchorsMatchLines]
    )
    private static let blockQuoteMarkerRegex = try! NSRegularExpression(
        pattern: "^\\s*(>)",
        options: [.anchorsMatchLines]
    )
    /// The task checkbox counts as part of the marker, so "- [x] " dims as a
    /// whole instead of leaving brackets in the body colour.
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: "^\\s*\(MarkdownLineGrammar.listMarker)\\s+"
            + "(?:(\(MarkdownLineGrammar.checkbox))\\s+)?",
        options: [.anchorsMatchLines]
    )
    private func applyHeadingStyle(range: NSRange, string: NSString) {
        // Only the searched lines are handed to the regex. NSRegularExpression
        // takes a Swift String, and bridging the backing store copies the
        // whole document — once per styled heading, on every restyle.
        // `anchorsMatchLines` behaves the same on the extracted lines as it did
        // on a sub-range of the document: the search always starts at a line
        // start, and anchoring bounds kept `^` from looking past it either way.
        let headingSearchRange = string.lineRange(for: range)
        Self.headingMarkerRegex
            .enumerateMatches(
                in: string.substring(with: headingSearchRange),
                range: NSRange(location: 0, length: headingSearchRange.length)
            ) { [self] match, _, _ in
                guard let match,
                      match.numberOfRanges > 1,
                      match.range(at: 1).location != NSNotFound
                else {
                    return
                }

                let matchRange = NSRange(
                    location: headingSearchRange.location + match.range.location,
                    length: match.range.length
                )
                let lineRange = string.lineRange(for: matchRange)
                guard let lineRange = boundedRange(lineRange) else {
                    return
                }

                addFontTraits(.boldFontMask, range: lineRange)

                let markerRange = NSRange(
                    location: headingSearchRange.location
                        + match.range(at: 1).location,
                    length: match.range(at: 1).length
                )
                let marker = string.substring(with: markerRange)
                let markerWidth = headingMarkerWidth(marker)
                let paragraphStyle = baseParagraphStyle()
                if !MarkdownEditorDiagnostics.disableHeadingOutdent,
                   !MarkdownEditorDiagnostics.disableParagraphStyle
                {
                    paragraphStyle.firstLineHeadIndent = paragraphGutter - markerWidth
                    paragraphStyle.headIndent = paragraphGutter
                    // The whole line including the trailing newline: TextKit
                    // conforms paragraph styles to paragraph boundaries, so a
                    // partial-line style would be re-expanded nondeterministically.
                    // The caret on the FOLLOWING empty line is protected by the
                    // extended restyle range in didProcessEditing instead.
                    textStorage.addAttribute(
                        .paragraphStyle,
                        value: paragraphStyle,
                        range: lineRange
                    )
                }
            }
    }

    private var headingMarkerWidthCache: [String: CGFloat] = [:]
    private var headingMarkerWidthCachePointSize: CGFloat = 0

    private func headingMarkerWidth(_ marker: String) -> CGFloat {
        if headingMarkerWidthCachePointSize != basePointSize {
            headingMarkerWidthCache.removeAll(keepingCapacity: true)
            headingMarkerWidthCachePointSize = basePointSize
        }

        if let cached = headingMarkerWidthCache[marker] {
            return cached
        }

        let width = (marker as NSString).size(withAttributes: [
            .font: boldFont,
            .kern: baseLetterSpacing,
        ]).width
        headingMarkerWidthCache[marker] = width
        return width
    }

    func addFontTraits(_ traits: NSFontTraitMask, range: NSRange) {
        guard !MarkdownEditorDiagnostics.disableFontTraits else {
            MarkdownEditorDiagnostics.log(
                "font traits skipped range=\(range.location)..\(NSMaxRange(range))"
            )
            return
        }

        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let currentFont = value as? NSFont ?? baseFont
            let existingTraits = NSFontManager.shared.traits(of: currentFont)
            textStorage.addAttribute(
                .font,
                value: LilexFontProvider.font(
                    size: currentFont.pointSize,
                    traits: existingTraits.union(traits)
                ),
                range: subrange
            )
        }
    }

    private func applyLineMarkerStyle(
        _ expression: NSRegularExpression,
        range: NSRange,
        string: NSString,
        markerCaptureGroup: Int? = nil,
        hangingIndentCharacterCount: Int = 2,
        checkboxCaptureGroup: Int? = nil
    ) {
        // Scanned over the extracted span text for the same reason as the
        // heading markers above: the regex needs a Swift String, and the
        // whole-document bridge is a copy per styled list and quote.
        expression.enumerateMatches(
            in: string.substring(with: range),
            range: NSRange(location: 0, length: range.length)
        ) { match, _, _ in
            guard let match else {
                return
            }

            let matchRange: NSRange
            if let markerCaptureGroup {
                guard markerCaptureGroup < match.numberOfRanges else {
                    return
                }
                matchRange = match.range(at: markerCaptureGroup)
            } else {
                matchRange = match.range
            }

            guard matchRange.location != NSNotFound else {
                return
            }

            let markerRange = NSRange(
                location: range.location + matchRange.location,
                length: matchRange.length
            )
            guard NSMaxRange(markerRange) <= string.length else {
                return
            }

            textStorage.addAttribute(
                .foregroundColor,
                value: colors.listMarker,
                range: markerRange
            )

            var indentCharacterCount = hangingIndentCharacterCount
            if let checkboxCaptureGroup,
               checkboxCaptureGroup < match.numberOfRanges
            {
                let checkboxRange = match.range(at: checkboxCaptureGroup)
                if checkboxRange.location != NSNotFound {
                    // The capture excludes the separating space after `[ ]`.
                    indentCharacterCount += checkboxRange.length + 1
                }
            }

            applyMarkerHangingIndent(
                to: string.lineRange(for: markerRange),
                characterCount: indentCharacterCount
            )
        }
    }

    /// Keeps a wrapped line aligned under the text following a list or quote
    /// marker. This is a paragraph-layout attribute only: the source string
    /// remains unchanged for editing and copying.
    private func applyMarkerHangingIndent(
        to lineRange: NSRange,
        characterCount: Int
    ) {
        guard !MarkdownEditorDiagnostics.disableParagraphStyle,
              let lineRange = boundedRange(lineRange)
        else {
            return
        }

        let paragraphStyle = baseParagraphStyle()
        paragraphStyle.headIndent += markerPrefixWidth(characterCount: characterCount)
        textStorage.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: lineRange
        )
    }

    func applyNonbreakingSpaceStyle(range: NSRange, string: NSString) {
        guard let range = boundedRange(range), range.length > 0 else {
            return
        }

        var searchRange = range
        let upperBound = NSMaxRange(range)
        while searchRange.length > 0 {
            let foundRange = string.range(of: "\u{00A0}", options: [], range: searchRange)
            guard foundRange.location != NSNotFound else {
                return
            }

            textStorage.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: colors.underline,
            ], range: foundRange)

            let nextLocation = NSMaxRange(foundRange)
            searchRange = NSRange(
                location: nextLocation,
                length: upperBound - nextLocation
            )
        }
    }

    private func boundedRange(_ range: NSRange) -> NSRange? {
        MarkdownStylingEngine.bounded(range, length: textStorage.length)
    }
}
