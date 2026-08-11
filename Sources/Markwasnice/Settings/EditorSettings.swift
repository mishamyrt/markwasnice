import AppKit

struct EditorSettings: Equatable {
    enum TabInsertionMode: String, CaseIterable {
        case spaces
        case tab
    }

    enum TypographyLocale: String, CaseIterable {
        case russian
        case english
    }

    static let maxTextWidthOptions = [64, 72, 80]
    static let tabWidthOptions = [1, 2, 4]
    static let wordsPerMinuteRange = 1 ... 1000
    static let defaultBasePointSize: CGFloat = 20
    static let defaultTextSizeScale: CGFloat = 1
    static let textSizeScaleRange: ClosedRange<CGFloat> = 0.05 ... 1.95
    static let textSizeScaleTickCount = 15
    static let textSizeScaleStep =
        (textSizeScaleRange.upperBound - textSizeScaleRange.lowerBound)
            / CGFloat(textSizeScaleTickCount - 1)
    static let defaultMaxTextColumns = 64
    static let defaultTabInsertionMode = TabInsertionMode.spaces
    static let defaultTabWidth = 4
    static let defaultTypographyLocale = TypographyLocale.russian
    static let defaultReadingWordsPerMinute = 200
    static let defaultSpeakingWordsPerMinute = 130

    var textSizeScale: CGFloat
    var maxTextColumns: Int
    var tabInsertionMode: TabInsertionMode
    var tabWidth: Int
    var typographyLocale: TypographyLocale = Self.defaultTypographyLocale
    var readingWordsPerMinute = Self.defaultReadingWordsPerMinute
    var speakingWordsPerMinute = Self.defaultSpeakingWordsPerMinute

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
        static let typographyLocale = "editor.typographyLocale"
        static let readingWordsPerMinute = "editor.readingWordsPerMinute"
        static let speakingWordsPerMinute = "editor.speakingWordsPerMinute"
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
        let storedTypographyLocale = defaults.string(forKey: Key.typographyLocale)
        let typographyLocale =
            storedTypographyLocale
                .flatMap(EditorSettings.TypographyLocale.init(rawValue:))
                ?? EditorSettings.defaultTypographyLocale
        let storedReadingWordsPerMinute = defaults.integer(
            forKey: Key.readingWordsPerMinute
        )
        let readingWordsPerMinute =
            EditorSettings.wordsPerMinuteRange.contains(storedReadingWordsPerMinute)
                ? storedReadingWordsPerMinute
                : EditorSettings.defaultReadingWordsPerMinute
        let storedSpeakingWordsPerMinute = defaults.integer(
            forKey: Key.speakingWordsPerMinute
        )
        let speakingWordsPerMinute =
            EditorSettings.wordsPerMinuteRange.contains(storedSpeakingWordsPerMinute)
                ? storedSpeakingWordsPerMinute
                : EditorSettings.defaultSpeakingWordsPerMinute

        return EditorSettings(
            textSizeScale: textSizeScale,
            maxTextColumns: maxTextColumns,
            tabInsertionMode: tabInsertionMode,
            tabWidth: tabWidth,
            typographyLocale: typographyLocale,
            readingWordsPerMinute: readingWordsPerMinute,
            speakingWordsPerMinute: speakingWordsPerMinute
        )
    }

    func save(_ settings: EditorSettings) {
        defaults.set(Double(settings.textSizeScale), forKey: Key.textSizeScale)
        defaults.set(settings.maxTextColumns, forKey: Key.maxTextColumns)
        defaults.set(settings.tabInsertionMode.rawValue, forKey: Key.tabInsertionMode)
        defaults.set(settings.tabWidth, forKey: Key.tabWidth)
        defaults.set(settings.typographyLocale.rawValue, forKey: Key.typographyLocale)
        defaults.set(
            settings.readingWordsPerMinute,
            forKey: Key.readingWordsPerMinute
        )
        defaults.set(
            settings.speakingWordsPerMinute,
            forKey: Key.speakingWordsPerMinute
        )
    }
}
