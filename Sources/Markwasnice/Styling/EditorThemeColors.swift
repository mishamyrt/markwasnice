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
        var proofreadingLow: NSColor
        var proofreadingMedium: NSColor
        var proofreadingHigh: NSColor
        var proofreadingCritical: NSColor

        func proofreadingColor(for severity: ProofreadingSeverity) -> NSColor {
            switch severity {
            case .low: proofreadingLow
            case .medium: proofreadingMedium
            case .high: proofreadingHigh
            case .critical: proofreadingCritical
            }
        }
    }

    var light: Variant
    var dark: Variant

    static let lightForeground = NSColor(
        calibratedRed: 0.102,
        green: 0.102,
        blue: 0.102,
        alpha: 1
    )
    static let lightBackground = NSColor(
        calibratedRed: 0.975,
        green: 0.975,
        blue: 0.975,
        alpha: 1
    )

    static let darkForeground = NSColor(
        calibratedRed: 0.8,
        green: 0.8,
        blue: 0.8,
        alpha: 1
    )
    static let darkBackground = NSColor(
        calibratedRed: 0.08,
        green: 0.08,
        blue: 0.08,
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
            selection: NSColor(srgbRed: 0.519, green: 0.893, blue: 1.000, alpha: 0.46),
            codeBackground: NSColor(
                calibratedRed: 0.937,
                green: 0.937,
                blue: 0.937,
                alpha: 1.00
            ),
            punctuation: lightForeground.blended(
                withFraction: 0.68,
                of: lightBackground
            )!,
            underline: lightForeground.blended(withFraction: 0.75, of: lightBackground)!,
            thematicBreak: NSColor(
                calibratedRed: 0.62,
                green: 0.60,
                blue: 0.55,
                alpha: 1
            ),
            listMarker: lightForeground.withAlphaComponent(0.4),
            frontmatter: lightForeground.blended(withFraction: 0.5, of: lightBackground)!,
            proofreadingLow: NSColor(
                calibratedRed: 0.22,
                green: 0.60,
                blue: 0.32,
                alpha: 1
            ),
            proofreadingMedium: NSColor(
                calibratedRed: 0.95,
                green: 0.60,
                blue: 0.20,
                alpha: 1
            ),
            proofreadingHigh: NSColor(
                calibratedRed: 0.93,
                green: 0.42,
                blue: 0.10,
                alpha: 1
            ),
            proofreadingCritical: NSColor(
                calibratedRed: 0.85,
                green: 0.22,
                blue: 0.18,
                alpha: 1
            )
        ),
        dark: Variant(
            background: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 1),
            foreground: darkForeground,
            caret: NSColor(calibratedRed: 0.88, green: 0.86, blue: 0.81, alpha: 1),
            selection: NSColor(srgbRed: 0.008, green: 0.302, blue: 0.403, alpha: 0.76),
            codeBackground: NSColor(
                srgbRed: 0.153,
                green: 0.153,
                blue: 0.153,
                alpha: 1.00
            ),
            punctuation: darkForeground.blended(withFraction: 0.46, of: darkBackground)!,
            underline: darkForeground.blended(withFraction: 0.67, of: darkBackground)!,
            thematicBreak: NSColor(
                calibratedRed: 0.48,
                green: 0.46,
                blue: 0.41,
                alpha: 1
            ),
            listMarker: NSColor(calibratedRed: 0.48, green: 0.46, blue: 0.41, alpha: 1),
            frontmatter: darkForeground.blended(withFraction: 0.46, of: darkBackground)!,
            proofreadingLow: NSColor(
                calibratedRed: 0.36,
                green: 0.72,
                blue: 0.44,
                alpha: 1
            ),
            proofreadingMedium: NSColor(
                calibratedRed: 0.98,
                green: 0.68,
                blue: 0.32,
                alpha: 1
            ),
            proofreadingHigh: NSColor(
                calibratedRed: 0.98,
                green: 0.52,
                blue: 0.22,
                alpha: 1
            ),
            proofreadingCritical: NSColor(
                calibratedRed: 0.94,
                green: 0.36,
                blue: 0.32,
                alpha: 1
            )
        )
    )
}
