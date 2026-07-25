import AppKit
import Testing
@testable import Markwasnice

/// EditorFileDropController path helpers: relativizing dropped image paths
/// against the document directory and escaping Markdown link text.
struct EditorFileDropPathTests {
    @Test func relativePathWithinSameDirectoryTree() {
        let base = URL(fileURLWithPath: "/Users/me/docs")
        let target = URL(fileURLWithPath: "/Users/me/docs/assets/pic.png")

        #expect(
            EditorFileDropController.relativePath(from: base, to: target)
                == "assets/pic.png"
        )
    }

    @Test func relativePathClimbsToSiblingDirectory() {
        let base = URL(fileURLWithPath: "/Users/me/docs/notes")
        let target = URL(fileURLWithPath: "/Users/me/images/pic.png")

        #expect(
            EditorFileDropController.relativePath(from: base, to: target)
                == "../../images/pic.png"
        )
    }

    @Test func escapeLinkTextEscapesClosingBracket() {
        #expect(
            EditorFileDropController.escapeLinkText("a ] b") == "a \\] b"
        )
        #expect(EditorFileDropController.escapeLinkText("plain") == "plain")
    }

    @MainActor
    @Test func markdownRelativePathFallsBackToFileNameWithoutDocument() {
        let controller = EditorFileDropController()

        #expect(
            controller.markdownRelativePath(
                for: URL(fileURLWithPath: "/tmp/pic.png")
            ) == "pic.png"
        )

        controller.documentURL = URL(fileURLWithPath: "/Users/me/docs/note.md")
        #expect(
            controller.markdownRelativePath(
                for: URL(fileURLWithPath: "/Users/me/docs/assets/pic.png")
            ) == "assets/pic.png"
        )
    }
}
