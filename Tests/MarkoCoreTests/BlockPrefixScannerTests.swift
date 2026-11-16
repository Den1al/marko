import Foundation
import Testing
@testable import MarkoCore

@Suite struct BlockPrefixScannerTests {
    private func scan(_ line: String, chain: [BlockPrefixScanner.Container], items: [BlockPrefixScanner.Item] = [],
                      line number: Int = 0) -> (prefix: String, result: BlockPrefixScanner.Prefix, scanner: BlockPrefixScanner) {
        var scanner = BlockPrefixScanner(items: items)
        let units = Array(line.utf16)
        let result = scanner.scan(units, from: 0, to: units.count, line: number, chain: chain)
        return (String(line.utf16.prefix(result.end))!, result, scanner)
    }

    private func item(line: Int = 0, ordered: Bool = false, indent: Int = 2) -> BlockPrefixScanner.Item {
        .init(line: line, isOrdered: ordered, indent: indent)
    }

    @Test func quoteMarkers() {
        #expect(scan("> a", chain: [.quote]).prefix == "> ")
        #expect(scan(">a", chain: [.quote]).prefix == ">")
        #expect(scan("   > a", chain: [.quote]).prefix == "   > ")
        #expect(scan(">>  > a", chain: [.quote, .quote, .quote]).prefix == ">>  > ")
        #expect(scan(">", chain: [.quote]).prefix == ">")
        #expect(scan("> > a", chain: [.quote]).prefix == "> ")
    }

    @Test func aMissingQuoteMarkerIsLazy() {
        let lazy = scan("text", chain: [.quote])
        #expect(lazy.prefix == "" && lazy.result.isLazy)
        let partial = scan("> text", chain: [.quote, .quote])
        #expect(partial.prefix == "> " && partial.result.isLazy)
        #expect(!scan("> a", chain: [.quote]).result.isLazy)
    }

    @Test func bulletAndOrderedMarkers() {
        let bullet = scan("- a", chain: [.listItem(0)], items: [item()])
        #expect(bullet.prefix == "- ")
        #expect(bullet.result.markers == [ListMarker(range: NSRange(location: 0, length: 1), isOrdered: false)])
        #expect(bullet.scanner.items[0].indent == 2)

        let ordered = scan("  12) a", chain: [.listItem(0)], items: [item(ordered: true)])
        #expect(ordered.prefix == "  12) ")
        #expect(ordered.result.markers == [ListMarker(range: NSRange(location: 2, length: 3), isOrdered: true)])
        #expect(ordered.scanner.items[0].indent == 6)

        #expect(scan("+   a", chain: [.listItem(0)], items: [item()]).prefix == "+   ")
        // Five spaces: the content is indented code starting one space after the marker.
        let code = scan("-     a", chain: [.listItem(0)], items: [item()])
        #expect(code.prefix == "- " && code.scanner.items[0].indent == 2)
        let empty = scan("-", chain: [.listItem(0)], items: [item()])
        #expect(empty.prefix == "-" && empty.scanner.items[0].indent == 2)
    }

    @Test func checkbox() {
        let open = scan("- [ ] a", chain: [.listItem(0)], items: [item()])
        #expect(open.prefix == "- [ ] ")
        #expect(open.result.markers[0].checkbox == .init(range: NSRange(location: 2, length: 3), isChecked: false))
        #expect(scan("1. [X] a", chain: [.listItem(0)], items: [item(ordered: true)]).result.markers[0].checkbox?.isChecked == true)
        // cmark-gfm wants a blank after the box and nothing but blanks before it.
        for notATask in ["- [ ]", "- [x]a", "- [y] a", "-     [ ] a"] {
            #expect(scan(notATask, chain: [.listItem(0)], items: [item()]).result.markers[0].checkbox == nil, "\(notATask)")
        }
        #expect(scan("- [ ] ", chain: [.listItem(0)], items: [item()]).prefix == "- [ ] ")
    }

    @Test func continuationLinesConsumeTheItemIndent() {
        let items = [item(line: 0, indent: 3)]
        #expect(scan("   text", chain: [.listItem(0)], items: items, line: 1).prefix == "   ")
        #expect(scan("      text", chain: [.listItem(0)], items: items, line: 1).prefix == "   ")
        #expect(scan("\ttext", chain: [.listItem(0)], items: items, line: 1).prefix == "\t")
        #expect(scan("  ", chain: [.listItem(0)], items: items, line: 1).prefix == "  ")
        let lazy = scan(" text", chain: [.listItem(0)], items: items, line: 1)
        #expect(lazy.prefix == "" && lazy.result.isLazy)
    }

    /// Indentation is measured in columns: a tab runs to the next multiple of four.
    @Test func tabsCountAsColumns() {
        let marker = scan("* \ta", chain: [.listItem(0)], items: [item()])
        #expect(marker.prefix == "* \t" && marker.scanner.items[0].indent == 4)
        #expect(scan("1.\ta", chain: [.listItem(0)], items: [item(ordered: true)]).scanner.items[0].indent == 4)
        // Three spaces do not reach an indent of four.
        #expect(scan("   b", chain: [.listItem(0)], items: [item(indent: 4)], line: 1).result.isLazy)

        // The item uses two of the tab's four columns; the quote marker is missing.
        let partial = scan("\tb", chain: [.listItem(0), .quote], items: [item()], line: 1)
        #expect(partial.prefix == "\t" && partial.result.isLazy && partial.result.padding == 2)
        let whole = scan("\tb", chain: [.listItem(0)], items: [item(indent: 4)], line: 1)
        #expect(whole.prefix == "\t" && whole.result.padding == 0)
        #expect(scan("  \t> b", chain: [.listItem(0), .quote], items: [item()], line: 1).prefix == "  \t> ")
        #expect(scan(">\tb", chain: [.quote]).result.padding == 2)
    }

    @Test func nestedContainers() {
        let nested = scan("> 1. - [x] a", chain: [.quote, .listItem(0), .listItem(1)],
                          items: [item(ordered: true), item()])
        #expect(nested.prefix == "> 1. - [x] ")
        #expect(nested.result.markers.map(\.range) == [NSRange(location: 2, length: 2), NSRange(location: 5, length: 1)])
        #expect(scan("   > b", chain: [.listItem(0), .quote], items: [item(indent: 3)], line: 1).prefix == "   > ")
    }

    @Test func aLineThatDoesNotMatchItsContainersStopsWithoutCrossingTheEnd() {
        #expect(scan("x", chain: [.listItem(0)], items: [item()]).prefix == "")
        #expect(scan("1x", chain: [.listItem(0)], items: [item(ordered: true)]).prefix == "")
        #expect(scan("-x", chain: [.listItem(0)], items: [item()]).prefix == "")
        #expect(scan("", chain: [.quote, .listItem(0)], items: [item()]).prefix == "")
        #expect(scan("- [", chain: [.listItem(0)], items: [item()]).prefix == "- ")
    }
}
