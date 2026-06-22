import AppKit

struct EditorThemeColors: Equatable {
    struct Variant: Equatable {
        var background: NSColor
        var foreground: NSColor
        var caret: NSColor
        var selection: NSColor
        var emphasis: NSColor
        var codeForeground: NSColor
        var codeBackground: NSColor
        var quote: NSColor
        var punctuation: NSColor
        var thematicBreak: NSColor
        var listMarker: NSColor
    }

    var light: Variant
    var dark: Variant

    func variant(for appearance: NSAppearance) -> Variant {
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? dark : light
    }

    static let `default` = EditorThemeColors(
        light: Variant(
            background: NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 1),
            foreground: NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.11, alpha: 1),
            caret: NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.11, alpha: 1),
            selection: NSColor(calibratedRed: 0.70, green: 0.82, blue: 1.00, alpha: 0.45),
            emphasis: NSColor(calibratedRed: 0.22, green: 0.18, blue: 0.14, alpha: 1),
            codeForeground: NSColor(calibratedRed: 0.11, green: 0.10, blue: 0.09, alpha: 1),
            codeBackground: NSColor(calibratedRed: 0.91, green: 0.89, blue: 0.84, alpha: 1),
            quote: NSColor(calibratedRed: 0.42, green: 0.40, blue: 0.35, alpha: 1),
            punctuation: NSColor(calibratedRed: 0.56, green: 0.54, blue: 0.49, alpha: 1),
            thematicBreak: NSColor(calibratedRed: 0.62, green: 0.60, blue: 0.55, alpha: 1),
            listMarker: NSColor(calibratedRed: 0.62, green: 0.60, blue: 0.55, alpha: 1)
        ),
        dark: Variant(
            background: NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.08, alpha: 1),
            foreground: NSColor(calibratedRed: 0.8, green: 0.8, blue: 0.79, alpha: 1),
            caret: NSColor(calibratedRed: 0.88, green: 0.86, blue: 0.81, alpha: 1),
            selection: NSColor(calibratedRed: 0.25, green: 0.40, blue: 0.65, alpha: 0.55),
            emphasis: NSColor(calibratedRed: 0.94, green: 0.83, blue: 0.64, alpha: 1),
            codeForeground: NSColor(calibratedRed: 0.92, green: 0.88, blue: 0.78, alpha: 1),
            codeBackground: NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.13, alpha: 1),
            quote: NSColor(calibratedRed: 0.68, green: 0.65, blue: 0.57, alpha: 1),
            punctuation: NSColor(calibratedRed: 0.55, green: 0.53, blue: 0.47, alpha: 1),
            thematicBreak: NSColor(calibratedRed: 0.48, green: 0.46, blue: 0.41, alpha: 1),
            listMarker: NSColor(calibratedRed: 0.48, green: 0.46, blue: 0.41, alpha: 1)
        )
    )
}
