import AppKit
import CoreText

@MainActor
enum LilexFontProvider {
    private static var didRegisterFonts = false

    static func registerFonts() {
        guard !didRegisterFonts else {
            return
        }

        didRegisterFonts = true
        for name in ["Lilex[wght]", "Lilex-Italic[wght]"] {
            guard let url = Bundle.module.url(
                forResource: name, withExtension: "ttf", subdirectory: "Fonts"
            )
            else {
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func regular(size: CGFloat) -> NSFont {
        NSFont(name: "Lilex", size: size) ?? .monospacedSystemFont(
            ofSize: size,
            weight: .regular
        )
    }

    static func italic(size: CGFloat) -> NSFont {
        NSFont(name: "Lilex Italic", size: size) ?? font(
            size: size,
            traits: .italicFontMask
        )
    }

    static func bold(size: CGFloat) -> NSFont {
        font(size: size, traits: .boldFontMask)
    }

    static func boldItalic(size: CGFloat) -> NSFont {
        font(size: size, traits: [.boldFontMask, .italicFontMask])
    }

    static func font(size: CGFloat, traits: NSFontTraitMask) -> NSFont {
        let regularFont = regular(size: size)
        let convertedFont = NSFontManager.shared.convert(regularFont, toHaveTrait: traits)
        return NSFontManager.shared.convert(convertedFont, toSize: size)
    }
}
