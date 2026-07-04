import AppKit
import Markdown

/// Renders markdown source into a fully styled attributed string for the
/// read-only preview mode: markup punctuation is consumed by the parser and
/// replaced with typographic styling.
@MainActor
struct MarkdownPreviewRenderer {
    struct Theme {
        var baseFontSize: CGFloat
        var colors: EditorThemeColors.Variant
    }

    let theme: Theme

    /// Heading point sizes relative to the body size, by level.
    static let headingScales: [CGFloat] = [1.7, 1.45, 1.25, 1.1, 1.0, 0.9]
    /// Matches the editor's line height so body text keeps the same leading.
    static let bodyLineHeightFactor: CGFloat = 1.8
    static let headingLineHeightFactor: CGFloat = 1.4
    static let codeFontScale: CGFloat = 0.85

    func render(_ source: String) -> NSAttributedString {
        let document = Document(parsing: source)
        let result = NSMutableAttributedString()
        for block in document.children {
            result.append(renderBlock(block, indent: 0, isQuoted: false))
        }
        return result
    }

    // MARK: Blocks

    private func renderBlock(
        _ block: Markup,
        indent: CGFloat,
        isQuoted: Bool
    ) -> NSAttributedString {
        switch block {
        case let paragraph as Paragraph:
            return renderParagraph(paragraph, indent: indent, isQuoted: isQuoted)
        case let heading as Heading:
            return renderHeading(heading, indent: indent, isQuoted: isQuoted)
        case let codeBlock as CodeBlock:
            return renderCodeText(codeBlock.code, indent: indent)
        case let htmlBlock as HTMLBlock:
            return renderCodeText(htmlBlock.rawHTML, indent: indent)
        case let blockQuote as BlockQuote:
            return renderBlockQuote(blockQuote, indent: indent)
        case let list as UnorderedList:
            return renderList(list, indent: indent, isQuoted: isQuoted) { item, _ in
                switch item.checkbox {
                case .checked:
                    "☑"
                case .unchecked:
                    "☐"
                case nil:
                    "•"
                }
            }
        case let list as OrderedList:
            return renderList(list, indent: indent, isQuoted: isQuoted) { _, index in
                "\(Int(list.startIndex) + index)."
            }
        case is ThematicBreak:
            return renderThematicBreak(indent: indent)
        default:
            // Unknown blocks (tables, directives, …) fall back to their
            // markdown source rendered as body text.
            return renderPlainParagraph(
                block.format().trimmingCharacters(in: .whitespacesAndNewlines),
                indent: indent,
                isQuoted: isQuoted
            )
        }
    }

    private func renderParagraph(
        _ paragraph: Paragraph,
        indent: CGFloat,
        isQuoted: Bool,
        style: NSParagraphStyle? = nil
    ) -> NSAttributedString {
        let paragraphStyle = style ?? blockParagraphStyle(indent: indent)
        let context = InlineContext(
            fontSize: theme.baseFontSize,
            foreground: foreground(isQuoted: isQuoted),
            paragraphStyle: paragraphStyle
        )
        let result = NSMutableAttributedString()
        result.append(renderInlineChildren(of: paragraph, context: context))
        result.append(NSAttributedString(
            string: "\n",
            attributes: attributes(for: context)
        ))
        return result
    }

    private func renderPlainParagraph(
        _ text: String,
        indent: CGFloat,
        isQuoted: Bool
    ) -> NSAttributedString {
        let context = InlineContext(
            fontSize: theme.baseFontSize,
            foreground: foreground(isQuoted: isQuoted),
            paragraphStyle: blockParagraphStyle(indent: indent)
        )
        return NSAttributedString(
            string: text + "\n",
            attributes: attributes(for: context)
        )
    }

    private func renderHeading(
        _ heading: Heading,
        indent: CGFloat,
        isQuoted: Bool
    ) -> NSAttributedString {
        let scaleIndex = min(max(heading.level, 1), Self.headingScales.count) - 1
        let size = theme.baseFontSize * Self.headingScales[scaleIndex]
        let style = paragraphStyle(
            lineHeight: size * Self.headingLineHeightFactor,
            spacing: theme.baseFontSize * 0.4,
            spacingBefore: theme.baseFontSize * 0.7,
            firstLineIndent: indent,
            headIndent: indent
        )
        let context = InlineContext(
            fontSize: size,
            bold: true,
            foreground: foreground(isQuoted: isQuoted),
            paragraphStyle: style
        )
        let result = NSMutableAttributedString()
        result.append(renderInlineChildren(of: heading, context: context))
        result.append(NSAttributedString(
            string: "\n",
            attributes: attributes(for: context)
        ))
        return result
    }

    private func renderCodeText(_ code: String, indent: CGFloat) -> NSAttributedString {
        let size = theme.baseFontSize * Self.codeFontScale
        let style = paragraphStyle(
            lineHeight: size * 1.6,
            spacing: theme.baseFontSize * 0.7,
            firstLineIndent: indent,
            headIndent: indent
        )
        let text = code.trimmingCharacters(in: .newlines)
        return NSAttributedString(string: text + "\n", attributes: [
            .font: LilexFontProvider.regular(size: size),
            .foregroundColor: theme.colors.foreground,
            .backgroundColor: theme.colors.codeBackground,
            .paragraphStyle: style,
        ])
    }

    private func renderBlockQuote(
        _ blockQuote: BlockQuote,
        indent: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in blockQuote.children {
            result.append(renderBlock(
                child,
                indent: indent + theme.baseFontSize * 1.2,
                isQuoted: true
            ))
        }
        return result
    }

    private func renderList(
        _ list: Markup,
        indent: CGFloat,
        isQuoted: Bool,
        marker: (ListItem, Int) -> String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var index = 0
        for child in list.children {
            guard let item = child as? ListItem else {
                continue
            }

            result.append(renderListItem(
                item,
                marker: marker(item, index),
                indent: indent,
                isQuoted: isQuoted
            ))
            index += 1
        }
        return result
    }

    private func renderListItem(
        _ item: ListItem,
        marker: String,
        indent: CGFloat,
        isQuoted: Bool
    ) -> NSAttributedString {
        let markerColumn = theme.baseFontSize * 1.6
        let contentIndent = indent + markerColumn
        let markerStyle = paragraphStyle(
            lineHeight: baseLineHeight,
            spacing: theme.baseFontSize * 0.25,
            firstLineIndent: indent,
            headIndent: contentIndent,
            tabLocation: contentIndent
        )
        let result = NSMutableAttributedString()
        var needsMarker = true

        for child in item.children {
            if needsMarker, let paragraph = child as? Paragraph {
                needsMarker = false
                result.append(NSAttributedString(
                    string: marker + "\t",
                    attributes: [
                        .font: PlexSansFontProvider.regular(size: theme.baseFontSize),
                        .foregroundColor: theme.colors.listMarker,
                        .paragraphStyle: markerStyle,
                    ]
                ))
                let content = renderParagraph(
                    paragraph,
                    indent: indent,
                    isQuoted: isQuoted,
                    style: markerStyle
                )
                result.append(content)
                continue
            }

            result.append(renderBlock(child, indent: contentIndent, isQuoted: isQuoted))
        }

        if needsMarker {
            // An item without a leading paragraph (empty, or starting with a
            // nested block) still shows its marker on its own line.
            result.insert(NSAttributedString(
                string: marker + "\n",
                attributes: [
                    .font: PlexSansFontProvider.regular(size: theme.baseFontSize),
                    .foregroundColor: theme.colors.listMarker,
                    .paragraphStyle: markerStyle,
                ]
            ), at: 0)
        }

        return result
    }

    private func renderThematicBreak(indent: CGFloat) -> NSAttributedString {
        let style = paragraphStyle(
            lineHeight: baseLineHeight,
            spacing: theme.baseFontSize * 0.7,
            spacingBefore: theme.baseFontSize * 0.3,
            firstLineIndent: indent,
            headIndent: indent
        )
        return NSAttributedString(
            string: String(repeating: "─", count: 20) + "\n",
            attributes: [
                .font: PlexSansFontProvider.regular(size: theme.baseFontSize * 0.8),
                .foregroundColor: theme.colors.thematicBreak,
                .paragraphStyle: style,
            ]
        )
    }

    // MARK: Inlines

    private struct InlineContext {
        var fontSize: CGFloat
        var bold = false
        var italic = false
        var strikethrough = false
        var isCode = false
        var foreground: NSColor
        var linkDestination: String?
        var paragraphStyle: NSParagraphStyle
    }

    private func renderInlineChildren(
        of markup: Markup,
        context: InlineContext
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in markup.children {
            result.append(renderInline(child, context: context))
        }
        return result
    }

    private func renderInline(
        _ markup: Markup,
        context: InlineContext
    ) -> NSAttributedString {
        switch markup {
        case let text as Markdown.Text:
            return NSAttributedString(
                string: text.string,
                attributes: attributes(for: context)
            )
        case is SoftBreak:
            return NSAttributedString(
                string: " ",
                attributes: attributes(for: context)
            )
        case is LineBreak:
            // U+2028 breaks the line without starting a new paragraph, so the
            // list/quote indentation is preserved.
            return NSAttributedString(
                string: "\u{2028}",
                attributes: attributes(for: context)
            )
        case let code as InlineCode:
            var context = context
            context.isCode = true
            return NSAttributedString(
                string: code.code,
                attributes: attributes(for: context)
            )
        case let emphasis as Emphasis:
            var context = context
            context.italic = true
            return renderInlineChildren(of: emphasis, context: context)
        case let strong as Strong:
            var context = context
            context.bold = true
            return renderInlineChildren(of: strong, context: context)
        case let strikethrough as Strikethrough:
            var context = context
            context.strikethrough = true
            return renderInlineChildren(of: strikethrough, context: context)
        case let link as Markdown.Link:
            var context = context
            context.linkDestination = link.destination
            return renderInlineChildren(of: link, context: context)
        case let image as Markdown.Image:
            var context = context
            context.foreground = theme.colors.punctuation
            context.italic = true
            let title = image.plainText
            return NSAttributedString(
                string: title.isEmpty ? (image.source ?? "") : title,
                attributes: attributes(for: context)
            )
        case let html as InlineHTML:
            var context = context
            context.isCode = true
            return NSAttributedString(
                string: html.rawHTML,
                attributes: attributes(for: context)
            )
        default:
            return renderInlineChildren(of: markup, context: context)
        }
    }

    private func attributes(
        for context: InlineContext
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: context),
            .foregroundColor: context.foreground,
            .paragraphStyle: context.paragraphStyle,
        ]
        if context.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if context.isCode {
            attributes[.backgroundColor] = theme.colors.codeBackground
        }
        if let destination = context.linkDestination {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = theme.colors.underline
            if let url = URL(string: destination) {
                attributes[.link] = url
            }
        }
        return attributes
    }

    private func font(for context: InlineContext) -> NSFont {
        if context.isCode {
            var traits: NSFontTraitMask = []
            if context.bold {
                traits.insert(.boldFontMask)
            }
            if context.italic {
                traits.insert(.italicFontMask)
            }
            let size = context.fontSize * Self.codeFontScale
            return traits.isEmpty
                ? LilexFontProvider.regular(size: size)
                : LilexFontProvider.font(size: size, traits: traits)
        }

        switch (context.bold, context.italic) {
        case (true, true):
            return PlexSansFontProvider.boldItalic(size: context.fontSize)
        case (true, false):
            return PlexSansFontProvider.bold(size: context.fontSize)
        case (false, true):
            return PlexSansFontProvider.italic(size: context.fontSize)
        case (false, false):
            return PlexSansFontProvider.regular(size: context.fontSize)
        }
    }

    // MARK: Styles

    private var baseLineHeight: CGFloat {
        theme.baseFontSize * Self.bodyLineHeightFactor
    }

    private func foreground(isQuoted: Bool) -> NSColor {
        isQuoted
            ? theme.colors.foreground.withAlphaComponent(
                theme.colors.foreground.alphaComponent * 0.7
            )
            : theme.colors.foreground
    }

    private func blockParagraphStyle(indent: CGFloat) -> NSParagraphStyle {
        paragraphStyle(
            lineHeight: baseLineHeight,
            spacing: theme.baseFontSize * 0.7,
            firstLineIndent: indent,
            headIndent: indent
        )
    }

    private func paragraphStyle(
        lineHeight: CGFloat,
        spacing: CGFloat,
        spacingBefore: CGFloat = 0,
        firstLineIndent: CGFloat,
        headIndent: CGFloat,
        tabLocation: CGFloat? = nil
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = spacingBefore
        style.firstLineHeadIndent = firstLineIndent
        style.headIndent = headIndent
        if let tabLocation {
            style.tabStops = [NSTextTab(
                textAlignment: .left,
                location: tabLocation
            )]
        }
        return style
    }
}
