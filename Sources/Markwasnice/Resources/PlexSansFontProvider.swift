import AppKit

/// The preview's proportional family, bundled as an upright and an italic
/// variable font whose faces are registered under the "IBM Plex Sans Var"
/// family name.
@MainActor
enum PlexSansFontProvider {
    private static let family = BundledFontFamily(
        resourceNames: ["IBM-Plex-Sans", "IBM-Plex-Sans-Italic"],
        regularFontName: "IBM Plex Sans Var",
        italicFontName: "IBM Plex Sans Var Italic",
        systemFallback: .proportional
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
