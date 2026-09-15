import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct EditorWindowControllerTests {
    @Test
    func controllerConfiguresWindowBeforeItIsPresented() {
        let appState = makeAppState()
        let session = appState.newSession()
        let window = NSWindow()
        let controller = EditorWindowController(editorWindow: window)

        controller.configure(session: session, appState: appState)

        #expect(window.delegate === controller)
        #expect(window.toolbar != nil)
        #expect(window.tabbingIdentifier == EditorWindowTabbing.identifier)
        #expect(!window.isVisible)

        controller.present(attachedTo: nil)
        #expect(window.isVisible)
        window.close()
    }

    @Test
    func coldStartShowsAStandaloneEditorWindow() async throws {
        let appState = makeAppState()
        let coordinator = EditorWindowCoordinator(appState: appState)

        await coordinator.start()

        let session = try #require(appState.sessions.values.first)
        let window = try #require(session.editorView.window)
        defer { window.close() }

        #expect(window.isVisible)
        #expect(coordinator.hasVisibleEditorWindows)
    }

    @Test
    func newTabShowsNativeTabStripAndTrafficLights() async throws {
        let appState = makeAppState()
        let coordinator = EditorWindowCoordinator(appState: appState)
        await coordinator.start()

        let initialSession = try #require(appState.sessions.values.first)
        let initialWindow = try #require(initialSession.editorView.window)
        initialSession.editorView.setString("typed", clearsUndo: false)
        initialSession.editorView.textView.didChangeText()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!initialSession.shellState.isToolbarVisible)

        appState.requestNewTab(attachedTo: initialWindow)
        try await Task.sleep(for: .milliseconds(50))
        defer {
            for window in initialWindow.tabGroup?.windows ?? [initialWindow] {
                window.close()
            }
        }

        let tabGroup = try #require(initialWindow.tabGroup)
        let selectedWindow = try #require(tabGroup.selectedWindow)
        #expect(tabGroup.windows.count == 2)
        #expect(tabGroup.isTabBarVisible)
        #expect(
            selectedWindow.titlebarAccessoryViewControllers.contains {
                !$0.isHidden
            }
        )
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            let button = try #require(
                selectedWindow.standardWindowButton(buttonType)
            )
            #expect(!button.isHidden)
            #expect(button.alphaValue == 1)
        }

        let selectedSession = try #require(appState.sessions.values.first {
            $0.editorView.window === selectedWindow
        })
        selectedSession.editorView.setString("typed", clearsUndo: false)
        selectedSession.editorView.textView.didChangeText()
        try await Task.sleep(for: .milliseconds(150))

        selectedSession.shellState.onToolbarHoverChanged?(true)
        try await Task.sleep(for: .milliseconds(150))

        #expect(
            selectedWindow.titlebarAccessoryViewControllers.contains {
                !$0.isHidden
            }
        )
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ] {
            let button = try #require(
                selectedWindow.standardWindowButton(buttonType)
            )
            #expect(button.alphaValue == 1)
        }
    }

    @Test
    func nativeNewTabActionQueuesAWindowAttachedToItsControllerWindow() throws {
        let appState = makeAppState()
        let window = NSWindow()
        window.tabbingIdentifier = EditorWindowTabbing.identifier
        let controller = EditorWindowController(editorWindow: window)
        controller.appState = appState

        controller.newWindowForTab(nil)

        let pendingIDs = appState.takePendingWindowIDs()
        #expect(pendingIDs.count == 1)
        let sessionID = try #require(pendingIDs.first)
        #expect(appState.takeTabAttachTarget(for: sessionID) === window)
    }

    @Test
    func newWindowRequestQueuesStandaloneSession() throws {
        let appState = makeAppState()

        appState.requestNewWindow()

        let pendingIDs = appState.takePendingWindowIDs()
        #expect(pendingIDs.count == 1)
        let sessionID = try #require(pendingIDs.first)
        #expect(appState.session(for: sessionID) != nil)
        #expect(appState.takeTabAttachTarget(for: sessionID) == nil)
    }

    private func makeAppState() -> MarkwasniceAppState {
        let identifier = "EditorWindowControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: identifier)!
        defaults.removePersistentDomain(forName: identifier)
        let autosaveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(identifier).json")
        return MarkwasniceAppState(
            autosaveStore: AutosaveStore(fileURL: autosaveURL),
            settingsStore: EditorSettingsStore(defaults: defaults)
        )
    }
}
