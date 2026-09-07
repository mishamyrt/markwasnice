import AppKit
import Testing
@testable import Markwasnice

@MainActor
struct MarkdownPreviewPresenterTests {
    @Test
    func cachesParsingAcrossThemeChangesAndRenderingAcrossReopens() async throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scrollView = NSScrollView(frame: container.bounds)
        let presenter = MarkdownPreviewPresenter(
            container: container, editorScrollView: scrollView
        )
        var sourceReads = 0
        var text = "# First"
        var theme = MarkdownPreviewRenderer.Theme(
            baseFontSize: 20, colors: EditorThemeColors.default.light
        )
        presenter.source = {
            sourceReads += 1
            return text
        }
        presenter.theme = { theme }
        presenter.setActive(true)
        await presenter.waitForRendering()
        let first = try #require(presenter.renderedContent)
        #expect(first.string == "First\n")
        #expect(sourceReads == 1)

        presenter.setActive(false)
        presenter.setActive(true)
        await presenter.waitForRendering()
        #expect(presenter.renderedContent === first)
        #expect(sourceReads == 1)

        theme.baseFontSize = 24
        presenter.refreshIfActive()
        await presenter.waitForRendering()
        #expect(presenter.renderedContent !== first)
        #expect(sourceReads == 1)

        text = "# Latest"
        presenter.invalidateContent()
        await presenter.waitForRendering()
        #expect(presenter.renderedContent?.string == "Latest\n")
        #expect(sourceReads == 2)
    }

    @Test
    func anInvalidatedParseCannotReplaceNewerContent() async {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scrollView = NSScrollView(frame: container.bounds)
        let presenter = MarkdownPreviewPresenter(
            container: container, editorScrollView: scrollView
        )
        let (starts, continuation) = AsyncStream<Void>.makeStream()
        presenter.source = {
            continuation.yield(())
            return String(repeating: "# Old\n\nparagraph\n\n", count: 5000)
        }
        presenter.theme = {
            .init(baseFontSize: 20, colors: EditorThemeColors.default.light)
        }
        presenter.setActive(true)
        var iterator = starts.makeAsyncIterator()
        await iterator.next()
        presenter.source = { "Latest" }
        presenter.invalidateContent()
        await presenter.waitForRendering()
        #expect(presenter.renderedContent?.string == "Latest\n")
        continuation.finish()
    }

    @Test
    func cooperativeRenderingMatchesTheSynchronousRenderer() async throws {
        let source = "# Title\n\n- **item**\n- [x] done\n\n```swift\nlet x = 1\n```"
        let renderer = MarkdownPreviewRenderer(theme: .init(
            baseFontSize: 20, colors: EditorThemeColors.default.light
        ))
        let document = await MarkdownPreviewRenderer.prepare(source)
        let content = try #require(await renderer.renderCooperatively(document))
        #expect(content.isEqual(to: renderer.render(source)))
    }
}
