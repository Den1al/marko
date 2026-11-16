import Foundation
import Testing
@testable import MarkoCore

@Suite struct TableEditsTests {
    typealias Rule = (String, StyleMap, NSRange) -> TextEdit?

    /// Applies `rule` to `marked`, where "¦" stands for the caret or, twice, for the ends of the
    /// selection, and returns the result in the same notation; nil when the rule does nothing.
    private func apply(_ rule: Rule, _ marked: String) -> String? {
        let parts = marked.components(separatedBy: "¦")
        let text = parts.joined()
        let start = (parts[0] as NSString).length
        let selection = NSRange(location: start, length: parts.count > 2 ? (parts[1] as NSString).length : 0)
        guard let edit = rule(text, MarkdownStyler.style(text), selection) else { return nil }
        let result = NSMutableString(string: (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
        if edit.selection.length > 0 { result.insert("¦", at: NSMaxRange(edit.selection)) }
        result.insert("¦", at: edit.selection.location)
        return result as String
    }

    private func command(_ command: TableCommand) -> Rule {
        { TableEdits.edit(command, in: $0, map: $1, selection: $2) }
    }

    private let tab: Rule = { TableEdits.nextCell(in: $0, map: $1, selection: $2) }
    private let backtab: Rule = { TableEdits.previousCell(in: $0, map: $1, selection: $2) }
    private let newline: Rule = { TableEdits.newline(in: $0, map: $1, selection: $2) }
    private let pipe: Rule = { TableEdits.pipe(in: $0, map: $1, selection: $2) }
    private let backspace: Rule = { TableEdits.deleteBackward(in: $0, map: $1, selection: $2) }
    private let delete: Rule = { TableEdits.deleteForward(in: $0, map: $1, selection: $2) }
    private let paragraphReturn: Rule = { InputRules.newline(in: $0, map: $1, selection: $2) }

    private let table = "| a | b |\n|---|:-:|\n| c | d |\n| e | f |\n"

    private func mark(_ text: String, before: String) -> String {
        text.replacingOccurrences(of: before, with: "¦" + before)
    }

    // MARK: keys

    @Test func tabSelectsTheNextCellAndSkipsTheDelimiterRow() {
        #expect(apply(tab, mark(table, before: "a |")) == "| a | ¦b¦ |\n|---|:-:|\n| c | d |\n| e | f |\n")
        #expect(apply(tab, mark(table, before: "b |")) == "| a | b |\n|---|:-:|\n| ¦c¦ | d |\n| e | f |\n")
        #expect(apply(tab, mark(table, before: "d |")) == "| a | b |\n|---|:-:|\n| c | d |\n| ¦e¦ | f |\n")
        #expect(apply(tab, "| a | b |¦\n|---|---|\n| c | d |\n") == "| a | b |\n|---|---|\n| ¦c¦ | d |\n", "behind the last pipe")
        #expect(apply(tab, "| a | b |\n|---|---|\n| ¦c |    |\n") == "| a | b |\n|---|---|\n| c | ¦   |\n", "an empty cell gets a caret")
        #expect(apply(tab, "| a | b |\n|---|---|\n|¦c||\n") == "| a | b |\n|---|---|\n|c|¦|\n")
    }

    @Test func tabInTheLastCellAppendsARow() {
        #expect(apply(tab, mark(table, before: "f |")) == "| a | b |\n|---|:-:|\n| c | d |\n| e | f |\n| ¦ |  |\n")
        #expect(apply(tab, "| a | b |\n|---|---|\n| c | d¦ |") == "| a | b |\n|---|---|\n| c | d |\n| ¦ |  |")
        #expect(apply(tab, "| a | b¦ |\n|---|---|\n") == "| a | b |\n|---|---|\n| ¦ |  |\n", "a table without rows")
        #expect(apply(tab, "| a | b |\r\n|---|---|\r\n| c | d¦ |\r\n") == "| a | b |\r\n|---|---|\r\n| c | d |\r\n| ¦ |  |\r\n")
        #expect(apply(tab, "| a | b |\n|---|---|\n| only¦ |\n") == "| a | b |\n|---|---|\n| only |\n| ¦ |  |\n", "a short row")
        #expect(apply(tab, "> | a | b |\n> |---|---|\n> | c | d¦ |\n") == "> | a | b |\n> |---|---|\n> | c | d |\n> | ¦ |  |\n")
        #expect(apply(tab, "- | a | b |\n  |---|---|\n  | c | d¦ |\n") == "- | a | b |\n  |---|---|\n  | c | d |\n  | ¦ |  |\n")
    }

    @Test func shiftTabSelectsThePreviousCell() {
        #expect(apply(backtab, mark(table, before: "f |")) == "| a | b |\n|---|:-:|\n| c | d |\n| ¦e¦ | f |\n")
        #expect(apply(backtab, mark(table, before: "e |")) == "| a | b |\n|---|:-:|\n| c | ¦d¦ |\n| e | f |\n")
        #expect(apply(backtab, mark(table, before: "c |")) == "| a | ¦b¦ |\n|---|:-:|\n| c | d |\n| e | f |\n")
        #expect(apply(backtab, mark(table, before: "a |")) == "| ¦a¦ | b |\n|---|:-:|\n| c | d |\n| e | f |\n", "the first cell stays")
    }

    @Test func returnMovesToTheCellBelow() {
        #expect(apply(newline, mark(table, before: "b |")) == "| a | b |\n|---|:-:|\n| c | ¦d¦ |\n| e | f |\n")
        #expect(apply(newline, mark(table, before: "c |")) == "| a | b |\n|---|:-:|\n| c | d |\n| ¦e¦ | f |\n")
        #expect(apply(newline, mark(table, before: "f |")) == "| a | b |\n|---|:-:|\n| c | d |\n| e | f |\n|  | ¦ |\n")
        #expect(apply(newline, "| a | b¦ |\n|---|---|") == "| a | b |\n|---|---|\n|  | ¦ |")
        #expect(apply(newline, "x\n\n|¦ a | b |\n|---|---|\n| c | d |\n") == "x\n\n| a | b |\n|---|---|\n| ¦c¦ | d |\n")
        #expect(apply(newline, "| a | b |\n|---|---|\n¦| c | d |\n| e | f |\n") == "| a | b |\n|---|---|\n| c | d |\n| ¦e¦ | f |\n")
        #expect(apply(newline, "| a | b |\n|---|---|\n| c | ¦d |\n| short |\n") == "| a | b |\n|---|---|\n| c | d |\n| short |¦\n")
    }

    @Test func returnAtTheStartOfATableThatStartsTheTextOpensALineAbove() {
        #expect(apply(newline, "|¦ a | b |\n|---|---|\n| c | d |\n") == "¦\n| a | b |\n|---|---|\n| c | d |\n")
        #expect(apply(newline, "¦| a | b |\n|---|---|\n| c | d |\n") == "¦\n| a | b |\n|---|---|\n| c | d |\n")
        #expect(apply(newline, "> |¦ a |\r\n> |---|\r\n") == "> ¦\r\n> | a |\r\n> |---|\r\n")
        #expect(apply(newline, "| ¦a | b |\n|---|---|\n| c | d |\n") == "| a | b |\n|---|---|\n| ¦c¦ | d |\n", "inside the cell it moves down")
        let opened = "top\n| a | b |\n|---|---|\n| c | d |\n", map = MarkdownStyler.style(opened)
        #expect(map.tables.first.map(map.isRegular) == true, "text typed on the new line leaves the table whole")
    }

    @Test func theBlankLineBetweenATableAndTextBelowIsNotDeleted() {
        let backspace: Rule = { TableEdits.separatorDelete(forward: false, in: $0, map: $1, selection: $2) }
        let delete: Rule = { TableEdits.separatorDelete(forward: true, in: $0, map: $1, selection: $2) }
        #expect(apply(backspace, "| a | b |\n|---|---|\n| c | d |\n¦\nend") == "| a | b |\n|---|---|\n| c | d ¦|\n\nend", "the caret goes into the last cell")
        #expect(apply(delete, "| a | b |\n|---|---|\n| c | d |\n¦\nend") == "| a | b |\n|---|---|\n| c | d |\n¦\nend")
        #expect(apply(backspace, "| a | b |\n|---|---|\n| c | d\n¦\nend") == "| a | b |\n|---|---|\n| c | d¦\n\nend", "a last cell left open")
        #expect(apply(backspace, "> | a |\n> |---|\n> ¦\n> end\n") == "> | a |\n> |---|\n> ¦\n> end\n")
        for source in ["| a | b |\n|---|---|\n| c | d |\n¦\n\nend", "| a | b |\n|---|---|\n| c | d |\n¦\n", "| a | b |\n|---|---|\n| c | d |\n¦",
                       "text\n¦\nend", "a | b\n--|--\nc | d\n¦\nend", "| a | b |\n|---|---|\n| c | d |\n\n¦\nend"] {
            #expect(apply(backspace, source) == nil && apply(delete, source) == nil, "\(source)")
        }
    }

    @Test func returnOnAnEmptyLastRowLeavesTheTable() {
        #expect(apply(newline, "| a | b |\n|---|---|\n| c | d |\n| ¦  |   |\n") == "| a | b |\n|---|---|\n| c | d |\n\n¦\n")
        #expect(apply(newline, "| a | b |\r\n|---|---|\r\n|  | ¦ |") == "| a | b |\r\n|---|---|\r\n\r\n¦")
        #expect(apply(newline, "> | a |\n> |---|\n> | ¦  |\n") == "> | a |\n> |---|\n> \n> ¦\n")
        #expect(apply(newline, "| a | b |\n|---|---|\n| ¦  |   |\n| c | d |\n") == "| a | b |\n|---|---|\n|   |   |\n| ¦c¦ | d |\n", "not the last row")
        let left = MarkdownStyler.style("| a | b |\n|---|---|\n| c | d |\n\nx\n")
        #expect(left.tables.map(\.lines) == [0..<3] && left.lines[4].kind == .paragraph)
    }

    @Test func textTypedDirectlyBelowATableGetsABlankLineBetween() {
        let below: (String) -> Rule = { typed in { TableEdits.textBelow(typed, in: $0, map: $1, selection: $2) } }
        #expect(apply(below("x"), "| a |\n|---|\n| c |\n¦") == "| a |\n|---|\n| c |\n\nx¦")
        #expect(apply(below("x"), "| a |\r\n|---|\r\n| c |\r\n¦\r\nnext") == "| a |\r\n|---|\r\n| c |\r\n\r\nx¦\r\nnext")
        #expect(apply(below("x"), "> | a |\n> |---|\n> ¦") == "> | a |\n> |---|\n> \n> x¦")
        #expect(apply(below("x"), "| a |\n|---|\n| c |\n\n¦") == nil, "already separated")
        #expect(apply(below("x"), "| a |\n|---|\n| c¦ |\n") == nil)
        #expect(apply(below("x"), "a | b\n--- | ---\n¦") == nil, "not a table that shows as one")
        #expect(MarkdownStyler.style("| a |\n|---|\n| c |\nx").tables.map(\.lines) == [0..<4], "without it the text is a row")
    }

    @Test func aTypedPipeIsEscapedInsideACell() {
        #expect(apply(pipe, mark(table, before: "c |")) == "| a | b |\n|---|:-:|\n| \\|¦c | d |\n| e | f |\n")
        #expect(apply(pipe, "| a | b |\n|---|---|\n| c¦ | d |") == "| a | b |\n|---|---|\n| c\\|¦ | d |")
        #expect(apply(pipe, "| a | b |\n|---|---|\n| ¦c¦ | d |") == "| a | b |\n|---|---|\n| \\|¦ | d |", "a selection is replaced")
        #expect(apply(pipe, "| a | b |\n|---|---|\n| c\\¦ | d |") == nil, "escaped by hand")
        #expect(apply(pipe, "¦| a | b |\n|---|---|\n| c | d |") == nil, "before the leading pipe")
        #expect(apply(pipe, "| a | b |\n|---|---|\n| c | d |¦") == nil, "behind the last pipe")
        #expect(apply(pipe, "| a | b |\n|--¦-|---|\n| c | d |") == nil, "the delimiter row")
        #expect(apply(pipe, "text ¦\n") == nil)
        let escaped = "| a | b |\n|---|---|\n| c\\| | d |"
        #expect(MarkdownStyler.style(escaped).lines[2].cells.count == 2, "the column count is kept")
    }

    @Test func backspaceAndDeleteDoNothingAtCellAndRowEdges() {
        #expect(apply(backspace, mark(table, before: "| c")) == mark(table, before: "| c"), "a row start")
        #expect(apply(backspace, mark(table, before: " c |")) == mark(table, before: " c |"), "behind the leading pipe")
        #expect(apply(backspace, mark(table, before: " d |")) == mark(table, before: " d |"), "behind an inner pipe")
        #expect(apply(backspace, mark(table, before: "c |")) == nil, "inside a cell")
        #expect(apply(backspace, "> | a |\n> |---|\n> ¦| c |\n") == "> | a |\n> |---|\n> ¦| c |\n", "behind a row's quote marker")
        #expect(apply(backspace, "x\n\n¦| a |\n|---|\n| c |\n") == nil, "the header row can be joined to what is above")
        #expect(apply(backspace, "| a |\n|---|\n| ¦c¦ |\n") == nil, "a selection is deleted")
        #expect(apply(delete, "| a | b |\n|---|---|\n| c | d |¦\n| e | f |\n") == "| a | b |\n|---|---|\n| c | d |¦\n| e | f |\n", "a row end")
        #expect(apply(delete, "| a | b |¦\n|---|---|\n") == "| a | b |¦\n|---|---|\n")
        #expect(apply(delete, mark(table, before: "| d")) == mark(table, before: "| d"), "in front of a pipe")
        #expect(apply(delete, mark(table, before: "c |")) == nil)
    }

    @Test func anEscapedPipeIsDeletedWhole() {
        #expect(apply(backspace, "|x|a\\|¦|\n|-|-|\n|c|d|\n") == "|x|a¦|\n|-|-|\n|c|d|\n", "behind it")
        #expect(apply(backspace, "| x | a\\¦|b |\n|---|---|\n| c | d |") == "| x | a¦b |\n|---|---|\n| c | d |", "inside it")
        #expect(apply(delete, "| x | a¦\\|b |\n|---|---|\n| c | d |") == "| x | a¦b |\n|---|---|\n| c | d |", "in front of it")
        #expect(apply(delete, "| x | a\\¦|b |\n|---|---|\n| c | d |") == "| x | a¦b |\n|---|---|\n| c | d |")
        // What a typed pipe put in, Backspace takes out again.
        let typed = apply(pipe, "| x | a¦ |\n|---|---|\n| c | d |")
        #expect(typed == "| x | a\\|¦ |\n|---|---|\n| c | d |" && typed.flatMap { apply(backspace, $0) } == "| x | a¦ |\n|---|---|\n| c | d |")
        #expect(apply(backspace, "| x | a\\b¦ |\n|---|---|\n| c | d |") == nil, "a backslash before anything else is text")
    }

    @Test func appendedRowsDoNotGrowWithTheCellsAboveThem() {
        // A cell's blanks count towards its column's width, so a new row has no more than it needs.
        let link = "| Name | Qty |\n|---|---|\n| [site](http://example.org/a/long/path) | 1¦ |"
        #expect(apply(tab, link) == "| Name | Qty |\n|---|---|\n| [site](http://example.org/a/long/path) | 1 |\n| ¦ |  |")
        var text = "| a | b |\n|---|---|\n| x | y¦ |"
        for _ in 0..<3 {
            text = apply(tab, text)!.replacingOccurrences(of: "| ¦ |  |", with: "| x | y¦ |")
        }
        #expect(text == "| a | b |\n|---|---|\n| x | y |\n| x | y |\n| x | y |\n| x | y¦ |")
    }

    @Test func keysLeaveIrregularTablesAndOtherLinesAlone() {
        for source in ["a | b\n--- | ---\nc¦ | d\n", "| a | b |\n|---|---|\n| c¦ | d | e |\n", "plain¦ text\n", "| a | b |\n|-¦--|---|\n| c | d |\n"] {
            for rule in [tab, backtab, newline, pipe, backspace, delete] { #expect(apply(rule, source) == nil, "\(source)") }
        }
        // A selection that runs over two rows is not one cell's.
        #expect(apply(tab, "| a | b |\n|---|---|\n| ¦c | d |\n| e¦ | f |\n") == nil)
        // A map that is not the text's.
        #expect(TableEdits.nextCell(in: table + "x", map: MarkdownStyler.style(table), selection: NSRange(location: 3, length: 0)) == nil)
    }

    // MARK: starting a table

    @Test func returnAfterAHeaderRowAddsTheDelimiterRowAndAnEmptyRow() {
        #expect(apply(paragraphReturn, "|a|b|¦") == "|a|b|\n|---|---|\n| ¦ |  |")
        #expect(apply(paragraphReturn, "| Name | Value |¦\n") == "| Name | Value |\n| ---- | ----- |\n| ¦ |  |\n")
        #expect(apply(paragraphReturn, "| a | b |¦  \r\n\r\nnext") == "| a | b |\r\n| --- | --- |\r\n| ¦ |  |\r\n\r\nnext")
        #expect(apply(paragraphReturn, "> |a|b|¦\n") == "> |a|b|\n> |---|---|\n> | ¦ |  |\n")
        #expect(apply(paragraphReturn, "- |a|b|¦\n") == "- |a|b|\n  |---|---|\n  | ¦ |  |\n")
        #expect(apply(paragraphReturn, "|a|¦") == nil, "one cell is not enough")
        #expect(apply(paragraphReturn, "|a|b¦|") == nil, "the caret is not at the end")
        #expect(apply(paragraphReturn, "|a|b| c¦") == nil)
        #expect(apply(paragraphReturn, "a|b|c|¦") == nil)
        #expect(apply(paragraphReturn, "|a\\|b|¦") == nil, "an escaped pipe does not count")
        for result in ["|a|b|\n|---|---|\n|  |  |", "| Name | Value |\n| ---- | ----- |\n|      |       |\n"] {
            let map = MarkdownStyler.style(result)
            #expect(map.tables.count == 1 && map.isRegular(map.tables[0]), "the result is a table")
        }
    }

    // MARK: commands

    @Test func rowsAreInsertedAboveAndBelow() {
        #expect(apply(command(.insertRowBelow), mark(table, before: "d |")) == "| a | b |\n|---|:-:|\n| c | d |\n|  | ¦ |\n| e | f |\n")
        #expect(apply(command(.insertRowAbove), mark(table, before: "d |")) == "| a | b |\n|---|:-:|\n|  | ¦ |\n| c | d |\n| e | f |\n")
        #expect(apply(command(.insertRowBelow), mark(table, before: "a |")) == "| a | b |\n|---|:-:|\n| ¦ |  |\n| c | d |\n| e | f |\n")
        #expect(apply(command(.insertRowAbove), mark(table, before: "a |")) == nil, "nothing goes above the header")
        #expect(apply(command(.insertRowBelow), "| a | b |\n|-¦--|---|") == "| a | b |\n|---|---|\n| ¦ |  |")
        #expect(apply(command(.insertRowBelow), "|  wide cell  | b |\n|---|---|\n|x|¦y|\r\n") == "|  wide cell  | b |\n|---|---|\n|x|y|\r\n|  | ¦ |\r\n")
        #expect(apply(command(.insertRowAbove), "> | a |\n> |---|\n> | ¦c |\n") == "> | a |\n> |---|\n> | ¦ |\n> | c |\n")
    }

    @Test func rowsAreDeleted() {
        #expect(apply(command(.deleteRow), mark(table, before: "d |")) == "| a | b |\n|---|:-:|\n| e | ¦f |\n")
        #expect(apply(command(.deleteRow), mark(table, before: "f |")) == "| a | b |\n|---|:-:|\n| c | ¦d |\n")
        #expect(apply(command(.deleteRow), "| a | b |\n|---|---|\n| c | ¦d |") == "| a | ¦b |\n|---|---|")
        #expect(apply(command(.deleteRow), "| a | b |\r\n|---|---|\r\n| c | ¦d |\r\n\r\nx") == "| a | ¦b |\r\n|---|---|\r\n\r\nx")
        #expect(apply(command(.deleteRow), mark(table, before: "a |")) == nil, "the header stays")
        #expect(apply(command(.deleteRow), "| a | b |\n|-¦--|---|\n| c | d |") == nil)
    }

    @Test func columnsAreInsertedLeftAndRightKeepingTheSpacing() {
        #expect(apply(command(.insertColumnLeft), mark(table, before: "d |"))
            == "| a |   | b |\n|---|---|:-:|\n| c | ¦  | d |\n| e |   | f |\n")
        #expect(apply(command(.insertColumnRight), mark(table, before: "d |"))
            == "| a | b |   |\n|---|:-:|---|\n| c | d | ¦  |\n| e | f |   |\n")
        #expect(apply(command(.insertColumnLeft), mark(table, before: "a |"))
            == "|   | a | b |\n|---|---|:-:|\n|   | c | d |\n|   | e | f |\n".replacingOccurrences(of: "|   | a", with: "| ¦  | a"))
        let padded = "| Name   | Qty |\r\n| :----- | --: |\r\n| apple  | ¦3   |\r\n| only |\r\n| open | 1\r\n"
        #expect(apply(command(.insertColumnLeft), padded)
            == "| Name   |     | Qty |\r\n| :----- | --- | --: |\r\n| apple  | ¦    | 3   |\r\n| only |     |\r\n| open |     | 1\r\n")
        #expect(apply(command(.insertColumnRight), padded)
            == "| Name   | Qty |     |\r\n| :----- | --: | --- |\r\n| apple  | 3   | ¦    |\r\n| only |\r\n| open | 1\r\n")
        #expect(apply(command(.insertColumnRight), "> | a |\n> |---|\n> | ¦c |\n") == "> | a |   |\n> |---|---|\n> | c | ¦  |\n")
    }

    @Test func columnsAreDeleted() {
        #expect(apply(command(.deleteColumn), mark(table, before: "c |")) == "| b |\n|:-:|\n| ¦d |\n| f |\n")
        #expect(apply(command(.deleteColumn), mark(table, before: "d |")) == "| a |\n|---|\n| ¦c |\n| e |\n")
        let ragged = "| a | b | c |\n|---|---|---|\n| 1 | ¦2 | 3 |\n| only |\n| x | open\n"
        #expect(apply(command(.deleteColumn), ragged) == "| a | c |\n|---|---|\n| 1 | ¦3 |\n| only |\n| x |\n")
        #expect(apply(command(.deleteColumn), "| a |\n|---|\n| ¦c |\n") == nil, "the last column stays")
        // A row whose only cell goes keeps an empty one: a pipe alone would end the table there.
        let short = "| a | b | c |\n|---|:-:|--:|\n| ¦d |\n| g | h\n| j | k | l"
        #expect(apply(command(.deleteColumn), short) == "| b | c |\n|:-:|--:|\n|¦  |\n| h\n| k | l")
        #expect(apply(command(.deleteColumn), "| a | b |\n|---|---|\n| ¦c | d |\n| open") == "| b |\n|---|\n| ¦d |\n|  |")
        let kept = MarkdownStyler.style("| b | c |\n|:-:|--:|\n|  |\n| h\n| k | l")
        #expect(kept.tables.map(\.lines) == [0..<5] && kept.isRegular(kept.tables[0]))
        let result = MarkdownStyler.style("| a | c |\n|---|---|\n| 1 | 3 |\n| only |\n| x |\n")
        #expect(result.tables.first?.alignments.count == 2 && result.isRegular(result.tables[0]))
    }

    @Test func alignmentRewritesOnlyTheDelimiterCell() {
        let source = "| a | b |\n| ----- |:-:|\n| c | ¦d¦ |\n"
        #expect(apply(command(.alignLeft), source) == "| a | b |\n| ----- |:--|\n| c | ¦d¦ |\n")
        #expect(apply(command(.alignRight), source) == "| a | b |\n| ----- |--:|\n| c | ¦d¦ |\n")
        #expect(apply(command(.alignNone), source) == "| a | b |\n| ----- |---|\n| c | ¦d¦ |\n")
        #expect(apply(command(.alignCenter), source) == nil, "already centred")
        #expect(apply(command(.alignCenter), "| ¦a | b |\n| ----- |:-:|\n| c | d |\n") == "| ¦a | b |\n| :---: |:-:|\n| c | d |\n")
        #expect(apply(command(.alignCenter), "| a |\n|-|\n| ¦c |\n") == "| a |\n|:-:|\n| ¦c |\n", "a delimiter too short for its colons grows")
        for (command, alignment) in [(TableCommand.alignLeft, ColumnAlignment.left), (.alignCenter, .center), (.alignRight, .right), (.alignNone, .none)] {
            let text = "| a | b |\n|---|--:|\n| c | d |\n"
            guard let edit = TableEdits.edit(command, in: text, map: MarkdownStyler.style(text), selection: NSRange(location: 2, length: 0)) else {
                #expect(alignment == .none)
                continue
            }
            let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            #expect(MarkdownStyler.style(result).tables.first?.alignments == [alignment, .right])
        }
    }

    @Test func commandsNeedARegularTable() {
        for source in ["plain ¦text\n", "a | b\n--- | ---\nc¦ | d\n", "| a | b |\n|---|---|\n| c¦ | d | e |\n", "| a | b |\n--- | ---\n| c¦ | d |\n"] {
            for command in TableCommand.allCases { #expect(apply(self.command(command), source) == nil, "\(command) in \(source)") }
        }
    }

    @Test func everyEditLeavesARegularTableWithTheCaretInIt() {
        let sources = [table, "| a | b |\r\n|---|:-:|\r\n| c | d |\r\n| e | f |", "| a | b | c |\n|---|:-:|--:|\n| d |\n| g | h\n| j | k | l", "> | a | b |\n> |---|:-:|\n> | c | d |\n> | e | f |\n",
                       "1. | a | b |\n   |---|:-:|\n   | c | d |\n   | e | f |\n", "| 表 | 🎉 |\n|---|---|\n| 中文 | d |\n| e | f |\n"]
        for source in sources {
            let text = source as NSString
            for location in 0...text.length {
                let selection = NSRange(location: location, length: 0)
                for command in TableCommand.allCases {
                    let map = MarkdownStyler.style(source)
                    guard let edit = TableEdits.edit(command, in: source, map: map, selection: selection) else { continue }
                    let result = text.replacingCharacters(in: edit.range, with: edit.replacement)
                    let after = MarkdownStyler.style(result)
                    #expect(after.tables.count == 1 && after.isRegular(after.tables[0]), "\(command) at \(location) in \(source)")
                    #expect(after.lineIndex(containing: edit.selection.location).flatMap { after.table(atLine: $0) } != nil,
                            "\(command) at \(location) in \(source)")
                    #expect(NSMaxRange(edit.selection) <= (result as NSString).length)
                }
            }
        }
    }
}
