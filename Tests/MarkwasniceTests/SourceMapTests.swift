import Foundation
import Markdown
import Testing
@testable import Markwasnice

@Suite
struct SourceMapTests {
    @Test
    func asciiSingleLine() {
        let map = SourceMap(text: "abc\n")
        #expect(map.nsRange(for: range(line: 1, column: 1, toLine: 1, column: 4)) == NSRange(location: 0, length: 3))
    }

    @Test
    func multilineRange() {
        let map = SourceMap(text: "abc\ndef\n")
        #expect(map.nsRange(for: range(line: 1, column: 2, toLine: 2, column: 3)) == NSRange(location: 1, length: 5))
    }

    @Test
    func cyrillicColumnsAreUTF8Bytes() {
        let map = SourceMap(text: "привет\n")
        #expect(map.nsRange(for: range(line: 1, column: 1, toLine: 1, column: 13)) == NSRange(location: 0, length: 6))
        #expect(map.nsRange(for: range(line: 1, column: 3, toLine: 1, column: 7)) == NSRange(location: 1, length: 2))
    }

    @Test
    func emojiColumnsAreUTF8BytesAndUTF16RangeUsesSurrogates() {
        let map = SourceMap(text: "a😀b\n")
        #expect(map.nsRange(for: range(line: 1, column: 1, toLine: 1, column: 7)) == NSRange(location: 0, length: 4))
        #expect(map.nsRange(for: range(line: 1, column: 2, toLine: 1, column: 6)) == NSRange(location: 1, length: 2))
    }

    @Test
    func combiningMarkColumnsAreUTF8Bytes() {
        let map = SourceMap(text: "e\u{301}\n")
        #expect(map.nsRange(for: range(line: 1, column: 1, toLine: 1, column: 4)) == NSRange(location: 0, length: 2))
    }

    @Test
    func mixedASCIIEmojiAndCyrillic() {
        let text = "a😀 кириллица b\n"
        let map = SourceMap(text: text)
        #expect(map.nsRange(for: range(line: 1, column: 1, toLine: 1, column: 27)) == NSRange(location: 0, length: (text as NSString).length - 1))
        #expect(map.nsRange(for: range(line: 1, column: 7, toLine: 1, column: 23)) == NSRange(location: 4, length: 8))
    }

    @Test
    func invalidLocationsReturnNil() {
        let map = SourceMap(text: "abc\n")
        #expect(map.nsRange(for: range(line: 0, column: 1, toLine: 1, column: 2)) == nil)
        #expect(map.nsRange(for: range(line: 3, column: 1, toLine: 3, column: 2)) == nil)
        #expect(map.nsRange(for: range(line: 1, column: 3, toLine: 1, column: 5)) == nil)
    }

    private func range(line: Int, column: Int, toLine: Int, column endColumn: Int) -> SourceRange {
        SourceLocation(line: line, column: column, source: nil)..<SourceLocation(line: toLine, column: endColumn, source: nil)
    }
}
