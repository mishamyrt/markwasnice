import AppKit
import CoreText

struct EditorSettings: Equatable {
    static let maxTextWidthOptions = [64, 72, 80]
    static let defaultBasePointSize: CGFloat = 17
    static let defaultTextSizeScale: CGFloat = 1
    static let defaultMaxTextColumns = 64

    var textSizeScale: CGFloat
    var maxTextColumns: Int

    var basePointSize: CGFloat {
        Self.defaultBasePointSize * textSizeScale
    }

    var lineHeight: CGFloat {
        basePointSize * 1.6
    }
}

final class EditorSettingsStore {
    private enum Key {
        static let textSizeScale = "editor.textSizeScale"
        static let maxTextColumns = "editor.maxTextColumns"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> EditorSettings {
        let storedScale = defaults.double(forKey: Key.textSizeScale)
        let textSizeScale =
            storedScale > 0 ? CGFloat(storedScale) : EditorSettings.defaultTextSizeScale
        let storedColumns = defaults.integer(forKey: Key.maxTextColumns)
        let maxTextColumns =
            EditorSettings.maxTextWidthOptions.contains(storedColumns)
            ? storedColumns
            : EditorSettings.defaultMaxTextColumns

        return EditorSettings(textSizeScale: textSizeScale, maxTextColumns: maxTextColumns)
    }

    func save(_ settings: EditorSettings) {
        defaults.set(Double(settings.textSizeScale), forKey: Key.textSizeScale)
        defaults.set(settings.maxTextColumns, forKey: Key.maxTextColumns)
    }
}

@MainActor
enum LilexFontProvider {
    private static var didRegisterFonts = false

    static func registerFonts() {
        guard !didRegisterFonts else {
            return
        }

        didRegisterFonts = true
        for name in ["Lilex[wght]", "Lilex-Italic[wght]"] {
            guard
                let url = Bundle.module.url(
                    forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            else {
                continue
            }

            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func regular(size: CGFloat) -> NSFont {
        NSFont(name: "Lilex", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func italic(size: CGFloat) -> NSFont {
        NSFont(name: "Lilex Italic", size: size) ?? font(size: size, traits: .italicFontMask)
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
