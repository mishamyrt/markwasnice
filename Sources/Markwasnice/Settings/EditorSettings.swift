import AppKit

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
            storedTabInsertionMode
                .flatMap(EditorSettings.TabInsertionMode.init(rawValue:))
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
