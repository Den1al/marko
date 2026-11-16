import Foundation

public enum TableCommand: CaseIterable, Sendable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight, deleteRow, deleteColumn
    case alignLeft, alignCenter, alignRight, alignNone
}

/// Table editing as string transforms that leave the rest of the table's source as the user wrote
/// it: the menu commands, and what Tab, Shift-Tab, Return, "|", Backspace and Delete do in a cell.
/// Like `InputRules`, each is a pure function of the text, its style map and the selection, and nil
/// means there is nothing to do. They act on regular tables only (`StyleMap.isRegular`).
public enum TableEdits {
    public static func edit(_ command: TableCommand, in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let table = Table(text, map, selection) else { return nil }
        switch command {
        case .insertRowAbove: return table.isBodyRow ? table.insertingRow(before: table.index) : nil
        case .insertRowBelow: return table.insertingRow(after: max(table.index, table.delimiter), caretColumn: table.column)
        case .insertColumnLeft: return table.insertingColumn(afterPipe: table.column)
        case .insertColumnRight: return table.insertingColumn(afterPipe: table.column + 1)
        case .deleteRow: return table.deletingRow()
        case .deleteColumn: return table.deletingColumn()
        case .alignLeft: return table.aligning(.left)
        case .alignCenter: return table.aligning(.center)
        case .alignRight: return table.aligning(.right)
        case .alignNone: return table.aligning(.none)
        }
    }

    /// Tab: selects the next cell's content; from the last cell it adds a row.
    public static func nextCell(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let table = Table(text, map, selection, inRow: true) else { return nil }
        if table.column + 1 < table.row.cells.count { return table.selecting(table.index, table.column + 1) }
        guard let next = table.row(after: table.index) else {
            return table.insertingRow(after: max(table.index, table.delimiter), caretColumn: 0)
        }
        return table.selecting(next, 0)
    }

    /// Shift-Tab: selects the previous cell's content; in the first cell it stays there.
    public static func previousCell(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let table = Table(text, map, selection, inRow: true) else { return nil }
        if table.column > 0 { return table.selecting(table.index, table.column - 1) }
        guard table.isBodyRow else { return table.selecting(table.index, 0) }
        let previous = table.index - 1 == table.delimiter ? table.header : table.index - 1
        return table.selecting(previous, max(0, table.map.lines[previous].cells.count - 1))
    }

    /// Return: selects the content of the cell below; below the last row it adds one, and from a
    /// last row that is empty it leaves the table. At the very start of a table that starts the
    /// text it opens a line above, which nothing else could.
    public static func newline(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let table = Table(text, map, selection, inRow: true) else { return nil }
        if table.index == 0, selection.length == 0, selection.location <= table.row.pipes[0] + 1 {
            let start = NSMaxRange(table.row.prefixRange)
            return TextEdit(range: NSRange(location: start, length: 0), replacement: table.line.newline + table.line.continuation(startsItem: false),
                            selection: NSRange(location: start, length: 0))
        }
        guard let next = table.row(after: table.index) else {
            if table.isBodyRow, table.row.cells.allSatisfy({ $0.contentRange.length == 0 }) { return table.leaving() }
            return table.insertingRow(after: max(table.index, table.delimiter), caretColumn: table.column)
        }
        return table.selecting(next, table.column)
    }

    /// A typed "|" in a cell: escaped, so that it stays text of the cell.
    public static func pipe(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let table = Table(text, map, selection, inRow: true),
              table.row.cells.contains(where: { $0.range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.range) }),
              table.text.character(at: selection.location - 1) != 0x5C else { return nil }
        return TextEdit(range: selection, replacement: "\\|", selection: NSRange(location: selection.location + 2, length: 0))
    }

    /// Text typed on the line directly below a table would be read as one more row of it, so a
    /// blank line goes between them.
    public static func textBelow(_ typed: String, in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        let source = text as NSString
        guard NSMaxRange(selection) <= source.length else { return nil }
        let start = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let contentEnd = source.lineContentEnd(at: selection.location)
        // The line above is looked up, because an empty last line has no entry in the map.
        guard start > 0, NSMaxRange(selection) <= contentEnd, let above = Line(text, map, at: start - 1),
              let table = map.table(atLine: above.index), map.isRegular(table) else { return nil }
        let prefix = above.continuation(startsItem: false)
        let blanks = CharacterSet.whitespaces
        guard source.substring(with: NSRange(location: start, length: contentEnd - start)).trimmingCharacters(in: blanks)
                == prefix.trimmingCharacters(in: blanks) else { return nil }
        let insertion = above.newline + prefix + typed
        return TextEdit(range: selection, replacement: insertion,
                        selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }

    /// Backspace and Delete on the blank line between a table and the text below it do not delete
    /// it: that text would become a row. Backspace goes to the end of the table's last cell instead.
    public static func separatorDelete(forward: Bool, in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let line = Line(text, map, at: selection.location), line.index > 0,
              line.isBlank(line.contentStart..<line.contentEnd), let next = line.next, next.kind != .blank,
              let table = map.table(atLine: line.index - 1), map.isRegular(table), let above = Line(text, map, at: line.start - 1) else {
            return nil
        }
        // A table without rows ends with its delimiter line, which is no place for the caret.
        let row = above.style
        guard !forward, case .tableRow = row.kind else { return TextEdit(range: selection, replacement: "", selection: selection) }
        let end = row.cells.count < row.pipes.count ? row.pipes[row.pipes.count - 1] : above.contentEnd
        return TextEdit(range: selection, replacement: "", selection: NSRange(location: end, length: 0))
    }

    /// Backspace behind a pipe or at the start of a row below the header does nothing: it would
    /// join two cells or two rows. Behind or inside an escaped pipe it deletes both characters:
    /// either one left alone would change the cells.
    public static func deleteBackward(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let table = Table(text, map, selection, inRow: true) else { return nil }
        if let escape = [selection.location - 2, selection.location - 1].first(where: table.isEscapedPipe) {
            return TextEdit(range: NSRange(location: escape, length: 2), replacement: "", selection: NSRange(location: escape, length: 0))
        }
        guard table.row.pipes.contains(selection.location - 1)
                || table.isBodyRow && selection.location <= NSMaxRange(table.row.prefixRange) else { return nil }
        return TextEdit(range: selection, replacement: "", selection: selection)
    }

    /// Forward Delete in front of a pipe or at the end of a row does nothing; in front of or inside
    /// an escaped pipe it deletes both characters.
    public static func deleteForward(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let table = Table(text, map, selection, inRow: true) else { return nil }
        if let escape = [selection.location, selection.location - 1].first(where: table.isEscapedPipe) {
            return TextEdit(range: NSRange(location: escape, length: 2), replacement: "", selection: NSRange(location: escape, length: 0))
        }
        guard table.row.pipes.contains(selection.location) || selection.location == table.line.contentEnd else { return nil }
        return TextEdit(range: selection, replacement: "", selection: selection)
    }
}

/// The regular table that holds the whole selection on one of its lines.
private struct Table {
    let line: Line
    let style: TableStyle
    let selection: NSRange

    /// With `inRow` the line must be a header or body row, not the delimiter line.
    init?(_ source: String, _ map: StyleMap, _ selection: NSRange, inRow: Bool = false) {
        guard let line = Line(source, map, at: selection.location), NSMaxRange(selection) <= line.contentEnd,
              let style = map.table(atLine: line.index), map.isRegular(style),
              !inRow || line.index != style.lines.lowerBound + 1 else { return nil }
        self.line = line
        self.style = style
        self.selection = selection
    }

    var text: NSString { line.text }
    var map: StyleMap { line.map }
    var index: Int { line.index }
    var row: LineStyle { line.style }
    var header: Int { style.lines.lowerBound }
    var delimiter: Int { header + 1 }
    var columns: Int { style.alignments.count }
    var isBodyRow: Bool { index > delimiter }

    /// The column the selection starts in. Before the leading pipe that is the first, behind the last pipe the last.
    var column: Int {
        min(max(row.pipes.count { $0 < selection.location } - 1, 0), columns - 1)
    }

    /// The row below `index`, the delimiter line not counted.
    func row(after index: Int) -> Int? {
        let next = index + 1 == delimiter ? index + 2 : index + 1
        return next < style.lines.upperBound ? next : nil
    }

    private func contentEnd(_ index: Int) -> Int {
        text.lineContentEnd(at: map.lines[index].range.location)
    }

    /// Whether a backslash at `offset` in the row escapes a pipe behind it.
    func isEscapedPipe(_ offset: Int) -> Bool {
        offset > row.pipes[0] && offset + 1 < line.contentEnd && text.character(at: offset) == 0x5C && text.character(at: offset + 1) == 0x7C
    }

    /// What to select in a cell: its content, or in an empty cell the place behind its first space.
    /// A row too short to have the cell gives its end.
    private func cell(_ index: Int, _ column: Int) -> NSRange {
        let cells = map.lines[index].cells
        guard column < cells.count else { return NSRange(location: contentEnd(index), length: 0) }
        let cell = cells[column]
        return cell.contentRange.length > 0 ? cell.contentRange
            : NSRange(location: cell.range.location + min(1, cell.range.length), length: 0)
    }

    func selecting(_ index: Int, _ column: Int) -> TextEdit {
        TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: cell(index, column))
    }

    // MARK: rows

    private var blankRow: String { line.blankRow(columns: columns) }

    private func caret(inBlankRowAt location: Int, column: Int) -> NSRange {
        NSRange(location: location + line.caretOffset(inBlankRowColumn: column), length: 0)
    }

    func insertingRow(before index: Int) -> TextEdit {
        let start = map.lines[index].range.location
        return TextEdit(range: NSRange(location: start, length: 0), replacement: blankRow + line.newline,
                        selection: caret(inBlankRowAt: start, column: column))
    }

    func insertingRow(after index: Int, caretColumn: Int) -> TextEdit {
        let end = contentEnd(index)
        return TextEdit(range: NSRange(location: end, length: 0), replacement: line.newline + blankRow,
                        selection: caret(inBlankRowAt: end + (line.newline as NSString).length, column: caretColumn))
    }

    /// Turns the row into a blank line and puts the caret on a new line below it.
    func leaving() -> TextEdit {
        let start = NSMaxRange(row.prefixRange)
        let insertion = line.newline + line.continuation(startsItem: false)
        return TextEdit(range: NSRange(location: start, length: line.contentEnd - start), replacement: insertion,
                        selection: NSRange(location: start + (insertion as NSString).length, length: 0))
    }

    func deletingRow() -> TextEdit? {
        guard isBodyRow else { return nil }
        if let next = row(after: index) {
            return TextEdit(range: row.range, replacement: "",
                            selection: NSRange(location: cell(next, column).location - row.range.length, length: 0))
        }
        // The last row goes with the line break before it, so the table keeps its own ending.
        let previous = index - 1 == delimiter ? header : index - 1
        let start = contentEnd(index - 1)
        return TextEdit(range: NSRange(location: start, length: line.contentEnd - start), replacement: "",
                        selection: NSRange(location: cell(previous, column).location, length: 0))
    }

    // MARK: columns

    /// Several replacements, on different lines of the table, as one edit. `caret` is where the
    /// caret would be in the text as it is; text put in there goes behind it.
    private func combined(_ edits: [(range: NSRange, text: String)], caret: Int) -> TextEdit? {
        TextEdit.combining(edits.map { Change(range: $0.range, text: $0.text, pushes: false) }, in: text, selection: NSRange(location: caret, length: 0))
    }

    /// A new column behind each line's pipe number `pipe`. A row that is too short to reach it stays as it is.
    func insertingColumn(afterPipe pipe: Int) -> TextEdit? {
        let rule = map.lines[delimiter].pipes
        let neighbour = min(pipe, columns - 1)
        let dashes = text.substring(with: NSRange(location: rule[neighbour] + 1, length: rule[neighbour + 1] - rule[neighbour] - 1))
            .replacingOccurrences(of: ":", with: "-")
        let blank = String(repeating: " ", count: (dashes as NSString).length)
        let edits = style.lines.compactMap { index -> (range: NSRange, text: String)? in
            let pipes = map.lines[index].pipes
            guard pipe < pipes.count else { return nil }
            return (NSRange(location: pipes[pipe] + 1, length: 0), (index == delimiter ? dashes : blank) + "|")
        }
        // Behind the new cell's first space, when the caret's own line got one.
        let isInNewCell = index != delimiter && pipe < row.pipes.count
        return combined(edits, caret: isInNewCell ? row.pipes[pipe] + 1 : selection.location).map {
            var edit = $0
            if isInNewCell { edit.selection.location += min(1, (blank as NSString).length) }
            return edit
        }
    }

    func deletingColumn() -> TextEdit? {
        guard columns > 1 else { return nil }
        let column = column
        let edits = style.lines.compactMap { index -> (range: NSRange, text: String)? in
            let pipes = map.lines[index].pipes
            guard column < pipes.count else { return nil }
            // The cell with the pipe that closes it, or what there is of a last cell left open. A row
            // whose only cell it is keeps an empty one: a pipe alone is not a row.
            let end = column + 1 < pipes.count ? pipes[column + 1] + 1 : contentEnd(index)
            let isOnlyCell = index != delimiter && column == 0 && map.lines[index].cells.count == 1
            return (NSRange(location: pipes[column] + 1, length: end - pipes[column] - 1), isOnlyCell ? Line.blankCell : "")
        }
        let neighbour = column + 1 < row.cells.count ? column + 1 : column - 1
        if index == delimiter { return combined(edits, caret: selection.location) }
        // In a row left with an empty cell the caret goes to that cell's start.
        return combined(edits, caret: neighbour < 0 ? row.pipes[0] + 1 : cell(index, neighbour).location)
    }

    /// Rewrites the column's delimiter cell, keeping its length where the colons fit and its padding.
    func aligning(_ alignment: ColumnAlignment) -> TextEdit? {
        guard style.alignments[column] != alignment else { return nil }
        let pipes = map.lines[delimiter].pipes
        var start = pipes[column] + 1, end = pipes[column + 1]
        while start < end, line.isBlank(start..<start + 1) { start += 1 }
        while end > start, line.isBlank(end - 1..<end) { end -= 1 }
        let left = alignment == .left || alignment == .center, right = alignment == .right || alignment == .center
        let dashes = String(repeating: "-", count: max(1, end - start - (left ? 1 : 0) - (right ? 1 : 0)))
        return combined([(NSRange(location: start, length: end - start), (left ? ":" : "") + dashes + (right ? ":" : ""))],
                        caret: selection.location).map {
            var edit = $0
            edit.selection.length = selection.length
            return edit
        }
    }
}
