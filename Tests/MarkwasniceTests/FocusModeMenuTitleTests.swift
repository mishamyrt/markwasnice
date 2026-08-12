import Testing
@testable import Markwasnice

@MainActor
struct FocusModeMenuTitleTests {
    @Test func titleReflectsWhetherFocusModeIsEnabled() {
        let state = EditorShellState()

        #expect(state.focusModeToggleTitle == "Enable Focus Mode")

        state.setFocusModeEnabled(true)

        #expect(state.focusModeToggleTitle == "Disable Focus Mode")
    }
}
