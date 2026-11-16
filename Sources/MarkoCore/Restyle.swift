import Foundation
import Markdown

extension MarkdownStyler {
    /// Brings `map`, made of the text before an edit, up to date with `text` by parsing only the
    /// blocks around the edit; `editedRange` and `delta` are what the text storage reports.
    /// Returns the lines that differ, as `StyleMap.diff` would, or nil with the map as it was when
    /// only a parse of the whole text will do.
    ///
    /// The part that is parsed runs from one line that starts a block outside every list and
    /// quote, directly below a blank line, to the next such line that the edit leaves alone
    /// (`StyleMap.endsBlocks`). The parser is in the same state at such a line whatever stands
    /// above it, with these exceptions, which are all refused: a link reference definition in the
    /// part, before or after the edit; a bracket in the part that could refer to a definition
    /// elsewhere; front matter that the part could open or close; an edited line that becomes a
    /// list item or a quote; and a part that ends inside a fence or an HTML block.
    ///
    /// A part of more than `limit` UTF-16 units besides what the edit put in is refused too: one
    /// list, fence or paragraph can be as long as the text, and parsing it costs what parsing the
    /// text does, on every key in it. MEASURED: 90 ms a key in a list of 16,000 items (500 KB).
    /// What a paste brings is parsed once and does not count.
    public static func restyle(
        _ map: inout StyleMap, in text: NSString, editedRange: NSRange, changeInLength delta: Int, limit: Int = .max
    ) -> LineDiff? {
        let count = map.lines.count, editEnd = NSMaxRange(editedRange) - delta
        guard let last = map.lines.last, NSMaxRange(last.range) + delta == text.length,
              editEnd >= editedRange.location, NSMaxRange(editedRange) <= text.length,
              var firstEdited = map.lineIndex(containing: editedRange.location),
              var lastEdited = map.lineIndex(containing: editEnd) else { return nil }
        if let diff = restyleRow(&map, at: firstEdited, in: text, editedRange: editedRange, changeInLength: delta)
            ?? restyleItem(&map, at: firstEdited, in: text, editedRange: editedRange, changeInLength: delta) { return diff }
        // Text put behind a lone CR can make a CRLF of it, which changes the line above.
        if firstEdited > 0, map.lines[firstEdited].range.location == editedRange.location,
           text.character(at: editedRange.location - 1) == 0x0D { firstEdited -= 1 }

        // MEASURED: in the app the text storage reports a typed character as a change of its whole
        // line. An edit that ends with a line break, in front of a line, has left that line alone.
        let newEnd = NSMaxRange(editedRange)
        if lastEdited > firstEdited, map.lines[lastEdited].range.location == editEnd, newEnd > 0,
           text.character(at: newEnd - 1) == 0x0A
            || text.character(at: newEnd - 1) == 0x0D && (newEnd == text.length || text.character(at: newEnd) != 0x0A) {
            lastEdited -= 1
        }

        /// Whether the line at `index`, which starts at `offset` in `text`, starts a block of its own
        /// below a blank line. Not indented, so that after an edit it still belongs to nothing above;
        /// and not with a byte order mark, which the parser drops at the start of what it is given.
        func isBorder(_ index: Int, at offset: Int) -> Bool {
            map.lines[index].containers.isEmpty && map.endsBlocks(above: index)
                && offset < text.length && ![0x20, 0x09, 0x0A, 0x0D, 0xFEFF].contains(text.character(at: offset))
        }
        var first = firstEdited
        while first > 0, !isBorder(first, at: map.lines[first].range.location) { first -= 1 }
        // The blank line above the border is one the edit left alone.
        var end = lastEdited + 2
        while end < count, !isBorder(end, at: map.lines[end].range.location + delta) { end += 1 }
        end = min(end, count)

        let opensFrontMatter = text.length > 3 && text.substring(to: 3) == "---" && [0x0A, 0x0D].contains(text.character(at: 3))
        // Front matter that ended above the part is as it was; any other could be closed by the edit.
        if first > 0, opensFrontMatter, map.lines[0].kind != .source { return nil }
        // A definition that the edit may have changed or taken away gives other lines another meaning.
        if map.lines[first..<end].contains(where: \.mayDefineReference) { return nil }

        let start = map.lines[first].range.location
        let stop = end < count ? map.lines[end].range.location + delta : text.length
        guard stop - start - max(delta, 0) <= limit else { return nil }
        var source = text.substring(with: NSRange(location: start, length: stop - start))
        // A line of text below the part shows how the part ends: it is a paragraph of its own
        // unless a fence or an HTML block is still open, which would take the lines below as well.
        if end < count { source += "x" }
        var part = build(source: source, document: Document(parsing: source), isWhole: first == 0).map
        guard !part.hasReferences, !(map.hasReferences && mayRefer(part.lines, in: source)) else { return nil }
        // The edited line may have become a list item or a quote, which can belong to what is above.
        if first > 0, part.lines.first?.containers.isEmpty == false { return nil }
        if end < count {
            guard let probe = part.lines.popLast(), probe.kind == .paragraph, probe.containers.isEmpty,
                  let border = part.lines.last, border.kind == .blank, border.containers.isEmpty else { return nil }
            // Front matter that opens in the part and does not close in it closes further down.
            if first == 0, opensFrontMatter, part.lines[0].kind != .source { return nil }
        }
        for index in part.lines.indices { part.lines[index].shift(by: start) }

        let old = end - first, new = part.lines.count
        var head = 0
        while head < old, head < new, map.lines[first + head] == part.lines[head] { head += 1 }
        var tail = 0
        while tail < old - head, tail < new - head,
              map.lines[end - 1 - tail].shifted(by: delta) == part.lines[new - 1 - tail] { tail += 1 }
        var diff = LineDiff(old: first + head..<end - tail, new: first + head..<first + new - tail)
        // Lines that all came out as they were are no change, also beside a table.
        guard !(diff.old.isEmpty && diff.new.isEmpty) else { return diff }
        diff.old = map.growingToTables(diff.old)

        map.lines.replaceSubrange(first..<end, with: part.lines)
        if delta != 0 { for index in first + new..<map.lines.count { map.lines[index].shift(by: delta) } }
        func moved(_ table: TableStyle, by lines: Int) -> TableStyle {
            TableStyle(lines: table.lines.lowerBound + lines..<table.lines.upperBound + lines, alignments: table.alignments)
        }
        map.tables = map.tables.prefix { $0.lines.upperBound <= first } + part.tables.map { moved($0, by: first) }
            + map.tables.drop { $0.lines.lowerBound < end }.map { moved($0, by: new - old) }
        diff.new = map.growingToTables(diff.new)
        return diff
    }

    /// Whether one of `lines`, the styles of `source`, has a bracket that a definition elsewhere
    /// could make a link of: one that is not in code, not escaped, not an empty checkbox, and not
    /// the start of a link or image that the parser found without any definition. A checked box
    /// counts: MEASURED, with a definition "[x]: ..." in the text a line like "> - [x] done" is
    /// a link in a paragraph for the parser and comes out without containers.
    private static func mayRefer(_ lines: [LineStyle], in source: String) -> Bool {
        let units = Array(source.utf16)
        return lines.contains { line in
            switch line.kind {
            case .codeBody, .codeFence: return false
            default: break
            }
            return (line.range.location..<min(NSMaxRange(line.range), units.count)).contains { offset in
                units[offset] == 0x5B && !line.listMarkers.contains { $0.checkbox?.range.location == offset && $0.checkbox?.isChecked == false }
                    && !line.tokens.contains { token in
                        switch token.kind {
                        case .code, .html, .escape: NSLocationInRange(offset, token.range)
                        case .link: token.range.location == offset
                        case .image: token.range.location + 1 == offset
                        default: false
                        }
                    }
            }
        }
    }

    /// The same for an edit inside one body row of a table that stands by itself: the row is
    /// parsed below the table's first two lines alone. While it comes out as a row of that table
    /// no other line can have changed, and a table of thousands of rows is not parsed for a key
    /// in one of them. Nil when it is not that simple.
    private static func restyleRow(
        _ map: inout StyleMap, at index: Int, in text: NSString, editedRange: NSRange, changeInLength delta: Int
    ) -> LineDiff? {
        let row = map.lines[index]
        guard row.kind == .tableRow(isHeader: false), row.containers.isEmpty, let table = map.table(atLine: index) else { return nil }
        let header = map.lines[table.lines.lowerBound], delimiter = map.lines[table.lines.lowerBound + 1]
        // Not a table whose first row ends a paragraph: the parser places that one by the paragraph.
        guard header.containers.isEmpty, table.lines.lowerBound == 0 || map.lines[table.lines.lowerBound - 1].kind == .blank else { return nil }
        // The row's line now, if it still is one line. The range reported for a typed character
        // can be the whole line, so what the edit did to the line break is read from the text.
        let range = NSRange(location: row.range.location, length: row.range.length + delta)
        guard editedRange.location >= range.location, NSMaxRange(editedRange) <= NSMaxRange(range), isOneLine(range, of: text) else { return nil }
        let source = text.substring(with: NSUnionRange(header.range, delimiter.range)) + text.substring(with: range)
        let part = build(source: source, document: Document(parsing: source), isWhole: false).map
        guard part.lines.count == 3, part.tables == [TableStyle(lines: 0..<3, alignments: table.alignments)],
              part.lines[2].kind == row.kind, !part.hasReferences, !row.mayDefineReference,
              !(map.hasReferences && mayRefer([part.lines[2]], in: source)) else { return nil }
        let style = part.lines[2].shifted(by: range.location - header.range.length - delimiter.range.length)
        guard style != row else { return LineDiff(old: index..<index, new: index..<index) }
        map.lines[index] = style
        if delta != 0 { for line in index + 1..<map.lines.count { map.lines[line].shift(by: delta) } }
        // As `diff` has it: the columns' geometry is shared by all rows.
        return LineDiff(old: table.lines, new: table.lines, changed: index..<index + 1)
    }
}

extension MarkdownStyler {
    /// Whether `range` of `text` is one line with its line break, or the text's last line without one.
    private static func isOneLine(_ range: NSRange, of text: NSString) -> Bool {
        let end = NSMaxRange(range)
        let breaks = (range.location..<end).filter { [0x0A, 0x0D].contains(text.character(at: $0)) }
        switch breaks.count {
        case 0: return end == text.length
        case 1: return breaks[0] == end - 1 && (text.character(at: end - 1) == 0x0A || end == text.length || text.character(at: end) != 0x0A)
        case 2: return breaks[0] == end - 2 && text.character(at: end - 2) == 0x0D && text.character(at: end - 1) == 0x0A
        default: return false
        }
    }

    /// The same for an edit in the text of a list item that is one line: a line that starts an
    /// item and holds a paragraph, with a blank line, another item's first line or nothing below
    /// it. Its markers are left alone by an edit behind them, so it stays the item it was in the
    /// list it was in, and while its text alone still reads as one line of paragraph, which the
    /// line below cannot continue, no other line has changed: only its inline styles are new.
    /// MEASURED: a key in a list of 2,400 items (74 KB) parsed the list, 23 ms.
    ///
    /// `editedRange` must not be narrower than the edit; one that is wider, as the text storage
    /// reports for a typed character, is refused where it reaches the markers.
    private static func restyleItem(
        _ map: inout StyleMap, at index: Int, in text: NSString, editedRange: NSRange, changeInLength delta: Int
    ) -> LineDiff? {
        let item = map.lines[index], start = NSMaxRange(item.prefixRange)
        let range = NSRange(location: item.range.location, length: item.range.length + delta)
        guard item.kind == .paragraph, let marker = item.listMarkers.last, !item.mayDefineReference,
              editedRange.location >= start, NSMaxRange(editedRange) <= NSMaxRange(range), start < NSMaxRange(range),
              isOneLine(range, of: text) else { return nil }
        if index + 1 < map.lines.count {
            let below = map.lines[index + 1]
            guard below.kind == .blank || !below.listMarkers.isEmpty else { return nil }
        }
        // What would no longer be the item's text: blanks, which belong to the marker, a
        // checkbox, and a byte order mark, which the parser drops at the start of what it is given.
        let first = text.character(at: start)
        guard ![0x20, 0x09, 0xFEFF].contains(first), first != 0x5B || marker.checkbox != nil else { return nil }
        guard !mayDefineReference(ArraySlice(text.substring(with: range).utf16)) else { return nil }
        let source = text.substring(with: NSRange(location: start, length: NSMaxRange(range) - start))
        // With its marker, "- --" is a rule.
        guard source.unicodeScalars.contains(where: { !"-*_ \t\r\n".unicodeScalars.contains($0) }) else { return nil }
        // A line with a range of the parser's that does not check out comes out plain, markers and all.
        let (part, inconsistent) = build(source: source, document: Document(parsing: source), isWhole: false)
        guard inconsistent.isEmpty, part.lines.count == 1, let line = part.lines.first, line.kind == .paragraph, line.containers.isEmpty,
              line.prefixRange.length == 0, !part.hasReferences, !(map.hasReferences && mayRefer([line], in: source)) else { return nil }
        var style = item
        style.range = range
        style.tokens = line.shifted(by: start).tokens
        guard style != item else { return LineDiff(old: index..<index, new: index..<index) }
        map.lines[index] = style
        if delta != 0 { for line in index + 1..<map.lines.count { map.lines[line].shift(by: delta) } }
        return LineDiff(old: index..<index + 1, new: index..<index + 1)
    }
}

extension StyleMap {
    /// Whether every block above the line at `index` has ended there, lists apart: the line
    /// above is blank, and the last line with text is one that a blank line ends. A blank line
    /// alone does not say it: one can be inside a fence or an HTML block, whose lines are code and
    /// source (the parser's range of an HTML block can stop short of its end, but what it leaves
    /// out shows as source or blank too).
    func endsBlocks(above index: Int) -> Bool {
        func isBlank(_ line: Int) -> Bool { lines[line].kind == .blank && lines[line].containers.isEmpty }
        guard index > 0, isBlank(index - 1) else { return false }
        guard let text = (0..<index - 1).last(where: { !isBlank($0) }) else { return true }
        switch lines[text].kind {
        case .paragraph, .heading, .headingUnderline, .tableRow, .tableDelimiter, .rule, .codeFence(_, isClosing: true): return true
        default: return false
        }
    }
}
