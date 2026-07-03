import Foundation
import Testing
@testable import Markwasnice

@Suite
struct DocumentTitleSuggesterTests {
    @Test
    func stripsHeadingMarkers() {
        #expect(DocumentTitleSuggester.title(from: "# Meeting Notes") == "Meeting Notes")
        #expect(DocumentTitleSuggester.title(from: "### Deep Heading") == "Deep Heading")
    }

    @Test
    func stripsClosingHeadingMarkers() {
        #expect(DocumentTitleSuggester.title(from: "## Title ##") == "Title")
    }

    @Test
    func stripsInlineEmphasis() {
        #expect(
            DocumentTitleSuggester.title(from: "**Bold** and *italic* and `code`")
                == "Bold and italic and code"
        )
        #expect(DocumentTitleSuggester.title(from: "~~gone~~ ==marked==") == "gone marked")
    }

    @Test
    func stripsEmphasisUnderscoresButKeepsSnakeCase() {
        #expect(DocumentTitleSuggester.title(from: "_emphasis_ text") == "emphasis text")
        #expect(DocumentTitleSuggester.title(from: "rename snake_case_var") == "rename snake_case_var")
    }

    @Test
    func replacesLinksAndImagesWithText() {
        #expect(
            DocumentTitleSuggester.title(from: "See [the docs](https://example.com)")
                == "See the docs"
        )
        #expect(DocumentTitleSuggester.title(from: "![diagram](img.png) overview") == "diagram overview")
    }

    @Test
    func stripsListAndQuoteMarkers() {
        #expect(DocumentTitleSuggester.title(from: "- First item") == "First item")
        #expect(DocumentTitleSuggester.title(from: "1. Ordered item") == "Ordered item")
        #expect(DocumentTitleSuggester.title(from: "> Quoted line") == "Quoted line")
        #expect(DocumentTitleSuggester.title(from: "- [ ] Task title") == "Task title")
    }

    @Test
    func skipsBlankAndMarkerOnlyLines() {
        #expect(DocumentTitleSuggester.title(from: "\n\n   \n---\nActual title") == "Actual title")
        #expect(DocumentTitleSuggester.title(from: "") == nil)
        #expect(DocumentTitleSuggester.title(from: "   \n\t\n") == nil)
    }

    @Test
    func keepsPlainTextIntact() {
        #expect(
            DocumentTitleSuggester.title(from: "Обычная первая строка\nвторая строка")
                == "Обычная первая строка"
        )
        #expect(DocumentTitleSuggester.title(from: "3 apples and 2 pears") == "3 apples and 2 pears")
    }

    @Test
    func truncatesLongTitles() {
        let line = String(repeating: "word ", count: 40)
        let title = DocumentTitleSuggester.title(from: line)

        #expect(title != nil)
        #expect(title!.hasSuffix("…"))
        #expect(title!.count <= DocumentTitleSuggester.maxTitleLength + 1)
    }

    @Test
    func fileNameAppendsMarkdownExtension() {
        #expect(DocumentTitleSuggester.fileName(from: "# Meeting Notes") == "Meeting Notes.md")
    }

    @Test
    func fileNameReplacesUnsafeCharacters() {
        #expect(
            DocumentTitleSuggester.fileName(from: "Plan: before/after")
                == "Plan- before-after.md"
        )
    }

    @Test
    func fileNameIsNilForEmptyText() {
        #expect(DocumentTitleSuggester.fileName(from: "\n\n") == nil)
    }
}
