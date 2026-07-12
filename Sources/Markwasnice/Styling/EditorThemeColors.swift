import AppKit

struct EditorThemeColors: Equatable {
    struct Variant: Equatable {
        var background: NSColor
        var foreground: NSColor
        var caret: NSColor
        var selection: NSColor
        var codeBackground: NSColor
        var punctuation: NSColor
        var underline: NSColor
        var thematicBreak: NSColor
        var listMarker: NSColor
        var frontmatter: NSColor
    }

    var light: Variant
    var dark: Variant

    static let lightForeground = NSColor(
        calibratedRed: 0.102,
        green: 0.102,
        blue: 0.102,
        alpha: 1
    )
    static let darkForeground = NSColor(
        calibratedRed: 0.8,
        green: 0.8,
        blue: 0.8,
        alpha: 1
    )

    func variant(for appearance: NSAppearance) -> Variant {
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? dark : light
    }

    static let `default` = Self(
        light: Variant(
            background: NSColor(
                calibratedRed: 0.975,
                green: 0.975,
                blue: 0.975,
                alpha: 1.00
            ),
            foreground: lightForeground,
            caret: NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.11, alpha: 1),
            selection: NSColor(calibratedRed: 0.70, green: 0.82, blue: 1.00, alpha: 0.45),
            codeBackground: NSColor(
                calibratedRed: 0.937,
                green: 0.937,
                blue: 0.937,
                alpha: 1.00
            ),
            punctuation: lightForeground.withAlphaComponent(0.32),
            underline: lightForeground.withAlphaComponent(0.25),
            thematicBreak: NSColor(
                calibratedRed: 0.62,
                green: 0.60,
                blue: 0.55,
                alpha: 1
            ),
            listMarker: lightForeground.withAlphaComponent(0.4),
            frontmatter: lightForeground.withAlphaComponent(0.5)
        ),
        dark: Variant(
            background: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 1),
            foreground: darkForeground,
            caret: NSColor(calibratedRed: 0.88, green: 0.86, blue: 0.81, alpha: 1),
            selection: NSColor(calibratedRed: 0.25, green: 0.40, blue: 0.65, alpha: 0.55),
            codeBackground: NSColor(
                calibratedRed: 0.153,
                green: 0.153,
                blue: 0.153,
                alpha: 1
            ),
            punctuation: darkForeground.withAlphaComponent(0.54),
            underline: darkForeground.withAlphaComponent(0.33),
            thematicBreak: NSColor(
                calibratedRed: 0.48,
                green: 0.46,
                blue: 0.41,
                alpha: 1
            ),
            listMarker: NSColor(calibratedRed: 0.48, green: 0.46, blue: 0.41, alpha: 1),
            frontmatter: darkForeground.withAlphaComponent(0.5)
        )
    )
}
