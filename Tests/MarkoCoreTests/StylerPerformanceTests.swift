import Foundation
import FixtureSupport
import Markdown
import Testing
@testable import MarkoCore

@Suite(.serialized) struct StylerPerformanceTests {
    /// Reports parse and style time; the bound is loose so only a gross regression fails.
    @Test(arguments: [30_000, 600_000]) func parseAndStyleTime(bytes: Int) throws {
        let unit = String(decoding: try Fixtures.data("kitchen-sink.md"), as: UTF8.self) + "\n"
        let source = String(repeating: unit, count: bytes / unit.utf8.count + 1)
        var parse = Duration.seconds(100), style = Duration.seconds(100), diff = Duration.seconds(100)
        var map = StyleMap()
        let clock = ContinuousClock()
        for _ in 0..<5 {
            var document: Document!
            parse = min(parse, clock.measure { document = Document(parsing: source) })
            style = min(style, clock.measure { map = MarkdownStyler.style(source: source, document: document) })
        }
        let edited = MarkdownStyler.style("x" + source)
        for _ in 0..<5 { diff = min(diff, clock.measure { _ = edited.diff(from: map) }) }
        func ms(_ d: Duration) -> String { String(format: "%.1f ms", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1e3) }
        print("PERF \(source.utf8.count) bytes, \(map.lines.count) lines: parse \(ms(parse)), style \(ms(style)), total \(ms(parse + style)), diff after a one-character edit at the top \(ms(diff))")
        #expect(map.lines.count == SourceIndex(source).lineCount)
        #expect(edited.diff(from: map) == LineDiff(old: 0..<1, new: 0..<1))
        #expect(parse + style < .seconds(bytes > 100_000 ? 10 : 1))
    }
}
