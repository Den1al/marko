import Foundation
import FixtureSupport
import Testing
@testable import MarkoCore

/// `MarkdownStyler.restyle` against the parse of the whole text: the same map and the same diff,
/// whatever the edit.
@Suite struct RestyleTests {
    /// SplitMix64, so that a failure can be run again.
    private struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A text with its map, edited the way the editor does it. Counts the edits that needed no whole parse.
    private struct Edited {
        var text: NSMutableString
        var map: StyleMap
        var partial = 0
        var reportsLines: Bool

        init(_ source: String, reportsLines: Bool = false) {
            text = NSMutableString(string: source)
            map = MarkdownStyler.style(source)
            self.reportsLines = reportsLines
        }

        /// Returns what is wrong after replacing `range` with `replacement`, or nil.
        mutating func replace(_ range: NSRange, with replacement: String) -> String? {
            let before = text as String, old = map
            text.replaceCharacters(in: range, with: replacement)
            let length = (replacement as NSString).length
            let whole = MarkdownStyler.style(text as String)
            // The text storage often reports more than was changed: the lines the edit touched.
            var reported = NSRange(location: range.location, length: length)
            if reportsLines { reported = text.lineRange(for: reported) }
            let diff = MarkdownStyler.restyle(&map, in: text, editedRange: reported, changeInLength: length - range.length)
            defer { map = whole }
            guard let diff else { return map == old ? nil : "a refused edit changed the map" }
            partial += 1
            // What a diff is: the lines outside it are the same apart from their offset. Where lines
            // repeat, `diff` of the two maps can place the change elsewhere, which is as true.
            let delta = length - range.length
            let isSame = old.lines[..<diff.old.lowerBound] == whole.lines[..<diff.new.lowerBound]
                && old.lines[diff.old.upperBound...].map { $0.shifted(by: delta) } == Array(whole.lines[diff.new.upperBound...])
                && (whole != old || diff.old.isEmpty && diff.new.isEmpty)
            // The same holds for the lines that differ themselves, which leave a table's other rows out.
            let changedEnd = diff.changed.upperBound - (whole.lines.count - old.lines.count)
            guard diff.new.lowerBound <= diff.changed.lowerBound, diff.changed.upperBound <= diff.new.upperBound,
                  diff.changed.lowerBound <= changedEnd, changedEnd <= old.lines.count,
                  old.lines[..<diff.changed.lowerBound] == whole.lines[..<diff.changed.lowerBound],
                  old.lines[changedEnd...].map({ $0.shifted(by: delta) }) == Array(whole.lines[diff.changed.upperBound...]) else {
                return "changed lines \(diff) of \(range) -> \(replacement.debugDescription) in \(before.debugDescription)"
            }
            let expected = whole.diff(from: old)
            let problem = map != whole ? "map, \(RestyleTests.difference(map, whole))" : isSame ? nil : "diff \(diff) for \(expected)"
            return problem.map { "\($0): \(range) -> \(replacement.debugDescription) in \(before.debugDescription)" }
        }
    }

    private static func difference(_ a: StyleMap, _ b: StyleMap) -> String {
        guard a.lines.count == b.lines.count else { return "\(a.lines.count) lines for \(b.lines.count)" }
        guard let line = a.lines.indices.first(where: { a.lines[$0] != b.lines[$0] }) else {
            return a.tables != b.tables ? "tables \(a.tables) for \(b.tables)" : "references"
        }
        return "line \(line): \(a.lines[line]) for \(b.lines[line])"
    }

    private static let fixtures = Fixtures.all.map { String(decoding: try! Data(contentsOf: $0), as: UTF8.self) }

    /// Checked boxes behind more than one container marker, in a text that defines "x": the
    /// parser reads "[x]" as a link there and the line comes out as a plain paragraph.
    private static let tasksUnderADefinition =
        "intro\n\n> - [ ] a\n> - [x] b\n\n- a\n- - [x] done\n\n1. - [X] c\n\ntext\n- - [x] lazy\n\n- [x] single\n\nend\n\n[x]: http://example.org\n"

    private static let pieces = [
        "a", "b c", " ", "  ", "    ", "\t", "\n", "\n\n", "\r\n", "\r", "\n\n\n", "- ", "* ", "+ ", "1. ", "9. ", "10) ", "> ",
        "- [ ] ", "# ", "## ", "===", "---", "---\n", "...\n", "***", "```", "```swift\n", "~~~\n", "`", "``", "*", "**", "_", "~~",
        "[", "]", "[x]", "[x]: /u", "[x][y]", "](", "(/u)", "![", "<", ">", "<!--", "-->", "<div>", "</div>", "<pre>", "</pre>",
        "<a href=\"x\">", "|", " | ", "| a | b |\n|---|:-:|\n| c | d |\n", "|--|--|", "\\", "\\|", "é", "日本", "😀", "\u{0}", "\u{2028}",
        "let x = 1 // c\n", "http://a.b ", "<http://a.b>", "&amp;", "text\ntext", "  text", "\n- a\n\n  b\n", "\n1. a\n2. b\n",
    ]

    @Test func typingEveryFixtureCharacterByCharacter() {
        var partial = 0, total = 0
        for source in Self.fixtures {
            var edited = Edited("")
            for (offset, unit) in source.utf16.enumerated() {
                let problem = edited.replace(NSRange(location: offset, length: 0), with: String(utf16CodeUnits: [unit], count: 1))
                #expect(problem == nil)
                if problem != nil { return }
            }
            partial += edited.partial
            total += source.utf16.count
        }
        // Most of the keys must go the short way, or the test proves nothing.
        #expect(partial * 2 > total, "\(partial) of \(total)")
    }

    @Test func deletingEveryFixtureFromTheEndAndFromTheStart() {
        for source in Self.fixtures {
            var edited = Edited(source)
            while edited.text.length > 0 {
                let problem = edited.replace(NSRange(location: edited.text.length - 1, length: 1), with: "")
                #expect(problem == nil)
                if problem != nil { return }
            }
            edited = Edited(source)
            while edited.text.length > 0 {
                let problem = edited.replace(NSRange(location: 0, length: 1), with: "")
                #expect(problem == nil)
                if problem != nil { return }
            }
        }
    }

    /// `MARKO_FUZZ=<n>` makes n times as many edits.
    @Test func randomEditsOfEveryFixture() {
        let rounds = 60 * (ProcessInfo.processInfo.environment["MARKO_FUZZ"].flatMap(Int.init) ?? 1)
        var random = Random(state: 20261115)
        var partial = 0, total = 0
        for (number, source) in (Self.fixtures + [Self.fixtures.joined(separator: "\n\n"), Self.tasksUnderADefinition]).enumerated() {
            for _ in 0..<rounds / 20 {
                var edited = Edited(source, reportsLines: Bool.random(using: &random))
                for _ in 0..<20 {
                    let length = edited.text.length
                    let location = Int.random(in: 0...length, using: &random)
                    // Mostly at the caret; sometimes a selection, sometimes most of the text.
                    let most = [0, 0, 0, 1, 1, 3, 12, 80, length][Int.random(in: 0..<9, using: &random)]
                    let range = NSRange(location: location, length: Int.random(in: 0...min(most, length - location), using: &random))
                    var replacement = ""
                    switch Int.random(in: 0..<10, using: &random) {
                    case 0: break
                    case 1:
                        // A piece of the text itself, as a paste is.
                        let from = Int.random(in: 0...length, using: &random)
                        replacement = edited.text.substring(with: NSRange(location: from, length: Int.random(in: 0...min(120, length - from), using: &random)))
                    default:
                        for _ in 0..<Int.random(in: 1...3, using: &random) { replacement += Self.pieces.randomElement(using: &random)! }
                    }
                    let problem = edited.replace(range, with: replacement)
                    #expect(problem == nil, "fixture \(number)")
                    if problem != nil { return }
                    total += 1
                }
                partial += edited.partial
            }
        }
        #expect(partial * 4 > total, "\(partial) of \(total)")
    }

    /// Edits that stay inside one line of a table, where a row is parsed without its table.
    @Test func randomEditsInsideTableRows() throws {
        let rounds = 40 * (ProcessInfo.processInfo.environment["MARKO_FUZZ"].flatMap(Int.init) ?? 1)
        var random = Random(state: 77)
        let pieces = ["x", " ", "|", "\\|", "\\", "`", "**", "*", "~~", "[x]", "[x](/u)", "<b>", "> ", "# ", "- ", "1. ", "---", "```", ":", "é", "😀", "\t", "    "]
        let tables = String(decoding: try Fixtures.data("tables.md"), as: UTF8.self)
        var partial = 0, total = 0
        for source in [tables, "| a | b |\n|---|--:|\n| c | d |\n| e | f |\n| g | h |\n\ntext\n", "text\n| a | b |\n|---|---|\n| c | d |\n| e | f |"] {
            for _ in 0..<rounds {
                var edited = Edited(source, reportsLines: Bool.random(using: &random))
                for _ in 0..<25 {
                    let rows = edited.map.lines.filter { if case .tableRow = $0.kind { true } else { false } }
                    guard let row = rows.randomElement(using: &random) else { break }
                    let end = edited.text.lineContentEnd(at: row.range.location)
                    let location = Int.random(in: row.range.location...end, using: &random)
                    let range = NSRange(location: location, length: Int.random(in: 0...min(2, end - location), using: &random))
                    let replacement = Bool.random(using: &random) ? pieces.randomElement(using: &random)! : ""
                    let problem = edited.replace(range, with: replacement)
                    #expect(problem == nil)
                    if problem != nil { return }
                    total += 1
                }
                partial += edited.partial
            }
        }
        #expect(partial * 2 > total, "\(partial) of \(total)")
    }

    /// Edits that stay inside one line that starts a list item, where the item's text is parsed without its list.
    @Test func randomEditsInsideListItems() {
        let rounds = 12 * (ProcessInfo.processInfo.environment["MARKO_FUZZ"].flatMap(Int.init) ?? 1)
        var random = Random(state: 4242)
        let pieces = ["x", "y z", " ", "  ", "    ", "\t", "- ", "* ", "+ ", "1. ", "10) ", "> ", "[ ] ", "[x] ", "[", "]", "[x]", "[x]: /u", "[a](/u)",
                      "![a](/u)", "# ", "===", "---", "***", "```", "~~~", "`", "**", "*", "_", "~~", "<b>", "<div>", "<!--", "\\", "|", ":", "é", "😀",
                      "\u{FEFF}", "&amp;", "http://a.b", "<http://a.b>", "\u{0}", "\u{2028}"]
        let list = """
            intro

            - one **bold** and `code`
            - two [link](/u) text
              - nested *item*
              - another
                1. deep
                2. deeper
            - [ ] task
            - [x] done [x] twice
            - lazy
            continuation
            - loose

              second paragraph

            - # heading
            -
            - last

            8. eight
            9. nine
            10. ten
            11) other list

            > - quoted
            > - items ~~here~~
            > 1. and numbers

            * star
            + plus
            - - two markers
            | a | b |
            |---|---|
            - below a table

            end
            """
        var partial = 0, total = 0
        for source in [list, list + "\n\n[x]: /defined\n", list.replacingOccurrences(of: "\n", with: "\r\n"), "- only", "1. a\n2. b"] {
            for _ in 0..<rounds {
                var edited = Edited(source, reportsLines: Int.random(in: 0..<4, using: &random) == 0)
                for _ in 0..<25 {
                    guard let item = edited.map.lines.filter({ !$0.listMarkers.isEmpty }).randomElement(using: &random) else { break }
                    let end = edited.text.lineContentEnd(at: item.range.location)
                    // Mostly in the item's text, sometimes among its markers or over its line break.
                    let low = Int.random(in: 0..<5, using: &random) == 0 ? item.range.location : min(NSMaxRange(item.prefixRange), end)
                    let high = Int.random(in: 0..<12, using: &random) == 0 ? NSMaxRange(item.range) : end
                    let location = Int.random(in: low...high, using: &random)
                    let range = NSRange(location: location, length: Int.random(in: 0...min(2, high - location), using: &random))
                    let replacement = Int.random(in: 0..<3, using: &random) == 0 ? "" : pieces.randomElement(using: &random)!
                    let problem = edited.replace(range, with: replacement)
                    #expect(problem == nil, "\(problem ?? "")")
                    if problem != nil { return }
                    total += 1
                }
                partial += edited.partial
            }
        }
        #expect(partial * 2 > total, "\(partial) of \(total)")
    }

    /// MEASURED: a key in a list of 2,400 items was 23 ms, all of it parsing the list.
    @Test func anItemIsParsedWithoutItsList() {
        let items = (1...3000).map { "\($0). item with **text** and `code`\n" }.joined()
        let text = NSMutableString(string: "intro\n\n" + items + "\nend\n")
        var map = MarkdownStyler.style(text as String)
        let clock = ContinuousClock()
        var item = Duration.zero, list = Duration.zero
        let place = text.range(of: "1500. item").location + 8
        for _ in 0..<5 {
            text.insert("x", at: place)
            item += clock.measure {
                #expect(MarkdownStyler.restyle(&map, in: text, editedRange: NSRange(location: place, length: 1), changeInLength: 1) != nil)
            }
        }
        #expect(map == MarkdownStyler.style(text as String))
        // A change to the number is the business of the whole list, and so is one the storage reports as the whole line.
        text.insert("9", at: place - 8)
        list = clock.measure {
            #expect(MarkdownStyler.restyle(&map, in: text, editedRange: NSRange(location: place - 8, length: 1), changeInLength: 1) != nil)
        }
        #expect(map == MarkdownStyler.style(text as String))
        print("PERF restyle in a list of 3,000 items: a key in an item \(item / 5), a key in a number \(list)")
        #expect(item / 5 * 10 < list, "the item alone was parsed")
    }

    @Test func aRowIsParsedWithoutItsTable() {
        let rows = (1...3000).map { "| \($0) | some **text** | `code` |\n" }.joined()
        let text = NSMutableString(string: "intro\n\n| No | What | Code |\n|---:|:---|---|\n" + rows + "\nend\n")
        var map = MarkdownStyler.style(text as String)
        let clock = ContinuousClock()
        var row = Duration.zero, table = Duration.zero
        let place = text.range(of: "| 1500 |").location + 4
        for _ in 0..<5 {
            text.insert("x", at: place)
            row += clock.measure {
                    let line = text.lineRange(for: NSRange(location: place, length: 1))
                #expect(MarkdownStyler.restyle(&map, in: text, editedRange: line, changeInLength: 1) != nil)
            }
        }
        #expect(map == MarkdownStyler.style(text as String))
        // A line break in a row is the business of the whole table.
        text.insert("\n", at: place)
        table = clock.measure {
            #expect(MarkdownStyler.restyle(&map, in: text, editedRange: NSRange(location: place, length: 1), changeInLength: 1) != nil)
        }
        #expect(map == MarkdownStyler.style(text as String))
        print("PERF restyle in a table of 3,000 rows: a key in a row \(row / 5), a line break \(table)")
        #expect(row / 5 * 10 < table, "the row alone was parsed")
    }

    @Test func aBlockIsParsedWithoutTheRestOfTheText() {
        let source = "# Title\n\nalpha **a**\n\nbeta `b`\n\n- gamma\n- delta\n\nomega\n"
        var edited = Edited(source)
        func type(_ text: String, at needle: String) -> String? {
            edited.replace(NSRange(location: edited.text.range(of: needle).location, length: 0), with: text)
        }
        #expect(type("s", at: " **a**") == nil)
        #expect(type("x", at: "- delta") == nil)
        #expect(type("\n\nnew", at: " `b`") == nil)
        #expect(type("```\n", at: "omega") == nil)
        #expect(edited.partial == 4, "an open fence at the end of the text is still a part of its own")
        #expect(type("```\n", at: "beta") == nil)
        #expect(edited.partial == 4, "a fence that swallows the lines below is not")
    }

    @Test func aBracketThatADefinitionCouldGiveAMeaningNeedsTheWholeText() {
        var edited = Edited("see [that] and [this](/inline)\n\nmore `[code]` and \\[escaped]\n\n- [ ] task\n\n[that]: /url\n")
        #expect(edited.map.hasReferences)
        func type(at needle: String) -> String? {
            edited.replace(NSRange(location: edited.text.range(of: needle).location, length: 0), with: "x")
        }
        #expect(type(at: "more") == nil && type(at: "task") == nil && edited.partial == 2, "no bracket there that could refer to anything")
        #expect(type(at: "see") == nil && edited.partial == 2, "a reference")
        #expect(type(at: "/url") == nil && edited.partial == 2, "the definition")
        // Taking the definition away or putting one in changes other lines.
        let definition = edited.text.range(of: "[that]: ")
        #expect(edited.replace(definition, with: "") == nil && edited.partial == 2)
        #expect(!edited.map.hasReferences && edited.map.lines[0].tokens.count == 1)
        #expect(type(at: "see") == nil && edited.partial == 3, "without a definition a bracket is a bracket")
        #expect(edited.replace(NSRange(location: edited.text.length, length: 0), with: "\n[that]: /url\n") == nil && edited.partial == 3)
        #expect(edited.map.hasReferences && edited.map.lines[0].tokens.count == 2)
        // Not every bracket at the start of a line is one.
        for plain in ["- [ ] task\n", "[link](/url) text\n", "- [link](/url)\n", "[^note] text\n"] {
            #expect(!MarkdownStyler.style(plain).hasReferences, "\(plain.debugDescription)")
        }
        for definition in ["[a]: /u\n", "> [a]: /u\n", "1. [a]: /u\n", "- [ ] [a]: /u\n", "[a\nb]: /u\n", "[a\\]b]: /u\n", "   [a]:\n/u\n"] {
            #expect(MarkdownStyler.style(definition).hasReferences, "\(definition.debugDescription)")
        }
    }

    @Test func aCheckedBoxThatADefinitionMakesALinkIsNotParsedByItself() {
        let sources = [
            "intro\n\n> - [ ] a\n> - [x] b\n\nend\n\n[x]: http://example.org\n",
            "intro\n\n- a\n- - [x] done\n\nend\n\n[x]: http://example.org\n",
            "[x]: http://example.org\n\nintro\n\ntext\n- - [x] done\n\nend\n",
            Self.tasksUnderADefinition,
        ]
        for source in sources {
            for reportsLines in [false, true] {
                for offset in 0...source.utf16.count {
                    var edited = Edited(source, reportsLines: reportsLines)
                    let problem = edited.replace(NSRange(location: offset, length: 0), with: "z")
                    #expect(problem == nil)
                    if problem != nil { return }
                }
            }
        }
        // An empty box cannot be a reference, and such a line still goes the short way.
        var edited = Edited("intro\n\n> - [ ] a\n\nend\n\n[x]: http://example.org\n")
        #expect(edited.replace(NSRange(location: 16, length: 0), with: "z") == nil && edited.partial == 1)
    }

    /// One block can be as long as the text. MEASURED: a key in a list of 16,000 items was 90 ms,
    /// all of it parsing the list. Such a part is refused, at once and with the map as it was.
    @Test func aPartLongerThanTheLimitIsRefusedAtOnce() {
        let source = "# List\n\n" + (1...16_000).map { "- item \($0) of a long list\n" }.joined()
        let text = NSMutableString(string: source)
        var map = MarkdownStyler.style(source)
        let old = map, place = text.length / 2, clock = ContinuousClock()
        text.insert("x", at: place)
        var best = Duration.seconds(100)
        for _ in 0..<5 {
            best = min(best, clock.measure {
                // As the text storage reports a typed character: its whole line, which an item is not parsed alone for.
                #expect(MarkdownStyler.restyle(&map, in: text, editedRange: text.lineRange(for: NSRange(location: place, length: 1)), changeInLength: 1, limit: 25_000) == nil)
            })
        }
        #expect(map == old)
        print("PERF restyle refusing a part of \(text.length) units: \(best)")
        // MEASURED: 4.7 ms in a debug build; parsing the list is 500 ms there.
        #expect(best < .milliseconds(50))
        // The same list in a part that fits is parsed.
        let short = NSMutableString(string: "# List\n\n" + (1...500).map { "- item \($0) of a long list\n" }.joined())
        var small = MarkdownStyler.style(short as String)
        short.insert("x", at: 100)
        #expect(MarkdownStyler.restyle(&small, in: short, editedRange: short.lineRange(for: NSRange(location: 100, length: 1)), changeInLength: 1, limit: 25_000) != nil)
        #expect(small == MarkdownStyler.style(short as String))
    }

    @Test func timeOfAKeyInALargeText() throws {
        let unit = String(decoding: try Fixtures.data("kitchen-sink.md"), as: UTF8.self)
            .replacingOccurrences(of: "\n[", with: "\n\\[") + "\n"
        let source = String(repeating: unit, count: 600_000 / unit.utf8.count + 1)
        let text = NSMutableString(string: source)
        var map = MarkdownStyler.style(source)
        try #require(!map.hasReferences)
        let clock = ContinuousClock()
        var best = Duration.seconds(100)
        for place in [10, text.length / 2, text.length - 10] {
            for _ in 0..<5 {
                text.insert("x", at: place)
                var diff: LineDiff?
                best = min(best, clock.measure {
                    diff = MarkdownStyler.restyle(&map, in: text, editedRange: NSRange(location: place, length: 1), changeInLength: 1)
                })
                #expect(diff != nil)
            }
        }
        #expect(map == MarkdownStyler.style(text as String))
        print("PERF restyle after one character in \(text.length) units, \(map.lines.count) lines: \(best)")
        // MEASURED: 0.17 ms in a debug build, 0.02 ms in release.
        #expect(best < .milliseconds(5))
    }
}
