import Foundation
import Testing
@testable import Markwasnice

@MainActor
struct EditorSearchPresentationTests {
    private static let settings = EditorSettings(
        textSizeScale: 1,
        maxTextColumns: 64,
        tabInsertionMode: .spaces,
        tabWidth: 4
    )

    private func makeSession(text: String) -> EditorDocumentSession {
        EditorDocumentSession(
            text: text,
            fileURL: nil,
            isEdited: false,
            settings: Self.settings
        ) {}
    }

    private func waitForMatchCount(
        _ count: Int,
        in session: EditorDocumentSession
    ) async throws {
        var attempts = 0
        while session.shellState.searchMatchCount != count, attempts < 200 {
            try await Task.sleep(for: .milliseconds(5))
            attempts += 1
        }
    }

    @Test func selectedTextBecomesTheSearchQuery() async throws {
        let text = "alpha beta alpha"
        let session = makeSession(text: text)
        session.shellState.setSearchQuery("alpha")
        session.editorView.textView.setSelectedRange(
            (text as NSString).range(of: "beta")
        )

        session.showSearch()
        try await waitForMatchCount(1, in: session)

        #expect(session.shellState.isSearchPresented)
        #expect(session.shellState.searchQuery == "beta")
        #expect(session.shellState.searchMatchCount == 1)
    }

    @Test func searchQueryIsPreservedWithoutASelection() async throws {
        let text = "alpha beta alpha"
        let session = makeSession(text: text)
        session.shellState.setSearchQuery("alpha")
        session.editorView.textView.setSelectedRange(
            NSRange(location: 6, length: 0)
        )

        session.showSearch()
        try await waitForMatchCount(2, in: session)

        #expect(session.shellState.searchQuery == "alpha")
        #expect(session.shellState.searchMatchCount == 2)
    }

    @Test func editInvalidatesSearchRangesBeforeRescan() async throws {
        let session = makeSession(text: "alpha beta")
        session.shellState.setSearchQuery("alpha")
        session.showSearch()
        try await waitForMatchCount(1, in: session)

        session.editorView.setString("gamma beta", clearsUndo: false)
        session.editorView.textView.didChangeText()

        #expect(session.shellState.searchMatchCount == 0)
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.shellState.searchMatchCount == 0)
    }

    @Test(arguments: [false, true])
    func supersedingSearchCancelsTheWorker(closesSearch: Bool) async {
        let session = makeSession(text: "alpha beta")
        let gate = DispatchSemaphore(value: 0)
        let (events, continuation) = AsyncStream<Bool>.makeStream()
        session.findSearchMatches = { query, _, _ in
            guard query == "alpha" else {
                return []
            }
            continuation.yield(false)
            _ = gate.wait(timeout: .now() + 5)
            continuation.yield(Task.isCancelled)
            continuation.finish()
            return [NSRange(location: 0, length: 5)]
        }
        session.shellState.setSearchQuery("alpha")
        session.shellState.showSearch()
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == false)

        if closesSearch {
            session.shellState.closeSearch()
        } else {
            session.shellState.setSearchQuery("gamma")
        }
        gate.signal()

        #expect(await iterator.next() == true)
        #expect(session.shellState.searchMatchCount == 0)
    }
}
