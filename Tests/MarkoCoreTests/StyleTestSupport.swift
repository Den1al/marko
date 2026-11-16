import Foundation
import FixtureSupport
import Markdown
@testable import MarkoCore

/// A styled source with helpers to address ranges by their text.
struct Styled {
    let source: NSString
    let map: StyleMap
    let inconsistentLines: Set<Int>

    init(_ source: String, document: Document? = nil) {
        self.source = source as NSString
        (map, inconsistentLines) = MarkdownStyler.build(source: source, document: document ?? Document(parsing: source))
    }

    init(fixture name: String) throws {
        self.init(String(decoding: try Fixtures.data(name), as: UTF8.self))
    }

    func text(_ range: NSRange) -> String { source.substring(with: range) }

    /// Range of the n-th occurrence of `text`.
    func range(of text: String, occurrence: Int = 0) -> NSRange {
        var search = NSRange(location: 0, length: source.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = source.range(of: text, range: search)
            guard found.location != NSNotFound else { break }
            search = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
        }
        return found
    }

    /// The line containing the n-th occurrence of `text`.
    func line(containing text: String, occurrence: Int = 0) -> LineStyle {
        let location = range(of: text, occurrence: occurrence).location
        return map.lines.first { NSLocationInRange(location, $0.range) }!
    }

    func tokens(_ kind: InlineToken.Kind) -> [InlineToken] {
        map.lines.flatMap(\.tokens).filter { $0.kind == kind }
    }

    /// "markers|content" as text, which reads well in expectations.
    func describe(_ token: InlineToken) -> String {
        token.markerRanges.map(text).joined(separator: " ") + "|" + text(token.contentRange)
    }
}

/// Structural invariants every StyleMap must satisfy for its source, whatever the input.
func invariantViolations(_ map: StyleMap, source: String) -> [String] {
    let units = Array(source.utf16)
    var problems: [String] = []
    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { problems.append(message()) }
    }
    func inside(_ inner: NSRange, _ outer: NSRange) -> Bool {
        inner.location >= outer.location && NSMaxRange(inner) <= NSMaxRange(outer) && inner.length >= 0
    }

    var expectedStart = 0
    for (number, line) in map.lines.enumerated() {
        check(line.range.location == expectedStart && line.range.length > 0, "line \(number) does not tile")
        expectedStart = NSMaxRange(line.range)
        guard expectedStart <= units.count else {
            problems.append("line \(number) exceeds the source")
            break
        }
        check(line.prefixRange.location == line.range.location && inside(line.prefixRange, line.range), "line \(number) prefix")
        let body = NSRange(location: NSMaxRange(line.prefixRange), length: NSMaxRange(line.range) - NSMaxRange(line.prefixRange))
        for marker in line.listMarkers {
            check(inside(marker.range, line.prefixRange) && marker.range.length > 0, "line \(number) list marker")
            if let box = marker.checkbox {
                check(inside(box.range, line.prefixRange) && box.range.length == 3, "line \(number) checkbox")
            }
        }
        for marker in line.headingMarkers { check(inside(marker, body), "line \(number) heading marker") }
        var cellEnd = body.location
        for cell in line.cells {
            check(inside(cell.range, body) && inside(cell.contentRange, cell.range) && cell.range.location >= cellEnd, "line \(number) cell")
            cellEnd = NSMaxRange(cell.range)
        }
        for pipe in line.pipes {
            check(NSLocationInRange(pipe, body) && units[pipe] == 0x7C, "line \(number) pipe")
        }
        for token in line.tokens {
            check(token.range.location >= 0 && NSMaxRange(token.range) <= units.count && token.range.length > 0, "line \(number) token range")
            check(NSIntersectionRange(token.range, line.range).length > 0, "line \(number) token not on line")
            for range in token.markerRanges + [token.contentRange] {
                check(inside(range, body) && inside(range, token.range), "line \(number) token piece \(range)")
            }
            check(token.markerRanges.allSatisfy { $0.length > 0 }, "line \(number) empty marker")
            check((token.destination != nil) == (token.kind == .link || token.kind == .image), "line \(number) destination")
        }
    }
    check(expectedStart == units.count, "lines end at \(expectedStart), source at \(units.count)")

    var tableEnd = 0
    for table in map.tables {
        check(table.lines.lowerBound >= tableEnd && table.lines.upperBound <= map.lines.count && !table.lines.isEmpty, "table \(table.lines)")
        tableEnd = table.lines.upperBound
        for (offset, line) in map.lines[table.lines.clamped(to: 0..<map.lines.count)].enumerated() {
            switch (offset, line.kind) {
            case (0, .tableRow(isHeader: true)), (1, .tableDelimiter), (2..., .tableRow(isHeader: false)): break
            default: problems.append("table \(table.lines) line \(offset) is \(line.kind)")
            }
        }
    }
    return problems
}

func fixtureSources() throws -> [(name: String, source: String)] {
    try Fixtures.all.map { ($0.lastPathComponent, String(decoding: try Data(contentsOf: $0), as: UTF8.self)) }
}
