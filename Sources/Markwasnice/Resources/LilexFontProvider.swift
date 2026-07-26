import AppKit

/// The editor's monospaced family, bundled as an upright and an italic
/// variable font (`Lilex[wght]` / `Lilex-Italic[wght]`).
@MainActor
enum LilexFontProvider {
    private static let family = BundledFontFamily(
        resourceNames: ["Lilex[wght]", "Lilex-Italic[wght]"],
        regularFontName: "Lilex",
        italicFontName: "Lilex Italic",
        systemFallback: .monospaced
    )

    static func registerFonts() {
        family.registerFonts()
    }

    static func regular(size: CGFloat) -> NSFont {
        family.regular(size: size)
    }

    static func italic(size: CGFloat) -> NSFont {
        family.italic(size: size)
    }

    static func bold(size: CGFloat) -> NSFont {
        family.bold(size: size)
    }

    static func boldItalic(size: CGFloat) -> NSFont {
        family.boldItalic(size: size)
    }

    static func font(size: CGFloat, traits: NSFontTraitMask) -> NSFont {
        family.font(size: size, traits: traits)
    }
}
