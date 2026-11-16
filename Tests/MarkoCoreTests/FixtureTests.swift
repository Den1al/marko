import Foundation
import FixtureSupport
import Markdown
import Testing

@Suite struct FixtureTests {
    @Test func everyFixtureIsUTF8AndParses() throws {
        #expect(Fixtures.all.count >= 13)
        for url in Fixtures.all {
            let source = try #require(String(data: Data(contentsOf: url), encoding: .utf8), "\(url.lastPathComponent)")
            _ = Document(parsing: source)
        }
    }

    @Test func lineEndingBytesAreExact() throws {
        let crlf = try Fixtures.data("crlf.md")
        let lfCount = crlf.count { $0 == 0x0A }
        #expect(lfCount > 0)
        #expect(crlf.count { $0 == 0x0D } == lfCount)

        let allowedCR: Set = ["crlf.md"]
        for url in Fixtures.all where !allowedCR.contains(url.lastPathComponent) {
            #expect(try !Data(contentsOf: url).contains(0x0D), "\(url.lastPathComponent)")
        }
    }

    @Test func bomAndTrailingNewlineBytesAreExact() throws {
        #expect(try Fixtures.data("bom.md").prefix(3) == Data([0xEF, 0xBB, 0xBF]))
        #expect(try Fixtures.data("no-trailing-newline.md").last != 0x0A)
        #expect(try Fixtures.data("lf.md").last == 0x0A)
    }

    @Test func kitchenSinkCoversEveryBlockKind() throws {
        let source = try String(decoding: Fixtures.data("kitchen-sink.md"), as: UTF8.self)
        let document = Document(parsing: source)
        var kinds = Set<String>()
        func walk(_ markup: any Markup) {
            kinds.insert(String(describing: type(of: markup)))
            markup.children.forEach(walk)
        }
        walk(document)
        let expected: Set = [
            "Heading", "Paragraph", "Emphasis", "Strong", "Strikethrough", "InlineCode", "Link", "Image",
            "UnorderedList", "OrderedList", "ListItem", "BlockQuote", "CodeBlock", "Table", "ThematicBreak",
        ]
        #expect(expected.subtracting(kinds).isEmpty, "missing: \(expected.subtracting(kinds))")
    }
}
