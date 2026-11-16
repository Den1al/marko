import Foundation
import FixtureSupport
import Markdown
import Testing
@testable import MarkoCore

@Suite struct SourceIndexTests {
    @Test func splitsOnEveryLineEnding() {
        let index = SourceIndex("a\nbb\r\nccc\rd")
        #expect(index.lineCount == 4)
        #expect((0..<4).map(index.lineRange) == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 4),
                                                  NSRange(location: 6, length: 4), NSRange(location: 10, length: 1)])
        #expect((0..<4).map(index.contentRange) == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2),
                                                     NSRange(location: 6, length: 3), NSRange(location: 10, length: 1)])
    }

    @Test func trailingTerminatorDoesNotOpenALine() {
        #expect(SourceIndex("").lineCount == 0)
        #expect(SourceIndex("a").lineCount == 1)
        #expect(SourceIndex("a\n").lineCount == 1)
        #expect(SourceIndex("a\r\n").lineCount == 1)
        #expect(SourceIndex("a\n\n").lineCount == 2)
        #expect(SourceIndex("\n").lineRange(0) == NSRange(location: 0, length: 1))
    }

    @Test func convertsUTF8ColumnsToUTF16Offsets() {
        // é is 2 bytes and 1 unit, 日 is 3 and 1, 😀 is 4 and 2.
        let index = SourceIndex("ab\né日😀x\r\nz")
        #expect(index.offset(line: 1, column: 1) == 0)
        #expect(index.offset(line: 1, column: 3) == 2)
        #expect(index.offset(line: 2, column: 1) == 3)
        #expect(index.offset(line: 2, column: 3) == 4)
        #expect(index.offset(line: 2, column: 6) == 5)
        #expect(index.offset(line: 2, column: 10) == 7)
        #expect(index.offset(line: 2, column: 11) == 8)
        #expect(index.offset(line: 3, column: 2) == 11)
    }

    @Test func rejectsPositionsOutsideALineOrInsideAScalar() {
        let index = SourceIndex("ab\né日😀x\r\nz")
        #expect(index.offset(line: 0, column: 1) == nil)
        #expect(index.offset(line: 4, column: 1) == nil)
        #expect(index.offset(line: 1, column: 0) == nil)
        #expect(index.offset(line: 1, column: 4) == nil)
        #expect(index.offset(line: 2, column: 2) == nil)
        #expect(index.offset(line: 2, column: 8) == nil)
        #expect(index.offset(line: 2, column: 12) == nil)
    }

    @Test func findsTheLineOfAnOffset() {
        let index = SourceIndex("a\nbb\r\nccc")
        #expect([0, 1, 2, 5, 6, 8].map(index.lineIndex) == [0, 0, 1, 1, 2, 2])
        #expect(index.lineIndex(containing: 9) == nil)
        #expect(index.lineIndex(containing: -1) == nil)
        #expect(SourceIndex("").lineIndex(containing: 0) == nil)
    }

    /// Every parser position in every fixture must convert, and the text at the converted range must
    /// have the UTF-8 length the parser reported.
    @Test func agreesWithTheParserOnEveryFixture() throws {
        for (name, source) in try fixtureSources() {
            let index = SourceIndex(source)
            let text = source as NSString
            #expect(index.lineCount == source.split(omittingEmptySubsequences: false) { $0.isNewline }.count - (source.last?.isNewline == true ? 1 : 0), "\(name)")
            func visit(_ node: any Markup) {
                // Single-line text is the one node kind whose columns need no correction.
                if let range = node.range, node is Text, node.parent is Paragraph, range.lowerBound.line == (node.parent?.range?.lowerBound.line ?? 0) {
                    let start = index.offset(line: range.lowerBound.line, column: range.lowerBound.column)
                    let end = index.offset(line: range.upperBound.line, column: range.upperBound.column)
                    #expect(start != nil && end != nil, "\(name) \(range)")
                    if let start, let end {
                        #expect(text.substring(with: NSRange(location: start, length: end - start)).utf8.count
                            == range.upperBound.column - range.lowerBound.column, "\(name) \(range)")
                    }
                }
                node.children.forEach(visit)
            }
            visit(Document(parsing: source))
        }
    }
}
