import Testing
@testable import Markwasnice

@MainActor
struct StatusBarStatisticsTests {
    @Test func formatsAllStatusBarMetrics() {
        let state = EditorShellState()
        state.characterCount = 512
        state.wordCount = 88
        state.sentenceCount = 7

        #expect(state.characterCountText == "512 characters")
        #expect(state.wordCountText == "88 words")
        #expect(state.sentenceCountText == "7 sentences")
        #expect(state.readingTimeText == "26 sec. reading")
        #expect(state.speakingTimeText == "41 sec. speaking")
    }

    @Test func usesSingularMetricLabels() {
        let state = EditorShellState()
        state.characterCount = 1
        state.wordCount = 1
        state.sentenceCount = 1

        #expect(state.characterCountText == "1 character")
        #expect(state.wordCountText == "1 word")
        #expect(state.sentenceCountText == "1 sentence")
    }

    @Test func countsEnglishAndRussianSentences() {
        let text = "One sentence. Это второе! Is this the third?"

        #expect(EditorDocumentSession.sentenceCount(in: text) == 3)
        #expect(EditorDocumentSession.sentenceCount(in: "") == 0)
    }

    @Test func usesConfiguredReadingAndSpeakingSpeeds() {
        let state = EditorShellState(
            readingWordsPerMinute: 120,
            speakingWordsPerMinute: 60
        )
        state.wordCount = 120

        #expect(state.readingTimeText == "1 min. reading")
        #expect(state.speakingTimeText == "2 min. speaking")
    }

    @Test func usesSelectionStatisticsUntilSelectionIsCleared() {
        let state = EditorShellState()
        state.characterCount = 512
        state.wordCount = 88
        state.sentenceCount = 7
        state.selectionStatistics = EditorTextStatistics(
            characterCount: 42,
            wordCount: 12,
            sentenceCount: 2
        )

        #expect(state.characterCountText == "42 characters")
        #expect(state.wordCountText == "12 words")
        #expect(state.sentenceCountText == "2 sentences")
        #expect(state.readingTimeText == "4 sec. reading")
        #expect(state.speakingTimeText == "6 sec. speaking")

        state.selectionStatistics = nil

        #expect(state.characterCountText == "512 characters")
        #expect(state.wordCountText == "88 words")
        #expect(state.sentenceCountText == "7 sentences")
    }
}
