import AppKit
import CoreText

/// One implementation behind every font family the app ships. The providers
/// used to carry a copy of this code each and had already drifted apart on
/// the italic path, so the families are now described by data — resource
/// files, face names, and the system face to fall back on — and share the
/// resolution rules.
@MainActor
final class BundledFontFamily {
    /// The editor's monospaced family, with separate upright and italic files.
    static let lilex = BundledFontFamily(
        resourceNames: ["Lilex[wght]", "Lilex-Italic[wght]"],
        regularFontName: "Lilex",
        italicFontName: "Lilex Italic",
        systemFallback: .monospaced
    )

    /// The preview's proportional family, registered as "IBM Plex Sans Var".
    static let plexSans = BundledFontFamily(
        resourceNames: ["IBM-Plex-Sans", "IBM-Plex-Sans-Italic"],
        regularFontName: "IBM Plex Sans Var",
        italicFontName: "IBM Plex Sans Var Italic",
        systemFallback: .proportional
    )

    /// The face the system provides when the bundled files are missing.
    enum SystemFallback {
        case monospaced
        case proportional

        func font(size: CGFloat) -> NSFont {
            switch self {
            case .monospaced:
                .monospacedSystemFont(ofSize: size, weight: .regular)
            case .proportional:
                .systemFont(ofSize: size, weight: .regular)
            }
        }
    }

    private let resourceNames: [String]
    private let regularFontName: String
    private let italicFontName: String
    private let systemFallback: SystemFallback
    private var didRegisterFonts = false

    init(
        resourceNames: [String],
        regularFontName: String,
        italicFontName: String,
        systemFallback: SystemFallback
    ) {
        self.resourceNames = resourceNames
        self.regularFontName = regularFontName
        self.italicFontName = italicFontName
        self.systemFallback = systemFallback
    }

    func registerFonts() {
        guard !didRegisterFonts else {
            return
        }

        didRegisterFonts = true
        for name in resourceNames {
            guard let url = ResourceBundle.current.url(
                forResource: name, withExtension: "ttf", subdirectory: "Fonts"
            )
            else {
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    func regular(size: CGFloat) -> NSFont {
        NSFont(name: regularFontName, size: size)
            ?? systemFallback.font(size: size)
    }

    func italic(size: CGFloat) -> NSFont {
        // The fallback goes straight through NSFontManager rather than
        // font(size:traits:), which resolves the italic trait by asking for
        // this very face and would recurse.
        NSFont(name: italicFontName, size: size)
            ?? NSFontManager.shared.convert(
                regular(size: size),
                toHaveTrait: .italicFontMask
            )
    }

    func bold(size: CGFloat) -> NSFont {
        font(size: size, traits: .boldFontMask)
    }

    func boldItalic(size: CGFloat) -> NSFont {
        font(size: size, traits: [.boldFontMask, .italicFontMask])
    }

    /// Every family here ships its italics as a separate file, so the italic
    /// face is picked by name instead of being left to NSFontManager: when it
    /// cannot resolve a trait within the family, convert(_:toHaveTrait:)
    /// silently returns the font unchanged and the italics come out upright.
    /// Weight is the only trait converted on top.
    func font(size: CGFloat, traits: NSFontTraitMask) -> NSFont {
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
