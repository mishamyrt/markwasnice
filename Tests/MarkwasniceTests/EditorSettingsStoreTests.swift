import Foundation
import Testing
@testable import Markwasnice

struct EditorSettingsStoreTests {
    @Test func readingAndSpeakingSpeedsRoundTrip() throws {
        let suiteName = "EditorSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.load()

        #expect(
            settings.readingWordsPerMinute
                == EditorSettings.defaultReadingWordsPerMinute
        )
        #expect(
            settings.speakingWordsPerMinute
                == EditorSettings.defaultSpeakingWordsPerMinute
        )

        settings.readingWordsPerMinute = 240
        settings.speakingWordsPerMinute = 150
        store.save(settings)

        let restored = store.load()
        #expect(restored.readingWordsPerMinute == 240)
        #expect(restored.speakingWordsPerMinute == 150)
    }
}
