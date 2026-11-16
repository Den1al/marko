import Foundation
import Testing
@testable import MarkoCore

@Suite struct StyleMapDiffTests {
    private func diff(_ old: String, _ new: String) -> LineDiff {
        MarkdownStyler.style(new).diff(from: MarkdownStyler.style(old))
    }

    private let document = "# Title\n\nalpha **a**\n\nbeta `b`\n\n- gamma\n- delta\n\nomega\n"

    @Test func identicalMapsHaveAnEmptyDiff() {
        let d = diff(document, document)
        #expect(d.old.isEmpty && d.new.isEmpty)
    }

    @Test func typingInsideALineChangesOnlyThatLine() {
        let d = diff(document, document.replacingOccurrences(of: "beta", with: "betas"))
        #expect(d == LineDiff(old: 4..<5, new: 4..<5))
    }

    @Test func typingPlainTextBeforeATokenStillReportsItsLine() {
        // Ranges on the line move, so its LineStyle differs even though no token was added.
        let d = diff(document, document.replacingOccurrences(of: "alpha", with: "alphas"))
        #expect(d == LineDiff(old: 2..<3, new: 2..<3))
    }

    @Test func insertingAndDeletingLines() {
        #expect(diff(document, "new first\n\n" + document) == LineDiff(old: 0..<0, new: 0..<2))
        #expect(diff(document, document.replacingOccurrences(of: "- delta\n", with: "")) == LineDiff(old: 7..<8, new: 7..<7))
        #expect(diff(document, document + "\ntail\n") == LineDiff(old: 10..<10, new: 10..<12))
        #expect(diff("", document) == LineDiff(old: 0..<0, new: 0..<10))
        #expect(diff(document, "") == LineDiff(old: 0..<10, new: 0..<0))
    }

    /// A fence typed with its closing fence (what the Enter rule will insert) restyles only the new lines.
    @Test func typedFenceWithClosingFenceIsMinimal() {
        let new = document.replacingOccurrences(of: "beta `b`\n", with: "```\n```\nbeta `b`\n")
        let d = diff(document, new)
        #expect(d == LineDiff(old: 4..<4, new: 4..<6))
        let map = MarkdownStyler.style(new)
        #expect(map.lines[4].kind == .codeFence(language: nil, isClosing: false))
        #expect(map.lines[5].kind == .codeFence(language: nil, isClosing: true))
        #expect(map.lines[6].tokens.count == 1)
    }

    /// An opening fence alone turns everything below it into code, and nothing above it.
    @Test func typedUnclosedFenceChangesExactlyTheLinesBelow() {
        let new = document.replacingOccurrences(of: "\nbeta", with: "```\nbeta")
        let d = diff(document, new)
        #expect(d == LineDiff(old: 3..<10, new: 3..<10))
        let map = MarkdownStyler.style(new)
        #expect(map.lines[2].tokens.count == 1)
        #expect(map.lines[3].kind == .codeFence(language: nil, isClosing: false))
        #expect(map.lines[4...].allSatisfy { $0.kind == .codeBody(language: nil) })
    }

    /// Typing the fence characters one by one: the span never reaches above the edited line.
    @Test func typingAFenceCharacterByCharacter() {
        var previous = document
        for typed in ["`", "``", "```", "```s", "```sw"] {
            let new = document.replacingOccurrences(of: "\nbeta", with: typed + "\nbeta")
            let d = diff(previous, new)
            #expect(d.new.lowerBound == 3, "\(typed)")
            #expect(d.new.upperBound == (typed.count < 3 ? 5 : 10), "\(typed)")
            previous = new
        }
    }

    @Test func closingAnOpenFenceRestoresTheLinesBelowIt() {
        let open = "a\n\n```\ncode\n\nb **x**\n\nc\n"
        let closed = "a\n\n```\ncode\n```\nb **x**\n\nc\n"
        #expect(diff(open, closed) == LineDiff(old: 4..<8, new: 4..<8))
    }

    @Test func aChangeInsideATableCoversTheWholeTable() {
        let table = "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\noutro\n"
        #expect(diff(table, table.replacingOccurrences(of: "| 3 |", with: "| 33 |")) == LineDiff(old: 2..<6, new: 2..<6, changed: 5..<6))
        // Only the delimiter line differs when an alignment changes.
        #expect(diff(table, table.replacingOccurrences(of: "|---|---|", with: "|:--|--:|")) == LineDiff(old: 2..<6, new: 2..<6, changed: 3..<4))
        #expect(diff(table, table.replacingOccurrences(of: "outro", with: "outro!")) == LineDiff(old: 7..<8, new: 7..<8))
    }

    /// A deleted row leaves no line of its own, but the rows that remain share its column geometry.
    /// `changed` is what differs itself, which is no line at all where one was deleted.
    @Test func deletingATableRowCoversTheRemainingTable() {
        let table = "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n| wide wide wide | 4 |\n| 5 | 6 |\n\noutro\n"
        #expect(diff(table, table.replacingOccurrences(of: "| wide wide wide | 4 |\n", with: "")) == LineDiff(old: 2..<7, new: 2..<6, changed: 5..<5))
        #expect(diff(table, table.replacingOccurrences(of: "| 5 | 6 |\n", with: "")) == LineDiff(old: 2..<7, new: 2..<6, changed: 6..<6))
        // The row becomes a blank line, which ends the table there.
        #expect(diff(table, table.replacingOccurrences(of: "| wide wide wide | 4 |", with: "")) == LineDiff(old: 2..<7, new: 2..<7, changed: 5..<7))
        // Undoing the deletion.
        #expect(diff(table.replacingOccurrences(of: "| wide wide wide | 4 |\n", with: ""), table) == LineDiff(old: 2..<6, new: 2..<7, changed: 5..<6))

        let leading = "| a | b |\n|---|---|\n| 1 | 2 |\n| 333333 | 4 |\n| 5 | 6 |\n\nend\n"
        #expect(diff(leading, leading.replacingOccurrences(of: "| 333333 | 4 |\n", with: "")) == LineDiff(old: 0..<5, new: 0..<4, changed: 3..<3))
        #expect(diff(leading, leading.replacingOccurrences(of: "| 5 | 6 |\n", with: "")) == LineDiff(old: 0..<5, new: 0..<4, changed: 4..<4))
        // Away from a table an empty span stays empty.
        #expect(diff(leading, leading.replacingOccurrences(of: "end\n", with: "")) == LineDiff(old: 6..<7, new: 6..<6))
    }

    @Test func shiftedLinesCompareEqual() {
        let map = MarkdownStyler.style("- [x] a **b** [l](u \"t\")\n| a | `b` |\n|---|---|\n# H #\n")
        for line in map.lines {
            #expect(line.shifted(by: 0) == line)
            #expect(line.shifted(by: 7) != line)
            #expect(line.shifted(by: 7).shifted(by: -7) == line)
        }
        let shifted = MarkdownStyler.style("1234567\n- [x] a **b** [l](u \"t\")\n| a | `b` |\n|---|---|\n# H #\n")
        // The table is a paragraph continuation in neither text, so the lines line up one to one.
        #expect(map.lines[0].shifted(by: 8) == shifted.lines[1])
    }

    @Test func lineLookupByStart() {
        let map = MarkdownStyler.style("a\nbb\n\nccc")
        #expect([0, 2, 5, 6].map(map.lineIndex(startingAt:)) == [0, 1, 2, 3])
        #expect(map.lineIndex(startingAt: 1) == nil)
        #expect(map.lineIndex(startingAt: 9) == nil)
    }
}
