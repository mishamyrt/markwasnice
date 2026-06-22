import AppKit
import CoreText

struct EditorSettings: Equatable {
    enum TabInsertionMode: String, CaseIterable {
        case spaces
        case tab
    }

    static let maxTextWidthOptions = [64, 72, 80]
    static let tabWidthOptions = [1, 2, 4]
    static let defaultBasePointSize: CGFloat = 20
    static let defaultTextSizeScale: CGFloat = 1
    static let defaultMaxTextColumns = 64
    static let defaultTabInsertionMode = TabInsertionMode.spaces
    static let defaultTabWidth = 4

    var textSizeScale: CGFloat
    var maxTextColumns: Int
    var tabInsertionMode: TabInsertionMode
    var tabWidth: Int

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
        static let tabInsertionMode = "editor.tabInsertionMode"
        static let tabWidth = "editor.tabWidth"
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
        let storedTabInsertionMode = defaults.string(forKey: Key.tabInsertionMode)
        let tabInsertionMode =
            storedTabInsertionMode.flatMap(EditorSettings.TabInsertionMode.init(rawValue:))
            ?? EditorSettings.defaultTabInsertionMode
        let storedTabWidth = defaults.integer(forKey: Key.tabWidth)
        let tabWidth =
            EditorSettings.tabWidthOptions.contains(storedTabWidth)
            ? storedTabWidth
            : EditorSettings.defaultTabWidth

        return EditorSettings(
            textSizeScale: textSizeScale,
            maxTextColumns: maxTextColumns,
            tabInsertionMode: tabInsertionMode,
            tabWidth: tabWidth
        )
    }

    func save(_ settings: EditorSettings) {
        defaults.set(Double(settings.textSizeScale), forKey: Key.textSizeScale)
        defaults.set(settings.maxTextColumns, forKey: Key.maxTextColumns)
        defaults.set(settings.tabInsertionMode.rawValue, forKey: Key.tabInsertionMode)
        defaults.set(settings.tabWidth, forKey: Key.tabWidth)
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
