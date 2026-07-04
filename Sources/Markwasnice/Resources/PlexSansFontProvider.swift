import AppKit
import CoreText

@MainActor
enum PlexSansFontProvider {
    private static var didRegisterFonts = false

    static func registerFonts() {
        guard !didRegisterFonts else {
            return
        }

        didRegisterFonts = true
        for name in ["IBM-Plex-Sans", "IBM-Plex-Sans-Italic"] {
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
        NSFont(name: "IBM Plex Sans Var", size: size) ?? .systemFont(
            ofSize: size,
            weight: .regular
        )
    }

    static func italic(size: CGFloat) -> NSFont {
        NSFont(name: "IBM Plex Sans Var Italic", size: size) ?? font(
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
        let baseFont = traits.contains(.italicFontMask)
            ? italic(size: size)
            : regular(size: size)
        guard traits.contains(.boldFontMask) else {
            return baseFont
        }

        let convertedFont = NSFontManager.shared.convert(
            baseFont,
            toHaveTrait: .boldFontMask
        )
        return NSFontManager.shared.convert(convertedFont, toSize: size)
    }
}
