import Testing
@testable import Markwasnice

@MainActor
struct StyleCheckMenuTitleTests {
    @Test func titleReflectsWhetherStyleCheckIsEnabled() {
        let state = EditorShellState()

        #expect(state.styleCheckToggleTitle == "Enable Style Check")

        state.setProofreadingEnabled(true)

        #expect(state.styleCheckToggleTitle == "Disable Style Check")
    }
}
