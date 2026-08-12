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

    @MainActor
    @Test func textSizeCommandsApplyAndPersistAcrossLaunches() throws {
        let suiteName = "EditorSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EditorSettingsStore(defaults: defaults)
        let appState = MarkwasniceAppState(settingsStore: store)

        appState.increaseTextSize()

        #expect(
            appState.settings.textSizeScale
                == EditorSettings.defaultTextSizeScale
                + EditorSettings.textSizeScaleStep
        )
        let relaunchedState = MarkwasniceAppState(settingsStore: store)
        #expect(relaunchedState.settings == appState.settings)

        relaunchedState.decreaseTextSize()
        #expect(
            relaunchedState.settings.textSizeScale
                == EditorSettings.defaultTextSizeScale
        )

        relaunchedState.increaseTextSize()
        relaunchedState.resetTextSize()
        #expect(
            relaunchedState.settings.textSizeScale
                == EditorSettings.defaultTextSizeScale
        )

        let resetRelaunchedState = MarkwasniceAppState(settingsStore: store)
        #expect(resetRelaunchedState.settings == relaunchedState.settings)
    }

    @MainActor
    @Test func textSizeCommandsStayWithinSliderRange() throws {
        let suiteName = "EditorSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = EditorSettingsStore(defaults: defaults)
        var settings = store.load()
        settings.textSizeScale = EditorSettings.textSizeScaleRange.upperBound
        store.save(settings)
        let appState = MarkwasniceAppState(settingsStore: store)

        appState.increaseTextSize()
        #expect(
            appState.settings.textSizeScale
                == EditorSettings.textSizeScaleRange.upperBound
        )

        settings.textSizeScale = EditorSettings.textSizeScaleRange.lowerBound
        store.save(settings)
        let lowerBoundState = MarkwasniceAppState(settingsStore: store)
        lowerBoundState.decreaseTextSize()
        #expect(
            lowerBoundState.settings.textSizeScale
                == EditorSettings.textSizeScaleRange.lowerBound
        )
    }
}
